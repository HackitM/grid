import Foundation
import GridCore
import ImageIO
import Observation

/// Terrain elevation for the map: AWS Terrain Tiles (Terrarium PNGs, public dataset, no key)
/// fetched only after map data is enabled and while the Terrain layer is on, cached on disk under
/// `Maps/terrain/`, decoded off the main thread into per-map-tile `TerrainGrid`s and contour
/// geometry. Elevation tiles stop at z12 (the source data is ~30 m), so deeper map tiles share
/// their z12 ancestor.
@Observable
@MainActor
final class TerrainStore {
    nonisolated static let host = "elevation-tiles-prod.s3.amazonaws.com"

    struct TileTerrain {
        let grid: TerrainGrid
        let contours: [LineBatch]
        let labels: [LabelAnchor]
        /// Borrowed from a coarser elevation tile until this tile's own arrives (no contours).
        var provisional = false
    }

    /// Bumped when terrain for a wanted tile becomes available.
    private(set) var revision = 0
    private(set) var errorCount = 0
    @ObservationIgnored var enabled = false
    @ObservationIgnored var feet = Locale.current.measurementSystem == .us

    @ObservationIgnored private var dem: [TileID: [Float]] = [:]
    @ObservationIgnored private var demOrder: [TileID] = []
    @ObservationIgnored private var tiles: [TileID: TileTerrain] = [:]
    @ObservationIgnored private var tileOrder: [TileID] = []
    @ObservationIgnored private var loadingDEM: Set<TileID> = []
    @ObservationIgnored private var building: Set<TileID> = []
    @ObservationIgnored private var failed: [TileID: Date] = [:]
    @ObservationIgnored private var wanted: Set<TileID> = []
    /// The wanted tiles in the order given (nearest first).
    @ObservationIgnored private var wantedList: [TileID] = []
    @ObservationIgnored private var aheadSet: Set<TileID> = []

    static let maxDEM = 96, maxTiles = 320
    /// Disk cap for cached elevation tiles (oldest removed first).
    nonisolated static let maxDiskBytes: Int64 = 150 << 20
    @ObservationIgnored private var bytesSinceTrim = 0

    func terrain(for t: TileID) -> TileTerrain? { tiles[t] }

    /// The map tiles in view (nearest first); loads what's missing. Until a tile's own elevation
    /// arrives it borrows a coarser one already in memory, so nothing sits at the wrong height.
    /// `ahead` (tiles around the view, loaded early) get their own elevation but never a borrowed one.
    func want(_ ids: [TileID], ahead: [TileID] = []) {
        wantedList = ids + ahead
        wanted = Set(wantedList)
        aheadSet = Set(ahead).subtracting(ids)
        guard enabled else { return }
        var borrowed = false
        let direct = ids.count
        for (k, t) in wantedList.enumerated() where !building.contains(t) {
            let d = Terrarium.demTile(for: t)
            if let have = tiles[t], !have.provisional { continue }
            if let heights = dem[d] { build(t, from: d, heights); continue }
            if k < direct, tiles[t] == nil, let (a, h) = loadedAncestor(of: d) {
                if let grid = Terrarium.grid(for: t, dem: a, heights: h, demSize: 256) {
                    insert(t, TileTerrain(grid: grid, contours: [], labels: [], provisional: true))
                    borrowed = true
                }
            }
            if !loadingDEM.contains(d), !(failed[d].map { Date().timeIntervalSince($0) < 60 } ?? false), loadingDEM.count < 6 {
                loadingDEM.insert(d)
                Task { await self.loadDEM(d) }
            }
        }
        if borrowed { revision &+= 1 }
    }

    /// Runs the wanted list again (after a load finished and freed a slot).
    private func pump() {
        let direct = wantedList.filter { !aheadSet.contains($0) }
        want(direct, ahead: wantedList.filter { aheadSet.contains($0) })
    }

    private func loadedAncestor(of d: TileID) -> (TileID, [Float])? {
        var p = TileMath.parent(d), steps = 0
        while let q = p, steps < 6 {
            if let h = dem[q] { return (q, h) }
            p = TileMath.parent(q); steps += 1
        }
        return nil
    }

    private func insert(_ t: TileID, _ terrain: TileTerrain) {
        tiles[t] = terrain
        tileOrder.removeAll { $0 == t }; tileOrder.append(t)
        guard tileOrder.count > Self.maxTiles else { return }
        // Oldest first, but never a tile the view is asking for (it would be rebuilt at once, and
        // its geometry uploaded again).
        var excess = tileOrder.count - Self.maxTiles
        tileOrder.removeAll { id in
            guard excess > 0, !wanted.contains(id) else { return false }
            tiles[id] = nil; excess -= 1
            return true
        }
    }

    func clear() {
        dem = [:]; demOrder = []; tiles = [:]; tileOrder = []; failed = [:]
        revision &+= 1
    }

