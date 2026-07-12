import SwiftUI

enum Fmt {
    static func hm(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        return "\(m / 60)h \(String(format: "%02d", m % 60))m"
    }
    static func pct(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
    /// "1h 10m" (under a day) or "4d 17h" (a day or more).
    static func until(_ date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        return d > 0 ? "\(d)d \(h)h" : "\(h)h \(String(format: "%02d", m))m"
    }
    /// "35m" / "1h 05m" — a duration.
    static func dur(_ t: TimeInterval) -> String {
        let m = max(0, Int(t) / 60)
        return m >= 60 ? "\(m / 60)h \(String(format: "%02d", m % 60))m" : "\(m)m"
    }
    /// "4s" / "2m" / "1h" — compact age of a timestamp.
    static func ago(_ date: Date) -> String {
        let s = max(0, Int(-date.timeIntervalSinceNow))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.0fK", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }
    static func usd(_ v: Double) -> String { String(format: "$%.2f", v) }

    /// Elapsed time as "m:ss" for the live activity timer (e.g. 65s → "1:05").
    /// Minutes aren't zero-padded (matches the reference's "0:05"); negatives clamp to "0:00".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    /// "default_claude_max_5x" -> "Claude Max 5x"; "default_claude_ai" -> "Claude Free".
    static func planLabel(_ raw: String) -> String {
        // Explicit labels for every tier we've actually observed from
        // oauthAccount.organizationRateLimitTier in ~/.claude.json. Note that
        // "default_claude_ai" is the base/free tier — the old generic logic
        // stripped it down to "ai" and rendered "Claude Ai".
        let known: [String: String] = [
            "default_claude_ai": "Claude Free",
            "default_claude_pro": "Claude Pro",
            "default_claude_max_5x": "Claude Max 5x",
            "default_claude_max_20x": "Claude Max 20x",
            "default_claude_team": "Claude Team",
            "default_claude_enterprise": "Claude Enterprise",
        ]
        if let label = known[raw] { return label }

        // Fallback for an unknown/future tier: strip the known prefixes and
        // prettify so it still reads as a plan name rather than a raw token.
        var s = raw.replacingOccurrences(of: "default_", with: "")
                   .replacingOccurrences(of: "claude_", with: "")
        if s.hasPrefix("max_") {
            s = s.replacingOccurrences(of: "max_", with: "")
            return "Claude Max \(s)"          // e.g. "50x"
        }
        return "Claude " + s.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
