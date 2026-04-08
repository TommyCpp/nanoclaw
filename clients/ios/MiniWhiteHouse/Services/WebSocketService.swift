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

@MainActor
final class WebSocketService: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var channels: [Channel] = []
    @Published var currentChatId: String = "main"
    @Published var isStreaming = false
    @Published var tasks: [ScheduledTask] = []
    @Published var isLoadingTasks = false
    @Published var unreadCounts: [String: Int] = [:]

    /// Per-channel messages keyed by chatId
    @Published var channelMessages: [String: [Message]] = [:]

    /// Convenience: messages for the current channel
    var messages: [Message] {
        get { channelMessages[currentChatId] ?? [] }
        set { channelMessages[currentChatId] = newValue }
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


    init() {
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

        case "token":
            guard let tokenText = json["text"] as? String else { return }
            let chatId = json["chatId"] as? String ?? "main"
            appendToken(tokenText, chatId: chatId)

        case "done":
            let chatId = json["chatId"] as? String ?? "main"
            streamingChannels.remove(chatId)
            currentStreamingMessageID[chatId] = nil
            if chatId == currentChatId {
                isStreaming = false
            }
            saveMessages()

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

    private func appendToken(_ token: String, chatId: String) {
        if let id = currentStreamingMessageID[chatId],
           var msgs = channelMessages[chatId],
           let index = msgs.firstIndex(where: { $0.id == id }) {
            msgs[index].text += token
            channelMessages[chatId] = msgs
        } else {
            let newMessage = Message(role: .assistant, text: token)
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
