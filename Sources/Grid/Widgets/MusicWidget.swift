import AppKit
import SwiftUI

/// How the Now Playing widget draws cover art.
enum ArtStyle: String, CaseIterable {
    /// A dot matrix like the new tab globe: dot size follows brightness.
    case dots
    /// Banded scan lines, like the board-room screens' video feeds.
    case lines
    case off

    var label: String {
        switch self { case .dots: "Dot matrix"; case .lines: "Scan lines"; case .off: "Hidden" }
    }
}

// MARK: - Widget

struct NowPlayingWidget: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let widget: WidgetInstance

    var body: some View {
        let np = app.nowPlaying
        let style = ArtStyle(rawValue: widget.string("art", ArtStyle.dots.rawValue)) ?? .dots
        VStack(alignment: .leading, spacing: 8) {
            if let t = np.track, let player = np.player {
                let side: CGFloat = widget.expanded ? 132 : 66
                HStack(alignment: .top, spacing: 10) {
                    if style != .off {
                        ArtworkView(matrix: np.artwork, style: style, key: t.id)
                            .frame(width: side, height: side)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Tag(np.playing ? "play" : "pause", color: np.playing ? theme.accent : theme.textMute)
                            WidgetFootnote(text: player.name)
                        }
                        Text(t.title).font(GridFont.bodyStrong).foregroundStyle(theme.text)
                            .lineLimit(widget.expanded ? 3 : 2)
                        if !t.artist.isEmpty {
                            Text(t.artist).font(GridFont.small).foregroundStyle(theme.textDim).lineLimit(1)
                        }
                        if widget.expanded || style == .off, !t.album.isEmpty {
                            Text(t.album).font(GridFont.small).foregroundStyle(theme.textMute).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(np.playing ? "Playing" : "Paused") in \(player.name): \(t.title)\(t.artist.isEmpty ? "" : " by \(t.artist)")")
                PlaybackProgress(np: np, duration: t.duration)
                HStack(spacing: 6) {
                    TransportButtons(np: np)
                    Spacer(minLength: 4)
                    if np.access[player] != .granted {
                        AccessHint(np: np, player: player, compact: true)
                    }
                    if !widget.bool("float", false) {
                        IconButton(symbol: "pip.exit", label: "Pop out: keep it above every page") { app.floatingWidgets.popOut(widget.id) }
                    }
                }
            } else {
                EmptyNowPlaying(np: np)
            }
        }
    }
}

/// Play/pause and skip buttons.
struct TransportButtons: View {
    @Environment(\.theme) private var theme
    let np: NowPlaying
    var size: CGFloat = 24

    var body: some View {
        HStack(spacing: 4) {
            button("backward.end.fill", "Previous track") { np.previous() }
            button(np.playing ? "pause.fill" : "play.fill", np.playing ? "Pause" : "Play", prominent: true) { np.playPause() }
            button("forward.end.fill", "Next track") { np.next() }
        }
    }

    private func button(_ symbol: String, _ label: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold))
                .frame(width: size * (prominent ? 1.5 : 1.15), height: size)
        }
        .buttonStyle(TransportStyle(prominent: prominent))
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct TransportStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? theme.textOnAccent : theme.text)
            .background(prominent ? theme.accent.opacity(configuration.isPressed ? 0.7 : 1)
                                  : (configuration.isPressed ? theme.accentSoft : theme.bg2))
            .clipShape(ClippedRect(cut: 5, topRight: true))
            .overlay(ClippedRect(cut: 5, topRight: true).stroke(prominent ? .clear : theme.line, lineWidth: Metrics.hairline))
            .contentShape(Rectangle())
    }
}

/// Elapsed / total with a segment bar. Ticks once a second, and only while playing.
private struct PlaybackProgress: View {
    @Environment(\.theme) private var theme
    let np: NowPlaying
    let duration: Double?

    var body: some View {
        if np.playing {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in row(np.position(at: ctx.date)) }
        } else {
            row(np.position(at: Date()))
        }
    }

    private func row(_ pos: Double?) -> some View {
        HStack(spacing: 8) {
            Text(pos.map(Self.time) ?? "--:--").font(GridFont.small).foregroundStyle(theme.textDim).monospacedDigit()
            SegmentBar(value: (pos ?? 0) / max(duration ?? 0, 1), segments: 32, warnAbove: 2)
            Text(duration.map(Self.time) ?? "--:--").font(GridFont.small).foregroundStyle(theme.textMute).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pos.map { "\(Self.time($0)) of \(duration.map(Self.time) ?? "unknown")" } ?? "Position unknown")
    }

    static func time(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Nothing to show yet: which player is open, and what GRID needs to show it.
private struct EmptyNowPlaying: View {
    @Environment(\.theme) private var theme
    let np: NowPlaying

    var body: some View {
        let running = NowPlaying.Player.allCases.filter(\.isRunning)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ArtworkView(matrix: nil, style: .dots, key: "idle").frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(running.isEmpty ? "NOTHING PLAYING" : "NO TRACK YET").font(GridFont.label).tracking(1.2).foregroundStyle(theme.textDim)
                    Text(running.isEmpty ? "Start Apple Music or Spotify." : "Press play in \(running.map(\.name).joined(separator: " or ")).")
                        .font(GridFont.small).foregroundStyle(theme.textMute)
                }
            }
            ForEach(running, id: \.self) { p in
                if np.access[p] != .granted { AccessHint(np: np, player: p, compact: false) }
            }
        }
    }
}

