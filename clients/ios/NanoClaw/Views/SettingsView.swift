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
            Form {
                Section("Connection") {
                    LabeledContent("Host") {
                        TextField("nanoclaw", text: $host)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    LabeledContent("Port") {
                        TextField("8080", text: $portText)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                }

                Section("Authentication") {
                    HStack {
                        if showToken {
                            TextField("Auth token", text: $token)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        } else {
                            SecureField("Auth token", text: $token)
                        }
                        Button {
                            showToken.toggle()
                        } label: {
                            Image(systemName: showToken ? "eye.slash" : "eye")
                                .foregroundStyle(.gray)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if isTesting {
                                ProgressView()
                            } else if let result = testResult {
                                switch result {
                                case .success:
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
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
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Reconnect") {
                        save()
                        webSocket.disconnect()
                        webSocket.connect()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        save()
                        webSocket.disconnect()
                        webSocket.connect()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
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
