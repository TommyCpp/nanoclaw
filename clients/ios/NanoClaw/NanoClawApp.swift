import SwiftUI

@main
struct NanoClawApp: App {
    @StateObject private var webSocketService = WebSocketService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environmentObject(webSocketService)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                webSocketService.reconnect()
            }
        }
    }
}
