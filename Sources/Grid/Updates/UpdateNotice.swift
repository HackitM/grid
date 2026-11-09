import AppKit
import SwiftUI

/// The status-bar cell for updates: the one-time "check daily?" question, then (if a newer
/// version is found) `◆ GRID x.y.z AVAILABLE` with View and dismiss. Shown once per version;
/// it never comes back after you dismiss, skip or open it.
struct UpdateStatusCell: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let u = app.updates
        if u.needsConsent {
            cell {
                Text("◆").font(.system(size: 7)).foregroundStyle(theme.accent)
                TypeOnText(text: "CHECK GITHUB DAILY FOR GRID UPDATES?", font: GridFont.label, color: theme.textDim, tracking: 1, duration: 0.3)
                    .lineLimit(1)
                    .help("GRID sends a plain request to api.github.com once a day, with no identifiers. Change it any time in Settings › Updates.")
                button("Check daily") { u.setCheckDaily(true) }
                button("Not now") { u.setCheckDaily(false) }
            }
        } else if u.showsNotice, let v = u.available?.version {
            cell {
                Text("◆").font(.system(size: 7)).foregroundStyle(theme.accent)
                // Ares text band: types on once, behind a sweeping highlight.
                TypeOnText(text: "GRID \(v) AVAILABLE", font: GridFont.label, color: theme.accent, tracking: 1, duration: 0.26)
                    .lineLimit(1)
                button("View") { u.dismissNotice(); app.settingsSection = "updates"; app.show(.settings) }
                Button { u.dismissNotice() } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(theme.textMute)
                        .frame(width: 14, height: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss (Settings › Updates still shows it)")
                .accessibilityLabel("Dismiss update notice")
            }
        }
    }

    private func cell<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .background(theme.accent.opacity(0.06))
            .overlay(alignment: .trailing) { Rectangle().fill(theme.line).frame(width: Metrics.hairline) }
            .accessibilityElement(children: .contain)
    }

    private func button(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(GridButtonStyle(compact: true))
            .controlSize(.mini)
            .frame(height: 18)
    }
}
