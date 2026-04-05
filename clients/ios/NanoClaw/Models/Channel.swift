import Foundation

struct Channel: Identifiable, Equatable, Codable {
    let chatId: String
    var name: String
    let folder: String
    let isMain: Bool

    var id: String { chatId }
}
