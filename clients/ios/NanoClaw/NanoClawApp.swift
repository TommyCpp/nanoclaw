import SwiftUI

@main
struct NanoClawApp: App {
    @StateObject private var webSocketService = WebSocketService()

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environmentObject(webSocketService)
                .preferredColorScheme(.dark)
        }
    }
}
