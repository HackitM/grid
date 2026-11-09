import AppKit
import GridCore
import Observation
import SwiftUI

/// What is being dragged inside GRID.
enum DragPayload: Equatable {
    case panel(WorkspacePanel)
    case pane(UUID)
    case tab(UUID)
    case widget(UUID)

    var string: String {
        switch self {
        case .panel(let p): "grid-panel:\(p.rawValue)"
        case .pane(let id): "grid-pane:\(id.uuidString)"
        case .tab(let id): "grid-tab:\(id.uuidString)"
        case .widget(let id): "grid-widget:\(id.uuidString)"
        }
    }

    init?(_ s: String) {
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "grid-panel": if let p = WorkspacePanel(rawValue: parts[1]) { self = .panel(p) } else { return nil }
        case "grid-pane": if let id = UUID(uuidString: parts[1]) { self = .pane(id) } else { return nil }
        case "grid-tab": if let id = UUID(uuidString: parts[1]) { self = .tab(id) } else { return nil }
        case "grid-widget": if let id = UUID(uuidString: parts[1]) { self = .widget(id) } else { return nil }
        default: return nil
        }
    }
}

/// Places a GRID drag can land.
enum DockTarget: Hashable {
    case panel(WorkspacePanel)   // dock beside a workspace panel (edge)
    case pane(UUID)              // dock beside a terminal pane (edge)
    case tab(UUID)               // move a pane into / a tab before this tab
    case tabBar                  // detach a pane into its own tab / move a tab last
    case widget(UUID)            // place a widget card beside (left/right) or above/below this card
    case widgetEnd               // move a widget card to the end

    /// Edge targets split themselves into halves; the others are simple drop zones.
    var usesEdges: Bool {
        switch self { case .panel, .pane, .widget: true; default: false }
    }
}

/// GRID's own drag tracking for re-docking panels, panes, tabs, and widget cards.
///
/// The system drag-and-drop (NSDraggingSession via `.onDrag`/`.onDrop`) does not reliably tell a
/// drop target when the pointer moves on to another target or when a drag is cancelled, which left
/// highlights stuck and drops unapplied. Everything here stays inside the window, so GRID tracks
/// the pointer itself: sources use a plain DragGesture, targets register their on-screen frames,
/// and this controller picks exactly one target (the innermost valid one) and one edge, draws one
/// highlight, applies the move on mouse-up, and cancels on Esc.
@Observable
@MainActor
final class DockDrag {
    static let shared = DockDrag()

    struct Hover: Equatable {
        let target: DockTarget
        let edge: DropEdge?
    }

    private(set) var payload: DragPayload?
    private(set) var label = ""
    /// Pointer location in window (global SwiftUI) coordinates.
    private(set) var location: CGPoint = .zero
    private(set) var hover: Hover?

    /// Frames of registered targets in window coordinates (not observed: only read on demand).
    @ObservationIgnored private(set) var frames: [DockTarget: CGRect] = [:]
    /// Which targets accept which payloads (set by AppState).
    @ObservationIgnored var isAllowed: (DragPayload, DockTarget) -> Bool = { _, _ in false }
    /// Applies a drop (set by AppState).
    @ObservationIgnored var perform: (DragPayload, DockTarget, DropEdge?) -> Void = { _, _, _ in }

    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var escMonitor: Any?
    @ObservationIgnored private var pushedCursor = false

    var isDragging: Bool { payload != nil }

    // MARK: Targets

    func register(_ t: DockTarget, frame: CGRect) {
        if frame.width > 1 && frame.height > 1 { frames[t] = frame } else { frames[t] = nil }
    }

    func unregister(_ t: DockTarget) { frames[t] = nil }

    func frame(of t: DockTarget) -> CGRect? { frames[t] }

    // MARK: Gesture plumbing (called by `dockDragSource`)

    func changed(_ p: DragPayload, label: String, location: CGPoint) {
        if cancelled { return }                  // Esc pressed: ignore the rest of this gesture
        if payload == nil { begin(p, label: label) }
        self.location = location
        let h = resolveHover(at: location)
        if h != hover { hover = h }
    }

