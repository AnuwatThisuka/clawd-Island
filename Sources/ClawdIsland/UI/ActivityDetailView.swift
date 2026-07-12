import SwiftUI

/// The live-activity detail band shown below the notch while Claude Code runs a tool (Phase D).
/// Centered verb headline ("Editing") with a softly pulsing underline, and the file/command/query
/// subtitle beneath it. The elapsed timer lives in the notch's right wing (`ActivityTimer`), not
/// here, so it sits at the pill's top-right corner exactly as in the reference layout.
struct ActivityDetailView: View {
    let activity: SessionActivity

    /// Drives the underline's opacity pulse — the "small animated indicator" from the plan, kept
    /// as a cheap opacity breathe rather than a guessed pixel-for-pixel motion.
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 3) {
            Text(activity.verb)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.7)

            // Animated underline: a short bar under the verb that breathes between faint and bright.
            Capsule()
                .fill(Color.tileGreen)
                .frame(width: 22, height: 2)
                .opacity(pulse ? 1 : 0.3)

            if let subtitle = activity.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.8)
            }

            // "+N" when several sessions run at once, kept quiet below the subtitle.
            if activity.runningCount > 1 {
                Text("+\(activity.runningCount - 1) more")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

/// Live "m:ss" elapsed timer for the notch's right wing. Ticks on its own 1s TimelineView schedule,
/// independent of AppModel's ~300ms state poll, so the seconds advance smoothly and don't jitter or
/// depend on when the hook feed happens to re-read.
struct ActivityTimer: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Text(Fmt.elapsed(context.date.timeIntervalSince(startedAt)))
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}
