import AppKit
import SwiftUI

/// GRID's motion vocabulary, taken from the reference films and kept short and purposeful:
/// - Legacy build-on: a frame traces itself from the top-left corner, the header rule extends,
///   and the plate's content expands from its centre.
/// - Ares flash: a plate lights up as a solid accent fill that resolves to its content.
/// - Ares text bands: text types on while a highlight band sweeps behind it, then dims.
/// - Legacy cascade: list rows pop in one after another.
/// Nothing here delays input (content is hit-testable from the first frame), and every effect is
/// skipped when Motion is off or macOS "Reduce motion" is on (`effects.motion`).
enum GridMotion {
    /// Fast-out, long-settle curve used for build-ons.
    static let build = Animation.timingCurve(0.16, 0.84, 0.24, 1, duration: 0.34)
    static let quick = Animation.easeOut(duration: 0.16)
    static let snap = Animation.spring(response: 0.26, dampingFraction: 0.86)
}

// MARK: - Build-on (Legacy frame trace + Ares flash + expand from centre)

struct BuildOn: ViewModifier {
    @Environment(\.effects) private var effects
    @Environment(\.theme) private var theme
    var cut: CGFloat = Metrics.cornerCut
    var topRight = true
    var bottomLeft = false
    /// y of the header rule to extend (nil = no header).
    var headerRule: CGFloat? = Metrics.headerHeight
    /// Re-run the build-on when this changes (e.g. a panel moved to a new dock position).
    var trigger: AnyHashable? = nil
    @State private var p: CGFloat = 1

