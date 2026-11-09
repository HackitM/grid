import AppKit
import SwiftUI

/// The window's startup build-on, after the Legacy board-room screens booting: the window frame
/// traces itself from the top-left corner, the bar rules and the rail divider extend, a scan line
/// passes down the window, then the bars fade in and the panels build on (their own BuildOn).
///
/// It lasts under a second, plays once per window, draws nothing once finished, and never blocks
/// input: the overlay ignores the mouse and the terminal is created a moment later (~0.3 s).
/// Skipped when Motion or "Startup build-on" is off, or macOS Reduce Motion is on.
enum StartupBuildOn {
    static var duration: Double { 0.8 * GridMotion.debugSlow }
    /// When the bars start to fade in, and when the panels are inserted (and build on).
    static var chromeDelay: Double { 0.2 * GridMotion.debugSlow }
    static var contentDelay: Double { 0.28 * GridMotion.debugSlow }

    /// Read at window creation, before the Settings object is in the environment.
    @MainActor static var shouldPlay: Bool {
        let d = UserDefaults.standard
        func flag(_ k: String) -> Bool { d.object(forKey: k) as? Bool ?? true }
        #if DEBUG
        if CommandLine.arguments.contains("--qa-no-boot") { return false }
        #endif
        return flag("fx.boot") && flag("fx.motion") && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// The lines of the startup build-on, drawn at progress `p` (0…1).
struct StartupTrace: View, Animatable {
    var p: CGFloat
    let accent: Color
    let glow: Color
    var animatableData: CGFloat { get { p } set { p = newValue } }

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            func clamp(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }
            let frame = clamp(p / 0.5)                       // outer frame
            let rules = clamp((p - 0.08) / 0.42)             // bar rules + rail divider
            let scan = clamp((p - 0.18) / 0.62)              // scan line down the window
            let fade = Double(clamp((1 - p) / 0.35))         // everything fades over the last third
            guard fade > 0 else { return }

            let top: CGFloat = 30, bottom = h - Metrics.statusHeight, rail = Metrics.railWidth
            var lines = Path()
            // Two traces leave the top-left corner: along the top then down the right side, and
            // down the left side then along the bottom; they meet in the bottom-right corner.
            var a = Path(); a.move(to: CGPoint(x: 0.5, y: 0.5)); a.addLine(to: CGPoint(x: w - 0.5, y: 0.5)); a.addLine(to: CGPoint(x: w - 0.5, y: h - 0.5))
            var b = Path(); b.move(to: CGPoint(x: 0.5, y: 0.5)); b.addLine(to: CGPoint(x: 0.5, y: h - 0.5)); b.addLine(to: CGPoint(x: w - 0.5, y: h - 0.5))
            lines.addPath(a.trimmedPath(from: 0, to: frame))
            lines.addPath(b.trimmedPath(from: 0, to: frame))
            if rules > 0 {
                lines.move(to: CGPoint(x: 0, y: top)); lines.addLine(to: CGPoint(x: w * rules, y: top))
                lines.move(to: CGPoint(x: 0, y: bottom)); lines.addLine(to: CGPoint(x: w * rules, y: bottom))
                lines.move(to: CGPoint(x: rail, y: top)); lines.addLine(to: CGPoint(x: rail, y: top + (bottom - top) * rules))
            }

            ctx.opacity = fade
            if scan > 0 && scan < 1 {
                let y = top + (bottom - top) * scan
                let band = CGRect(x: rail, y: y - 48, width: w - rail, height: 48)
                ctx.fill(Path(band), with: .linearGradient(Gradient(colors: [accent.opacity(0), accent.opacity(0.10)]),
                                                           startPoint: CGPoint(x: 0, y: band.minY), endPoint: CGPoint(x: 0, y: band.maxY)))
                ctx.fill(Path(CGRect(x: rail, y: y - 0.5, width: w - rail, height: 1)), with: .color(accent.opacity(0.45)))
            }
            var glowing = ctx
            glowing.addFilter(.shadow(color: glow, radius: 5))
            glowing.stroke(lines, with: .color(accent), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if DEBUG
extension Notification.Name {
    static let gridQAReplayStartup = Notification.Name("grid.qa.replayStartup")
}
#endif
