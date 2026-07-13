import Testing
import Foundation
@testable import ClawdIsland

@Suite struct PermissionStoreTests {
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawd-perm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a `<id>.request` file `age` seconds in the past, mirroring what permission-hook.sh
    /// publishes while it blocks.
    private func writeRequest(_ dir: URL, id: String, tool: String, age: TimeInterval, now: Date,
                              detail: String? = nil, cwd: String? = nil) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var obj: [String: Any] = [
            "id": id,
            "tool_name": tool,
            "created_at": iso.string(from: now.addingTimeInterval(-age)),
        ]
        if let detail { obj["detail"] = detail }
        if let cwd { obj["cwd"] = cwd }
        let data = try JSONSerialization.data(withJSONObject: obj)
        try data.write(to: dir.appendingPathComponent("\(id).request"))
    }

    @Test func emptyDirHasNoPending() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(PermissionStore.pending(now: Date(), from: dir).isEmpty)
    }

    @Test func freshRequestParsedWithDisplayFields() throws {
        let now = Date()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeRequest(dir, id: "a", tool: "Bash", age: 1, now: now,
                         detail: "npm install", cwd: "/Users/x/clawd-Island")
        let reqs = PermissionStore.pending(now: now, from: dir)
        #expect(reqs.count == 1)
        let r = try #require(reqs.first)
        #expect(r.toolName == "Bash")
        #expect(r.verb == "Running")
        #expect(r.subtitle == "npm install")
        #expect(r.projectName == "clawd-Island")
    }

    @Test func pendingSortedOldestFirst() throws {
        let now = Date()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeRequest(dir, id: "new", tool: "Edit", age: 1, now: now)
        try writeRequest(dir, id: "old", tool: "Bash", age: 10, now: now)
        let ids = PermissionStore.pending(now: now, from: dir).map(\.id)
        #expect(ids == ["old", "new"])   // FIFO: oldest answered first
    }

    @Test func staleRequestSkippedFromPending() throws {
        let now = Date()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeRequest(dir, id: "stale", tool: "Bash",
                         age: PermissionStore.staleAfter + 10, now: now)
        #expect(PermissionStore.pending(now: now, from: dir).isEmpty)
    }

    @Test func malformedRequestIgnored() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Missing tool_name / created_at → not decodable.
        try Data("{\"id\":\"x\"}".utf8).write(to: dir.appendingPathComponent("x.request"))
        #expect(PermissionStore.pending(now: Date(), from: dir).isEmpty)
    }

    @Test func decideWritesDecisionFileTheHookPollsFor() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        PermissionStore.decide("a", allow: true, in: dir)
        let url = dir.appendingPathComponent("a.decision")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(obj?["decision"] as? String == "allow")

        PermissionStore.decide("b", allow: false, in: dir)
        let objB = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("b.decision"))) as? [String: Any]
        #expect(objB?["decision"] as? String == "deny")
    }

    @Test func decideDoesNotRemoveRequest() throws {
        // The still-blocked hook owns removal; the app must not race it by deleting the request.
        let now = Date()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeRequest(dir, id: "a", tool: "Bash", age: 1, now: now)
        PermissionStore.decide("a", allow: true, in: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.request").path))
    }

    @Test func pruneRemovesStaleRequestAndOrphanDecision() throws {
        let now = Date()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeRequest(dir, id: "stale", tool: "Bash",
                         age: PermissionStore.staleAfter + 10, now: now)
        try writeRequest(dir, id: "fresh", tool: "Edit", age: 1, now: now)
        try Data("{\"decision\":\"allow\"}".utf8)
            .write(to: dir.appendingPathComponent("stale.decision"))

        PermissionStore.pruneStale(now: now, in: dir)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("stale.request").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("stale.decision").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("fresh.request").path))
    }
}
