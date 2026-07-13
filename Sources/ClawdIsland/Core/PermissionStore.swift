import Foundation

/// The app side of the permission protocol driven by `Hooks/permission-hook.sh`. Reads the
/// pending `permissions.d/<id>.request` files the (synchronous, blocking) hook publishes, and
/// writes the `<id>.decision` file it is polling for when the user approves or denies.
///
/// Read-mostly, like `SessionActivityFeed`: the hook removes both files once it reads a decision,
/// so the only cleanup left to the app is pruning requests whose hook has already timed out and
/// exited (leaving an orphan `.request` with no owner still waiting).
enum PermissionStore {
    static var requestsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClawdIsland/permissions.d",
                                    isDirectory: true)
    }

    /// A request older than this is assumed abandoned — its hook's 55s poll has long since timed
    /// out and deferred to the terminal prompt, so answering it now would write a decision no one
    /// reads. Kept comfortably above the hook's `max_wait` (55s) plus Claude Code's 60s hook cap so
    /// we never drop a request the hook is still genuinely waiting on.
    static let staleAfter: TimeInterval = 120

    /// All live pending requests, oldest first (so the queue is answered FIFO). Stale ones are
    /// skipped here and swept by `pruneStale`.
    static func pending(now: Date = Date()) -> [PermissionRequest] {
        pending(now: now, from: requestsDir)
    }

    /// Directory-injectable core, so tests can point it at a fixture dir.
    static func pending(now: Date, from dir: URL) -> [PermissionRequest] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir,
                                                        includingPropertiesForKeys: nil) else { return [] }
        var out: [PermissionRequest] = []
        for url in entries where url.pathExtension == "request" {
            guard let req = decode(url) else { continue }
            guard now.timeIntervalSince(req.createdAt) <= staleAfter else { continue }
            out.append(req)
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    /// Parse one `.request` file into a `PermissionRequest`, or nil if malformed / missing fields.
    private static func decode(_ url: URL) -> PermissionRequest? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String, !id.isEmpty,
              let tool = obj["tool_name"] as? String, !tool.isEmpty,
              let iso = obj["created_at"] as? String,
              let created = ISO8601.date(from: iso) else { return nil }
        return PermissionRequest(id: id,
                                 sessionID: obj["session_id"] as? String ?? "",
                                 toolName: tool,
                                 detail: obj["detail"] as? String,
                                 cwd: obj["cwd"] as? String,
                                 createdAt: created)
    }

    /// Record the user's answer by writing the `<id>.decision` file the hook is polling for. The
    /// hook removes both files once it reads this, so the app doesn't delete the `.request` here —
    /// doing so would race the still-blocked hook. Writes atomically (temp + rename).
    static func decide(_ id: String, allow: Bool, in dir: URL = requestsDir) {
        let decision = allow ? "allow" : "deny"
        let target = dir.appendingPathComponent("\(id).decision")
        let tmp = dir.appendingPathComponent("\(id).decision.tmp")
        guard let data = try? JSONSerialization.data(withJSONObject: ["decision": decision]) else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: tmp, options: .atomic)
            try FileManager.default.replaceItem(at: target, withItemAt: tmp,
                                                backupItemName: nil, options: [],
                                                resultingItemURL: nil)
        } catch {
            // Fall back to a plain atomic write if replaceItem couldn't run (e.g. no prior file).
            try? data.write(to: target, options: .atomic)
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// Remove `.request` files whose hook has already timed out, so the queue doesn't accumulate
    /// orphans forever. Called off the app's poll; safe to run every tick since it only touches
    /// files older than `staleAfter`.
    static func pruneStale(now: Date = Date(), in dir: URL = requestsDir) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir,
                                                        includingPropertiesForKeys: nil) else { return }
        for url in entries where url.pathExtension == "request" {
            guard let req = decode(url), now.timeIntervalSince(req.createdAt) > staleAfter else { continue }
            try? fm.removeItem(at: url)
            try? fm.removeItem(at: dir.appendingPathComponent("\(req.id).decision"))
        }
    }
}
