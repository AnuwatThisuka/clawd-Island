import Foundation
import UserNotifications

/// Fires a native macOS notification when session (5-hour) or weekly (7-day) usage first crosses
/// a threshold (80%, then 95%). Each threshold notifies once per limit period; when a limit resets
/// (its `resetsAt` jumps forward) its fired thresholds re-arm so the next period notifies again.
///
/// Only functional in the bundled `.app` — `UNUserNotificationCenter` needs a bundle identifier, so
/// this is inert (and never touches the notification center) under `swift run`.
@MainActor
final class NotificationManager {

    /// Usage fractions (0…1) at which to notify, low → high.
    private static let thresholds: [Double] = [0.80, 0.95]

    /// Whether threshold notifications are on. Persisted; default on.
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            if isEnabled { requestAuthorization() }
        }
    }

    /// True once the OS notification bundle is usable (i.e. we're a real .app).
    private let available: Bool = Bundle.main.bundleIdentifier != nil
    private var didRequestAuth = false

    private enum Keys {
        static let enabled = "notificationsEnabled"
        static let session = "notifFiredSession"      // [Int] percent thresholds already fired
        static let weekly = "notifFiredWeekly"
        static let sessionReset = "notifSessionResetKey"   // resets_at epoch for the fired set above
        static let weeklyReset = "notifWeeklyResetKey"
    }

    init() {
        // Default on: absent key reads as true.
        isEnabled = (UserDefaults.standard.object(forKey: Keys.enabled) as? Bool) ?? true
        if isEnabled { requestAuthorization() }
    }

    /// Ask the user for notification permission (no-op if denied earlier — the OS just ignores it).
    private func requestAuthorization() {
        guard available, !didRequestAuth else { return }
        didRequestAuth = true
        // Use the async API — the callback variant invokes its handler on a background queue,
        // which traps under @MainActor isolation checking.
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Evaluate both limits against the thresholds and fire any newly crossed ones. Safe to call on
    /// every limits refresh — a threshold fires at most once per period.
    func evaluate(session: Double?, sessionResetsAt: Date?,
                  weekly: Double?, weeklyResetsAt: Date?) {
        guard isEnabled, available else { return }
        check(usage: session, resetsAt: sessionResetsAt,
              firedKey: Keys.session, resetKey: Keys.sessionReset, limitName: "5-hour session")
        check(usage: weekly, resetsAt: weeklyResetsAt,
              firedKey: Keys.weekly, resetKey: Keys.weeklyReset, limitName: "weekly")
    }

    private func check(usage: Double?, resetsAt: Date?,
                       firedKey: String, resetKey: String, limitName: String) {
        guard let usage else { return }
        let defaults = UserDefaults.standard

        // A new period (reset time advanced) clears the fired set so it can notify again.
        let resetEpoch = resetsAt?.timeIntervalSince1970 ?? 0
        let storedEpoch = defaults.double(forKey: resetKey)
        if abs(resetEpoch - storedEpoch) > 1 {
            defaults.set(resetEpoch, forKey: resetKey)
            defaults.removeObject(forKey: firedKey)
        }

        var fired = Set(defaults.array(forKey: firedKey) as? [Int] ?? [])
        for t in Self.thresholds {
            let pct = Int((t * 100).rounded())
            guard usage >= t, !fired.contains(pct) else { continue }
            fired.insert(pct)
            notify(percent: pct, limitName: limitName, resetsAt: resetsAt)
        }
        defaults.set(Array(fired), forKey: firedKey)
    }

    private func notify(percent: Int, limitName: String, resetsAt: Date?) {
        let content = UNMutableNotificationContent()
        content.title = "Claude usage at \(percent)%"
        var body = "You've used \(percent)% of your \(limitName) limit."
        if let resetsAt {
            body += " Resets in \(Fmt.until(resetsAt))."
        }
        content.body = body
        content.sound = percent >= 95 ? .default : nil

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
