import Foundation

/// Shared ISO 8601 timestamp parsing for the JSONL logs and the claude.ai JSON,
/// both of which mix whole-second (`2026-07-12T10:00:00Z`) and fractional-second
/// (`2026-07-12T10:00:00.123Z`) forms. A given string parses under exactly one of
/// the two option sets — `.withFractionalSeconds` matches only strings that carry
/// a fractional part, and its absence matches only those that don't — so trying
/// the fractional formatter first and the whole-second one as a fallback returns
/// the same `Date` regardless of order. Callers therefore need not know which form
/// a particular field uses.
///
/// ## Concurrency
/// `ISO8601DateFormatter` is a reference type that Foundation has not annotated as
/// `Sendable`, yet the two instances here are configured once in `init` and are
/// only ever *read* from afterwards via `date(from:)` — their `formatOptions` are
/// never mutated again. Foundation's date formatters are documented as safe for
/// concurrent formatting/parsing once configured, so sharing these immutable,
/// read-only instances across isolation domains is race-free. That is the specific,
/// reviewed reason for `@unchecked Sendable` — it is not a blanket opt-out of the
/// checker. (Building the formatters per call would also be correct but allocates
/// two ICU-backed formatters on every parsed log line, which this hot path avoids.)
enum ISO8601 {
    private struct Parser: @unchecked Sendable {
        let fractional = ISO8601DateFormatter()
        let wholeSecond = ISO8601DateFormatter()
        init() {
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            wholeSecond.formatOptions = [.withInternetDateTime]
        }
        func date(from string: String) -> Date? {
            fractional.date(from: string) ?? wholeSecond.date(from: string)
        }
    }

    private static let parser = Parser()

    /// Parse an internet ISO-8601 timestamp, with or without fractional seconds.
    static func date(from string: String) -> Date? { parser.date(from: string) }
}
