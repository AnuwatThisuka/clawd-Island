import Foundation

/// What Claude Code is doing right now, distilled from the per-session state files that
/// `Hooks/session-hook.sh` writes. `nil` on `AppModel` means nothing is running; a value
/// means at least one live session is mid-tool.
struct SessionActivity: Equatable, Sendable {
    /// Pretty tool name of the most-recently-updated running session (e.g. "Bash", "Edit").
    /// Retained for the current compact wing; the redesigned view uses `verb`/`subtitle` instead.
    var tool: String
    /// Present-participle action for the surfaced tool ("Editing", "Reading", "Running", …).
    /// For unmapped/MCP tools this falls back to `prettyToolName` (e.g. "deployments").
    var verb: String
    /// Short human-readable object of the action — file basename, truncated command, search
    /// pattern, or web domain/query. `nil` when the tool exposes no salient argument.
    var subtitle: String?
    /// How many sessions are running at this instant (fresh heartbeat + status == "running").
    var runningCount: Int
    /// When the surfaced session's current tool run began — the hook's `started_at`, which
    /// (unlike the heartbeat) is not re-stamped on every event. Drives the elapsed-time UI.
    /// Falls back to `updated_at` when an old/partial state file carries no `started_at`.
    var startedAt: Date
}
