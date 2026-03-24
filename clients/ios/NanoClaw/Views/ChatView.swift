import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var webSocket: WebSocketService
    @State private var inputText = ""
    @State private var showSettings = false
    @State private var isAtBottom = false
    @FocusState private var inputFocused: Bool

    private let bgColor = Color(hex: 0x111111)

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    messageList
                    quickActionBar
                    inputBar
                }
                if !isAtBottom && !webSocket.messages.isEmpty {
                    scrollToBottomButton
                }
            }
            .background(bgColor)
            .navigationTitle("NanoClaw")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(bgColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    connectionIndicator
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(.gray)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(webSocket)
            }
            .onAppear {
                if KeychainService.loadToken() == nil {
                    showSettings = true
                } else {
                    webSocket.connect()
                }
            }
        }
    }

    // MARK: - Subviews

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if webSocket.messages.isEmpty && !webSocket.isStreaming {
                    emptyState
                }

                LazyVStack(spacing: 12) {
                    ForEach(webSocket.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if webSocket.isStreaming && webSocket.messages.last?.role != .assistant {
                        TypingIndicator()
                            .id("typing")
                    }

                    Color.clear.frame(height: 1)
                        .id("bottomAnchor")
                        .onAppear { withAnimation(.easeInOut(duration: 0.2)) { isAtBottom = true } }
                        .onDisappear { withAnimation(.easeInOut(duration: 0.2)) { isAtBottom = false } }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .onAppear {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: webSocket.messages.count) {
                if isAtBottom {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if let lastId = webSocket.messages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        } else {
                            proxy.scrollTo("typing", anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: webSocket.messages.last?.text) {
                if isAtBottom {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(webSocket.messages.last?.id, anchor: .bottom)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .scrollToBottom)) { _ in
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            }
        }
    }

    private var scrollToBottomButton: some View {
        Button {
            NotificationCenter.default.post(name: .scrollToBottom, object: nil)
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color(hex: 0x3a3a3a))
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        }
        .padding(.bottom, 120)
        .transition(.scale(scale: 0.7).combined(with: .opacity))
    }

    // MARK: - Quick Actions

    private struct QuickAction {
        let label: String
        let icon: String
        let message: String
    }

    private let quickActions: [QuickAction] = [
        QuickAction(label: "What now", icon: "newspaper", message: "用中文告诉我过去一小时内最重要的3条新闻"),
        QuickAction(label: "CC Session", icon: "terminal", message: "/cc-session"),
    ]

    private var quickActionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickActions, id: \.label) { action in
                    Button {
                        webSocket.send(action.message)
                    } label: {
                        Label(action.label, systemImage: action.icon)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color(hex: 0x2E2E2E))
                            .clipShape(Capsule())
                    }
                    .disabled(!webSocket.connectionState.isConnected || webSocket.isStreaming)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(hex: 0x1A1A1A))
    }

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField("Message...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(hex: 0x222222))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .foregroundStyle(.white)
                .focused($inputFocused)

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend ? .purple : .gray.opacity(0.4))
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(hex: 0x1A1A1A))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(.gray.opacity(0.4))
            switch webSocket.connectionState {
            case .error(let msg):
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
                Button("Open Settings") {
                    showSettings = true
                }
                .font(.caption)
                .foregroundStyle(.purple)
            case .disconnected:
                Text("Not connected")
                    .font(.caption)
                    .foregroundStyle(.gray)
            default:
                Text("Connecting...")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectionIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)
            Text(indicatorLabel)
                .font(.caption2)
                .foregroundStyle(.gray)
        }
    }

    // MARK: - Helpers

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && webSocket.connectionState.isConnected
            && !webSocket.isStreaming
    }

    private var indicatorColor: Color {
        switch webSocket.connectionState {
        case .connected: .green
        case .connecting, .authenticating: .yellow
        case .disconnected: .gray
        case .error: .red
        }
    }

    private var indicatorLabel: String {
        switch webSocket.connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting..."
        case .authenticating: "Authenticating..."
        case .disconnected: "Disconnected"
        case .error: "Error"
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        webSocket.send(text)
    }
}

private extension Notification.Name {
    static let scrollToBottom = Notification.Name("scrollToBottom")
}

