import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var webSocket: WebSocketService
    @Environment(\.dismiss) private var dismiss

    @State private var host: String
    @State private var portText: String
    @State private var token: String
    @State private var showToken = false
    @State private var testResult: TestResult?
    @State private var isTesting = false
    @State private var showClearConfirm = false
    @State private var showQuickActionsEditor = false
    @State private var showConnectionLog = false

    private enum TestResult {
        case success
        case failure(String)
    }

    init() {
        let config = ConnectionConfig()
        _host = State(initialValue: config.host)
        _portText = State(initialValue: String(config.port))
        _token = State(initialValue: KeychainService.loadToken() ?? "")
    }

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                authSection
                testSection
                quickActionsSection
                dataSection
                launchSection
                reconnectSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(hex: 0x0D0D0D))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(hex: 0x111111), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color(hex: 0xA78BFA))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        save()
                        webSocket.disconnect()
                        webSocket.connect()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(hex: 0xA78BFA))
                }
            }
            .sheet(isPresented: $showQuickActionsEditor) {
                QuickActionsEditorView()
            }
            .sheet(isPresented: $showConnectionLog) {
                ConnectionLogView()
                    .environmentObject(webSocket)
            }
        }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        Section {
            settingsRow(icon: "globe", iconColor: Color(hex: 0x6EE7B7)) {
                LabeledContent("Host") {
                    TextField("nanoclaw", text: $host)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .foregroundStyle(.white)
                }
            }
            settingsRow(icon: "network", iconColor: Color(hex: 0x93C5FD)) {
                LabeledContent("Port") {
                    TextField("8080", text: $portText)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .foregroundStyle(.white)
                }
            }
        } header: {
            sectionHeader("Connection")
        }
        .listRowBackground(Color(hex: 0x151515))
    }

    private var authSection: some View {
        Section {
            settingsRow(icon: "key.fill", iconColor: Color(hex: 0xFBBF24)) {
                HStack {
                    if showToken {
                        TextField("Auth token", text: $token)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .foregroundStyle(.white)
                    } else {
                        SecureField("Auth token", text: $token)
                            .foregroundStyle(.white)
                    }
                    Button {
                        showToken.toggle()
                    } label: {
                        Image(systemName: showToken ? "eye.slash" : "eye")
                            .foregroundStyle(Color(hex: 0x666666))
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            sectionHeader("Authentication")
        }
        .listRowBackground(Color(hex: 0x151515))
    }

    private var testSection: some View {
        Section {
            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: 0xA78BFA))
                        .frame(width: 28)
                    Text("Test Connection")
                        .foregroundStyle(.white)
                    Spacer()
                    if isTesting {
                        ProgressView()
                            .tint(Color(hex: 0x7C3AED))
                    } else if let result = testResult {
                        switch result {
                        case .success:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color(hex: 0x6EE7B7))
                        case .failure:
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .disabled(isTesting)

            if case .failure(let msg) = testResult {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
            }
        }
        .listRowBackground(Color(hex: 0x151515))
    }

    private var quickActionsSection: some View {
        Section {
            Button {
                showQuickActionsEditor = true
            } label: {
                HStack {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: 0xFBBF24))
                        .frame(width: 28)
                    Text("Quick Actions")
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(QuickActionStore.load().count)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: 0x555555))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: 0x444444))
                }
            }
        } header: {
            sectionHeader("Shortcuts")
        }
        .listRowBackground(Color(hex: 0x151515))
    }

    private var dataSection: some View {
        Section {
            Button {
                showConnectionLog = true
            } label: {
                HStack {
                    Image(systemName: "doc.text")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: 0x93C5FD))
                        .frame(width: 28)
                    Text("Connection Log")
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: 0x444444))
                }
            }

            Button {
                showClearConfirm = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(.red.opacity(0.8))
                        .frame(width: 28)
                    Text("Clear All Chat History")
                        .foregroundStyle(.red.opacity(0.8))
                }
            }
            .confirmationDialog("Clear all chat history?", isPresented: $showClearConfirm) {
                Button("Clear All", role: .destructive) {
                    webSocket.clearHistory()
                }
            } message: {
                Text("This will delete all messages in all channels. This cannot be undone.")
            }
        } header: {
            sectionHeader("Data")
        }
        .listRowBackground(Color(hex: 0x151515))
    }

    private var launchSection: some View {
        Section {
            settingsRow(icon: "rocket", iconColor: Color(hex: 0xA78BFA)) {
                Picker("Open app to", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: "launchScreen") ?? "cabinet" },
                    set: { UserDefaults.standard.set($0, forKey: "launchScreen") }
                )) {
                    Text("Cabinet").tag("cabinet")
                    Text("Oval Office").tag("main")
                }
                .tint(Color(hex: 0x7C3AED))
            }
        } header: {
            sectionHeader("Launch")
        }
        .listRowBackground(Color(hex: 0x151515))
    }

    private var reconnectSection: some View {
        Section {
            Button {
                save()
                webSocket.disconnect()
                webSocket.connect()
                dismiss()
            } label: {
                HStack {
                    Spacer()
                    Text("Reconnect")
                        .fontWeight(.medium)
                        .foregroundStyle(Color(hex: 0xA78BFA))
                    Spacer()
                }
            }
        }
        .listRowBackground(Color(hex: 0x151515))
    }

    // MARK: - Helpers

    private func settingsRow<Content: View>(icon: String, iconColor: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
                .frame(width: 28)
            content()
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(hex: 0x666666))
            .textCase(.uppercase)
    }

    private func save() {
        var config = ConnectionConfig()
        config.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let port = Int(portText), port > 0 {
            config.port = port
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            KeychainService.saveToken(trimmedToken)
        } else {
            KeychainService.deleteToken()
        }
    }

    private func testConnection() async {
        save()
        isTesting = true
        testResult = nil

        let error = await webSocket.testConnection()
        isTesting = false
        testResult = error == nil ? .success : .failure(error!)
    }
}