/// Explains (and requests) the Automation permission controls and artwork need.
private struct AccessHint: View {
    @Environment(\.theme) private var theme
    let np: NowPlaying
    let player: NowPlaying.Player
    let compact: Bool

    var body: some View {
        let denied = np.access[player] == .denied
        if compact {
            Button(denied ? "Not allowed" : "Connect") { denied ? Self.openAutomationSettings() : np.connect(player) }
                .buttonStyle(GridButtonStyle(compact: true))
                .help(denied ? "GRID isn't allowed to control \(player.name). Open System Settings › Privacy & Security › Automation."
                             : "Let GRID control \(player.name) and read its artwork. macOS asks once.")
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text(denied
                     ? "GRID isn't allowed to control \(player.name). Turn it on in System Settings › Privacy & Security › Automation."
                     : "Connect to show what \(player.name) is playing now, its artwork, and the controls. macOS asks you once; GRID never opens \(player.name) itself.")
                    .font(GridFont.small).foregroundStyle(theme.textMute)
                    .fixedSize(horizontal: false, vertical: true)
                Button(denied ? "Open Automation Settings" : "Connect \(player.name)") {
                    denied ? Self.openAutomationSettings() : np.connect(player)
                }
                .buttonStyle(GridButtonStyle(compact: true))
            }
        }
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Artwork

/// Cover art redrawn in the theme's accent: no photo, just brightness as dots or scan lines.
/// A new cover scans in from the top (once per track, skipped without Motion).
struct ArtworkView: View {
    @Environment(\.theme) private var theme
    @Environment(\.effects) private var effects
    let matrix: ArtMatrix?
    let style: ArtStyle
    /// Identifies the track; the scan-in replays when it (or the artwork) changes.
    let key: String
    @State private var reveal: CGFloat = 1

    var body: some View {
        ArtCanvas(matrix: matrix, style: style, reveal: reveal, accent: theme.accent, line: theme.line)
            .background(theme.bg1)
            .clipShape(ClippedRect(cut: 6, topRight: true))
            .overlay(ClippedRect(cut: 6, topRight: true).stroke(theme.line, lineWidth: Metrics.hairline))
            .onChange(of: matrix) { _, m in
                guard m != nil, effects.motion else { reveal = 1; return }
                reveal = 0
                withAnimation(.easeOut(duration: 0.6)) { reveal = 1 }
            }
            .accessibilityHidden(true)
    }
}

private struct ArtCanvas: View, Animatable {
    let matrix: ArtMatrix?
    let style: ArtStyle
    var reveal: CGFloat
    let accent: Color
    let line: Color
    var animatableData: CGFloat { get { reveal } set { reveal = newValue } }

    var body: some View {
        Canvas { ctx, size in
            let n = ArtMatrix.size
            guard let m = matrix else {
                // No artwork (yet): a faint empty matrix.
                let step = size.width / 8
                for y in 0..<8 { for x in 0..<8 {
                    let c = CGPoint(x: (CGFloat(x) + 0.5) * step, y: (CGFloat(y) + 0.5) * step)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1, y: c.y - 1, width: 2, height: 2)), with: .color(line))
                } }
                return
            }
            let cell = size.width / CGFloat(n)
            let rows = Int((CGFloat(n) * reveal).rounded(.up))
            switch style {
            case .dots, .off:
                for y in 0..<min(rows, n) {
                    for x in 0..<n {
                        let v = m.value(x, y)
                        guard v > 0.06 else { continue }
                        let r = cell * 0.5 * CGFloat(pow(v, 0.75))
                        let c = CGPoint(x: (CGFloat(x) + 0.5) * cell, y: (CGFloat(y) + 0.5) * cell)
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                                 with: .color(accent.opacity(0.35 + 0.65 * v)))
                    }
                }
            case .lines:
                // Each row becomes runs of 4 brightness levels, one pixel of gap between rows.
                for y in 0..<min(rows, n) {
                    var x = 0
                    while x < n {
                        let level = (m.value(x, y) * 3.999).rounded(.down)
                        var end = x + 1
                        while end < n, (m.value(end, y) * 3.999).rounded(.down) == level { end += 1 }
                        if level > 0 {
                            let r = CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: CGFloat(end - x) * cell, height: max(1, cell - 1))
                            ctx.fill(Path(r), with: .color(accent.opacity(0.18 + 0.27 * level)))
                        }
                        x = end
                    }
                }
            }
            if reveal < 1 {
                let y = CGFloat(rows) * cell
                ctx.fill(Path(CGRect(x: 0, y: y - 1, width: size.width, height: 1.5)), with: .color(accent))
            }
        }
    }
}

// MARK: - Status bar ticker

/// A compact now-playing cell for the status bar, visible on every page.
struct NowPlayingStatusCell: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let np = app.nowPlaying
        if let t = np.track {
            HStack(spacing: 6) {
                Button { np.playPause() } label: {
                    Image(systemName: np.playing ? "pause.fill" : "play.fill").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.accent).frame(width: 14, height: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(np.playing ? "Pause" : "Play")
                .accessibilityLabel(np.playing ? "Pause" : "Play")
                Text(t.title + (t.artist.isEmpty ? "" : " · " + t.artist))
                    .font(GridFont.small).foregroundStyle(np.playing ? theme.text : theme.textDim)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 240, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .trailing) { Rectangle().fill(theme.line).frame(width: Metrics.hairline) }
            .help("\(np.player?.name ?? "Now playing"): \(t.title)")
        }
    }
}
