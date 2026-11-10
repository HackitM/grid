import CryptoKit
import Foundation
import GridCore
import Observation

/// Base-map tiles: TileJSON → wanted tiles → disk cache or network → decode (off the main
/// thread, validating) → `TileGeometry` in a memory LRU. Never fetches before map data is enabled.
@Observable
@MainActor
final class TileStore {
    nonisolated static let defaultTileJSON = URL(string: "https://tiles.openfreemap.org/planet")!
    nonisolated static let defaultHosts: Set<String> = ["tiles.openfreemap.org"]

    private(set) var source: TileSource?
    /// Bumps when the source changes; the renderer drops its GPU tiles then.
    private(set) var generation = 0
    private(set) var loadedCount = 0
    private(set) var wantedCount = 0
    private(set) var errorCount = 0
    private(set) var sourceError: String?
    /// Bumped when a wanted tile becomes available (the model rebuilds its frame).
    private(set) var revision = 0

    @ObservationIgnored var enabled = false
    @ObservationIgnored private var cache: TileCache?
    @ObservationIgnored private var decoded: [TileID: TileGeometry] = [:]
    /// When each decoded tile was last drawn or asked for (eviction takes the smallest).
    @ObservationIgnored private var lastUse: [TileID: UInt64] = [:]
    @ObservationIgnored private var useClock: UInt64 = 0
    @ObservationIgnored private var decodedBytes = 0
    @ObservationIgnored private var inFlight: Set<TileID> = []
    @ObservationIgnored private var queue: [TileID] = []
    /// The tiles in view.
    @ObservationIgnored private var wanted: Set<TileID> = []
    /// The tiles the frame draws: the view and the ring around it.
    @ObservationIgnored private var drawn: Set<TileID> = []
    /// Everything asked for: the view, its low-zoom backdrop and the tiles around and ahead of it.
    @ObservationIgnored private var keep: Set<TileID> = []
    @ObservationIgnored private var background: Set<TileID> = []
    @ObservationIgnored private var failed: [TileID: Date] = [:]
    @ObservationIgnored private var loadingSource = false

    static let maxDecodedBytes = 192 << 20
    /// Loads running for tiles still asked for. Loads the view has moved away from finish (and
    /// are cached) without holding up the queue, up to `maxInFlightTotal`.
    static let maxInFlight = 10
    static let maxInFlightTotal = 20

