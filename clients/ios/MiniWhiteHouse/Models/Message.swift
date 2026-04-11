import Foundation

struct Message: Identifiable, Equatable, Codable {
    let id: UUID
    let role: Role
    var text: String
    let timestamp: Date
    /// Server-assigned monotonic sequence for outbound (assistant) messages.
    /// Used for resync deduplication. nil for user messages and for older
    /// persisted messages loaded before the resync feature shipped.
    var serverSeq: Int?

    enum Role: String, Equatable, Codable {
        case user
        case assistant
    }

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        timestamp: Date = .now,
        serverSeq: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.serverSeq = serverSeq
    }
}
