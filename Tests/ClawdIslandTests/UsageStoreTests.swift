import Testing
import Foundation
@testable import ClawdIsland

@Suite struct UsageStoreTests {
    func fixtureURL(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")!
    }

    @Test func dedupesAndAggregates() throws {
        let store = UsageStore()
        try store.ingest(fileURL: fixtureURL("dedup"))
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let now = f.date(from: "2026-07-03T10:30:00Z")!
        let snap = store.snapshot(now: now)
        #expect(snap.tokensToday == 1_500_000)
        #expect(abs(snap.costToday - 15.40) < 0.0001)
        #expect(snap.topModel == "claude-opus-4-8")
        #expect(snap.blockRemaining != nil)
        #expect(!snap.isEmpty)
    }

    @Test func splitsTodayByProject() throws {
        let store = UsageStore()
        try store.ingest(fileURL: fixtureURL("dedup"))
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let now = f.date(from: "2026-07-03T10:30:00Z")!
        let snap = store.snapshot(now: now)
        #expect(snap.projectsToday.count == 2)
        // Sorted by cost descending: opus in proj-a ($15), haiku in proj-b ($0.40).
        #expect(snap.projectsToday[0].name == "proj-a")
        #expect(snap.projectsToday[0].tokens == 1_000_000)
        #expect(abs(snap.projectsToday[0].cost - 15.0) < 0.0001)
        #expect(snap.projectsToday[1].name == "proj-b")
        #expect(snap.projectsToday[1].tokens == 500_000)
        #expect(abs(snap.projectsToday[1].cost - 0.40) < 0.0001)
        // Per-project figures must add back up to the daily totals.
        #expect(snap.projectsToday.reduce(0) { $0 + $1.tokens } == snap.tokensToday)
    }

    @Test func emptyStoreIsEmptySnapshot() {
        let snap = UsageStore().snapshot(now: Date())
        #expect(snap.isEmpty)
        #expect(snap.tokensToday == 0)
        #expect(snap.blockRemaining == nil)
    }
}
