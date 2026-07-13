import Foundation
import SwiftUI

@MainActor @Observable
final class AppModel {
    private(set) var snapshot: UsageSnapshot = .empty
    /// Live "what Claude Code is doing right now" status, driven by the hook state files.
    /// nil = nothing running. Updated ~3×/s off the `state.d/` heartbeat feed.
    private(set) var activity: SessionActivity?
    /// Tool-approval requests currently blocking a session, oldest first, from the permission
    /// hook feed. Independent of `isPaused` (a blocked session must still be answerable) and
    /// of `activity` — a pending request takes the drop slot with priority. Empty = nothing to approve.
    private(set) var pendingPermissions: [PermissionRequest] = []
    var isExpanded = false
    var isPaused = false
    var claudeRunning = false
    var avatarStyle: AvatarStyle = AvatarStyle.selected
    /// Whether the icon (Clawd / Spark) animates. Persisted; default on.
    var animateIcon: Bool = (UserDefaults.standard.object(forKey: "animateIcon") as? Bool) ?? true
    /// Notch geometry of the screen the island lives on (updated on display changes).
    var notchWidth: CGFloat = 190
    var topInset: CGFloat = 32
    /// Measured natural height of the expanded drop-down content. Written by IslandView once
    /// the Usage Monitor panel lays out, read by IslandWindow to size the click-catcher. Starts
    /// at a sensible estimate so the very first expand isn't clipped before the measurement lands.
    var dropHeight: CGFloat = 250
    /// Measured natural height of the live-activity detail band (verb + subtitle) shown below the
    /// notch while a tool runs. Same read/write contract as `dropHeight`, but for the auto-opened
    /// active state rather than the click-opened tile grid. Seeded so the first frame isn't clipped.
    var activityDropHeight: CGFloat = 46
    /// Measured natural height of the permission-approval band (summary + Approve/Deny buttons).
    /// Same read/write contract as `activityDropHeight`, for the pending-request drop slot. Seeded
    /// tall enough that the first frame — which includes two buttons — isn't clipped before measure.
    var permissionDropHeight: CGFloat = 118

    /// The request the notch is currently asking the user to answer (the oldest pending one), or
    /// nil when nothing is blocked. Drives the approval band's presence and priority over activity.
    var currentPermission: PermissionRequest? { pendingPermissions.first }

    /// Live account limits from claude.ai (authoritative, matches Claude Desktop).
    private(set) var limits: ClaudeLimits?
    /// Context window remaining, 0…1, from the terminal statusline feed (nil if unknown).
    private(set) var contextRemaining: Double?
    /// Friendly plan name, e.g. "Claude Max 5x" (from ~/.claude.json).
    private(set) var planName: String?
    private(set) var organizationType: String?
    private var statuslineUsage: Double?
    private var weeklyResetFromConfig: Date?
    /// Recent (time, session %) samples for the burn-rate ETA.
    private var pctHistory: [(t: Date, pct: Double)] = []

    private let store = UsageStore()
    private let loader = LogLoader()
    private let claudeAPI = ClaudeAPIService()
    let notifier = NotificationManager()
    private var watcher: LogWatcher?
    private var ticker: Timer?
    private var limitsTimer: Timer?
    /// Fast poll (~300ms) of the hook state feed — real-time, so it runs far tighter than the
    /// 5s usage ticker and 60s limits fetch.
    private var activityTimer: Timer?
    /// mtime of each log file the last time we parsed it, so the periodic sweep re-reads only
    /// files that actually grew and skips the rest.
    private var parsedMTimes: [URL: Date] = [:]
    private var lastReingest = Date.distantPast

    // MARK: display values (prefer live limits, then terminal feed, then estimate)

    var sessionUsage: Double? {
        limits?.sessionPct ?? statuslineUsage ?? (snapshot.isEmpty ? nil : snapshot.blockUsageEstimate)
    }
    var weeklyUsage: Double? { limits?.weeklyPct }
    var weeklyOpusUsage: Double? { limits?.weeklyOpusPct }
    var weeklySonnetUsage: Double? { limits?.weeklySonnetPct }
    var sessionResetsAt: Date? { limits?.sessionResetsAt }
    var weeklyResetsAt: Date? { limits?.weeklyResetsAt ?? weeklyResetFromConfig }
    var lastFetch: Date? { limits?.fetchedAt }
    var usageSource: String {
        if let l = limits { return l.source ?? "claude.ai" }
        if statuslineUsage != nil { return "terminal" }
        return "estimate"
    }
    /// True when live limits exist but haven't refreshed recently (fetches failing) — the UI
    /// dims the numbers so a frozen value is never shown as if it were current.
    var isStale: Bool {
        guard let f = limits?.fetchedAt else { return false }
        return Date().timeIntervalSince(f) > staleAfter
    }
    private let staleAfter: TimeInterval = 150   // ~2–3 missed 60s fetches

