import SwiftUI
import AppKit

/// Top-anchors the pill inside the fixed full-width window, horizontally centered on the notch.
/// The pill stays flush with the top screen edge in every state; only its height grows downward.
struct IslandRootView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            IslandView(model: model, notchWidth: model.notchWidth, topInset: model.topInset)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The notch-fused black island. Closed: Clawd + session-% flanking the camera. Expanded: it
/// grows taller and a little wider, dropping a Usage Monitor panel below the notch. The
/// NotchShape's radii animate, so it morphs like the notch itself growing.
struct IslandView: View {
    let model: AppModel
    let notchWidth: CGFloat
    let topInset: CGFloat

    /// 5-Hour row: false = show burn-rate ETA when available, true = always show reset.
    @State private var prefReset = false

    private let closedWing: CGFloat = 56
    private let iconSize: CGFloat = 18
    private let edgeInset: CGFloat = 12   // keeps content off the pill's flared edges
    /// Wider than the closed pill so the limit rows + stats can breathe like the reference card.
    private let expandedWidth: CGFloat = 400

    private var expanded: Bool { model.isExpanded }
    private var dropHeight: CGFloat { model.dropHeight }   // measured from the monitor panel
    private var closedH: CGFloat { max(topInset, 30) }
    private var gap: CGFloat { notchWidth }
    private var closedWidth: CGFloat { closedWing + gap + closedWing + edgeInset * 2 }
    /// Closed: tight around the camera. Open: grows sideways so the dashboard fits.
    private var pillWidth: CGFloat { expanded ? max(closedWidth, expandedWidth) : closedWidth }
    /// Side wings stretch with the pill so the avatar / % stay camera-flanking when open.
    private var wing: CGFloat { max(closedWing, (pillWidth - gap - edgeInset * 2) / 2) }
    private var used: Double { model.sessionUsage ?? 0 }

    /// A tool is running and the user hasn't click-opened the monitor, so the pill auto-drops the
    /// live-activity detail band. A manual expand (monitor panel) takes precedence over it.
    private var showActivityBand: Bool { model.activity != nil && !expanded }

    /// How far the pill grows below the notch: the monitor when click-opened, the activity band
    /// when a tool runs, otherwise nothing (stays a closed pill).
    private var contentDropHeight: CGFloat {
        if expanded { return dropHeight }
        if showActivityBand { return model.activityDropHeight }
        return 0
    }

    var body: some View {
        let dropped = expanded || showActivityBand
        let shape = NotchShape(topRadius: 8,
                               bottomRadius: dropped ? 22 : max(10, closedH * 0.40))
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            VStack(spacing: 0) {
                notchRow.frame(width: pillWidth, height: closedH)
                if expanded {
                    dropDown
                        .frame(width: pillWidth, alignment: .top)   // natural height, measured below
                        .background(dropHeightReader)
                } else if let act = model.activity {
                    ActivityDetailView(activity: act)
                        .frame(width: closedWidth, alignment: .top)
                        .background(activityHeightReader)
                }
            }
        }
        .frame(width: pillWidth,
               height: closedH + contentDropHeight,
               alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
        .contextMenu { menu }
        // Notchnook / Dynamic Island feel: snappy drop with a light elastic settle
        // (was response 0.6 / damping 1.0 — heavy and critically damped).
        .animation(Self.islandSpring, value: expanded)
        .animation(Self.islandSpring, value: dropHeight)
        .animation(Self.islandSpring, value: model.activityDropHeight)
        .animation(.easeInOut(duration: 0.3), value: used)
        .animation(.easeInOut(duration: 0.25), value: model.activity)
    }

    private static let islandSpring = Animation.spring(response: 0.38, dampingFraction: 0.82)

