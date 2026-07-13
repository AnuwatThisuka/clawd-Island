import SwiftUI

/// The approval band shown below the notch when Claude Code is blocked on a gated tool. Mirrors
/// the reference (vibe-notch) UX: a one-line "what wants to run" summary and two big Approve /
/// Deny buttons, so the user never has to switch to the terminal to answer a permission prompt.
///
/// Priority over the live-activity band: a pending request is a hard stop for the session, so it
/// takes the drop slot even while another tool's activity is running.
struct PermissionView: View {
    let request: PermissionRequest
    /// How many requests are queued behind this one (0 when this is the only one).
    let queued: Int
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            header
            summary
            buttons
            if queued > 0 {
                Text("\(queued) more waiting")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    /// Amber "permission needed" cue — distinct from the green live-activity accent so a stop reads
    /// as a stop, not as normal running status.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.permissionAmber)
            Text("Permission needed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.permissionAmber)
            Spacer(minLength: 0)
            if let project = request.projectName {
                Text(project)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    /// "Running · npm install" — the verb plus the salient argument, same wording as live activity.
    private var summary: some View {
        VStack(spacing: 2) {
            Text(request.verb)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.8)
            if let subtitle = request.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.8)
            } else {
                Text(request.prettyTool)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            actionButton(title: "Deny", tint: Color.permissionRed, action: onDeny)
            actionButton(title: "Approve", tint: Color.tileGreen, action: onApprove)
        }
    }

    private func actionButton(title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(tint.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

extension Color {
    /// Attention accent for a pending permission (a stop, not the green "running" state).
    static let permissionAmber = Color(red: 1.0, green: 0.75, blue: 0.3)
    /// Deny action tint.
    static let permissionRed = Color(red: 1.0, green: 0.45, blue: 0.42)
}