    /// Estimated time until the 5-hour limit at the current pace (nil if usage isn't trending
    /// up, or if the block resets first). Uses the slope of session % — no token cap needed.
    var etaToLimit: TimeInterval? {
        guard let cur = sessionUsage, cur < 0.999 else { return nil }
        let cutoff = Date().addingTimeInterval(-600)   // slope over the last 10 minutes
        let recent = pctHistory.filter { $0.t > cutoff }
        guard let first = recent.first, let last = recent.last else { return nil }
        let dt = last.t.timeIntervalSince(first.t)
        let dpct = last.pct - first.pct
        guard dt > 60, dpct > 0.005 else { return nil }
        let eta = (1.0 - cur) / (dpct / dt)
        if let reset = limits?.sessionResetsAt, eta >= reset.timeIntervalSinceNow { return nil }
        return (eta > 0 && eta < 6 * 3600) ? eta : nil
    }

    /// How urgent the icon should look (0…1) — drives Clawd's walk speed.
    var iconUrgency: Double { max(sessionUsage ?? 0, limits?.weeklyPct ?? 0) }

    /// A limit (5-hour or 7-day) is used up — there's nothing left to spend, so Clawd stops
    /// walking and stands still rather than sprinting at max speed.
    var isAtLimit: Bool { iconUrgency >= 0.999 }

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private var usageFileURL: URL { home.appendingPathComponent(".claude/notch-usage.json") }
    private var configURL: URL { home.appendingPathComponent(".claude.json") }

