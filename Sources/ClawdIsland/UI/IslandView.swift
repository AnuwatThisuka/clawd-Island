import SwiftUI
import AppKit

/// Top-anchors the pill inside the fixed full-width window, horizontally centered on the notch.
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
/// grows taller (never wider), dropping a tile grid below the notch. The NotchShape's radii
/// animate, so it morphs like the notch itself growing.
struct IslandView: View {
    let model: AppModel
    let notchWidth: CGFloat
    let topInset: CGFloat

    /// 5-Hour tile: false = show burn-rate ETA when available, true = always show reset.
    @State private var prefReset = false
    /// Drives the pulsing activity dot shown while Claude Code is running a tool.
    @State private var pulse = false

    private let wing: CGFloat = 56
    private let iconSize: CGFloat = 18
    private let edgeInset: CGFloat = 12   // keeps content off the pill's flared edges

    private var expanded: Bool { model.isExpanded }
    private var dropHeight: CGFloat { model.dropHeight }   // measured from the tile grid
    private var closedH: CGFloat { max(topInset, 30) }
    private var gap: CGFloat { notchWidth }
    private var closedWidth: CGFloat { wing + gap + wing + edgeInset * 2 }
    private var used: Double { model.sessionUsage ?? 0 }

    var body: some View {
        let shape = NotchShape(topRadius: 8,
                               bottomRadius: expanded ? 22 : max(10, closedH * 0.40))
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            VStack(spacing: 0) {
                notchRow.frame(width: closedWidth, height: closedH)
                dropDown
                    .frame(width: closedWidth, alignment: .top)   // natural height, measured below
                    .background(dropHeightReader)
                    .opacity(expanded ? 1 : 0)
            }
        }
        .frame(width: closedWidth,
               height: expanded ? closedH + dropHeight : closedH,
               alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
        .contextMenu { menu }
        .animation(.spring(response: 0.6, dampingFraction: 1.0), value: expanded)
        .animation(.spring(response: 0.6, dampingFraction: 1.0), value: dropHeight)
        .animation(.easeInOut(duration: 0.3), value: used)
        .animation(.easeInOut(duration: 0.25), value: model.activity)
    }

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
                // While a tool is running, the right wing shows the live tool name; otherwise the
                // session-usage readout. Real-time status takes priority over the % when both exist.
                if let act = model.activity {
                    activityReadout(act)
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

    // Live tool status: a pulsing dot plus the running tool's name (with a "+N" badge when more
    // than one session is active). Text scales down before it clips in the narrow wing.
    private func activityReadout(_ act: SessionActivity) -> some View {
        HStack(spacing: 4) {
            Circle().fill(Color.tileGreen)
                .frame(width: 6, height: 6)
                .opacity(pulse ? 1 : 0.35)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
            Text(act.runningCount > 1 ? "\(act.tool) +\(act.runningCount - 1)" : act.tool)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.6)
        }
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

    // MARK: drop-down — tile grid below the notch

    private var dropDown: some View {
        let s = model.snapshot
        return VStack(spacing: 8) {
            LazyVGrid(columns: [.init(.flexible(), spacing: 8), .init(.flexible(), spacing: 8)], spacing: 8) {
                limitTile("5-Hour", icon: "hourglass", model.sessionUsage, resets: model.sessionResetsAt,
                          eta: prefReset ? nil : model.etaToLimit)
                    .contentShape(Rectangle())
                    .onTapGesture { if model.etaToLimit != nil { prefReset.toggle() } }
                    .help(model.etaToLimit != nil ? "Click to switch reset / burn-rate" : "")
                limitTile("7-Day", icon: "calendar", model.weeklyUsage, resets: model.weeklyResetsAt,
                          breakdown: weeklyBreakdown)
                tile("credits", icon: "gift", model.limits?.creditsPct.map { Fmt.pct($0) + " used" } ?? "none", numeric: true)
                tile("cost today", icon: "dollarsign.circle", s.isEmpty ? "—" : Fmt.usd(s.costToday), numeric: true)
                tile("tokens today", icon: "cpu", s.isEmpty ? "—" : Fmt.tokens(s.tokensToday), numeric: true)
                tile("plan", icon: "crown", shortPlan, numeric: false)
            }
            .opacity(model.isStale ? 0.55 : 1)         // dim live limits when not fresh

            HStack {
                Text(model.lastFetch.map { "Updated \(Fmt.ago($0)) ago" + (model.isStale ? " · reconnecting" : "") }
                     ?? "token estimate")
                    .foregroundStyle(model.isStale ? Color.tileAmber
                                                    : .white.opacity(0.4))
                Spacer()
                Text(model.usageSource).foregroundStyle(.white.opacity(0.4))
            }
            .font(.system(size: 10))
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 9)
    }

    private var shortPlan: String {
        (model.planName ?? "Claude").replacingOccurrences(of: "Claude ", with: "")
    }

    /// "Opus 42% · Sonnet 88%" when the source splits the 7-day limit by model, else nil.
    private var weeklyBreakdown: String? {
        guard let o = model.weeklyOpusUsage, let s = model.weeklySonnetUsage else { return nil }
        return "Opus \(Fmt.pct(o)) · Sonnet \(Fmt.pct(s))"
    }

    // A primary limit tile: icon+label, a large colour-coded %, a thin progress bar showing the
    // real fraction, a "resets in …" subline, and an optional per-model breakdown line (used by
    // the 7-Day tile when Opus/Sonnet are tracked separately). These read as the top tier: bigger
    // number, stronger card fill than the secondary tiles below.
    private func limitTile(_ label: String, icon: String, _ value: Double?, resets: Date?,
                           eta: TimeInterval? = nil, breakdown: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            tileLabel(label, icon: icon)
            Text(value.map(Fmt.pct) ?? "—")
                .font(.system(size: 26, weight: .medium)).monospacedDigit()   // mono: no jitter on 60s updates
                .foregroundStyle(barColor(value ?? 0))
            progressBar(value ?? 0)
            if let eta {
                Text("~\(Fmt.dur(eta)) to limit")
                    .font(.system(size: 9.5, weight: .medium)).lineLimit(1)
                    .foregroundStyle(Color.tileAmber)
            } else {
                Text(resets.map { "resets in \(Fmt.until($0))" } ?? "resets —")
                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            if let breakdown {
                Text(breakdown)
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .tileCard(0.09)
    }

    // A secondary value tile: smaller number, fainter card. Clearly a lower tier than the two
    // limit tiles above. `numeric` gets monospaced digits (steady width as values tick).
    private func tile(_ label: String, icon: String, _ value: String, numeric: Bool) -> some View {
        let valueText = Text(value).font(.system(size: 15, weight: .medium))
        return VStack(alignment: .leading, spacing: 2) {
            tileLabel(label, icon: icon)
            (numeric ? valueText.monospacedDigit() : valueText)
                .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .tileCard(0.035)
    }

    // Shared icon+label header row for every tile.
    private func tileLabel(_ label: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(label).font(.system(size: 10))
        }
        .foregroundStyle(.white.opacity(0.5))
    }

    // Thin rounded bar filling to `fraction`, colour-matched to the % via barColor/RingState.
    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(barColor(fraction))
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
        .animation(.easeInOut(duration: 0.5), value: fraction)
    }

    private func barColor(_ used: Double) -> Color {
        switch RingState(usage: used) {
        case .ok: return .white
        case .warn: return .tileAmber
        case .critical: return .tileRed
        }
    }
}

private extension View {
    /// The translucent rounded backing shared by every island tile. `opacity` sets the tier:
    /// stronger for the primary limit tiles, fainter for the secondary value tiles.
    func tileCard(_ opacity: Double = 0.06) -> some View {
        background(Color.white.opacity(opacity))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private extension Color {
    /// Warn/critical accents for tile values and the stale-data notice. (The ring in
    /// `Ring.swift` uses its own, deliberately brighter palette and is left untouched.)
    static let tileAmber = Color(red: 0.96, green: 0.70, blue: 0.20)
    static let tileRed = Color(red: 0.92, green: 0.34, blue: 0.34)
    /// Live-activity accent for the running-tool indicator dot.
    static let tileGreen = Color(red: 0.36, green: 0.85, blue: 0.52)
}
