import Foundation

struct QuickAction: Identifiable, Codable, Equatable {
    var id: UUID
    var label: String
    var icon: String
    var message: String

    init(id: UUID = UUID(), label: String, icon: String, message: String) {
        self.id = id
        self.label = label
        self.icon = icon
        self.message = message
    }

    static let defaults: [QuickAction] = [
        QuickAction(label: "新闻速递", icon: "newspaper", message: "用中文告诉我过去一小时内最重要的3条新闻"),
        QuickAction(label: "CC Session", icon: "terminal", message: "/cc-session"),
    ]
}

enum QuickActionStore {
    private static let key = "quick_actions_v1"

    static func load() -> [QuickAction] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let actions = try? JSONDecoder().decode([QuickAction].self, from: data)
        else {
            return QuickAction.defaults
        }
        return actions
    }

    static func save(_ actions: [QuickAction]) {
        guard let data = try? JSONEncoder().encode(actions) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
