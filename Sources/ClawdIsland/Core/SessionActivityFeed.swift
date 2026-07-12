import Foundation

/// Reads the per-session state files written by `Hooks/session-hook.sh` and distils them into a
/// single "what is Claude Code doing right now" view for the island.
///
/// Each `state.d/<session_id>.json` is a tiny snapshot the hook re-stamps on every SessionStart,
/// PreToolUse and Stop. We treat `updated_at` as a heartbeat: a session counts as live only if it
/// was touched within `liveWithin`. Because the hooks fire in real time — not on a 60s poll like the
/// usage feed — that window is short: a tool whose file hasn't been re-stamped for ~12s is already
/// considered dead (the session likely crashed or the hook never sent a Stop).
enum SessionActivityFeed {
    // TODO(Phase 3): nothing ever deletes files from state.d/. The hook writes an "idle" file per
    // session on Stop and leaves it (deliberately, for debuggability), so over months of use the
    // directory accumulates one stale JSON per session forever. read() ignores them by heartbeat so
    // there's no correctness bug, only unbounded growth. Add a cleanup on app start that removes
    // files whose updated_at is older than ~24h. Kept out of the hot read() path on purpose.
    static var stateDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClawdIsland/state.d", isDirectory: true)
    }

    /// A session whose last heartbeat is older than this is treated as dead and ignored. Kept far
    /// shorter than the usage feed's 150s staleness because hook events are real-time.
    ///
    /// Sizing is a deliberate compromise, not a fully-solved problem. Claude Code fires no
    /// mid-tool heartbeat event (verified against code.claude.com/docs/en/hooks) — only
    /// PreToolUse at the start and PostToolUse at the end. So a *single* long-running tool
    /// re-stamps nothing between those two points: a 20s `sleep` is silent for 20s. To keep it
    /// showing "running" the whole time, this window must comfortably exceed a typical slow tool,
    /// hence 45s rather than the original 12s. A sequence of ordinary tools stays live via the
    /// PostToolUse heartbeat; a tool that runs longer than this window will still lapse to idle
    /// and recover on its PostToolUse — an accepted edge, not a claim of full coverage.
    static let liveWithin: TimeInterval = 45

    /// The current activity across all live sessions, or nil when nothing is running right now.
    ///
    /// When several sessions run at once we surface the most-recently-updated one's tool (the freshest
    /// signal) and report how many are active, so the UI can show e.g. "Bash +2". Read-only: stale idle
    /// files are simply skipped here, never deleted — pruning is left to a separate cleanup step.
    static func read(now: Date = Date()) -> SessionActivity? {
        read(now: now, from: stateDir)
    }

    /// Directory-injectable core of `read`, so tests can point it at a fixture dir.
    static func read(now: Date, from dir: URL) -> SessionActivity? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir,
                                                        includingPropertiesForKeys: nil) else { return nil }

        var running: [(tool: String, updated: Date, started: Date)] = []
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = obj["status"] as? String,
                  let iso = obj["updated_at"] as? String,
                  let updated = ISO8601.date(from: iso) else { continue }
            // Heartbeat gate first: anything not touched recently is dead, whatever its status says.
            guard now.timeIntervalSince(updated) <= liveWithin, status == "running" else { continue }
            let tool = (obj["tool_name"] as? String).map(prettyToolName) ?? "working"
            // started_at drives the elapsed-time UI. Old/partial state files predate it, so fall
            // back to updated_at rather than dropping the session — the timer just starts from now.
            let started = (obj["started_at"] as? String).flatMap(ISO8601.date(from:)) ?? updated
            running.append((tool, updated, started))
        }

        guard let latest = running.max(by: { $0.updated < $1.updated }) else { return nil }
        return SessionActivity(tool: latest.tool, runningCount: running.count, startedAt: latest.started)
    }

    /// Common verb prefixes on MCP action names, stripped so the notch shows the noun that
    /// actually identifies the call ("deployments") rather than the verb ("list_deploym…").
    private static let mcpVerbPrefixes = ["list_", "get_", "create_", "update_", "delete_", "fetch_"]

    /// Turn a raw tool identifier into something short enough for the notch. MCP tools arrive as
    /// `mcp__<server>__<action>`; we keep just the trailing action, then drop a leading verb prefix
    /// so `mcp__railway__list_deployments` reads as "deployments". Non-MCP tools pass through
    /// unchanged. Anything still too long for the wing falls back to ellipsis truncation in the view.
    static func prettyToolName(_ raw: String) -> String {
        guard raw.hasPrefix("mcp__") else { return raw }
        let parts = raw.components(separatedBy: "__")
        guard let action = parts.last, !action.isEmpty else { return raw }
        for verb in mcpVerbPrefixes where action.hasPrefix(verb) {
            let stripped = String(action.dropFirst(verb.count))
            if !stripped.isEmpty { return stripped }   // keep the verb if nothing would remain
        }
        return action
    }
}
