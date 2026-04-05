import SwiftUI

struct ChannelListView: View {
    @EnvironmentObject private var webSocket: WebSocketService
    @State private var showNewChannel = false
    @State private var newChatId = ""
    @State private var newChannelName = ""

    var body: some View {
        List {
            if webSocket.channels.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        if webSocket.connectionState.isConnected {
                            ProgressView()
                                .padding(.vertical, 20)
                        } else {
                            Text("Connect to see channels")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 20)
                        }
                        Spacer()
                    }
                }
            } else {
                Section {
                    ForEach(webSocket.channels) { channel in
                        NavigationLink(value: channel.chatId) {
                            ChannelRow(channel: channel, hasUnread: false)
                        }
                    }
                }
            }
        }
        .navigationTitle("Channels")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNewChannel = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!webSocket.connectionState.isConnected)
            }
        }
        .alert("New Channel", isPresented: $showNewChannel) {
            TextField("Channel ID (e.g. work)", text: $newChatId)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("Display Name", text: $newChannelName)
            Button("Create") {
                let chatId = newChatId.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = newChannelName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !chatId.isEmpty else { return }
                webSocket.createChannel(chatId: chatId, name: name.isEmpty ? chatId : name)
                newChatId = ""
                newChannelName = ""
            }
            Button("Cancel", role: .cancel) {
                newChatId = ""
                newChannelName = ""
            }
        }
    }
}

private struct ChannelRow: View {
    let channel: Channel
    let hasUnread: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: channel.isMain ? "star.fill" : "number")
                .foregroundStyle(channel.isMain ? .yellow : .gray)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .fontWeight(hasUnread ? .semibold : .regular)
                Text(channel.chatId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
