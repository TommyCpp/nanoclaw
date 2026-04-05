import SwiftUI

struct ChannelListView: View {
    @EnvironmentObject private var webSocket: WebSocketService
    @State private var showNewGroup = false
    @State private var newGroupId = ""
    @State private var newGroupName = ""

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
        .navigationTitle("Groups")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNewGroup = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!webSocket.connectionState.isConnected)
            }
        }
        .alert("New Group", isPresented: $showNewGroup) {
            TextField("Group ID (e.g. work)", text: $newGroupId)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("Display Name", text: $newGroupName)
            Button("Create") {
                let chatId = newGroupId.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !chatId.isEmpty else { return }
                webSocket.createChannel(chatId: chatId, name: name.isEmpty ? chatId : name)
                newGroupId = ""
                newGroupName = ""
            }
            Button("Cancel", role: .cancel) {
                newGroupId = ""
                newGroupName = ""
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
