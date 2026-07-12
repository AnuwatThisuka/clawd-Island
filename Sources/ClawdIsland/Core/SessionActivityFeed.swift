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

        var running: [(tool: String, verb: String, subtitle: String?, updated: Date, started: Date)] = []
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = obj["status"] as? String,
                  let iso = obj["updated_at"] as? String,
                  let updated = ISO8601.date(from: iso) else { continue }
            // Heartbeat gate first: anything not touched recently is dead, whatever its status says.
            guard now.timeIntervalSince(updated) <= liveWithin, status == "running" else { continue }
            let rawTool = obj["tool_name"] as? String
            let detail = obj["detail"] as? String
            let tool = rawTool.map(prettyToolName) ?? "working"
            let toolVerb = rawTool.map(verb(forTool:)) ?? "working"
            let toolSubtitle = rawTool.flatMap { subtitle(forTool: $0, detail: detail) }
            // started_at drives the elapsed-time UI. Old/partial state files predate it, so fall
            // back to updated_at rather than dropping the session — the timer just starts from now.
            let started = (obj["started_at"] as? String).flatMap(ISO8601.date(from:)) ?? updated
            running.append((tool, toolVerb, toolSubtitle, updated, started))
        }

        guard let latest = running.max(by: { $0.updated < $1.updated }) else { return nil }
        return SessionActivity(tool: latest.tool, verb: latest.verb, subtitle: latest.subtitle,
                               runningCount: running.count, startedAt: latest.started)
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

    // MARK: verb + subtitle mapping

    /// Longest a subtitle may be before it's ellipsised. Sized to the notch wing so a long file
    /// path or Bash command can't blow out the pill the way `list_deployments` once did.
    static let subtitleMaxLength = 28

    /// Map a raw tool name to a present-participle verb for the activity headline. Known first-party
    /// tools get a hand-picked verb; anything else (MCP tools, future tools) falls back to
    /// `prettyToolName`, so `mcp__railway__list_deployments` still reads as "deployments".
    static func verb(forTool raw: String) -> String {
        switch raw {
        case "Edit", "MultiEdit", "Write": return "Editing"
        case "Read":                        return "Reading"
        case "Bash":                        return "Running"
        case "Grep", "Glob":                return "Searching"
        case "WebFetch", "WebSearch":       return "Researching"
        default:                            return prettyToolName(raw)
        }
    }

    /// Derive the display subtitle from the raw tool name and its salient argument (`detail`, the
    /// hook-forwarded tool_input field). File paths collapse to a basename; commands and patterns
    /// are whitespace-normalised; URLs collapse to their domain. Everything is length-capped.
    /// Returns nil when there's nothing useful to show (no detail, or an unmapped tool whose verb
    /// already names the action).
    static func subtitle(forTool raw: String, detail: String?) -> String? {
        guard let detail, case let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        switch raw {
        case "Edit", "MultiEdit", "Write", "Read":
            return truncate(basename(trimmed))
        case "Bash":
            return truncate(collapseWhitespace(trimmed))
        case "Grep", "Glob", "WebSearch":
            return truncate(collapseWhitespace(trimmed))
        case "WebFetch":
            return truncate(domain(trimmed) ?? trimmed)
        default:
            return nil   // MCP/unmapped: the verb already carries the action name
        }
    }

    /// Last path component, e.g. `/a/b/sidebar.tsx` → `sidebar.tsx`. Falls back to the whole
    /// string if there's no trailing component (e.g. a path ending in `/`).
    private static func basename(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// Host of a URL, minus a leading `www.`, e.g. `https://www.example.com/x` → `example.com`.
    private static func domain(_ raw: String) -> String? {
        guard let host = URL(string: raw)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Fold any run of whitespace (including newlines in a multi-line Bash command) into a single
    /// space so the subtitle stays one tidy line.
    private static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Cap at `subtitleMaxLength`, replacing the tail with an ellipsis. The `…` counts toward the
    /// limit so the result never exceeds it.
    private static func truncate(_ s: String) -> String {
        s.count <= subtitleMaxLength ? s : String(s.prefix(subtitleMaxLength - 1)) + "…"
    }
}