    /// Unit change (feet / metres) rebuilds the contours.
    func setFeet(_ on: Bool) {
        guard on != feet else { return }
        feet = on
        tiles = [:]; tileOrder = []
        revision &+= 1
    }

    // MARK: Loading

    private func file(_ d: TileID) -> URL {
        MapStorage.terrain
            .appendingPathComponent("\(d.z)", isDirectory: true).appendingPathComponent("\(d.x)", isDirectory: true)
            .appendingPathComponent("\(d.y).png")
    }

    private func loadDEM(_ d: TileID) async {
        // Afterwards, start whatever the in-flight cap held back.
        defer { loadingDEM.remove(d); if enabled { pump() } }
        // Disk read and decode together, off the main thread.
        let url = file(d)
        if let cached = await Task.detached(priority: .userInitiated, operation: { () -> [Float]? in
            MapStorage.read(url, maxBytes: 2 << 20).flatMap(Self.decodePNG)
        }).value {
            store(d, cached)
            return
        }
        var data: Data?
        var fromNetwork = false
        if data == nil {
            guard enabled, d.isValid,
                  let url = URL(string: "https://\(Self.host)/terrarium/\(d.z)/\(d.x)/\(d.y).png") else { return }
            do {
                let r = try await MapNetwork.shared.get(url, hosts: [Self.host], maxBytes: 2 << 20)
                guard r.status == 200 else { throw MapNetwork.NetError.http(r.status) }
                data = r.data
                fromNetwork = true
            } catch {
                failed[d] = Date(); errorCount += 1
                return
            }
        }
        guard let bytes = data else { return }
        let heights = await Task.detached(priority: .userInitiated) { Self.decodePNG(bytes) }.value
        guard let heights else { failed[d] = Date(); errorCount += 1; return }
        // Cache only what decoded (a captive portal page never lands on disk).
        if fromNetwork, (try? MapStorage.write(bytes, to: file(d))) != nil {
            bytesSinceTrim += bytes.count
            if bytesSinceTrim > 8 << 20 { bytesSinceTrim = 0; Task.detached(priority: .utility) { Self.trimDisk() } }
        }
        store(d, heights)
    }

    private func store(_ d: TileID, _ heights: [Float]) {
        dem[d] = heights
        demOrder.removeAll { $0 == d }; demOrder.append(d)
        if demOrder.count > Self.maxDEM {
            let needed = Set(wantedList.map { Terrarium.demTile(for: $0) })
            var excess = demOrder.count - Self.maxDEM
            demOrder.removeAll { id in
                guard excess > 0, id != d, !needed.contains(id) else { return false }
                dem[id] = nil; excess -= 1
                return true
            }
        }
        for t in wantedList where Terrarium.demTile(for: t) == d && (tiles[t]?.provisional ?? true) { build(t, from: d, heights) }
    }

    private func build(_ t: TileID, from d: TileID, _ heights: [Float]) {
        building.insert(t)
        let feet = self.feet
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> TileTerrain? in
                guard let grid = Terrarium.grid(for: t, dem: d, heights: heights, demSize: 256) else { return nil }
                let (lines, labels) = Contours.geometry(grid, feet: feet)
                return TileTerrain(grid: grid, contours: lines, labels: labels)
            }.value
            building.remove(t)
            guard let result, feet == self.feet else { return }
            insert(t, result)
            if wanted.contains(t) { revision &+= 1 }
        }
    }

    /// Removes the oldest cached elevation tiles until under 90% of the cap.
    nonisolated static func trimDisk() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: MapStorage.terrain, includingPropertiesForKeys: keys) else { return }
        var files: [(URL, Int64, Date)] = []
        var total: Int64 = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let s = Int64(v.fileSize ?? 0)
            total += s
            files.append((u, s, v.contentModificationDate ?? .distantPast))
        }
        guard total > maxDiskBytes else { return }
        for (u, s, _) in files.sorted(by: { $0.2 < $1.2 }) {
            try? FileManager.default.removeItem(at: u)
            total -= s
            if total < maxDiskBytes * 9 / 10 { break }
        }
    }

    /// Terrarium PNG → elevations (256 × 256). Reads the decoded pixel bytes directly: drawing
    /// into a bitmap would colour-manage them, and these channels are data, not colours.
    nonisolated static func decodePNG(_ data: Data) -> [Float]? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) == 1,
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              img.width == 256, img.height == 256, img.bitsPerComponent == 8,
              img.bitsPerPixel == 24 || img.bitsPerPixel == 32,
              let raw = img.dataProvider?.data as Data? else { return nil }
        // Alpha-first layouts would shift the channels; Terrarium tiles are RGB (or RGBA last).
        switch img.alphaInfo {
        case .first, .premultipliedFirst, .noneSkipFirst: return nil
        default: break
        }
        return Terrarium.decode([UInt8](raw), width: img.width, height: img.height,
                                bytesPerPixel: img.bitsPerPixel / 8, bytesPerRow: img.bytesPerRow)
    }
}
