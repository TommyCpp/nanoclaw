import Foundation
import Combine

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case error(String)

    var isConnected: Bool {
        self == .connected
    }
}

/// Agent activity reported by the host in sync_response.state.
/// - idle: nothing queued, no container running
/// - queued: messages queued but container not yet producing output
/// - running: container alive and producing output
/// - stalled: container alive but silent >10s (likely stuck)
enum AgentState: String, Equatable {
    case idle
    case queued
    case running
    case stalled

    /// True when the user should see a "working" indicator.
    var isBusy: Bool {
        self == .queued || self == .running || self == .stalled
    }
}

@MainActor
final class WebSocketService: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var channels: [Channel] = []
    @Published var currentChatId: String = "main"
    @Published var isStreaming = false
    @Published var tasks: [ScheduledTask] = []
    @Published var isLoadingTasks = false
    @Published var unreadCounts: [String: Int] = [:]
    /// Per-channel agent state as reported by the host via sync_response.
    /// Defaults to .idle until the first sync comes back.
    @Published var agentStates: [String: AgentState] = [:]

    /// Per-channel messages keyed by chatId
    @Published var channelMessages: [String: [Message]] = [:]

    /// Convenience: messages for the current channel
    var messages: [Message] {
        get { channelMessages[currentChatId] ?? [] }
        set { channelMessages[currentChatId] = newValue }
    }

    /// Agent state for the current channel.
    var currentAgentState: AgentState {
        agentStates[currentChatId] ?? .idle
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?
    /// Per-channel streaming message ID
    private var currentStreamingMessageID: [String: UUID] = [:]
    /// Per-channel streaming state
    private var streamingChannels: Set<String> = []
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var connectionGeneration = 0
    /// Highest server seq seen per chat, persisted to UserDefaults.
    /// Used to drive sync requests — on reconnect we ask the host
    /// "give me everything after <lastSeqByChatId[chatId]>".
    private var lastSeqByChatId: [String: Int] = [:]
    private static let lastSeqDefaultsKey = "ios_channel.lastSeqByChatId"


    init() {
        loadLastSeq()
        loadMessages()
        loadChannels()
    }

    func connect() {
        guard connectionState != .connecting && connectionState != .authenticating else { return }

        connectionGeneration += 1

        let config = ConnectionConfig()
        guard let url = config.webSocketURL else {
            connectionState = .error("Invalid URL")
            return
        }
        guard let token = KeychainService.loadToken(), !token.isEmpty else {
            connectionState = .error("No auth token configured")
            return
        }

        connectionState = .connecting
        let urlSession = URLSession(configuration: .default)
        session = urlSession
        let task = urlSession.webSocketTask(with: url)
        webSocketTask = task
        task.resume()

        authenticate(token: token, generation: connectionGeneration)
    }


    /// Reconnect if not already connected or connecting. Resets error state.
    func connectIfNeeded() {
        switch connectionState {
        case .connected, .connecting, .authenticating:
            return
        case .disconnected, .error:
            reconnectAttempts = 0
            connect()
        }
    }


    /// Force disconnect and reconnect — used when returning from background
    /// where the socket may be silently dead.
    func reconnect() {
        stopPingTimer()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        connectionState = .disconnected
        isStreaming = false
        streamingChannels.removeAll()
        currentStreamingMessageID.removeAll()
        reconnectAttempts = 0
        connect()
    }

    func disconnect() {
        stopPingTimer()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        connectionState = .disconnected
        isStreaming = false
        streamingChannels.removeAll()
        currentStreamingMessageID.removeAll()
        reconnectAttempts = 0
    }

    func requestTasks() {
        guard connectionState.isConnected else { return }
        isLoadingTasks = true
        let payload: [String: String] = ["type": "list_tasks"]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(jsonString)) { _ in }
    }

    func requestChannels() {
        guard connectionState.isConnected else { return }
        let payload: [String: String] = ["type": "list_channels"]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(jsonString)) { _ in }
    }

    func createChannel(chatId: String, name: String) {
        guard connectionState.isConnected else { return }
        let payload: [String: Any] = ["type": "create_channel", "chatId": chatId, "name": name]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(jsonString)) { _ in }
    }

    func clearHistory(chatId: String? = nil) {
        if let chatId {
            channelMessages[chatId] = []
        } else {
            channelMessages.removeAll()
        }
        saveMessages()
    }

    func switchChannel(_ chatId: String) {
        currentChatId = chatId
        unreadCounts[chatId] = 0
        // Update isStreaming to reflect current channel's state
        isStreaming = streamingChannels.contains(chatId)
        // Force SwiftUI to re-evaluate channelMessages for this chatId
        objectWillChange.send()
    }

    func send(_ text: String) {
        guard connectionState.isConnected else { return }

        let userMessage = Message(role: .user, text: text)
        var msgs = channelMessages[currentChatId] ?? []
        msgs.append(userMessage)
        channelMessages[currentChatId] = msgs
        saveMessages()

        let payload: [String: String] = ["type": "message", "text": text, "chatId": currentChatId]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else { return }

        streamingChannels.insert(currentChatId)
        isStreaming = true

        webSocketTask?.send(.string(jsonString)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.handleError("Send failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// One-shot connection test. Returns nil on success or an error string.
    func testConnection() async -> String? {
        let config = ConnectionConfig()
        guard let url = config.webSocketURL else {
            return "Invalid URL"
        }
        guard let token = KeychainService.loadToken(), !token.isEmpty else {
            return "No auth token configured"
        }

        let testSession = URLSession(configuration: .default)
        let task = testSession.webSocketTask(with: url)
        task.resume()

        // Send auth frame
        let authPayload: [String: String] = ["auth": token]
        guard let data = try? JSONSerialization.data(withJSONObject: authPayload),
              let jsonString = String(data: data, encoding: .utf8) else {
            task.cancel(with: .normalClosure, reason: nil)
            testSession.invalidateAndCancel()
            return "Failed to encode auth payload"
        }

        do {
            try await task.send(.string(jsonString))
        } catch {
            task.cancel(with: .normalClosure, reason: nil)
            testSession.invalidateAndCancel()
            return "Failed to connect: \(error.localizedDescription)"
        }

        // Wait for auth_ok
        do {
            let message = try await task.receive()
            task.cancel(with: .normalClosure, reason: nil)
            testSession.invalidateAndCancel()

            switch message {
            case .string(let text):
                if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                   let type = obj["type"] as? String, type == "auth_ok" {
                    return nil // success
                } else {
                    return "Unexpected response: \(text)"
                }
            case .data:
                return "Unexpected binary response"
            @unknown default:
                return "Unknown response type"
            }
        } catch {
            task.cancel(with: .normalClosure, reason: nil)
            testSession.invalidateAndCancel()
            return "No response: \(error.localizedDescription)"
        }
    }


    // MARK: - Persistence

    private static var messagesFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("channel_messages.json")
    }

    private static var channelsFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("channels.json")
    }

    /// Legacy single-channel file for migration
    private static var legacyMessagesFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("messages.json")
    }

    private func loadMessages() {
        // Try new per-channel format first
        if let data = try? Data(contentsOf: Self.messagesFileURL),
           let saved = try? JSONDecoder().decode([String: [Message]].self, from: data) {
            channelMessages = saved
            return
        }
        // Migrate from legacy single-channel format
        if let data = try? Data(contentsOf: Self.legacyMessagesFileURL),
           let saved = try? JSONDecoder().decode([Message].self, from: data) {
            channelMessages["main"] = saved
            saveMessages()
            // Remove legacy file after migration
            try? FileManager.default.removeItem(at: Self.legacyMessagesFileURL)
        }
    }

    private func saveMessages() {
        guard let data = try? JSONEncoder().encode(channelMessages) else { return }
        try? data.write(to: Self.messagesFileURL, options: .atomic)
    }

    private func loadChannels() {
        guard let data = try? Data(contentsOf: Self.channelsFileURL),
              let saved = try? JSONDecoder().decode([Channel].self, from: data)
        else { return }
        channels = saved
    }

    private func saveChannels() {
        guard let data = try? JSONEncoder().encode(channels) else { return }
        try? data.write(to: Self.channelsFileURL, options: .atomic)
    }

    private func loadLastSeq() {
        if let dict = UserDefaults.standard.dictionary(forKey: Self.lastSeqDefaultsKey)
            as? [String: Int]
        {
            lastSeqByChatId = dict
        }
    }

    private func saveLastSeq() {
        UserDefaults.standard.set(lastSeqByChatId, forKey: Self.lastSeqDefaultsKey)
    }

    // MARK: - Resync

    /// Send a `sync` request for a given chat. Response handled in
    /// handleTextMessage under "sync_response".
    func requestSync(chatId: String) {
        guard connectionState.isConnected else { return }
        let sinceSeq = lastSeqByChatId[chatId] ?? 0
        let payload: [String: Any] = [
            "type": "sync",
            "chatId": chatId,
            "sinceSeq": sinceSeq,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(jsonString)) { _ in }
    }

    /// Sync every known channel. Called after auth_ok.
    private func syncAllChannels() {
        // Always sync "main" (the default chat) plus every channel we know about.
        var seen: Set<String> = ["main"]
        requestSync(chatId: "main")
        for channel in channels where !seen.contains(channel.chatId) {
            requestSync(chatId: channel.chatId)
            seen.insert(channel.chatId)
        }
        // Also sync any chats we have seq records for but no channel metadata
        // yet (edge case: UserDefaults has state the server hasn't told us about
        // via list_channels yet).
        for chatId in lastSeqByChatId.keys where !seen.contains(chatId) {
            requestSync(chatId: chatId)
            seen.insert(chatId)
        }
    }

    /// Ingest a sync_response frame.
    private func handleSyncResponse(_ json: [String: Any]) {
        guard let chatId = json["chatId"] as? String else { return }
        let lastSeq = json["lastSeq"] as? Int ?? 0
        if let stateStr = json["state"] as? String,
           let state = AgentState(rawValue: stateStr)
        {
            agentStates[chatId] = state
            if chatId == currentChatId {
                // isStreaming stays tied to the running/queued/stalled states.
                isStreaming = state.isBusy
            }
        }

        // If the server reports fewer messages than we have tracked locally,
        // the DB was reset. Drop local seq to 0 and accept whatever the server
        // returns as the new truth.
        if lastSeq < (lastSeqByChatId[chatId] ?? 0) {
            print("iOS: sync detected seq regression for \(chatId); resetting local lastSeq")
            lastSeqByChatId[chatId] = 0
        }

        guard let messages = json["messages"] as? [[String: Any]] else {
            saveLastSeq()
            return
        }

        var msgs = channelMessages[chatId] ?? []
        let existingSeqs = Set(msgs.compactMap { $0.serverSeq })
        var appended = false

        for entry in messages {
            guard let seq = entry["seq"] as? Int,
                  let text = entry["text"] as? String
            else { continue }
            if existingSeqs.contains(seq) { continue }
            let createdAtMs = entry["createdAt"] as? Double
            let timestamp =
                createdAtMs.map { Date(timeIntervalSince1970: $0 / 1000.0) } ?? .now
            msgs.append(
                Message(role: .assistant, text: text, timestamp: timestamp, serverSeq: seq))
            appended = true
        }

        if appended {
            channelMessages[chatId] = msgs
            saveMessages()
            if chatId != currentChatId {
                // Bump unread count by the number we just added for non-active chat
                unreadCounts[chatId, default: 0] += messages.count
            }
        }

        // Always advance the tracked seq — even when messages is empty, this
        // is how a pure state-poll sync works.
        if lastSeq > (lastSeqByChatId[chatId] ?? 0) {
            lastSeqByChatId[chatId] = lastSeq
            saveLastSeq()
        }
    }

    // MARK: - Private

    private func authenticate(token: String, generation: Int) {
        connectionState = .authenticating

        let payload: [String: String] = ["auth": token]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else {
            connectionState = .error("Failed to encode auth")
            return
        }

        webSocketTask?.send(.string(jsonString)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.connectionState = .error("Auth send failed: \(error.localizedDescription)")
                }
            }
        }

        receiveMessages(generation: generation)
    }

    private func receiveMessages(generation: Int) {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.connectionGeneration == generation else { return }

                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleTextMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleTextMessage(text)
                        }
                    @unknown default:
                        break
                    }
                    // Continue listening
                    self.receiveMessages(generation: generation)

                case .failure(let error):
                    if self.connectionState.isConnected || self.connectionState == .authenticating {
                        self.handleDisconnect(error: error)
                    }
                }
            }
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "auth_ok":
            connectionState = .connected
            reconnectAttempts = 0
            startPingTimer()
            // Fetch channel list on connect
            requestChannels()
            if let pending = json["pending"] as? Int, pending > 0 {
                isStreaming = true
            }
            // Resync every known chat. This catches messages that were lost
            // to WebSocket races or that the host generated while the app
            // was in the background, and refreshes agent state display.
            syncAllChannels()

        case "token":
            guard let tokenText = json["text"] as? String else { return }
            let chatId = json["chatId"] as? String ?? "main"
            let seq = json["seq"] as? Int
            appendToken(tokenText, chatId: chatId, seq: seq)
            if let seq, seq > (lastSeqByChatId[chatId] ?? 0) {
                lastSeqByChatId[chatId] = seq
                saveLastSeq()
            }

        case "done":
            let chatId = json["chatId"] as? String ?? "main"
            streamingChannels.remove(chatId)
            currentStreamingMessageID[chatId] = nil
            if chatId == currentChatId {
                isStreaming = false
            }
            if let seq = json["seq"] as? Int,
               seq > (lastSeqByChatId[chatId] ?? 0)
            {
                lastSeqByChatId[chatId] = seq
                saveLastSeq()
            }
            saveMessages()

        case "sync_response":
            handleSyncResponse(json)

        case "typing":
            // Typing indicators are per-channel but we only show for current
            let chatId = json["chatId"] as? String ?? "main"
            if chatId == currentChatId {
                // The existing isStreaming flag already handles this
            }

        case "error":
            let errorMsg = json["message"] as? String ?? "Unknown error"
            let chatId = json["chatId"] as? String ?? currentChatId
            streamingChannels.remove(chatId)
            currentStreamingMessageID[chatId] = nil
            if chatId == currentChatId {
                isStreaming = false
            }
            let errorMessage = Message(role: .assistant, text: "Error: \(errorMsg)")
            var msgs = channelMessages[chatId] ?? []
            msgs.append(errorMessage)
            channelMessages[chatId] = msgs

        case "pong":
            break // heartbeat acknowledged

        case "channels":
            if let channelsArray = json["channels"] as? [[String: Any]] {
                channels = channelsArray.compactMap { dict in
                    guard let chatId = dict["chatId"] as? String,
                          let name = dict["name"] as? String,
                          let folder = dict["folder"] as? String else { return nil }
                    let isMain = dict["isMain"] as? Bool ?? false
                    return Channel(chatId: chatId, name: name, folder: folder, isMain: isMain)
                }
                saveChannels()
            }

        case "channel_created":
            if let chatId = json["chatId"] as? String,
               let name = json["name"] as? String,
               let folder = json["folder"] as? String {
                let channel = Channel(chatId: chatId, name: name, folder: folder, isMain: false)
                if !channels.contains(where: { $0.chatId == chatId }) {
                    channels.append(channel)
                    saveChannels()
                }
            }

        case "tasks":
            isLoadingTasks = false
            let decoder = JSONDecoder()
            if let tasksData = text.data(using: .utf8),
               let envelope = try? JSONSerialization.jsonObject(with: tasksData) as? [String: Any],
               let tasksArray = envelope["tasks"],
               let tasksJSON = try? JSONSerialization.data(withJSONObject: tasksArray) {
                tasks = (try? decoder.decode([ScheduledTask].self, from: tasksJSON)) ?? []
            }

        default:
            break
        }
    }

    private func appendToken(_ token: String, chatId: String, seq: Int? = nil) {
        // Sync-delivered messages are deduped by serverSeq; make sure a token
        // that arrives via the live stream also gets tagged so a later sync
        // for the same chat won't produce a duplicate bubble.
        if let id = currentStreamingMessageID[chatId],
           var msgs = channelMessages[chatId],
           let index = msgs.firstIndex(where: { $0.id == id }) {
            msgs[index].text += token
            if let seq, msgs[index].serverSeq == nil {
                msgs[index].serverSeq = seq
            }
            channelMessages[chatId] = msgs
        } else {
            // Guard: if we already have a message with this seq (delivered via
            // sync a moment ago), don't create a duplicate bubble.
            if let seq,
               let existing = channelMessages[chatId],
               existing.contains(where: { $0.serverSeq == seq })
            {
                return
            }
            let newMessage = Message(role: .assistant, text: token, serverSeq: seq)
            currentStreamingMessageID[chatId] = newMessage.id
            var msgs = channelMessages[chatId] ?? []
            msgs.append(newMessage)
            channelMessages[chatId] = msgs
        }
        streamingChannels.insert(chatId)
        if chatId == currentChatId {
            isStreaming = true
        } else {
            unreadCounts[chatId, default: 0] += 1
        }
        saveMessages()
    }

    private func handleDisconnect(error: Error) {
        stopPingTimer()
        webSocketTask = nil
        isStreaming = false
        streamingChannels.removeAll()
        currentStreamingMessageID.removeAll()
        connectionState = .disconnected

        guard reconnectAttempts < maxReconnectAttempts else {
            connectionState = .error("Disconnected: \(error.localizedDescription)")
            return
        }
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts)), 30.0)
        Task {
            try? await Task.sleep(for: .seconds(delay))
            self.connect()
        }
    }

    private func handleError(_ message: String) {
        connectionState = .error(message)
        isStreaming = false
    }

    private func startPingTimer() {
        stopPingTimer()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendPing()
            }
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func sendPing() {
        guard connectionState.isConnected else { return }

        let payload: [String: String] = ["type": "ping"]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else { return }

        webSocketTask?.send(.string(jsonString)) { _ in }
    }
}
