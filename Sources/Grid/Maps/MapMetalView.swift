import AppKit
import GridCore
import MetalKit
import QuartzCore
import SwiftUI
import simd

// The map view: an MTKView subclass that turns AppKit input into `MapGesture`s, and a container
// that pauses drawing when the window isn't key or visible (like GlobeMetalContainer). Pan, zoom
// and rotate are applied to a view-local camera immediately so dragging feels direct; the model
// applies the same gesture to its own camera and hands back a new frame only when what is drawn
// changes. Labels are drawn by the renderer in the same pass as the map.

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

/// Hosts the Metal view; owns the renderer and the local camera.
@MainActor
final class MapContainerView: NSView {
    let mtk: MapInputView
    let renderer: MapRenderer
    var onGesture: (MapGesture) -> Void = { _ in }
    var onViewport: (SIMD2<Double>) -> Void = { _ in }
    var interactive = true { didSet { mtk.interactive = interactive } }

    /// The frame last handed to the renderer.
    private var currentFrame: MapFrame?
    private var camera: MapCamera?
    private var observers: [NSObjectProtocol] = []
    private var viewportWork: DispatchWorkItem?
    private var lastReportedViewport = SIMD2<Double>(0, 0)

    #if DEBUG
    /// The map view on screen (QA gesture runs).
    nonisolated(unsafe) static weak var debugCurrent: MapContainerView?
    var debugProbe: MapGestureProbe?
    #endif

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
        mtk.setAccessibilityHidden(true)
        addSubview(mtk)
        mtk.onGesture = { [weak self] g in self?.handle(g) }
        #if DEBUG
        renderer.debugOnFrameDrawn = { [weak self] proj in self?.debugProbe?.frameDrawn(proj) }
        #endif
        updatePaused()
        #if DEBUG
        Self.debugCurrent = self
        #endif
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        mtk.frame = bounds
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
        // SwiftUI re-renders the panel for unrelated state; the model then hands back the same frame.
        if let old = currentFrame, old.stamp == f.stamp {
            // A build of the model is known by its stamp (only the camera is checked besides);
            // frames without one (0: QA, printing) are compared in full.
            let unchanged = f.stamp != 0 ? old.camera == f.camera : old == f
            if unchanged { return }
        }
        currentFrame = f
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { MapDebugTimes.add("setFrame", since: t0) }
        #endif
        renderer.setFrame(f)
        // A frame carries the model's camera from when it was built, which can be a few gesture
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
            case .click, .rectangle, .key, .contextMenu: break
            }
            if cam != camera {
                camera = cam
                rememberLocal(cam)
                renderer.setCamera(cam)
            }
        }
        onGesture(g)
    }
}

