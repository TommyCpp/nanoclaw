import SwiftUI

@main
struct MiniWhiteHouseApp: App {
    @StateObject private var webSocketService = WebSocketService()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var navigationPath = NavigationPath()

    private var launchToMain: Bool {
        UserDefaults.standard.string(forKey: "launchScreen") == "main"
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack(path: $navigationPath) {
                    ChannelListView()
                        .navigationDestination(for: String.self) { chatId in
                            ChatView(chatId: chatId)
                        }
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    showSettings = true
                                } label: {
                                    Image(systemName: "seal")
                                        .foregroundStyle(.gray)
                                }
                            }
                        }
                }
                .tabItem {
                    Label("Cabinet", systemImage: "building.columns")
                }
                JobsView()
                    .tabItem {
                        Label("Executive Orders", systemImage: "doc.text")
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
                    if launchToMain {
                        navigationPath.append("main")
                    }
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
