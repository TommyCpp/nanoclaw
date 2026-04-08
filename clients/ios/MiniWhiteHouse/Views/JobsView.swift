import SwiftUI

struct JobsView: View {
    @EnvironmentObject private var webSocket: WebSocketService

    var body: some View {
        NavigationStack {
            Group {
                if webSocket.tasks.isEmpty && !webSocket.isLoadingTasks {
                    emptyState
                } else {
                    List(webSocket.tasks) { task in
                        TaskRow(task: task)
                            .listRowBackground(Color(hex: 0x151515))
                            .listRowSeparatorTint(Color(hex: 0x1A1A1A))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable {
                        webSocket.requestTasks()
                    }
                }
            }
            .background(Color(hex: 0x0D0D0D))
            .navigationTitle("Executive Orders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(hex: 0x111111), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .onAppear {
            if webSocket.connectionState.isConnected {
                webSocket.requestTasks()
            }
        }
        .onChange(of: webSocket.connectionState) { _, newState in
            if newState.isConnected && webSocket.tasks.isEmpty {
                webSocket.requestTasks()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.badge.xmark")
                .font(.system(size: 48))
                .foregroundStyle(Color(hex: 0x333333))
            Text("No Executive Orders")
                .font(.headline)
                .foregroundStyle(Color(hex: 0x666666))
            Text("Scheduled tasks will appear here.")
                .font(.caption)
                .foregroundStyle(Color(hex: 0x444444))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - TaskRow

private struct TaskRow: View {
    let task: ScheduledTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(task.prompt)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatusBadge(status: task.status)
            }

            HStack(spacing: 12) {
                Label(scheduleLabel, systemImage: scheduleIcon)
                    .font(.caption)
                    .foregroundStyle(Color(hex: 0x666666))

                if let next = task.nextRun {
                    Label(relativeTime(next), systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(Color(hex: 0x555555))
                }
            }

            if let last = task.lastRun {
                Text("Last run \(relativeTime(last))")
                    .font(.caption2)
                    .foregroundStyle(Color(hex: 0x444444))
            }

            if let result = task.lastResult, !result.isEmpty {
                Text(result)
                    .font(.caption2)
                    .foregroundStyle(Color(hex: 0x555555))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 6)
    }

    private var scheduleLabel: String {
        switch task.scheduleType {
        case .cron: return task.scheduleValue
        case .interval: return "Every \(task.scheduleValue)"
        case .once: return "Once"
        }
    }

    private var scheduleIcon: String {
        switch task.scheduleType {
        case .cron: return "calendar.badge.clock"
        case .interval: return "repeat"
        case .once: return "1.circle"
        }
    }

    private func relativeTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
            return iso
        }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - StatusBadge

private struct StatusBadge: View {
    let status: ScheduledTask.TaskStatus

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    private var label: String {
        switch status {
        case .active: return "Active"
        case .paused: return "Paused"
        case .completed: return "Done"
        }
    }

    private var color: Color {
        switch status {
        case .active: return Color(hex: 0x6EE7B7)
        case .paused: return Color(hex: 0xFBBF24)
        case .completed: return Color(hex: 0x666666)
        }
    }
}
