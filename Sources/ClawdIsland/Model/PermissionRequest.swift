import Foundation

/// A pending tool-execution approval, parsed from a `permissions.d/<id>.request` file that
/// `Hooks/permission-hook.sh` publishes while it blocks Claude Code waiting for a decision.
/// The app surfaces one at a time in the notch; the user's Approve/Deny writes the matching
/// `<id>.decision` file the hook is polling for.
struct PermissionRequest: Equatable, Identifiable, Sendable {
    /// Correlates the request with its decision file — the hook's `<id>`, unique per call.
    let id: String
    /// Session that raised the request (may be empty for a malformed/old payload).
    let sessionID: String
    /// Raw tool identifier, e.g. "Bash", "Edit", "mcp__railway__deploy".
    let toolName: String
    /// The one salient argument (file path / command / pattern / url / query), raw. `nil` when
    /// the tool exposes none. Turned into a display subtitle the same way live activity is.
    let detail: String?
    /// Working directory of the session, for the "which project" context line. `nil` if absent.
    let cwd: String?
    /// When the hook published the request; drives staleness pruning and the "age" display.
    let createdAt: Date

    /// Present-participle action verb, e.g. "Running", "Editing" — reuses the live-activity mapping
    /// so a gated tool reads identically to how it shows while running.
    var verb: String { SessionActivityFeed.verb(forTool: toolName) }

    /// Pretty, notch-sized tool name (MCP names collapsed to their trailing action).
    var prettyTool: String { SessionActivityFeed.prettyToolName(toolName) }

    /// Short human-readable object of the action — file basename, truncated command, etc.
    /// `nil` when there's nothing useful to show.
    var subtitle: String? { SessionActivityFeed.subtitle(forTool: toolName, detail: detail) }

    /// Last path component of `cwd`, e.g. `/Users/me/clawd-Island` -> `clawd-Island`. `nil` when
    /// no cwd was recorded. Names the project the request belongs to.
    var projectName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}