    func ended() {
        defer { reset() }
        guard !cancelled, let p = payload, let h = hover else { return }
        perform(p, h.target, h.edge)
    }

    func cancel() {
        guard payload != nil else { return }
        cancelled = true
        clearVisuals()
    }

    private func begin(_ p: DragPayload, label: String) {
        payload = p
        self.label = label
        cancelled = false
        if !pushedCursor { NSCursor.closedHand.push(); pushedCursor = true }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53 else { return e }       // Esc cancels the drag
            MainActor.assumeIsolated { self?.cancel() }
            return nil
        }
    }

    private func clearVisuals() {
        payload = nil
        hover = nil
        label = ""
        if pushedCursor { NSCursor.pop(); pushedCursor = false }
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }

    private func reset() {
        clearVisuals()
        cancelled = false
    }

    // MARK: Hit testing

    /// The innermost (smallest) registered target under `point` that accepts the payload; for edge
    /// targets, the nearest edge.
    func resolveHover(at point: CGPoint) -> Hover? {
        guard let p = payload else { return nil }
        let hits = frames.filter { $0.value.contains(point) && isAllowed(p, $0.key) }
        guard let (target, rect) = hits.min(by: { $0.value.width * $0.value.height < $1.value.width * $1.value.height }) else { return nil }
        return Hover(target: target, edge: target.usesEdges ? Self.nearestEdge(point, in: rect) : nil)
    }

    static func nearestEdge(_ p: CGPoint, in r: CGRect) -> DropEdge {
        guard r.width > 0, r.height > 0 else { return .right }
        let dx = (p.x - r.minX) / r.width, dy = (p.y - r.minY) / r.height
        let d: [(DropEdge, CGFloat)] = [(.left, dx), (.right, 1 - dx), (.top, dy), (.bottom, 1 - dy)]
        return d.min { $0.1 < $1.1 }!.0
    }

    // MARK: QA support

    var debugFrames: [String: String] {
        Dictionary(uniqueKeysWithValues: frames.map { k, v in ("\(k)", "\(Int(v.minX)),\(Int(v.minY)) \(Int(v.width))x\(Int(v.height))") })
    }

    /// Simulates a drag along window-coordinate points (DEBUG QA hooks).
    func simulate(_ p: DragPayload, label: String, points: [CGPoint], commit: Bool = true, hold: Bool = false) {
        for pt in points { changed(p, label: label, location: pt) }
        if hold { return }                      // leave the drag in progress (for captures)
        if commit { ended() } else { cancel(); reset() }
    }

    /// Ends a held QA drag (drops if `commit`).
    func finishSimulated(commit: Bool) { if commit { ended() } else { cancel(); reset() } }
}

// MARK: - View modifiers

/// The visible area (window coordinates) drop targets inside a scroll view are limited to.
private struct DockClipKey: EnvironmentKey { static let defaultValue: CGRect? = nil }
extension EnvironmentValues {
    var dockClip: CGRect? {
        get { self[DockClipKey.self] }
        set { self[DockClipKey.self] = newValue }
    }
}

/// Registers the view's frame as a drop target, cut to the enclosing scroll view's visible area so
/// a card scrolled partly out of sight can't catch drops (or draw highlights) outside its panel.
private struct DockTargetModifier: ViewModifier {
    @Environment(\.dockClip) private var clip
    let target: DockTarget

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { g in
                let f = clip.map { g.frame(in: .global).intersection($0) } ?? g.frame(in: .global)
                Color.clear
                    .onAppear { DockDrag.shared.register(target, frame: f) }
                    .onChange(of: f) { _, nf in DockDrag.shared.register(target, frame: nf) }
                    .onDisappear { DockDrag.shared.unregister(target) }
            }
        )
    }
}

extension View {
    /// Registers this view's on-screen frame as a drop target.
    func dockTarget(_ t: DockTarget) -> some View { modifier(DockTargetModifier(target: t)) }

    /// Limits drop targets inside this (scroll) view to its visible frame.
    func dockClipToBounds() -> some View { modifier(DockClipModifier()) }
}

