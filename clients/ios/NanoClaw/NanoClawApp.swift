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
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active && oldPhase == .background {
                webSocketService.reconnect()
            }
        }
    }
}
