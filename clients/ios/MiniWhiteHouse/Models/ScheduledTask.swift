import Foundation

struct ScheduledTask: Identifiable, Codable {
    let id: String
    let groupFolder: String
    let chatJid: String
    let prompt: String
    let scheduleType: ScheduleType
    let scheduleValue: String
    let contextMode: String
    let nextRun: String?
    let lastRun: String?
    let lastResult: String?
    let status: TaskStatus
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case groupFolder = "group_folder"
        case chatJid = "chat_jid"
        case prompt
        case scheduleType = "schedule_type"
        case scheduleValue = "schedule_value"
        case contextMode = "context_mode"
        case nextRun = "next_run"
        case lastRun = "last_run"
        case lastResult = "last_result"
        case status
        case createdAt = "created_at"
    }

    enum ScheduleType: String, Codable {
        case cron
        case interval
        case once
    }

    enum TaskStatus: String, Codable {
        case active
        case paused
        case completed
    }
}
