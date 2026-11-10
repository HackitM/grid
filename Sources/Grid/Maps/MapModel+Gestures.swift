import Dispatch
import GridCore
import QuartzCore

// Gestures and programmatic camera moves. A gesture changes the camera at once; everything that
// follows from it is paced: the tile plan runs at most 30 times a second, SwiftUI views that read
// the camera hear about it about 10 times a second, and a last plan runs once the gesture has
// stopped (which swaps the look-ahead for the ring around the view).

extension MapModel {
    struct GestureState {
        var planScheduled = false
        var notifyScheduled = false
        var settleScheduled = false
        var lastGestureTime: CFTimeInterval = 0
        /// Cameras of the last ~0.2 s of gestures (oldest first), for the velocity.
        var trail: [(at: CFTimeInterval, camera: MapCamera)] = []
    }

    private enum Pace {
        static let planInterval = 1.0 / 30
        static let notifyInterval = 0.1
        static let trailSeconds = 0.2
        /// A gesture has stopped when nothing arrived for this long.
        static let settleAfter = 0.18
        static let settleCheckInterval = 0.2
    }

    // MARK: Input from the map view

    func handle(_ g: MapGesture) {
        // Pan, zoom and rotate go through MapGestureMath, exactly as the map view applies them.
        let cam = liveCamera
        switch g {
        case .pan(let delta):
            gestured(MapGestureMath.pan(cam, by: delta, viewport: viewport))
        case .zoom(let dz, let p):
            gestured(MapGestureMath.zoom(cam, by: dz, around: p, viewport: viewport))
        case .rotate(let db, let dp):
            gestured(MapGestureMath.rotate(cam, bearing: db, pitch: dp))
        case .click(let p):
            click(p, mapProjection(camera: camera, viewport: viewport))
        case .rectangle(let a, let b, let ended):
            dragRectangle(from: a, to: b, ended: ended)
        case .contextMenu(let p, let screen):
            showContextMenu(at: p, screen: screen)
        case .key(let key):
            handle(key)
        }
    }

    private func handle(_ key: MapKey) {
        let middle = viewport / 2
        switch key {
        case .left: handle(.pan(SIMD2(120, 0)))
        case .right: handle(.pan(SIMD2(-120, 0)))
        case .up: handle(.pan(SIMD2(0, 120)))
        case .down: handle(.pan(SIMD2(0, -120)))
        case .zoomIn: handle(.zoom(1, around: middle))
        case .zoomOut: handle(.zoom(-1, around: middle))
        case .resetNorth:
            var c = camera
            c.bearing = 0
            c.pitch = 0
            setCamera(c)
        }
    }

    // MARK: Gesture pacing

    private func gestured(_ c: MapCamera) {
        guard c != liveCamera else { return }
        liveCamera = c
        let now = CACurrentMediaTime()
        gesture.lastGestureTime = now
        gesture.trail.append((now, c))
        if let firstRecent = gesture.trail.firstIndex(where: { now - $0.at <= Pace.trailSeconds }), firstRecent > 0 {
            gesture.trail.removeFirst(firstRecent)
        }
        schedulePlan(now: now)
        scheduleNotify()
        scheduleSettle()
    }

    /// Plans now if the last plan is old enough, else once when it will be.
    private func schedulePlan(now: CFTimeInterval) {
        let sinceLast = now - tilePlan.lastPlanTime
        if sinceLast >= Pace.planInterval {
            planForGesture()
        } else if !gesture.planScheduled {
            gesture.planScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Pace.planInterval - sinceLast) { [weak self] in
                self?.gesture.planScheduled = false
                self?.planForGesture()
            }
        }
    }

    /// The frame is rebuilt only when the plan changed what it draws.
    private func planForGesture() {
        if plan() { invalidateFrame() }
    }

    /// Tells the views that read `camera` (readout, tilt button) that it moved, and refreshes the
    /// cameras-in-view count, at most once per `notifyInterval`.
    private func scheduleNotify() {
        guard !gesture.notifyScheduled else { return }
        gesture.notifyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Pace.notifyInterval) { [weak self] in
            guard let self else { return }
            self.gesture.notifyScheduled = false
            self.withMutation(keyPath: \.camera) {}
            self.updateCamerasInView()
        }
    }

    /// One more plan once the gesture has stopped.
    private func scheduleSettle() {
        guard !gesture.settleScheduled else { return }
        gesture.settleScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Pace.settleCheckInterval) { [weak self] in
            guard let self else { return }
            self.gesture.settleScheduled = false
            if CACurrentMediaTime() - self.gesture.lastGestureTime >= Pace.settleAfter {
                self.gesture.trail.removeAll(keepingCapacity: true)
                self.planForGesture()
            } else {
                self.scheduleSettle()
            }
        }
    }

    // MARK: Programmatic moves

    /// Clamped to the world (no antimeridian wrap in v1), exactly as the map view clamps its own
    /// camera, so both stay identical during gestures.
    static func wrap(_ c: Mercator) -> Mercator {
        Mercator(x: min(1, max(0, c.x)), y: min(1, max(0, c.y)))
    }

    func flyTo(_ p: LonLat, zoom: Double? = nil) {
        var c = camera
        c.center = TileMath.project(p)
        if let zoom { c.zoom = zoom }
        setCamera(c)
    }

    /// Every programmatic camera change (fly to, reset, tilt toggle, QA): drops a pending
    /// gesture update so it can't overwrite this one.
    func setCamera(_ c: MapCamera) {
        gesture.trail.removeAll(keepingCapacity: true)
        var c = c
        c.center = Self.wrap(c.center)
        c.pitch = min(MapCamera.maxPitch, max(0, c.pitch))
        c.zoom = min(MapCamera.maxZoom, max(MapCamera.minZoom, c.zoom))
        camera = c
        refresh()
    }
}
