import Testing
import Foundation
@testable import ClawdIsland

@Suite struct SessionActivityFeedTests {
    // MARK: prettyToolName

    @Test func prettyToolNamePassesPlainTools() {
        #expect(SessionActivityFeed.prettyToolName("Bash") == "Bash")
        #expect(SessionActivityFeed.prettyToolName("Edit") == "Edit")
    }

    @Test func prettyToolNameStripsMcpServerAndVerb() {
        // mcp__<server>__<action>: keep the action, then drop a common leading verb prefix so the
        // notch shows the identifying noun.
        #expect(SessionActivityFeed.prettyToolName("mcp__railway__list_deployments") == "deployments")
        #expect(SessionActivityFeed.prettyToolName("mcp__railway__list_services") == "services")
        #expect(SessionActivityFeed.prettyToolName("mcp__github__create_pr") == "pr")
        #expect(SessionActivityFeed.prettyToolName("mcp__railway__get_logs") == "logs")
        #expect(SessionActivityFeed.prettyToolName("mcp__x__update_domain") == "domain")
        #expect(SessionActivityFeed.prettyToolName("mcp__x__delete_volume") == "volume")
        #expect(SessionActivityFeed.prettyToolName("mcp__x__fetch_docs") == "docs")
    }

    @Test func prettyToolNameKeepsActionWithNoKnownVerb() {
        // No recognised verb prefix → the whole action stays.
        #expect(SessionActivityFeed.prettyToolName("mcp__railway__whoami") == "whoami")
        #expect(SessionActivityFeed.prettyToolName("mcp__x__deploy") == "deploy")
    }

    @Test func prettyToolNameKeepsVerbWhenNothingWouldRemain() {
        // Action is exactly a verb prefix → stripping would leave nothing, so keep it.
        #expect(SessionActivityFeed.prettyToolName("mcp__x__list_") == "list_")
    }

    // MARK: read() over a fixture dir

    /// Writes a state file into a temp dir. `age` is how long ago `updated_at` was stamped;
    /// `startedAge`, when given, stamps a separate `started_at` that far in the past — mirroring
    /// the hook's split fields (a run that began long ago but is still heartbeating).
    private func writeState(_ dir: URL, id: String, status: String, tool: String?,
                            age: TimeInterval, now: Date, startedAge: TimeInterval? = nil) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var obj: [String: Any] = [
            "session_id": id,
            "status": status,
            "updated_at": iso.string(from: now.addingTimeInterval(-age)),
        ]
        if let tool { obj["tool_name"] = tool }
        if let startedAge { obj["started_at"] = iso.string(from: now.addingTimeInterval(-startedAge)) }
        let data = try JSONSerialization.data(withJSONObject: obj)
        try data.write(to: dir.appendingPathComponent("\(id).json"))
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawd-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func emptyDirIsNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SessionActivityFeed.read(now: Date(), from: dir) == nil)
    }

    @Test func freshRunningSessionReported() throws {
        let now = Date()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeState(dir, id: "s1", status: "running", tool: "Bash", age: 1, now: now)
        let act = SessionActivityFeed.read(now: now, from: dir)
        #expect(act?.tool == "Bash")
        #expect(act?.runningCount == 1)
    }

    @Test func idleSessionIsNotActivity() throws {
        let now = Date()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeState(dir, id: "s1", status: "idle", tool: nil, age: 1, now: now)
        #expect(SessionActivityFeed.read(now: now, from: dir) == nil)
    }

    // A running file whose heartbeat is older than liveWithin is dead — e.g. the session crashed
    // mid-tool and never sent Stop. It must not show as active.
    @Test func staleRunningSessionIgnored() throws {
        let now = Date()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeState(dir, id: "s1", status: "running", tool: "Bash",
                       age: SessionActivityFeed.liveWithin + 5, now: now)
        #expect(SessionActivityFeed.read(now: now, from: dir) == nil)
    }

    // Several live sessions: surface the most-recently-updated one's tool and count them all.
    @Test func multipleRunningPicksFreshestAndCounts() throws {
        let now = Date()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeState(dir, id: "s1", status: "running", tool: "Read", age: 4, now: now)
        try writeState(dir, id: "s2", status: "running", tool: "Edit", age: 1, now: now)  // freshest
        try writeState(dir, id: "s3", status: "idle", tool: nil, age: 1, now: now)
        let act = SessionActivityFeed.read(now: now, from: dir)
        #expect(act?.tool == "Edit")
        #expect(act?.runningCount == 2)   // s3 idle is excluded
    }

    // A run that started long ago but is still heartbeating (fresh updated_at) stays live, and the
    // surfaced startedAt reflects the old start — this is exactly the long-running-tool case the
    // split started_at/updated_at fields exist to handle.
    @Test func oldStartWithFreshHeartbeatIsLive() throws {
        let now = Date()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeState(dir, id: "s1", status: "running", tool: "Bash",
                       age: 1, now: now, startedAge: 300)  // heartbeat 1s ago, started 5m ago
        let act = SessionActivityFeed.read(now: now, from: dir)
        #expect(act?.tool == "Bash")
        #expect(act?.runningCount == 1)
        // startedAt carries the old start, not the recent heartbeat, so the timer counts from t-300.
        let started = try #require(act?.startedAt)
        #expect(abs(started.timeIntervalSince(now.addingTimeInterval(-300))) < 1)
    }

    // Old/partial state files predate started_at. Parsing must not crash and must fall back to
    // updated_at rather than dropping the session.
    @Test func missingStartedAtFallsBackToUpdatedAt() throws {
        let now = Date()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeState(dir, id: "s1", status: "running", tool: "Edit", age: 2, now: now)  // no started_at
        let act = SessionActivityFeed.read(now: now, from: dir)
        #expect(act?.tool == "Edit")
        let started = try #require(act?.startedAt)
        #expect(abs(started.timeIntervalSince(now.addingTimeInterval(-2))) < 1)  // == updated_at
    }

    // A stale running session alongside a fresh one must not inflate the running count.
    @Test func staleRunningExcludedFromCount() throws {
        let now = Date()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeState(dir, id: "s1", status: "running", tool: "Bash", age: 1, now: now)
        try writeState(dir, id: "s2", status: "running", tool: "Grep",
                       age: SessionActivityFeed.liveWithin + 30, now: now)
        let act = SessionActivityFeed.read(now: now, from: dir)
        #expect(act?.tool == "Bash")
        #expect(act?.runningCount == 1)
    }
}