    func start() {
        readPlanLimits()
        watcher = LogWatcher { [weak self] urls in
            guard let self, !self.isPaused else { return }
            Task { await self.ingest(urls) }
        }
        watcher?.start()
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        limitsTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetchLimits() }
        }
        activityTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readActivity() }
        }
        Task { await ingest(ClaudePaths.recentLogFiles(within: 2)) }
        fetchLimits()
        readActivity()
    }

    /// Refresh the live tool-activity status from the hook feed. Gated on `isPaused` (pausing
    /// tracking hides live status too) and only reassigns on an actual change so the observable
    /// property doesn't invalidate the view 3×/s while nothing is happening.
    private func readActivity() {
        let next = isPaused ? nil : SessionActivityFeed.read()
        if next != activity { activity = next }
        readPermissions()
    }

    /// Refresh pending tool-approval requests from the permission hook feed. Unlike activity this
    /// is NOT gated on `isPaused` — a session blocked on a permission must stay answerable — and it
    /// runs on the same 0.3s timer so an Approve/Deny prompt appears near-instantly. Stale requests
    /// (whose hook already timed out to the terminal prompt) are swept before reading.
    private func readPermissions() {
        PermissionStore.pruneStale()
        let next = PermissionStore.pending()
        if next != pendingPermissions { pendingPermissions = next }
    }

    /// Approve the oldest pending request: write its decision (the blocked hook is polling for it)
    /// and drop it from the queue immediately so the UI advances to the next one without waiting
    /// for the hook to remove the file on the next poll.
    func approveCurrentPermission() { decideCurrent(allow: true) }
    func denyCurrentPermission() { decideCurrent(allow: false) }

    private func decideCurrent(allow: Bool) {
        guard let req = pendingPermissions.first else { return }
        PermissionStore.decide(req.id, allow: allow)
        pendingPermissions.removeFirst()
    }

    func togglePause() { isPaused.toggle(); if !isPaused { refresh() } }
    func cycleAvatar() { setAvatar(avatarStyle.next) }
    func setAvatar(_ s: AvatarStyle) { avatarStyle = s; AvatarStyle.selected = s }
    func toggleAnimateIcon() {
        animateIcon.toggle()
        UserDefaults.standard.set(animateIcon, forKey: "animateIcon")
    }

    /// Fetch live claude.ai limits off-main (Keychain prompt appears on first run).
    /// Only replaces the last-known-good limits with a response that actually carries a
    /// session %, so a partial/failed read can never clobber correct data.
    func fetchLimits() {
        Task { [claudeAPI] in
            if let l = await claudeAPI.fetch(), l.sessionPct != nil { self.applyLimits(l) }
        }
    }

    /// Store new limits and track the % trend for the burn-rate ETA.
    private func applyLimits(_ l: ClaudeLimits) {
        // A new block (reset time jumped later) → clear the ETA trend. Also clear on the first
        // live fetch: earlier samples came from the statusline feed, whose % can be offset from
        // the live value, and mixing the two would fake a slope jump.
        if limits == nil {
            pctHistory.removeAll()
        } else if let prev = limits?.sessionResetsAt, let now = l.sessionResetsAt,
                  now > prev.addingTimeInterval(60) {
            pctHistory.removeAll()
        }
        limits = l
        trackSessionPct()
        notifier.evaluate(session: l.sessionPct, sessionResetsAt: l.sessionResetsAt,
                          weekly: l.weeklyPct, weeklyResetsAt: l.weeklyResetsAt)
    }

    func toggleNotifications() { notifier.isEnabled.toggle() }

    private func ingest(_ files: [URL]) async {
        let parsed = await loader.parse(files)
        for item in parsed { store.ingest(fileURL: item.url, events: item.events) }
        for url in files { parsedMTimes[url] = Self.mtime(url) }
        refresh()
    }

    /// Fires every 5s: re-read any grown log files (freshness safety net that doesn't depend on
    /// the FSEvents watcher), then recompute the snapshot.
    private func tick() {
        reingestChangedFiles()
        refresh()
    }

    /// Re-parse recent log files whose mtime advanced since we last read them. This makes local
    /// token/cost stay fresh even if the FSEvents watcher misses an append (e.g. after a launch
    /// with no prior same-day activity). Throttled and mtime-gated so unchanged files are skipped.
    private func reingestChangedFiles() {
        guard !isPaused, Date().timeIntervalSince(lastReingest) >= 10 else { return }
        let changed = ClaudePaths.recentLogFiles(within: 2)
            .filter { Self.mtime($0) > (parsedMTimes[$0] ?? .distantPast) }
        guard !changed.isEmpty else { return }
        lastReingest = Date()
        Task { await ingest(changed) }
    }

    private static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    func refresh() {
        snapshot = store.snapshot(now: Date())
        readStatusFeed()
        trackSessionPct()
    }

    /// Sample the displayed session % into the burn-rate history. Runs on the 5s tick as well
    /// as the 60s limits fetch, so the ETA warms up in about a minute instead of several.
    /// Unchanged values are re-sampled at most every 15s to keep the trend window populated
    /// without flooding the buffer.
    private func trackSessionPct() {
        guard let p = sessionUsage else { return }
        if let last = pctHistory.last, last.pct == p, Date().timeIntervalSince(last.t) < 15 { return }
        pctHistory.append((Date(), p))
        if pctHistory.count > 80 { pctHistory.removeFirst(pctHistory.count - 80) }
    }

    /// Terminal statusline feed (fallback source for session % and context).
    private func readStatusFeed() {
        guard let data = try? Data(contentsOf: usageFileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let rem = (obj["rate_remaining"] as? NSNumber)?.doubleValue {
            statuslineUsage = max(0, min(1, (100 - rem) / 100))
        }
        if let ctx = (obj["ctx_remaining"] as? NSNumber)?.doubleValue {
            contextRemaining = max(0, min(1, ctx / 100))
        }
    }

    /// Weekly reset fallback from ~/.claude.json (used only until the live fetch lands).
    private func readPlanLimits() {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let gb = root["cachedGrowthBookFeatures"] as? [String: Any],
           let lattice = gb["tengu_saffron_lattice"] as? [String: Any],
           let iso = lattice["planLimitsEndDate"] as? String {
            weeklyResetFromConfig = ISO8601DateFormatter().date(from: iso)
        }
        if let oauth = root["oauthAccount"] as? [String: Any],
           let type = oauth["organizationType"] as? String {
            planName = Fmt.organizationTypeLabel(type)
        }
    }
}