/// The MTKView with input. Points are view coordinates with a top-left origin.
final class MapInputView: MTKView {
    var onGesture: (MapGesture) -> Void = { _ in }
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
        if e.modifierFlags.contains(.control) { rightMouseDown(with: e); return }
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
        dragMoved = true
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
        } else {
            onGesture(.click(p))
        }
        dragStart = nil; dragLast = nil; dragMoved = false
    }

    override func rightMouseDown(with e: NSEvent) {
        guard interactive else { return super.rightMouseDown(with: e) }
        let s = GridMenu.screenLocation(of: e)
        onGesture(.contextMenu(point(e), screen: SIMD2(Double(s.x), Double(s.y))))
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

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

#if DEBUG
/// QA: worst main-thread time per named section since the last reset.
@MainActor
enum MapDebugTimes {
    static var worst: [String: Double] = [:]
    static var total: [String: Double] = [:]
    static func add(_ name: String, since t0: CFTimeInterval) {
        add(name, ms: (CACurrentMediaTime() - t0) * 1000)
    }
    static func add(_ name: String, ms: Double) {
        worst[name] = max(worst[name] ?? 0, ms)
        total[name, default: 0] += ms
    }
}

/// QA: drives the map through the view's own gesture path (the same closure trackpad and mouse
/// events end in) at a fixed rate, and records what each drawn frame looked like: frame times,
/// how far the labels on screen were from the map under them, and tile coverage.
@MainActor
final class MapGestureProbe {
    struct Spec {
        var seconds = 4.0
        var hz = 120.0
        /// Points per second.
        var pan = SIMD2<Double>(0, 0)
        /// Zoom levels, degrees of bearing and degrees of pitch per second.
        var zoom = 0.0, rotate = 0.0, pitch = 0.0
        /// Velocities ease out to zero over the run (a fling) instead of staying constant.
        var fling = false
        /// Seconds to keep watching after the gesture stops.
        var settle = 8.0
    }
    let spec: Spec
    private weak var view: MapContainerView?
    /// Tile coverage for a camera: cover size, tiles not decoded, tiles with nothing to draw (store
    /// and drawn frame).
    var coverage: ((MapCamera) -> [String: Int])?
    var done: (([String: Any]) -> Void)?

    private var timer: DispatchSourceTimer?
    private var start = 0.0, lastTick = 0.0, lastSample = 0.0
    private var frameTimes: [Double] = []
    private var encodeMs: [Double] = []
    private var labelErr: [Double] = []
    private var labelAge: [Double] = []
    private var labelMs: [Double] = []
    private var samples: [[String: Any]] = []
    private var labelCamera: MapCamera?
    private var labelTime = 0.0
    private var drawn: MapCamera?
    private var gestureEnd = 0.0
    private var filledAt: Double?
    private var drawnFilledAt: Double?
    private var events = 0
    private var worstTickGap = 0.0, worstTickAt = 0.0

    init(_ spec: Spec, view: MapContainerView) { self.spec = spec; self.view = view }

    func begin() {
        MapDebugTimes.worst = [:]; MapDebugTimes.total = [:]
        start = CACurrentMediaTime(); lastTick = start
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1 / max(1, spec.hz), leeway: .milliseconds(0))
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        timer = t
        t.resume()
    }

    private func tick() {
        guard let view else { finish(); return }
        let now = CACurrentMediaTime()
        let elapsed = now - start
        if now - lastTick > worstTickGap, elapsed < spec.seconds + 0.3 { worstTickGap = now - lastTick; worstTickAt = elapsed }
        if elapsed < spec.seconds {
            let dt = min(0.1, now - lastTick)
            let u = elapsed / spec.seconds
            let k = spec.fling ? (1 - u) * (1 - u) * 3 : 1          // same distance as a constant run
            if spec.pan != .zero { view.mtk.onGesture(.pan(spec.pan * dt * k)); events += 1 }
            if spec.zoom != 0 { view.mtk.onGesture(.zoom(spec.zoom * dt * k, around: SIMD2(Double(view.bounds.width) / 2, Double(view.bounds.height) / 2))); events += 1 }
            if spec.rotate != 0 || spec.pitch != 0 { view.mtk.onGesture(.rotate(bearingDelta: spec.rotate * dt * k, pitchDelta: spec.pitch * dt * k)); events += 1 }
            gestureEnd = now
        } else if elapsed > spec.seconds + spec.settle || (drawnFilledAt != nil && now - gestureEnd > 1.5) {
            finish(); return
        }
        lastTick = now
        if now - lastSample >= 0.1, let cam = view.debugLocalCamera, let coverage {
            lastSample = now
            var c: [String: Any] = coverage(cam)
            c["t"] = now - start
            c["moving"] = elapsed < spec.seconds
            samples.append(c)
            if elapsed >= spec.seconds {
                if filledAt == nil, (c["missing"] as? Int) == 0 { filledAt = now }
                if drawnFilledAt == nil, (c["drawnMissing"] as? Int) == 0, (c["missing"] as? Int) == 0 { drawnFilledAt = now }
            }
        }
    }

    /// Called for every frame encoded, after label placement had its chance.
    func frameDrawn(_ proj: any MapScreenProjection) {
        let now = CACurrentMediaTime()
        guard now - start < spec.seconds else { return }
        frameTimes.append(now)
        encodeMs.append(view?.renderer.debugLastEncodeCPUms ?? 0)
        // Labels are placed inside the frame's own encode, with its projection.
        labelMs.append(view?.renderer.debugLastLabelMs ?? 0)
        labelCamera = proj.camera
        labelTime = now
        guard let lc = labelCamera, lc != proj.camera else { labelErr.append(0); labelAge.append(0); drawn = proj.camera; return }
        // How far labels placed with `lc` sit from where this frame draws the same ground.
        let old = mapProjection(camera: lc, viewport: proj.viewport)
        var worst = 0.0
        for f in [SIMD2(0.25, 0.3), SIMD2(0.75, 0.3), SIMD2(0.5, 0.5), SIMD2(0.25, 0.8), SIMD2(0.75, 0.8)] {
            let s = f * proj.viewport
            guard let g = old.groundPoint(screen: s), let q = proj.screen(g) else { continue }
            worst = max(worst, simd_length(q - s))
        }
        labelErr.append(worst)
        labelAge.append((now - labelTime) * 1000)
        drawn = proj.camera
    }

    private func finish() {
        timer?.cancel(); timer = nil
        view?.debugProbe = nil
        func pct(_ a: [Double], _ p: Double) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))] }
        func stats(_ a: [Double]) -> [String: Double] {
            ["n": Double(a.count), "mean": a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count), "p50": pct(a, 0.5), "p95": pct(a, 0.95), "max": a.max() ?? 0]
        }
        let intervals = zip(frameTimes.dropFirst(), frameTimes).map { ($0 - $1) * 1000 }
        let worstAt = intervals.indices.max { intervals[$0] < intervals[$1] }.map { frameTimes[$0] - start } ?? -1
        let moving = samples.filter { $0["moving"] as? Bool == true }
        func avg(_ k: String) -> Double { moving.isEmpty ? 0 : Double(moving.reduce(0) { $0 + (($1[k] as? Int) ?? 0) }) / Double(moving.count) }
        func peak(_ k: String) -> Int { moving.map { ($0[k] as? Int) ?? 0 }.max() ?? 0 }
        let out: [String: Any] = [
            "events": events, "frames": frameTimes.count, "seconds": spec.seconds,
            "fps": Double(frameTimes.count) / max(0.001, (frameTimes.last ?? 0) - (frameTimes.first ?? 0)),
            "frameMs": stats(intervals), "over12ms": intervals.filter { $0 > 12.5 }.count, "over25ms": intervals.filter { $0 > 25 }.count,
            "encodeMs": stats(encodeMs), "labelPlaceMs": stats(labelMs), "labelPlacements": labelMs.count,
            "labelErrPt": stats(labelErr), "labelAgeMs": stats(labelAge),
            "labelStaleFrames": labelErr.filter { $0 > 0.5 }.count,
            "tilesWhileMoving": ["cover": avg("cover"), "missingAvg": avg("missing"), "missingMax": peak("missing"),
                                 "holesAvg": avg("holes"), "holesMax": peak("holes"),
                                 "drawnMissingAvg": avg("drawnMissing"), "drawnHolesAvg": avg("drawnHoles"), "drawnHolesMax": peak("drawnHoles")],
            "fillAfterStopS": filledAt.map { $0 - gestureEnd } ?? -1,
            "drawnFillAfterStopS": drawnFilledAt.map { $0 - gestureEnd } ?? -1,
            "samples": samples, "worstFrameAt": worstAt, "worstTickGapMs": worstTickGap * 1000, "worstTickAt": worstTickAt,
            "worstMs": MapDebugTimes.worst, "totalMs": MapDebugTimes.total,
        ]
        done?(out)
    }
}
#endif