// MARK: - Quick Actions Editor

struct QuickActionsEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var actions: [QuickAction] = QuickActionStore.load()
    @State private var showAddSheet = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(actions) { action in
                    HStack(spacing: 12) {
                        Image(systemName: action.icon)
                            .font(.system(size: 14))
                            .foregroundStyle(Color(hex: 0xA78BFA))
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.label)
                                .font(.system(size: 15))
                                .foregroundStyle(.white)
                            Text(action.message)
                                .font(.system(size: 12))
                                .foregroundStyle(Color(hex: 0x555555))
                                .lineLimit(1)
                        }
                    }
                    .listRowBackground(Color(hex: 0x151515))
                }
                .onDelete { indexSet in
                    actions.remove(atOffsets: indexSet)
                    QuickActionStore.save(actions)
                }
                .onMove { source, destination in
                    actions.move(fromOffsets: source, toOffset: destination)
                    QuickActionStore.save(actions)
                }

                Button {
                    showAddSheet = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(hex: 0x7C3AED))
                            .frame(width: 28)
                        Text("Add Action")
                            .foregroundStyle(Color(hex: 0xA78BFA))
                    }
                }
                .listRowBackground(Color(hex: 0x151515))

                if !actions.isEmpty {
                    Button {
                        actions = QuickAction.defaults
                        QuickActionStore.save(actions)
                    } label: {
                        HStack {
                            Spacer()
                            Text("Reset to Defaults")
                                .font(.system(size: 14))
                                .foregroundStyle(Color(hex: 0x666666))
                            Spacer()
                        }
                    }
                    .listRowBackground(Color(hex: 0x151515))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(hex: 0x0D0D0D))
            .navigationTitle("Quick Actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                        .foregroundStyle(Color(hex: 0xA78BFA))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color(hex: 0xA78BFA))
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddQuickActionView { action in
                    actions.append(action)
                    QuickActionStore.save(actions)
                }
            }
        }
    }
}

// MARK: - Add Quick Action

private struct AddQuickActionView: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (QuickAction) -> Void

    @State private var label = ""
    @State private var icon = "star"
    @State private var message = ""

    private let iconOptions = [
        "star", "newspaper", "terminal", "chart.bar", "globe",
        "magnifyingglass", "bolt", "bell", "clock", "paperplane",
        "doc.text", "folder", "tray", "envelope", "bookmark",
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Label", text: $label)
                        .foregroundStyle(.white)
                    TextField("Message to send", text: $message)
                        .foregroundStyle(.white)
                } header: {
                    Text("Details")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hex: 0x666666))
                }
                .listRowBackground(Color(hex: 0x151515))

                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 16) {
                        ForEach(iconOptions, id: \.self) { name in
                            Button {
                                icon = name
                            } label: {
                                Image(systemName: name)
                                    .font(.system(size: 18))
                                    .foregroundStyle(icon == name ? Color(hex: 0xA78BFA) : Color(hex: 0x666666))
                                    .frame(width: 40, height: 40)
                                    .background(icon == name ? Color(hex: 0x7C3AED).opacity(0.15) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Icon")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hex: 0x666666))
                }
                .listRowBackground(Color(hex: 0x151515))
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(hex: 0x0D0D0D))
            .navigationTitle("New Action")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color(hex: 0xA78BFA))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        let action = QuickAction(
                            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                            icon: icon,
                            message: message.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        onAdd(action)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(hex: 0xA78BFA))
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Connection Log

struct ConnectionLogView: View {
    @EnvironmentObject private var webSocket: WebSocketService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusRow("State", value: stateLabel)
                    statusRow("Channels", value: "\(webSocket.channels.count)")
                    statusRow("Messages", value: "\(totalMessages)")
                } header: {
                    Text("Current Status")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hex: 0x666666))
                }
                .listRowBackground(Color(hex: 0x151515))

                Section {
                    let config = ConnectionConfig()
                    statusRow("URL", value: config.webSocketURL?.absoluteString ?? "Invalid")
                    statusRow("Host", value: config.host)
                    statusRow("Port", value: "\(config.port)")
                } header: {
                    Text("Connection Details")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hex: 0x666666))
                }
                .listRowBackground(Color(hex: 0x151515))

                if !webSocket.channels.isEmpty {
                    Section {
                        ForEach(webSocket.channels) { channel in
                            let msgCount = webSocket.channelMessages[channel.chatId]?.count ?? 0
                            statusRow(channel.name, value: "\(msgCount) msgs")
                        }
                    } header: {
                        Text("Channels")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(hex: 0x666666))
                    }
                    .listRowBackground(Color(hex: 0x151515))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(hex: 0x0D0D0D))
            .navigationTitle("Connection Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color(hex: 0xA78BFA))
                }
            }
        }
    }

    private var stateLabel: String {
        switch webSocket.connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting..."
        case .authenticating: "Authenticating..."
        case .disconnected: "Disconnected"
        case .error(let msg): "Error: \(msg)"
        }
    }

    private var totalMessages: Int {
        webSocket.channelMessages.values.reduce(0) { $0 + $1.count }
    }

    private func statusRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: 0xCCCCCC))
            Spacer()
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color(hex: 0x666666))
                .lineLimit(1)
        }
    }
}
