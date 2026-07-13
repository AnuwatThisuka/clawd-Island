import Foundation

enum RingState { case ok, warn, critical }

extension RingState {
    /// Colour thresholds for a usage fraction (0…1 consumed): ok < 0.66 ≤ warn < 0.85 ≤ critical.
    /// The single source of truth for both the ring colour and the snapshot's block state.
    init(usage: Double) {
        switch usage {
        case ..<0.66: self = .ok
        case ..<0.85: self = .warn
        default:      self = .critical
        }
    }
}

/// Today's spend for one project folder (grouped by the sessions' working directory).
struct ProjectUsage: Equatable, Sendable, Identifiable {
    let path: String     // full project directory ("" when the logs never recorded a cwd)
    let tokens: Int
    let cost: Double
    var id: String { path }
    /// Display label: last path component of the project directory.
    var name: String {
        path.isEmpty ? "Other" : (path as NSString).lastPathComponent
    }
}

struct UsageSnapshot: Equatable, Sendable {
    var blockRemaining: TimeInterval?
    var blockFractionElapsed: Double
    var blockEnd: Date?
    var tokensToday: Int
    var costToday: Double
    /// Today's usage split by project folder, sorted by cost descending.
    var projectsToday: [ProjectUsage] = []
    var activeSessionTokens: Int
    var weeklyTokens: Int = 0
    var topModel: String?
    /// Rough fallback usage (0…1): active-block tokens ÷ largest block ever seen.
    /// Used only until the authoritative statusline rate-limit % is available.
    var blockUsageEstimate: Double = 0

    var isEmpty: Bool { tokensToday == 0 && blockRemaining == nil }

    var ringState: RingState { RingState(usage: blockFractionElapsed) }

    static let empty = UsageSnapshot(blockRemaining: nil, blockFractionElapsed: 0,
        blockEnd: nil, tokensToday: 0, costToday: 0, activeSessionTokens: 0,
        topModel: nil)
}
