import Foundation

struct UsageEvent: Equatable, Sendable {
    let timestamp: Date
    let sessionId: String
    let requestId: String?
    let messageId: String?
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    /// Absolute working directory the session ran in (the log line's `cwd`), if recorded.
    var projectPath: String? = nil

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    var dedupeKey: String {
        (messageId ?? "?") + ":" + (requestId ?? "?")
    }
}
