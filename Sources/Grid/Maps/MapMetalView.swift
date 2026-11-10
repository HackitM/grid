import AppKit
import GridCore
import MetalKit
import QuartzCore
import SwiftUI

// The map view: an MTKView subclass that turns AppKit input into `MapGesture`s, a label overlay,
// and a container that pauses drawing when the window isn't key or visible (like
// GlobeMetalContainer). Pan, zoom and rotate are applied to a view-local camera immediately so
// dragging feels direct; the model echoes them through `frame.camera`, which is authoritative
// whenever a frame arrives.

/// SwiftUI wrapper (IMPLEMENTATION.md §3.3 C).
struct MapMetalView: NSViewRepresentable {
    var frame: MapFrame
    var onGesture: (MapGesture) -> Void
    var onViewport: (SIMD2<Double>) -> Void
    var interactive: Bool

    func makeNSView(context: Context) -> NSView {
        guard let v = MapContainerView() else { return NSView() }
        v.onGesture = onGesture
        v.onViewport = onViewport
        v.interactive = interactive
        v.setFrame(frame)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        guard let c = v as? MapContainerView else { return }
        c.onGesture = onGesture
        c.onViewport = onViewport
        c.interactive = interactive
        c.setFrame(frame)
    }

    /// False when there is no Metal device or the shaders failed to compile (show a StateBlock instead).
    @MainActor static var isSupported: Bool { MapContainerView.supported }
}

/// Hosts the Metal view and the label layer; owns the renderer and the local camera.
@MainActor
final class MapContainerView: NSView {
    let mtk: MapInputView
    let renderer: MapRenderer
    let labels = MapLabelLayer(frame: .zero)
    let planner = MapLabelPlanner()
    var onGesture: (MapGesture) -> Void = { _ in }
    var onViewport: (SIMD2<Double>) -> Void = { _ in }
    var interactive = true { didSet { mtk.interactive = interactive } }

    private var frame_: MapFrame?
    private var camera: MapCamera?
    private var observers: [NSObjectProtocol] = []
    private var viewportWork: DispatchWorkItem?
    private var lastReportedViewport = SIMD2<Double>(0, 0)
    private var labelFrameSkip = 0

    static let supported: Bool = {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        let probe = MTKView(frame: .zero, device: device)
        return MapRenderer(view: probe) != nil
    }()

