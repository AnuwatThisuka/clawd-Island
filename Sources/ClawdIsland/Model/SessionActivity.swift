import Foundation

/// What Claude Code is doing right now, distilled from the per-session state files that
/// `Hooks/session-hook.sh` writes. `nil` on `AppModel` means nothing is running; a value
/// means at least one live session is mid-tool.
struct SessionActivity: Equatable, Sendable {
    /// Pretty tool name of the most-recently-updated running session (e.g. "Bash", "Edit").
    var tool: String
    /// How many sessions are running at this instant (fresh heartbeat + status == "running").
    var runningCount: Int
}
