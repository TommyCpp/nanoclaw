import SwiftUI

@main
struct NanoClawApp: App {
    @StateObject private var webSocketService = WebSocketService()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack {
                    ChannelListView()
                        .navigationDestination(for: String.self) { chatId in
                            ChatView(chatId: chatId)
                        }
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    showSettings = true
                                } label: {
                                    Image(systemName: "gearshape")
                                        .foregroundStyle(.gray)
                                }
                            }
                        }
                }
                .tabItem {
                    Label("Groups", systemImage: "bubble.left.and.bubble.right")
                }
                JobsView()
                    .tabItem {
                        Label("Jobs", systemImage: "clock")
                    }
            }
            .tint(.purple)
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(webSocketService)
            }
            .environmentObject(webSocketService)
            .preferredColorScheme(.dark)
            .onAppear {
                if KeychainService.loadToken() == nil {
                    showSettings = true
                } else {
                    webSocketService.connect()
                }
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active && oldPhase == .background {
                webSocketService.reconnect()
            }
        }
    }
}
