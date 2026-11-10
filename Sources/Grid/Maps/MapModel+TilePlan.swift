import GridCore
import QuartzCore

// Which tiles the current camera needs: the view, a low-zoom backdrop under it, and the tiles
// around it and ahead of the gesture in progress.

extension MapModel {
    /// How far around and ahead of the view tiles are loaded. Every prefetched tile is a request
    /// (and a decode) that is wasted if the view never gets there, so these stay as small as they
    /// can without ground arriving late.
    enum Prefetch {
        /// Most tiles the view itself may ask for.
        static let coverLimit = 48
        /// Most tiles loaded beyond the view at any time.
        static let limit = 48
        /// At rest: the view grown by this factor. The ring is also all the frame holds beyond
        /// the view, so it is what the map view draws during the first moments of a fling, before
        /// the next plan lands; shrinking it shows empty ground at the leading edge.
        static let restPad = 1.35
        static let restLimit = 80
        /// While moving: where the camera will be after each of these delays, grown a little.
        static let lookAheadSeconds = [0.3, 0.6]
        static let lookAheadPad = 1.15
        static let lookAheadLimit = 56
        /// The look-ahead centre goes no further than this many screens from the view. Trackpad
        /// momentum decays, so a straight-line guess further out mostly loads ground that is
        /// never reached; one screen is still several plans ahead at any speed.
        static let maxReachScreens = 1.0
        /// Zoom is predicted only this far ahead. A zoom level is a whole new set of tiles, and a
        /// pinch that stops short of the next level would have loaded them for nothing.
        static let zoomHorizon = 0.3
    }

    /// The tiles asked for by the last plan.
    struct TilePlan {
        /// The tiles in view, nearest first.
        var cover: [TileID] = []
        /// Prefetched tiles around the view that the frame carries too (drawn the moment they
        /// scroll in, without waiting for the next frame): same level as the cover or coarser.
        var ring: [TileID] = []
        /// What the frame draws that depends on the camera; a gesture rebuilds the frame only
        /// when this changes.
        var contentKey: ContentKey?
        /// Geographic box of the cover: markers are collected for all of it, so panning inside it
        /// needs no new frame.
        var markerBox: BBox?
        var lastPlanTime: CFTimeInterval = 0
    }

    struct ContentKey: Equatable {
        var cover: Set<TileID>
        var ring: Set<TileID>
        var globe: Bool
        var markerLevel: Int
    }

    /// Cameras are drawn one by one from this zoom; below it they are clustered.
    static let cameraDetailZoom = 12.0

    /// The clustering step for a zoom: -1 when cameras are drawn one by one, else the zoom in
    /// quarter levels (clusters regroup four times per zoom level, not on every frame).
    static func markerLevel(zoom: Double) -> Int {
        zoom >= cameraDetailZoom ? -1 : Int((zoom * 4).rounded(.down))
    }

    /// Asks the stores for the tiles of the current camera. True when what the frame draws changed.
    @discardableResult
    func plan() -> Bool {
        let cam = liveCamera
        tilePlan.lastPlanTime = CACurrentMediaTime()
        #if DEBUG
        let started = tilePlan.lastPlanTime
        defer { MapDebugTimes.add("plan", since: started) }
        #endif
        let maxZoom = tiles.source?.maxZoom ?? 14
        let cover = TileMath.cover(cam, viewport: viewport, maxZoom: maxZoom, limit: Prefetch.coverLimit)
        let coverSet = Set(cover)
        let deepest = Int(cover.map(\.z).max() ?? 0)

        let backdrop = Self.backdrop(of: cover, deepest: deepest)
        let prefetch = prefetchTiles(around: cam, maxZoom: maxZoom, excluding: coverSet.union(backdrop))

        // Deeper tiles ahead of a zoom-in are loaded but not drawn until the view reaches their level.
        let ring = prefetch.filter { Int($0.z) <= deepest }
        let ahead = prefetch.filter { Int($0.z) > deepest }
        tilePlan.cover = cover
        tilePlan.ring = ring
        tiles.want(cover, ring: ring, backdrop: backdrop, prefetch: ahead)
        if showTerrain && !cam.isGlobe { terrain.want(cover + backdrop, ahead: prefetch) }

        let key = ContentKey(cover: coverSet, ring: Set(ring), globe: cam.isGlobe, markerLevel: Self.markerLevel(zoom: cam.zoom))
        guard key != tilePlan.contentKey else { return false }
        tilePlan.contentKey = key
        tilePlan.markerBox = Self.geoBounds(of: cover)
        return true
    }

