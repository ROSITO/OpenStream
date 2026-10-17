import Foundation

/// Événements JSON Lines pour un agent IA (stdout).
enum AgentEventName: String, Codable, Sendable {
    case queued
    case progress
    case assembling
    case completed
    case failed
    case cancelled
    case detected
    case info
    case episode
    case seasonDone = "season_done"
}

struct AgentEvent: Codable, Sendable {
    var event: AgentEventName
    var jobId: String?
    var title: String?
    var kind: String?
    var progress: Double?
    var completedUnits: Int?
    var totalUnits: Int?
    var path: String?
    var message: String?
    var url: String?
    var show: String?
    var season: Int?
    var episode: Int?

    static func emit(_ event: AgentEvent, jsonMode: Bool) {
        if jsonMode {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(event),
               let line = String(data: data, encoding: .utf8)
            {
                print(line)
                fflush(stdout)
            }
        } else if let message = event.message {
            print(message)
            fflush(stdout)
        } else if event.event == .completed, let path = event.path {
            print("completed \(path)")
            fflush(stdout)
        } else if event.event == .episode, let url = event.url {
            let label = event.title ?? url
            print("episode \(label) \(url)")
            fflush(stdout)
        } else {
            print(event.event.rawValue)
            fflush(stdout)
        }
    }
}

enum AgentExitCode {
    static let success: Int32 = 0
    static let usage: Int32 = 2
    static let network: Int32 = 3
    static let assemble: Int32 = 4
    static let notFound: Int32 = 5
    static let cancelled: Int32 = 6
    static let detectTimeout: Int32 = 7
}
