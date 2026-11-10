import AppKit
import GridCore

// What is under the pointer and in view: clicks, the right-click menu, the visible box.

extension MapModel {
    /// A camera or cluster is hit within this many points of it.
    private enum HitRadius {
        static let camera = 12.0, cluster = 18.0, place = 14.0
    }

    // MARK: The ground in view

    /// Geographic box of the ground in view (nil when it can't be computed).
    func visibleBBox() -> BBox? {
        if camera.isGlobe {
            // The facing hemisphere, roughly (the renderer hides anything on the far side).
            let c = TileMath.unproject(camera.center)
            return BBox(west: max(-180, c.lon - 95), south: max(-85, c.lat - 90), east: min(180, c.lon + 95), north: min(85, c.lat + 90))
        }
        let projection = MapProjection(camera: camera, viewport: viewport)
        var west = Double.infinity, south = Double.infinity, east = -Double.infinity, north = -Double.infinity
        for sx in [0.0, 0.5, 1.0] {
            for sy in [0.0, 1.0] {
                guard let ground = projection.groundPoint(screen: SIMD2(sx * viewport.x, sy * viewport.y)) else { continue }
                let p = TileMath.unproject(Self.wrap(ground))
                west = min(west, p.lon); east = max(east, p.lon)
                south = min(south, p.lat); north = max(north, p.lat)
            }
        }
        guard west.isFinite else { return nil }
        return BBox(west: west, south: south, east: east, north: north)
    }

    // MARK: Cameras in view

    /// Starts a recount of the cameras in view (and the nearest ones, while the list is open).
    /// The count shows in the readout, which redraws during gestures; counting a large index
    /// there would stall them, so it is done off the main thread and arrives a moment later.
    func updateCamerasInView() {
        guard showCameras, !alpr.index.cameras.isEmpty, let box = visibleBBox() else { inView.reset(); return }
        inView.update(index: alpr.index, revision: alpr.revision, box: box, centre: TileMath.unproject(liveCamera.center))
    }

    /// The cameras in view, counted now (QA state; the page reads `inView.count`).
    func camerasInViewCount() -> Int { visibleBBox().map { alpr.index.query($0).count } ?? 0 }

