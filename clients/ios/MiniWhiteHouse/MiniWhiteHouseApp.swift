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
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    showSettings = true
                                } label: {
                                    Image(systemName: "gearshape")
                                        .font(.system(size: 15))
                                        .foregroundStyle(Color(hex: 0x666666))
                                }
                            }
                        }
                        .toolbarBackground(Color(hex: 0x111111), for: .navigationBar)
                        .toolbarBackground(.visible, for: .navigationBar)
                }
                .tabItem {
                    Label("Cabinet", systemImage: "building.columns")
                }
                JobsView()
                    .tabItem {
                        Label("Orders", systemImage: "doc.text")
                    }
            }
            .tint(Color(hex: 0xA78BFA))
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(webSocketService)
            }
            .environmentObject(webSocketService)
            .preferredColorScheme(.dark)
            .onAppear {
                configureTabBarAppearance()
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

    private func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Color(hex: 0x111111))
        appearance.stackedLayoutAppearance.normal.iconColor = UIColor(Color(hex: 0x555555))
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor(Color(hex: 0x555555))]
        appearance.stackedLayoutAppearance.selected.iconColor = UIColor(Color(hex: 0xA78BFA))
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor(Color(hex: 0xA78BFA))]
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}
