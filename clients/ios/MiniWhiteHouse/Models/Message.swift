import Foundation

struct Message: Identifiable, Equatable, Codable {
    let id: UUID
    let role: Role
    var text: String
    let timestamp: Date

    enum Role: String, Equatable, Codable {
        case user
        case assistant
    }

    init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}
