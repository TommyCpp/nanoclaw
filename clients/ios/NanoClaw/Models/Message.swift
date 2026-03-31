import Foundation

struct Message: Identifiable, Equatable, Codable {
    let id: UUID
    let role: Role
    var text: String
    let timestamp: Date
    var subtype: Subtype
    var tool: String?

    enum Role: String, Equatable, Codable {
        case user
        case assistant
    }

    enum Subtype: String, Equatable, Codable {
        case agent
        case event
    }

    init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = .now,
         subtype: Subtype = .agent, tool: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.subtype = subtype
        self.tool = tool
    }

    // Custom Decodable: subtype defaults to .agent when missing (backward compat)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(UUID.self,    forKey: .id)
        role      = try c.decode(Role.self,    forKey: .role)
        text      = try c.decode(String.self,  forKey: .text)
        timestamp = try c.decode(Date.self,    forKey: .timestamp)
        subtype   = (try? c.decode(Subtype.self, forKey: .subtype)) ?? .agent
        tool      = try? c.decode(String.self, forKey: .tool)
    }
}