    /// Reads the TileJSON (each time the Map opens, so a new planet build is noticed).
    func loadSource(url: URL = defaultTileJSON, hosts: Set<String> = defaultHosts) async {
        guard enabled, !loadingSource else { return }
        loadingSource = true
        defer { loadingSource = false }
        do {
            let r = try await MapNetwork.shared.get(url, hosts: hosts, maxBytes: 1 << 20)
            guard r.status == 200 else { throw MapNetwork.NetError.http(r.status) }
            let s = try TileSource.parse(r.data, from: url)
            guard MapNetwork.isAllowed(URL(string: s.template.replacingOccurrences(of: "{z}", with: "0")
                .replacingOccurrences(of: "{x}", with: "0").replacingOccurrences(of: "{y}", with: "0"))
                ?? url, hosts: hosts) else { throw MapNetwork.NetError.blockedURL(s.template) }
            sourceError = nil
            if s != source {
                source = s
                cache = TileCache(sourceKey: Self.sourceKey(s))
                resetMemory()
                generation += 1
            }
        } catch {
            sourceError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// A short hash of host + template: the cache folder never takes a remote string as its name.
    static func sourceKey(_ s: TileSource) -> String {
        let digest = SHA256.hash(data: Data((s.host + "|" + s.template).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// What the current view needs, each list nearest first: `visible` is in view; `ring` is the
    /// tiles around it and ahead of a gesture, drawn too so they are there before they scroll in;
    /// `backdrop` is a few low-zoom ancestors that stand in for anything not loaded yet (loaded
    /// first, so moving never shows empty ground); `prefetch` is loaded last and not drawn.
    func want(_ visible: [TileID], ring: [TileID] = [], backdrop: [TileID] = [], prefetch: [TileID] = []) {
        wanted = Set(visible)
        drawn = wanted.union(ring)
        background = Set(prefetch).union(ring).subtracting(wanted)
        keep = drawn.union(backdrop).union(prefetch)
        let loaded = visible.reduce(0) { $0 + (decoded[$1] != nil ? 1 : 0) }
        if wantedCount != visible.count { wantedCount = visible.count }
        if loadedCount != loaded { loadedCount = loaded }
        guard enabled, source != nil else { return }
        let now = Date()
        var seen = Set<TileID>()
        queue.removeAll(keepingCapacity: true)
        for list in [backdrop, visible, ring, prefetch] {
            for t in list where decoded[t] == nil && !inFlight.contains(t) && seen.insert(t).inserted {
                if let f = failed[t], now.timeIntervalSince(f) < 30 { continue }
                queue.append(t)
            }
        }
        pump()
    }

    /// Geometry to draw for `tiles`: each loaded tile, else its nearest loaded ancestor (≤ 6 levels up).
    func geometry(for tiles: [TileID]) -> [TileGeometry] {
        var out: [TileGeometry] = []
        out.reserveCapacity(tiles.count + 4)
        var seen = Set<TileID>()
        useClock &+= 1
        for t in tiles {
            if let g = decoded[t] { if seen.insert(t).inserted { out.append(g); lastUse[t] = useClock } ; continue }
            var p = TileMath.parent(t), steps = 0
            while let q = p, steps < 6 {
                if let g = decoded[q] { if seen.insert(q).inserted { out.append(g); lastUse[q] = useClock }; break }
                p = TileMath.parent(q); steps += 1
            }
        }
        return out
    }

    /// Every decoded tile in memory (place search reads their names).
    func allGeometry() -> [TileGeometry] { Array(decoded.values) }

    func clearMemory() { resetMemory(); generation += 1 }

    private func resetMemory() {
        decoded = [:]; lastUse = [:]; decodedBytes = 0; failed = [:]; queue = []
        loadedCount = 0
    }

    private func pump() {
        while !queue.isEmpty, inFlight.count < Self.maxInFlightTotal {
            var active = 0
            for t in inFlight where keep.contains(t) { active += 1 }
            guard active < Self.maxInFlight else { return }
            let t = queue.removeFirst()
            guard keep.contains(t), decoded[t] == nil, !inFlight.contains(t) else { continue }
            inFlight.insert(t)
            Task { await self.load(t) }
        }
    }

    private func load(_ t: TileID) async {
        defer { inFlight.remove(t); pump() }
        guard let source, let cache else { return }
        let gen = generation
        // Cached tiles are read and decoded in one trip off the main thread: each hop back to the
        // main actor waits behind drawing while the map moves, which made tiles arrive late.
        // Tiles around the view decode behind the ones in it.
        let priority: TaskPriority = background.contains(t) ? .utility : .userInitiated
        let cached = await Task.detached(priority: priority) { () -> TileGeometry?? in
            guard let bytes = cache.read(t) else { return .none }
            return .some(Self.decode(bytes, t))
        }.value
        guard gen == generation else { return }
        if case .some(let g?) = cached { insertLoaded(g); return }
        var data: Data?
        var fromNetwork = false
        if data == nil {
            guard keep.contains(t), let url = source.url(for: t) else { return }
            do {
                let r = try await MapNetwork.shared.get(url, hosts: [source.host], maxBytes: TileCache.maxTileBytes)
                switch r.status {
                case 200: data = r.data; fromNetwork = true
                case 204, 404: data = Data()    // outside coverage: draw nothing
                default: throw MapNetwork.NetError.http(r.status)
                }
            } catch {
                failed[t] = Date(); errorCount += 1
                return
            }
        }
        guard let bytes = data, gen == generation else { return }
        #if DEBUG
        let t0 = CFAbsoluteTimeGetCurrent()
        defer {
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            statLoads += 1; statDecodeMs += ms; statMaxDecodeMs = max(statMaxDecodeMs, ms)
            if fromNetwork { statNetwork += 1 }
        }
        #endif
        let result = await Task.detached(priority: priority) { Self.decode(bytes, t) }.value
        guard gen == generation else { return }
        guard let geometry = result else {
            // Not a vector tile (a captive portal page, a truncated body…): don't cache it, retry later.
            failed[t] = Date(); errorCount += 1
            return
        }
        if fromNetwork && !bytes.isEmpty { Task.detached(priority: .utility) { await cache.write(t, bytes) } }
        insertLoaded(geometry)
    }

    private func insertLoaded(_ geometry: TileGeometry) {
        insert(geometry)
        guard keep.contains(geometry.id) else { return }
        if wanted.contains(geometry.id) { loadedCount = wanted.reduce(0) { $0 + (decoded[$1] != nil ? 1 : 0) } }
        // The frame only changes when this tile is drawn: its own place, or standing in for another.
        if drawn.contains(geometry.id) || standsIn(geometry.id) { revision &+= 1 }
    }

    /// MVT bytes → geometry (empty bytes = outside coverage); nil when it isn't a vector tile.
    nonisolated static func decode(_ bytes: Data, _ t: TileID) -> TileGeometry? {
        if bytes.isEmpty { return TileGeometry(id: t, fills: [], lines: [], extrusion: nil, labels: [], byteCount: 64) }
        guard let tile = try? MVTDecoder.decode(bytes, layers: OpenMapTilesSchema.layers) else { return nil }
        return TileGeometryBuilder.build(tile, id: t)
    }

    #if DEBUG
    @ObservationIgnored private var statLoads = 0
    @ObservationIgnored private var statNetwork = 0
    @ObservationIgnored private var statEvictWanted = 0
    @ObservationIgnored private var statDecodeMs = 0.0
    @ObservationIgnored private var statMaxDecodeMs = 0.0
    var debugStats: [String: Any] {
        ["decoded": decoded.count, "decodedMB": decodedBytes >> 20, "inFlight": inFlight.count, "queue": queue.count,
         "loads": statLoads, "network": statNetwork, "evictedWanted": statEvictWanted,
         "avgDecodeMs": statLoads > 0 ? statDecodeMs / Double(statLoads) : 0, "maxDecodeMs": statMaxDecodeMs]
    }
    #endif

    #if DEBUG
    /// How many of `cover` aren't decoded, and how many of those have no ancestor to stand in.
    func debugCoverage(_ cover: [TileID]) -> (missing: Int, holes: Int) {
        var missing = 0, holes = 0
        for t in cover where decoded[t] == nil {
            missing += 1
            var p = TileMath.parent(t), steps = 0, found = false
            while let q = p, steps < 6 { if decoded[q] != nil { found = true; break }; p = TileMath.parent(q); steps += 1 }
            if !found { holes += 1 }
        }
        return (missing, holes)
    }
    #endif

    /// A drawn tile that isn't loaded has `id` as an ancestor (so `id` would be drawn in its place).
    private func standsIn(_ id: TileID) -> Bool {
        for t in drawn where t.z > id.z && decoded[t] == nil {
            let shift = UInt32(t.z - id.z)
            if shift <= 6, t.x >> shift == id.x, t.y >> shift == id.y { return true }
        }
        return false
    }

    private func insert(_ g: TileGeometry) {
        if let old = decoded[g.id] { decodedBytes -= old.byteCount }
        decoded[g.id] = g
        decodedBytes += g.byteCount
        useClock &+= 1
        lastUse[g.id] = useClock
        guard decodedBytes > Self.maxDecodedBytes else { return }
        // Least recently used first; tiles the view asked for go last.
        let order = decoded.keys.sorted { a, b in
            let ka = keep.contains(a), kb = keep.contains(b)
            return ka != kb ? !ka : (lastUse[a] ?? 0) < (lastUse[b] ?? 0)
        }
        for victim in order where victim != g.id {
            guard decodedBytes > Self.maxDecodedBytes * 7 / 8 else { break }
            if let v = decoded.removeValue(forKey: victim) { decodedBytes -= v.byteCount }
            lastUse[victim] = nil
            #if DEBUG
            if wanted.contains(victim) { statEvictWanted += 1 }
            #endif
        }
    }
}
