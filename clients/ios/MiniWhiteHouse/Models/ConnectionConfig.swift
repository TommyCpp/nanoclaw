import Foundation

struct ConnectionConfig {
    private enum Keys {
        static let host = "nanoclaw_host"
        static let port = "nanoclaw_port"
    }

    private let defaults = UserDefaults.standard

    var host: String {
        get { defaults.string(forKey: Keys.host) ?? "nanoclaw" }
        set { defaults.set(newValue, forKey: Keys.host) }
    }

    var port: Int {
        get {
            let value = defaults.integer(forKey: Keys.port)
            return value > 0 ? value : 8080
        }
        set { defaults.set(newValue, forKey: Keys.port) }
    }

    var webSocketURL: URL? {
        URL(string: "ws://\(host):\(port)/ws")
    }
}
