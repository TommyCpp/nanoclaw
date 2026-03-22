import SwiftUI

@main
struct NanoClawApp: App {
    @StateObject private var webSocketService = WebSocketService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                ChatView()
                    .tabItem {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    }
                JobsView()
                    .tabItem {
                        Label("Jobs", systemImage: "clock")
                    }
            }
            .tint(.purple)
            .environmentObject(webSocketService)
            .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active && oldPhase == .background {
                webSocketService.reconnect()
            }
        }
    }
}
