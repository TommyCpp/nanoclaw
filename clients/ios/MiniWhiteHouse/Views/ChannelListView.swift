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
                                .tint(Color(hex: 0x7C3AED))
                                .padding(.vertical, 20)
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "wifi.slash")
                                    .font(.system(size: 28))
                                    .foregroundStyle(Color(hex: 0x333333))
                                Text("Connect to see departments")
                                    .foregroundStyle(Color(hex: 0x555555))
                                    .font(.subheadline)
                            }
                            .padding(.vertical, 20)
                        }
                        Spacer()
                    }
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(webSocket.channels) { channel in
                        NavigationLink(value: channel.chatId) {
                            ChannelRow(
                                channel: channel,
                                preview: previewFor(channel),
                                unreadCount: webSocket.unreadCounts[channel.chatId] ?? 0
                            )
                        }
                        .listRowBackground(Color(hex: 0x151515))
                        .listRowSeparatorTint(Color(hex: 0x1A1A1A))
                    }
                }
            }
        }
        .listStyle(.plain)
        .background(Color(hex: 0x0D0D0D))
        .scrollContentBackground(.hidden)
        .navigationTitle("The Cabinet")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNewDepartment = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: 0x7C3AED), Color(hex: 0x6D28D9)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(Circle())
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

    private func previewFor(_ channel: Channel) -> ChannelPreview? {
        guard let messages = webSocket.channelMessages[channel.chatId],
              let last = messages.last else { return nil }
        return ChannelPreview(
            lastMessage: last.text,
            timestamp: last.timestamp,
            unreadCount: webSocket.unreadCounts[channel.chatId] ?? 0
        )
    }
}

private struct ChannelRow: View {
    let channel: Channel
    let preview: ChannelPreview?
    let unreadCount: Int

    var body: some View {
        HStack(spacing: 12) {
            channelIcon
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(channel.name)
                        .font(.system(size: 15, weight: unreadCount > 0 ? .semibold : .regular))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    if let preview {
                        Text(relativeTime(preview.timestamp))
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: 0x555555))
                    }
                }
                HStack {
                    if let preview {
                        Text(preview.lastMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0x666666))
                            .lineLimit(1)
                    } else {
                        Text(channel.isMain ? "Chief of Staff" : channel.chatId)
                            .font(.system(size: 13))
                            .foregroundStyle(
                                channel.isMain ? Color(hex: 0x7C3AED).opacity(0.7) : Color(hex: 0x555555)
                            )
                    }
                    Spacer()
                    if unreadCount > 0 {
                        Text("\(unreadCount)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Color(hex: 0x7C3AED))
                            .clipShape(Circle())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var channelIcon: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(
                channel.isMain
                    ? LinearGradient(
                        colors: [Color(hex: 0x7C3AED).opacity(0.15), Color(hex: 0x5B21B6).opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    : LinearGradient(
                        colors: [Color(hex: 0x1A1A1A), Color(hex: 0x1A1A1A)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
            )
            .frame(width: 40, height: 40)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        channel.isMain ? Color(hex: 0x7C3AED).opacity(0.3) : Color(hex: 0x2A2A2A),
                        lineWidth: 1
                    )
            )
            .overlay(
                Image(systemName: channel.isMain ? "star.fill" : "building.2")
                    .font(.system(size: 16))
                    .foregroundStyle(channel.isMain ? Color(hex: 0xA78BFA) : Color(hex: 0x666666))
            )
    }

    private func relativeTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "E"
            return formatter.string(from: date)
        }
    }
}
