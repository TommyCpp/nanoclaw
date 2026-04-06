import SwiftUI

struct ChannelListView: View {
    @EnvironmentObject private var webSocket: WebSocketService
    @State private var showNewDepartment = false

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
                            Text("Connect to see departments")
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
        .navigationTitle("The Cabinet")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNewDepartment = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!webSocket.connectionState.isConnected)
            }
        }
        .sheet(isPresented: $showNewDepartment) {
            NewDepartmentView { chatId, name in
                webSocket.createChannel(chatId: chatId, name: name)
            }
        }
    }
}

private struct ChannelRow: View {
    let channel: Channel
    let hasUnread: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: channel.isMain ? "star.fill" : "building.2")
                .foregroundStyle(channel.isMain ? .yellow : .gray)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .fontWeight(hasUnread ? .semibold : .regular)
                Text(channel.isMain ? "Chief of Staff" : channel.chatId)
                    .font(.caption)
                    .foregroundStyle(channel.isMain ? .yellow.opacity(0.7) : .secondary)
            }
        }
    }
}