    func body(content: Content) -> some View {
        let shape = ClippedRect(cut: cut, topRight: topRight, bottomLeft: bottomLeft)
        content
            .opacity(Double(min(1, 0.15 + p * 1.4)))
            .scaleEffect(0.975 + 0.025 * p, anchor: .center)
            .overlay {
                // Always present; visibility is driven only by animatable values. (A `p < 1`
                // condition would read the animation's *final* value and never draw.)
                ZStack(alignment: .topLeading) {
                    // Ares flash: accent fill that resolves as the plate builds.
                    shape.fill(theme.accent.opacity(0.13 * Double(1 - p)))
                    // Legacy trace: a bright line runs around the frame from the top-left corner,
                    // fading as it completes.
                    shape.trim(from: 0, to: p)
                        .stroke(theme.accent, lineWidth: 1.5)
                        .shadow(color: effects.glow ? theme.glow.opacity(0.8) : .clear, radius: 4)
                        .opacity(Double(min(1, (1 - p) * 2.5)))
                    if let y = headerRule {
                        Rectangle().fill(theme.accent)
                            .frame(height: 1)
                            .scaleEffect(x: max(0.001, p), anchor: .leading)
                            .offset(y: y)
                            .opacity(Double(min(1, (1 - p) * 2.5)))
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onAppear { run() }
            .onChange(of: trigger) { _, _ in run() }
    }

    private func run() {
        guard effects.motion else { p = 1; return }
        p = 0
        withAnimation(GridMotion.build) { p = 1 }
    }
}

extension View {
    /// Legacy/Ares build-on for a framed plate. Match `cut`/corners to the plate's ClippedRect.
    func buildOn(cut: CGFloat = Metrics.cornerCut, topRight: Bool = true, bottomLeft: Bool = false,
                 headerRule: CGFloat? = Metrics.headerHeight, trigger: AnyHashable? = nil) -> some View {
        modifier(BuildOn(cut: cut, topRight: topRight, bottomLeft: bottomLeft, headerRule: headerRule, trigger: trigger))
    }
}

// MARK: - Type-on text with an Ares highlight band

/// Reveals `text` left to right (layout stays fixed: hidden characters are transparent), with an
/// accent band sweeping behind the revealed part that dims once the text is complete.
struct TypeOnText: View {
    @Environment(\.effects) private var effects
    @Environment(\.theme) private var theme
    let text: String
    var font: Font = GridFont.label
    var color: Color? = nil
    var tracking: CGFloat = 0
    /// Total reveal time; long strings are capped so nothing takes longer than this.
    var duration: Double = 0.22
    var band = true
    @State private var shown = Int.max
    @State private var bandOpacity = 0.0
    @State private var task: Task<Void, Never>?

    var body: some View {
        let chars = Array(text)
        let n = min(shown, chars.count)
        var attributed = AttributedString(String(chars.prefix(n)))
        attributed.foregroundColor = color ?? theme.text
        var rest = AttributedString(String(chars.dropFirst(n)))
        rest.foregroundColor = .clear
        return Text(attributed + rest)
            .font(font)
            .tracking(tracking)
            .background(alignment: .leading) {
                if band && bandOpacity > 0 {
                    GeometryReader { g in
                        Rectangle().fill(theme.accent.opacity(0.28 * bandOpacity))
                            .frame(width: g.size.width * CGFloat(n) / CGFloat(max(chars.count, 1)))
                    }
                    .padding(.vertical, -1)
                    .allowsHitTesting(false)
                }
            }
            .onAppear { start() }
            .onChange(of: text) { _, _ in start() }
            .onDisappear { task?.cancel() }
            .accessibilityLabel(text)
    }

    private func start() {
        task?.cancel()
        let count = text.count
        guard effects.motion, count > 0 else { shown = Int.max; bandOpacity = 0; return }
        shown = 0
        bandOpacity = band ? 1 : 0
        let step = max(0.008, duration / Double(count))
        task = Task { @MainActor in
            for i in 1...count {
                try? await Task.sleep(for: .seconds(step))
                if Task.isCancelled { return }
                shown = i
            }
            withAnimation(.easeOut(duration: 0.45)) { bandOpacity = 0 }
        }
    }
}

// MARK: - Cascade (rows pop in one after another)

/// Marks the start of a cascade (e.g. a folder was opened or the palette's results changed).
/// Rows that appear shortly after animate in with a per-row delay; rows that appear later (by
/// scrolling) show immediately, so scrolling never animates.
@MainActor
final class CascadeClock {
    static let shared = CascadeClock()
    private(set) var startedAt = Date.distantPast
    private(set) var generation = 0
    func start() { startedAt = Date(); generation &+= 1 }
    var isActive: Bool { Date().timeIntervalSince(startedAt) < 0.35 }
}

struct CascadeIn: ViewModifier {
    @Environment(\.effects) private var effects
    let index: Int
    @State private var shown = true

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(x: shown ? 0 : -8)
            .onAppear {
                guard effects.motion, index < 18, CascadeClock.shared.isActive else { return }
                shown = false
                let delay = Double(index) * 0.014
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation(GridMotion.quick) { shown = true }
                }
            }
    }
}

extension View {
    func cascadeIn(_ index: Int) -> some View { modifier(CascadeIn(index: index)) }
}

// MARK: - Scan sweep (drop targets, "processing" states)

/// A bright horizontal scan line sweeping across the view (Ares "scanning"). Only animates while
/// shown; use it for transient states (an active drop target), never as idle decoration.
struct ScanSweep: View {
    @Environment(\.effects) private var effects
    @Environment(\.theme) private var theme
    var vertical = false
    var period: Double = 0.9

    var body: some View {
        if effects.motion {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                GeometryReader { g in
                    let len = vertical ? g.size.height : g.size.width
                    Rectangle()
                        .fill(LinearGradient(colors: [theme.accent.opacity(0), theme.accent.opacity(0.35), theme.accent.opacity(0)],
                                             startPoint: vertical ? .top : .leading, endPoint: vertical ? .bottom : .trailing))
                        .frame(width: vertical ? g.size.width : 40, height: vertical ? 24 : g.size.height)
                        .offset(x: vertical ? 0 : CGFloat(t) * (len + 40) - 40, y: vertical ? CGFloat(t) * (len + 24) - 24 : 0)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Pop (tags and badges)

/// Pops in from 60% with a brief accent flash; used for status tags like DONE / BELL.
struct PopIn: ViewModifier {
    @Environment(\.effects) private var effects
    @State private var scale: CGFloat = 1
    @State private var flash = 0.0

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .brightness(flash)
            .onAppear {
                guard effects.motion else { return }
                scale = 0.6; flash = 0.5
                withAnimation(GridMotion.snap) { scale = 1 }
                withAnimation(.easeOut(duration: 0.5)) { flash = 0 }
            }
    }
}

extension View {
    func popIn() -> some View { modifier(PopIn()) }
}
