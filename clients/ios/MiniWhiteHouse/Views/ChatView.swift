import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var webSocket: WebSocketService
    let chatId: String
    @State private var inputText = ""
    @State private var isAtBottom = false
    @State private var quickActions: [QuickAction] = QuickActionStore.load()
    @FocusState private var inputFocused: Bool

    private let bgColor = Color(hex: 0x0D0D0D)

    private var channelMessages: [Message] {
        webSocket.channelMessages[chatId] ?? []
    }

    private var channelName: String {
        webSocket.channels.first(where: { $0.chatId == chatId })?.name ?? chatId
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                messageList
                quickActionBar
                inputBar
            }
            if !isAtBottom && !channelMessages.isEmpty {
                scrollToBottomButton
            }
        }
        .background(bgColor)
        .navigationTitle(channelName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(hex: 0x111111), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                connectionIndicator
            }
        }
        .onAppear {
            webSocket.switchChannel(chatId)
            quickActions = QuickActionStore.load()
        }
        .onChange(of: chatId) {
            webSocket.switchChannel(chatId)
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if channelMessages.isEmpty && !webSocket.isStreaming {
                    emptyState
                }

                LazyVStack(spacing: 0) {
                    ForEach(Array(channelMessages.enumerated()), id: \.element.id) { index, message in
                        MessageRow(message: message)
                            .id(message.id)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)

                        if index < channelMessages.count - 1 {
                            Divider()
                                .background(
                                    LinearGradient(
                                        colors: [.clear, Color(hex: 0x222222), .clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .padding(.horizontal, 54)
                        }
                    }

                    if webSocket.isStreaming && channelMessages.last?.role != .assistant {
                        TypingIndicator()
                            .id("typing")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }

                    Color.clear.frame(height: 1)
                        .id("bottomAnchor")
                        .onAppear { withAnimation(.easeInOut(duration: 0.2)) { isAtBottom = true } }
                        .onDisappear { withAnimation(.easeInOut(duration: 0.2)) { isAtBottom = false } }
                }
                .padding(.vertical, 12)
                .onAppear {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: channelMessages.count) {
                if isAtBottom {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if let lastId = channelMessages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        } else {
                            proxy.scrollTo("typing", anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: channelMessages.last?.text) {
                if isAtBottom {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(channelMessages.last?.id, anchor: .bottom)
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

    // MARK: - Scroll to Bottom

    private var scrollToBottomButton: some View {
        Button {
            NotificationCenter.default.post(name: .scrollToBottom, object: nil)
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color(hex: 0x2A2A2A))
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(Color(hex: 0x3A3A3A), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        }
        .padding(.bottom, 120)
        .transition(.scale(scale: 0.7).combined(with: .opacity))
    }

    // MARK: - Quick Actions

    private var quickActionBar: some View {
        Group {
            if !quickActions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickActions) { action in
                            Button {
                                webSocket.send(action.message)
                            } label: {
                                Label(action.label, systemImage: action.icon)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color(hex: 0xA78BFA))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(Color(hex: 0x1A1A1A))
                                    .overlay(
                                        Capsule().stroke(Color(hex: 0x2A2A2A), lineWidth: 1)
                                    )
                                    .clipShape(Capsule())
                            }
                            .disabled(!webSocket.connectionState.isConnected || webSocket.isStreaming)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .background(Color(hex: 0x111111))
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundStyle(Color(hex: 0x1A1A1A)),
                    alignment: .top
                )
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Message...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(hex: 0x1A1A1A))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color(hex: 0x2A2A2A), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .foregroundStyle(.white)
                .focused($inputFocused)

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        canSend
                            ? LinearGradient(
                                colors: [Color(hex: 0x7C3AED), Color(hex: 0x6D28D9)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : LinearGradient(
                                colors: [Color(hex: 0x2A2A2A), Color(hex: 0x2A2A2A)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                    )
                    .clipShape(Circle())
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(hex: 0x111111))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color(hex: 0x1A1A1A)),
            alignment: .top
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(Color(hex: 0x333333))
            switch webSocket.connectionState {
            case .error(let msg):
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
            case .disconnected:
                Text("Not connected")
                    .font(.caption)
                    .foregroundStyle(.gray)
            default:
                Text("Start a conversation")
                    .font(.caption)
                    .foregroundStyle(Color(hex: 0x555555))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Connection Indicator

    private var connectionIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 7, height: 7)
            Text(indicatorLabel)
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0x666666))
                .fixedSize()
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
        case .connected: Color(hex: 0x6EE7B7)
        case .connecting, .authenticating: .yellow
        case .disconnected: Color(hex: 0x555555)
        case .error: .red
        }
    }

    private var indicatorLabel: String {
        switch webSocket.connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting..."
        case .authenticating: "Auth..."
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
