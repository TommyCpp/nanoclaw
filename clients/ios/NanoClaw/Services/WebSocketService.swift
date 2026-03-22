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
    @Published var messages: [Message] = []
    @Published var isStreaming = false
    @Published var tasks: [ScheduledTask] = []
    @Published var isLoadingTasks = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?
    private var currentStreamingMessageID: UUID?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var connectionGeneration = 0


    init() {
        loadMessages()
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
        currentStreamingMessageID = nil
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
        currentStreamingMessageID = nil
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

    func send(_ text: String) {
        guard connectionState.isConnected else { return }

        let userMessage = Message(role: .user, text: text)
        messages.append(userMessage)
        saveMessages()

        let payload: [String: String] = ["type": "message", "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else { return }

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
            .appendingPathComponent("messages.json")
    }

    private func loadMessages() {
        guard let data = try? Data(contentsOf: Self.messagesFileURL),
              let saved = try? JSONDecoder().decode([Message].self, from: data)
        else { return }
        messages = saved
    }

    private func saveMessages() {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: Self.messagesFileURL, options: .atomic)
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
            if let pending = json["pending"] as? Int, pending > 0 {
                isStreaming = true // show typing indicator while buffered messages arrive
            }

        case "token":
            guard let tokenText = json["text"] as? String else { return }
            appendToken(tokenText)

        case "done":
            isStreaming = false
            currentStreamingMessageID = nil
            saveMessages()

        case "error":
            let errorMsg = json["message"] as? String ?? "Unknown error"
            isStreaming = false
            currentStreamingMessageID = nil
            let errorMessage = Message(role: .assistant, text: "Error: \(errorMsg)")
            messages.append(errorMessage)

        case "pong":
            break // heartbeat acknowledged

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

    private func appendToken(_ token: String) {
        if let id = currentStreamingMessageID,
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text += token
        } else {
            let newMessage = Message(role: .assistant, text: token)
            currentStreamingMessageID = newMessage.id
            messages.append(newMessage)
        }
        saveMessages()
    }

    private func handleDisconnect(error: Error) {
        stopPingTimer()
        webSocketTask = nil
        isStreaming = false
        currentStreamingMessageID = nil
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