    // Right-click menu (replaces the menu-bar item).
    @ViewBuilder private var menu: some View {
        Menu("Icon") {
            ForEach(AvatarStyle.allCases) { style in
                Button {
                    model.setAvatar(style)
                } label: {
                    if model.avatarStyle == style {
                        Label(style.label, systemImage: "checkmark")
                    } else {
                        Text(style.label)
                    }
                }
            }
        }
        Button(model.isPaused ? "Resume tracking" : "Pause tracking") { model.togglePause() }
        Button((model.animateIcon ? "✓ " : "") + "Animate icon") { model.toggleAnimateIcon() }
        Button((model.notifier.isEnabled ? "✓ " : "") + "Threshold alerts") { model.toggleNotifications() }
        Button((LoginItem.isEnabled ? "✓ " : "") + "Launch at Login") { LoginItem.toggle() }
        Divider()
        Button("Check for Updates…") { Updater.shared.checkForUpdates() }
        Divider()
        Button("Clawd Island v\(AppInfo.version) — \(AppInfo.tagline)") {}.disabled(true)
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }

    // MARK: closed row

    private var notchRow: some View {
        HStack(spacing: 0) {
            AvatarView(style: model.avatarStyle, active: model.animateIcon && !model.isPaused && !model.isAtLimit,
                       urgency: model.iconUrgency)
                .frame(width: iconSize, height: iconSize)
                .frame(width: wing, height: closedH)
                .onTapGesture { model.cycleAvatar() }
                .help("Click to change the icon")

            Color.clear.frame(width: gap, height: closedH)

            Group {
                // While a tool is running, the right wing shows the live elapsed timer (with the
                // verb/subtitle detail dropping below the notch); otherwise the session-usage
                // readout. Real-time status takes priority over the % when both exist.
                if let act = model.activity {
                    ActivityTimer(startedAt: act.startedAt)
                } else {
                    usageReadout
                }
            }
            .frame(width: wing, height: closedH)
            .contentShape(Rectangle())
            .onTapGesture { model.isExpanded.toggle() }
        }
        .padding(.horizontal, edgeInset)
    }