    /// Great-circle distance in metres.
    nonisolated static func distance(_ a: LonLat, _ b: LonLat) -> Double {
        let radius = 6_371_000.0, lat1 = a.lat * .pi / 180, lat2 = b.lat * .pi / 180
        let dLat = (b.lat - a.lat) * .pi / 180, dLon = (b.lon - a.lon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * asin(min(1, sqrt(h)))
    }

    // MARK: Hit testing on the drawn terrain

    /// The last frame with the terrain lift of the current camera (what is on screen).
    private var drawnFrame: MapFrame? {
        guard var f = frameCache.frame else { return nil }
        f.lift = f.lift(for: liveCamera, viewport: viewport)
        return f
    }

    /// Screen point of a world point on the drawn terrain.
    private func screenOnTerrain(_ w: Mercator, _ projection: any MapScreenProjection, _ f: MapFrame?) -> SIMD2<Double>? {
        projection.screen(w, heightMeters: f?.elevation(at: w) ?? 0)
    }

    /// The world point under a screen point on the drawn terrain: the ground-plane hit, refined a
    /// few times by the lift's screen offset there.
    private func pick(_ p: SIMD2<Double>, _ projection: any MapScreenProjection) -> Mercator? {
        guard var ground = projection.groundPoint(screen: p) else { return nil }
        guard let f = drawnFrame, !f.lift.isFlat else { return ground }
        for _ in 0..<4 {
            guard let lifted = projection.screen(ground, heightMeters: f.elevation(at: ground)), let flat = projection.screen(ground),
                  let next = projection.groundPoint(screen: p - (lifted - flat)) else { break }
            ground = next
        }
        return ground
    }

    /// The drawn point of interest nearest a view point, from the last frame.
    private func poi(at p: SIMD2<Double>, _ projection: any MapScreenProjection) -> PlaceResult? {
        guard let f = frameCache.frame, f.poiMask != 0 else { return nil }
        let zoom = Float(camera.zoom)
        let drawn = drawnFrame
        var best: (distance: Double, anchor: POIAnchor, world: Mercator)?
        for t in f.tiles where !t.pois.isEmpty {
            let (nw, se) = TileMath.bounds(t.id)
            for a in t.pois where a.minZoom <= zoom && f.poiMask & (1 << UInt16(a.category.rawValue)) != 0 {
                let w = Mercator(x: nw.x + Double(a.pos.x) * (se.x - nw.x), y: nw.y + Double(a.pos.y) * (se.y - nw.y))
                guard let s = screenOnTerrain(w, projection, drawn) else { continue }
                let d = hypot(s.x - p.x, s.y - p.y)
                guard d < HitRadius.place, d < (best?.distance ?? .infinity) else { continue }
                // Only a glyph that is on screen (not dropped for overlapping another label).
                let shown = MapLabelPlanner.display(a.name, kind: .road)
                guard MapLabelPlanner.drawnPOIs.contains(where: { $0.name == shown && hypot($0.center.x - s.x, $0.center.y - s.y) < 4 }) else { continue }
                best = (d, a, w)
            }
        }
        guard let best else { return nil }
        let ll = TileMath.unproject(best.world)
        return PlaceResult(id: String(format: "poi:%.6f,%.6f:", ll.lat, ll.lon) + best.anchor.name, name: best.anchor.name, kind: .poi,
                           category: best.anchor.category, detail: best.anchor.detail, coordinate: ll, source: .local, distance: nil)
    }

    // MARK: Click

    func click(_ p: SIMD2<Double>, _ projection: any MapScreenProjection) {
        if camera.zoom < Self.cameraDetailZoom {
            if let cluster = cluster(at: p, projection) {
                if cluster.count == 1 {
                    select(cluster.representative)
                } else {
                    // Zoom in on it, far enough to see its cameras one by one.
                    let around = projection.screen(TileMath.project(cluster.center)) ?? p
                    handle(.zoom(min(3, Self.cameraDetailZoom + 0.2 - camera.zoom), around: around))
                }
                return
            }
            clearSelection()
            return
        }
        guard let ground = pick(p, projection) else { select(nil); return }
        if let hit = camera(near: TileMath.unproject(ground), projection) {
            select(hit)
        } else if let hit = poi(at: p, projection) {
            selectPlace(hit)
        } else {
            clearSelection()
        }
    }

    /// The drawn camera at a ground point (none while the camera layer is hidden).
    private func camera(near p: LonLat, _ projection: any MapScreenProjection) -> Int? {
        guard showCameras else { return nil }
        return alpr.index.nearest(to: p, maxWorldDistance: HitRadius.camera / projection.worldScale)
    }

    private func clearSelection() {
        select(nil)
        selectPlace(nil)
    }

    /// The cluster drawn nearest a view point. Uses the clusters the frame draws, so a click
    /// finds what is on screen.
    private func cluster(at p: SIMD2<Double>, _ projection: any MapScreenProjection) -> CameraCluster? {
        guard showCameras else { return nil }
        let clusters: [CameraCluster]
        if let drawn = drawnClusters {
            clusters = drawn
        } else if let box = tilePlan.markerBox ?? visibleBBox() {
            // The marker set isn't ready (or was built for individual cameras): the same grouping, worked out now.
            clusters = alpr.index.clusters(box, cellWorld: CameraMarkerSet.clusterCell(level: Self.markerLevel(zoom: camera.zoom)))
        } else {
            return nil
        }
        let drawn = drawnFrame
        var best: (cluster: CameraCluster, distance: Double)?
        for c in clusters {
            guard let s = screenOnTerrain(TileMath.project(c.center), projection, drawn) else { continue }
            let d = hypot(s.x - p.x, s.y - p.y)
            if d < HitRadius.cluster, d < (best?.distance ?? .infinity) { best = (c, d) }
        }
        return best?.cluster
    }

    // MARK: Right-click menu

    func showContextMenu(at p: SIMD2<Double>, screen: SIMD2<Double>) {
        let projection = mapProjection(camera: camera, viewport: viewport)
        guard let ground = pick(p, projection) else { return }
        let ll = TileMath.unproject(ground)
        let coordinates = String(format: "%.5f, %.5f", ll.lat, ll.lon)
        let title = String(format: "%.4f %@ · %.4f %@", abs(ll.lat), ll.lat >= 0 ? "N" : "S", abs(ll.lon), ll.lon >= 0 ? "E" : "W")
        let endName = String(format: "%.4f, %.4f", ll.lat, ll.lon)
        let zoom = Int(camera.zoom.rounded())
        let cameraHit = camera.zoom >= Self.cameraDetailZoom ? camera(near: ll, projection) : nil

        var items: [GridMenuItem] = []
        if let i = cameraHit {
            items.append(.action("Inspect Camera") { [weak self] in self?.select(i); self?.app?.inspectorVisible = true })
            items.append(.divider)
        } else if let hit = poi(at: p, projection) {
            items.append(.action("Inspect \(hit.name)") { [weak self] in self?.selectPlace(hit) })
            items.append(.divider)
        }
        items.append(.action("Directions from Here") { [weak self] in
            self?.routing.setEnd(from: true, MapRouting.End(name: endName, coordinate: ll))
        })
        items.append(.action("Directions to Here") { [weak self] in
            self?.routing.setEnd(from: false, MapRouting.End(name: endName, coordinate: ll))
        })
        items.append(.divider)
        items.append(.action("Centre Map Here") { [weak self] in self?.flyTo(ll) })
        items.append(.action("Copy Coordinates") { [weak self] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(coordinates, forType: .string)
            self?.app?.flash(.info, "Copied \(coordinates)")
        })
        items.append(.divider)
        // These two leave GRID on purpose: the point goes to Apple Maps or the browser.
        items.append(.action("Open in Apple Maps") {
            if let u = URL(string: String(format: "https://maps.apple.com/?ll=%.6f,%.6f&z=%d", ll.lat, ll.lon, max(3, zoom))) { NSWorkspace.shared.open(u) }
        })
        items.append(.action("View on OpenStreetMap") { [weak self] in
            self?.app?.openURL(String(format: "https://www.openstreetmap.org/#map=%d/%.5f/%.5f", max(3, min(19, zoom)), ll.lat, ll.lon))
        })
        items.append(.divider)
        items.append(.action("Download Cameras for This View", enabled: enabled && !camera.isGlobe && !alpr.busy) { [weak self] in
            guard let self, let box = self.visibleBBox(), box.isValid else { return }
            self.requestDownload(of: box)
        })
        GridMenu.shared.show(items, title: title, anchor: .point(NSPoint(x: screen.x, y: screen.y)), window: NSApp.keyWindow ?? NSApp.mainWindow)
    }
}