    init?(_ unused: Void = ()) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        mtk = MapInputView(frame: .zero, device: device)
        guard let r = MapRenderer(view: mtk) else { return nil }
        renderer = r
        super.init(frame: .zero)
        mtk.autoresizingMask = [.width, .height]
        labels.autoresizingMask = [.width, .height]
        mtk.setAccessibilityHidden(true)
        addSubview(mtk)
        addSubview(labels)
        mtk.onGesture = { [weak self] g in self?.handle(g) }
        mtk.onDragState = { [weak self] dragging in self?.renderer.dragging = dragging }
        renderer.onFrameDrawn = { [weak self] proj, frame in self?.placeLabels(proj, frame) }
        updatePaused()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        mtk.frame = bounds
        labels.frame = bounds
        scheduleViewportReport()
    }

    /// Debounced: drawable sizes churn during the startup build-on.
    private func scheduleViewportReport() {
        viewportWork?.cancel()
        let size = SIMD2<Double>(Double(bounds.width), Double(bounds.height))
        guard size.x >= 1, size.y >= 1, size != lastReportedViewport else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let now = SIMD2<Double>(Double(self.bounds.width), Double(self.bounds.height))
            guard now.x >= 1, now.y >= 1, now != self.lastReportedViewport else { return }
            self.lastReportedViewport = now
            self.onViewport(now)
        }
        viewportWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let w = window {
            for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                      NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updatePaused() }
                })
            }
        }
        updatePaused()
    }

    override func viewDidHide() { super.viewDidHide(); updatePaused() }
    override func viewDidUnhide() { super.viewDidUnhide(); updatePaused() }

    /// Draws on demand only while the window is key and visible; frames arriving meanwhile are
    /// kept and drawn once on resume.
    private func updatePaused() {
        var active = window.map { $0.isKeyWindow && $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? false
        if isHiddenOrHasHiddenAncestor { active = false }
        #if DEBUG
        if MapRenderer.debugForceActive { active = window != nil }
        #endif
        renderer.isActive = active
    }

    // MARK: Frames and the local camera

    func setFrame(_ f: MapFrame) {
        // SwiftUI re-renders the panel for unrelated state; identical frames cost nothing.
        if let old = frame_, old == f { return }
        let paletteChanged = frame_?.palette != f.palette
        frame_ = f
        if paletteChanged { labels.setPalette(f.palette) }
        renderer.setFrame(f)
        // The model publishes gesture cameras at ≤ 30 Hz, so a frame can carry a camera a few
        // events behind this view's own. A camera that matches one of this view's recent local
        // cameras is such an echo: keep the local camera (no snap-back). Anything else is a
        // programmatic change (flyTo, Locate, reset north, pitch toggle, keys): it wins, even
        // mid-gesture, and the local history starts over from it.
        pruneRecent()
        if let local = camera, local != f.camera, let i = recentLocal.lastIndex(where: { Self.matches($0.camera, f.camera) }) {
            // The model echoes gestures in order, so everything up to the matched camera is behind it
            // now; dropping it keeps an earlier state from masquerading as an echo later.
            recentLocal.removeFirst(i + 1)
            renderer.setCamera(local)
        } else {
            camera = f.camera
            recentLocal.removeAll(keepingCapacity: true)
        }
    }

    /// Cameras this view produced from gestures in the last `recentWindow` seconds (newest last).
    private var recentLocal: [(camera: MapCamera, at: TimeInterval)] = []
    private static let recentWindow: TimeInterval = 0.3
    private static let recentLimit = 120

    private func pruneRecent() {
        let cutoff = CACurrentMediaTime() - Self.recentWindow
        if let i = recentLocal.firstIndex(where: { $0.at >= cutoff }) { recentLocal.removeFirst(i) } else { recentLocal.removeAll(keepingCapacity: true) }
    }

    private func rememberLocal(_ c: MapCamera) {
        recentLocal.append((c, CACurrentMediaTime()))
        if recentLocal.count > Self.recentLimit { recentLocal.removeFirst(recentLocal.count - Self.recentLimit) }
    }

    /// Same camera to within half a pixel of centre (at the camera's zoom) and 1e-6 in zoom,
    /// bearing and pitch: the model and the view run identical gesture math, so an echo is
    /// (near) exact, while any programmatic move is far outside this.
    static func matches(_ a: MapCamera, _ b: MapCamera) -> Bool {
        guard abs(a.zoom - b.zoom) < 1e-6, abs(a.pitch - b.pitch) < 1e-6 else { return false }
        var db = abs(a.bearing - b.bearing); if db > 180 { db = 360 - db }
        guard db < 1e-6 else { return false }
        let worldScale = 256 * pow(2, a.zoom)
        return abs(a.center.x - b.center.x) * worldScale < 0.5 && abs(a.center.y - b.center.y) * worldScale < 0.5
    }

    #if DEBUG
    /// The view-local camera (QA / harness).
    var debugLocalCamera: MapCamera? { camera }
    #endif

    private var viewportPoints: SIMD2<Double> { SIMD2(Double(max(1, bounds.width)), Double(max(1, bounds.height))) }

    private func handle(_ g: MapGesture) {
        guard interactive else { return }
        if var cam = camera {
            // The same maths as MapModel.handle, so the model's echo matches this camera exactly.
            switch g {
            case .pan(let d): cam = MapGestureMath.pan(cam, by: d, viewport: viewportPoints)
            case .zoom(let dz, let around): cam = MapGestureMath.zoom(cam, by: dz, around: around, viewport: viewportPoints)
            case .rotate(let db, let dp): cam = MapGestureMath.rotate(cam, bearing: db, pitch: dp)
            case .click, .rectangle, .key: break
            }
            if cam != camera {
                camera = cam
                rememberLocal(cam)
                renderer.setCamera(cam)
            }
        }
        onGesture(g)
    }

    private static func clampCenter(_ m: Mercator) -> Mercator {
        Mercator(x: min(1, max(0, m.x)), y: min(1, max(0, m.y)))
    }

    // MARK: Labels

    private func placeLabels(_ proj: any MapScreenProjection, _ frame: MapFrame) {
        // While dragging, re-place at most every other frame.
        if renderer.dragging {
            labelFrameSkip += 1
            if labelFrameSkip % 2 == 1 { return }
        } else { labelFrameSkip = 0 }
        var counts: [MapCountLabel] = []
        counts.reserveCapacity(frame.clusters.count)
        for c in frame.clusters {
            guard c.count > 0, let s = proj.screen(c.world), s.x > -40, s.y > -20, s.x < proj.viewport.x + 40, s.y < proj.viewport.y + 20 else { continue }
            let side = MapRenderer.clusterSide(c.count)
            counts.append(MapCountLabel(text: Self.countText(c.count), center: CGPoint(x: s.x + side / 2 + 3, y: s.y)))
        }
        let placed = planner.place(tiles: frame.tiles, projection: proj, counts: counts)
        labels.apply(placed.labels, counts: placed.counts) { [planner] in planner.width(of: $0) }
    }

    static func countText(_ n: Int) -> String {
        n >= 10_000 ? "\(n / 1000)K" : (n >= 1000 ? String(format: "%.1fK", Double(n) / 1000) : "\(n)")
    }
}