    // Session-usage %, shown when Claude Code is idle.
    private var usageReadout: some View {
        HStack(spacing: 5) {
            Text(model.sessionUsage.map(Fmt.pct) ?? "—")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white)
            Ring(fraction: used, state: RingState(usage: used), lineWidth: 3)
                .frame(width: 14, height: 14)
        }
        .opacity(model.isStale ? 0.5 : 1)          // dim when data isn't fresh
    }

    // Reports the drop-down's natural laid-out height into the model, so the pill frame and the
    // window's click-catcher both track the real content instead of a hard-coded constant.
    private var dropHeightReader: some View {
        GeometryReader { geo in
            Color.clear.onChange(of: geo.size.height, initial: true) { _, h in
                if h > 0 { model.dropHeight = h }
            }
        }
    }

    // Same contract as `dropHeightReader`, but for the live-activity band — feeds its measured
    // height into the model so the pill and click-catcher size to the real verb/subtitle content.
    private var activityHeightReader: some View {
        GeometryReader { geo in
            Color.clear.onChange(of: geo.size.height, initial: true) { _, h in
                if h > 0 { model.activityDropHeight = h }
            }
        }
    }

    // MARK: drop-down — Usage Monitor panel below the notch

    private var dropDown: some View {
        let s = model.snapshot
        return VStack(spacing: 0) {
            statusRow
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 10)

            divider

            limitRow(title: "5-Hour Limit", icon: "hourglass",
                     value: model.sessionUsage, segments: 5,
                     resets: model.sessionResetsAt,
                     eta: prefReset ? nil : model.etaToLimit)
                .contentShape(Rectangle())
                .onTapGesture { if model.etaToLimit != nil { prefReset.toggle() } }
                .help(model.etaToLimit != nil ? "Click to switch reset / burn-rate" : "")
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            divider

            limitRow(title: "7-Day Limit", icon: "calendar.badge.checkmark",
                     value: model.weeklyUsage, segments: 7,
                     resets: model.weeklyResetsAt,
                     breakdown: weeklyBreakdown)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            divider

            HStack(alignment: .top, spacing: 0) {
                statCol(icon: "cpu", label: "Tokens Today",
                        value: s.isEmpty ? "—" : Fmt.tokens(s.tokensToday), numeric: true)
                statCol(icon: "dollarsign.circle", label: "Cost Today",
                        value: s.isEmpty ? "—" : Fmt.usd(s.costToday), numeric: true)
                statCol(icon: "crown", label: "Plan", value: shortPlan, numeric: false)
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 12)

            divider

            footer
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
        .opacity(model.isStale ? 0.55 : 1)
    }

    private var shortPlan: String {
        (model.planName ?? "Claude").replacingOccurrences(of: "Claude ", with: "")
    }

    /// "Opus 42% · Sonnet 88%" when the source splits the 7-day limit by model, else nil.
    private var weeklyBreakdown: String? {
        guard let o = model.weeklyOpusUsage, let s = model.weeklySonnetUsage else { return nil }
        return "Opus \(Fmt.pct(o)) · Sonnet \(Fmt.pct(s))"
    }

    /// Compact status pill under the notch — red accent matches the reference card.
    private var statusRow: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
            Spacer(minLength: 0)
        }
    }

    private var statusLabel: String {
        if model.isStale { return "Reconnecting" }
        if model.isAtLimit { return "Limit Reached" }
        if model.iconUrgency >= 0.85 { return "Approaching Limit" }
        return "All Systems Normal"
    }

    private var statusColor: Color {
        if model.isStale { return .tileAmber }
        return .tileRed
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 16)
    }

    /// One horizontal limit row: icon box, title + reset subline, segmented bar, trailing %.
    private func limitRow(title: String, icon: String, value: Double?, segments: Int,
                          resets: Date?, eta: TimeInterval? = nil,
                          breakdown: String? = nil) -> some View {
        let frac = value ?? 0
        let color = barColor(frac)
        return HStack(spacing: 12) {
            iconBox(icon, color: color)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        if let eta {
                            Text("~\(Fmt.dur(eta)) to limit")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.tileAmber)
                                .lineLimit(1)
                        } else {
                            Text(resets.map { "resets in \(Fmt.until($0))" } ?? "resets —")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                        if let breakdown {
                            Text(breakdown)
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.4))
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 2) {
                        Text(value.map(Fmt.pct) ?? "—")
                            .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(color)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(color.opacity(0.7))
                    }
                }
                segmentedBar(fraction: frac, segments: segments, color: color)
            }
        }
    }

    private func iconBox(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 32, height: 32)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Segmented meter: `segments` slots, filled left-to-right by `fraction`.
    private func segmentedBar(fraction: Double, segments: Int, color: Color) -> some View {
        let clamped = min(1, max(0, fraction))
        let filled = Int((clamped * Double(segments)).rounded(.toNearestOrAwayFromZero))
        return HStack(spacing: 3) {
            ForEach(0..<segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(i < filled ? color : Color.white.opacity(0.12))
                    .frame(height: 8)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: fraction)
    }

    /// One column in the Tokens / Cost / Plan strip.
    @ViewBuilder
    private func statCol(icon: String, label: String, value: String, numeric: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.tileRed)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            if numeric {
                Text(value)
                    .font(.system(size: 18, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Text(value)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9, weight: .medium))
            Text(model.lastFetch.map {
                "Updated \(Fmt.ago($0)) ago" + (model.isStale ? " · reconnecting" : "")
            } ?? "token estimate")
            Spacer(minLength: 0)
            Text(model.usageSource)
        }
        .font(.system(size: 10))
        .foregroundStyle(model.isStale ? Color.tileAmber : .white.opacity(0.4))
    }

    private func barColor(_ used: Double) -> Color {
        switch RingState(usage: used) {
        case .ok: return .tileRed          // brand accent (matches the reference card)
        case .warn: return .tileAmber
        case .critical: return .tileRed
        }
    }
}

extension Color {
    /// Warn/critical accents for monitor values and the stale-data notice. (The ring in
    /// `Ring.swift` uses its own, deliberately brighter palette and is left untouched.)
    static let tileAmber = Color(red: 0.96, green: 0.70, blue: 0.20)
    static let tileRed = Color(red: 0.92, green: 0.34, blue: 0.34)
    /// Live-activity accent for the running-tool indicator dot.
    static let tileGreen = Color(red: 0.36, green: 0.85, blue: 0.52)
}