    /// The cover's ancestors two and four levels up: a handful of tiles that span many screens,
    /// so ground that scrolls or zooms into view is never empty.
    private static func backdrop(of cover: [TileID], deepest: Int) -> [TileID] {
        var backdrop: [TileID] = []
        var seen = Set<TileID>()
        for level in [deepest - 2, deepest - 4] where level >= 0 {
            for t in cover where Int(t.z) > level {
                let shift = Int(t.z) - level
                let ancestor = TileID(z: level, x: Int(t.x) >> shift, y: Int(t.y) >> shift)
                if seen.insert(ancestor).inserted { backdrop.append(ancestor) }
            }
        }
        return backdrop
    }

    /// Tiles to load beyond the view, most useful first: a ring around the view at rest; where
    /// the gesture is heading while it moves.
    private func prefetchTiles(around cam: MapCamera, maxZoom: Int, excluding: Set<TileID>) -> [TileID] {
        var prefetch: [TileID] = []
        var seen = excluding
        func add(viewOf c: MapCamera, pad: Double, limit: Int) {
            for t in TileMath.cover(c, viewport: viewport * pad, maxZoom: maxZoom, limit: limit) where seen.insert(t).inserted {
                prefetch.append(t)
            }
        }
        if let velocity = gestureVelocity() {
            for seconds in Prefetch.lookAheadSeconds {
                add(viewOf: Self.advance(cam, by: velocity, seconds: seconds, viewport: viewport),
                    pad: Prefetch.lookAheadPad, limit: Prefetch.lookAheadLimit)
            }
        } else {
            add(viewOf: cam, pad: Prefetch.restPad, limit: Prefetch.restLimit)
        }
        if prefetch.count > Prefetch.limit { prefetch.removeSubrange(Prefetch.limit...) }
        return prefetch
    }

    private static func geoBounds(of tiles: [TileID]) -> BBox? {
        guard !tiles.isEmpty else { return nil }
        var west = 180.0, south = 90.0, east = -180.0, north = -90.0
        for t in tiles {
            let b = TileMath.geoBounds(t)
            west = min(west, b.west); south = min(south, b.south); east = max(east, b.east); north = max(north, b.north)
        }
        return BBox(west: max(-180, west), south: max(-85.06, south), east: min(180, east), north: min(85.06, north))
    }

    // MARK: Look-ahead

    /// Camera change per second.
    struct CameraVelocity {
        var center: SIMD2<Double>
        var zoom: Double
        var bearing: Double
        var pitch: Double
    }

    /// Camera change per second over the last moments of a gesture; nil at rest.
    func gestureVelocity() -> CameraVelocity? {
        guard let first = gesture.trail.first, let last = gesture.trail.last,
              CACurrentMediaTime() - last.at < 0.12, last.at - first.at >= 0.03 else { return nil }
        let dt = last.at - first.at
        var turn = last.camera.bearing - first.camera.bearing
        if turn > 180 { turn -= 360 } else if turn < -180 { turn += 360 }
        let moved = SIMD2(last.camera.center.x - first.camera.center.x, last.camera.center.y - first.camera.center.y)
        return CameraVelocity(center: moved / dt, zoom: (last.camera.zoom - first.camera.zoom) / dt,
                              bearing: turn / dt, pitch: (last.camera.pitch - first.camera.pitch) / dt)
    }

    /// Where the camera will be in `seconds` at this velocity, within the limits in `Prefetch`
    /// (and no more than one zoom level, a sixth of a turn or 20° of tilt).
    static func advance(_ cam: MapCamera, by v: CameraVelocity, seconds: Double, viewport: SIMD2<Double>) -> MapCamera {
        var c = cam
        var travel = v.center * seconds
        let reach = Prefetch.maxReachScreens * max(viewport.x, viewport.y) / (256 * pow(2, cam.zoom))
        let length = (travel.x * travel.x + travel.y * travel.y).squareRoot()
        if length > reach { travel *= reach / length }
        c.center = Mercator(x: cam.center.x + travel.x, y: cam.center.y + travel.y)
        c.zoom += min(1, max(-1, v.zoom * min(seconds, Prefetch.zoomHorizon)))
        c.bearing += min(60, max(-60, v.bearing * seconds))
        c.pitch += min(20, max(-20, v.pitch * seconds))
        return MapGestureMath.clamp(c)
    }
}