/// The MTKView with input. Points are view coordinates with a top-left origin.
final class MapInputView: MTKView {
    var onGesture: (MapGesture) -> Void = { _ in }
    var onDragState: (Bool) -> Void = { _ in }
    var interactive = true

    private var dragStart: SIMD2<Double>?
    private var dragLast: SIMD2<Double>?
    private var dragMoved = false
    private var dragMode: DragMode = .pan
    private enum DragMode { case pan, rotate, rectangle }
    static let clickThreshold: Double = 4

    override var acceptsFirstResponder: Bool { interactive }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { true }

    private func point(_ e: NSEvent) -> SIMD2<Double> {
        let p = convert(e.locationInWindow, from: nil)
        return SIMD2(Double(p.x), Double(bounds.height - p.y))
    }

    // Trackpad scroll pans; ⌘-scroll and mouse wheels zoom around the pointer; ⌥ + two-finger
    // swipe tilts (up/down) and turns (left/right) the 3D view.
    override func scrollWheel(with e: NSEvent) {
        guard interactive else { return super.scrollWheel(with: e) }
        let at = point(e)
        if e.modifierFlags.contains(.option) {
            let dx = Double(e.scrollingDeltaX), dy = Double(e.scrollingDeltaY)
            let k = e.hasPreciseScrollingDeltas ? 1.0 : 6.0
            // Whichever axis dominates, so a vertical swipe doesn't also spin the map.
            if abs(dy) >= abs(dx) { if dy != 0 { onGesture(.rotate(bearingDelta: 0, pitchDelta: -dy * 0.25 * k)) } }
            else { onGesture(.rotate(bearingDelta: dx * 0.3 * k, pitchDelta: 0)) }
            return
        }
        if e.hasPreciseScrollingDeltas {
            if e.modifierFlags.contains(.command) {
                onGesture(.zoom(-Double(e.scrollingDeltaY) * 0.012, around: at))
            } else {
                let d = SIMD2(Double(e.scrollingDeltaX), Double(e.scrollingDeltaY))
                if d != .zero { onGesture(.pan(d)) }
            }
        } else {
            let dz = Double(e.scrollingDeltaY) * 0.1
            if dz != 0 { onGesture(.zoom(min(1, max(-1, dz)), around: at)) }
        }
    }

    override func magnify(with e: NSEvent) {
        guard interactive else { return }
        let dz = log2(max(0.05, 1 + Double(e.magnification)))
        if dz != 0 { onGesture(.zoom(dz, around: point(e))) }
    }

    override func rotate(with e: NSEvent) {
        guard interactive else { return }
        let r = Double(e.rotation)
        if r != 0 { onGesture(.rotate(bearingDelta: r, pitchDelta: 0)) }
    }

    override func mouseDown(with e: NSEvent) {
        guard interactive else { return }
        window?.makeFirstResponder(self)
        let p = point(e)
        dragStart = p; dragLast = p; dragMoved = false
        dragMode = e.modifierFlags.contains(.shift) ? .rectangle : (e.modifierFlags.contains(.option) ? .rotate : .pan)
    }

    override func mouseDragged(with e: NSEvent) {
        guard interactive, let start = dragStart, let last = dragLast else { return }
        let p = point(e)
        let total = p - start
        if !dragMoved && (total.x * total.x + total.y * total.y).squareRoot() < Self.clickThreshold { return }
        if !dragMoved { dragMoved = true; onDragState(true) }
        let d = p - last
        dragLast = p
        switch dragMode {
        case .pan: onGesture(.pan(d))
        case .rotate: onGesture(.rotate(bearingDelta: d.x * 0.3, pitchDelta: -d.y * 0.25))
        case .rectangle: onGesture(.rectangle(start, p, ended: false))
        }
    }

    override func mouseUp(with e: NSEvent) {
        guard interactive, let start = dragStart else { return }
        let p = point(e)
        if dragMoved {
            if dragMode == .rectangle { onGesture(.rectangle(start, p, ended: true)) }
            onDragState(false)
        } else {
            onGesture(.click(p))
        }
        dragStart = nil; dragLast = nil; dragMoved = false
    }

    override func keyDown(with e: NSEvent) {
        guard interactive else { return super.keyDown(with: e) }
        let key: MapKey?
        switch e.keyCode {
        case 123: key = .left
        case 124: key = .right
        case 126: key = .up
        case 125: key = .down
        default:
            switch e.charactersIgnoringModifiers {
            case "+", "=": key = .zoomIn
            case "-", "_": key = .zoomOut
            case "0": key = .resetNorth
            default: key = nil
            }
        }
        if let key { onGesture(.key(key)) } else { super.keyDown(with: e) }
    }
}