private struct DockClipModifier: ViewModifier {
    @State private var frame: CGRect?
    func body(content: Content) -> some View {
        content
            .environment(\.dockClip, frame)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { frame = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in frame = f }
            })
    }
}

extension View {
    /// Makes this view a drag source for `payload` (a plain mouse drag; taps still work).
    func dockDragSource(_ payload: DragPayload, label: String) -> some View {
        gesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .global)
                .onChanged { v in DockDrag.shared.changed(payload, label: label, location: v.location) }
                .onEnded { _ in DockDrag.shared.ended() }
        )
    }
}

// MARK: - Overlay (one highlight + a label following the pointer)

/// Drawn once over the whole window; shows the single hovered target and the drag label.
struct DockDragOverlay: View {
    @Environment(\.theme) private var theme
    private var drag: DockDrag { .shared }

    var body: some View {
        GeometryReader { g in
            let origin = g.frame(in: .global).origin
            if drag.isDragging {
                ZStack(alignment: .topLeading) {
                    if let h = drag.hover, let r = drag.frame(of: h.target) {
                        let local = r.offsetBy(dx: -origin.x, dy: -origin.y)
                        DockHighlight(target: h.target, edge: h.edge)
                            .frame(width: local.width, height: local.height)
                            .offset(x: local.minX, y: local.minY)
                    }
                    // Label following the pointer.
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal").font(.system(size: 8, weight: .semibold))
                        Text(drag.label.uppercased()).font(GridFont.label).tracking(1.4)
                        if drag.hover == nil {
                            Text(drag.payload.map { if case .widget = $0 { return "· drop on a card edge" } else { return "· drop on a panel edge" } } ?? "")
                                .font(GridFont.small).foregroundStyle(theme.textMute)
                        }
                    }
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(theme.bg2.opacity(0.95))
                    .overlay(Rectangle().stroke(theme.lineStrong, lineWidth: 1))
                    .fixedSize()
                    .offset(x: drag.location.x - origin.x + 14, y: drag.location.y - origin.y + 12)
                }
                .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The highlight for a hovered target: the half an edge drop will take (with an Ares scan band),
/// a leading insertion bar for tabs/widget cards, or an outline for the tab bar / list end.
struct DockHighlight: View {
    @Environment(\.theme) private var theme
    let target: DockTarget
    let edge: DropEdge?

    var body: some View {
        if let edge {
            GeometryReader { g in
                let horizontal = edge.axis == .horizontal
                let w = horizontal ? g.size.width / 2 : g.size.width
                let h = horizontal ? g.size.height : g.size.height / 2
                let x: CGFloat = edge == .right ? g.size.width / 2 : 0
                let y: CGFloat = edge == .bottom ? g.size.height / 2 : 0
                ZStack {
                    Rectangle().fill(theme.accent.opacity(0.12))
                    ScanSweep(vertical: !horizontal, period: 0.8)
                    Rectangle().stroke(theme.accent.opacity(0.8), lineWidth: 1.5)
                    Text(Self.label(edge, target: target)).font(GridFont.label).tracking(1.6).foregroundStyle(theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 4).background(theme.bg0.opacity(0.85))
                }
                .frame(width: w, height: h)
                .offset(x: x, y: y)
            }
        } else {
            switch target {
            case .tab:
                HStack { Rectangle().fill(theme.accent).frame(width: 3); Spacer() }
                    .background(theme.accent.opacity(0.12))
            case .widget:
                VStack { Rectangle().fill(theme.accent).frame(height: 3).offset(y: -5); Spacer() }
            default:
                Rectangle().stroke(theme.accent, lineWidth: 1.5).background(theme.accent.opacity(0.08))
            }
        }
    }

    static func label(_ e: DropEdge, target: DockTarget) -> String {
        if case .widget = target {
            switch e { case .left: return "◂ BESIDE"; case .right: return "BESIDE ▸"; case .top: return "▴ ROW ABOVE"; case .bottom: return "ROW BELOW ▾" }
        }
        switch e { case .left: return "◂ DOCK LEFT"; case .right: return "DOCK RIGHT ▸"; case .top: return "▴ DOCK TOP"; case .bottom: return "DOCK BOTTOM ▾" }
    }
}
