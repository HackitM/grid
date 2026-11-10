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
    @ObservationIgnored private var lru: [TileID] = []
    @ObservationIgnored private var decodedBytes = 0
    @ObservationIgnored private var inFlight: Set<TileID> = []
    @ObservationIgnored private var queue: [TileID] = []
    @ObservationIgnored private var wanted: Set<TileID> = []
    @ObservationIgnored private var failed: [TileID: Date] = [:]
    @ObservationIgnored private var loadingSource = false

    static let maxDecodedBytes = 160 << 20
    static let maxInFlight = 6

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

    /// The tiles the current view needs (nearest first). Starts loads for missing ones.
    func want(_ tiles: [TileID]) {
        wanted = Set(tiles)
        wantedCount = tiles.count
        loadedCount = tiles.filter { decoded[$0] != nil }.count
        guard enabled, source != nil else { return }
        queue = tiles.filter { decoded[$0] == nil && !inFlight.contains($0) && !(failed[$0].map { Date().timeIntervalSince($0) < 30 } ?? false) }
        pump()
    }

    /// Geometry to draw for `tiles`: each loaded tile, else its nearest loaded ancestor (≤ 5 levels up).
    func geometry(for tiles: [TileID]) -> [TileGeometry] {
        var out: [TileGeometry] = []
        var seen = Set<TileID>()
        for t in tiles {
            if let g = decoded[t] { if seen.insert(t).inserted { out.append(g); touch(t) } ; continue }
            var p = TileMath.parent(t), steps = 0
            while let q = p, steps < 5 {
                if let g = decoded[q] { if seen.insert(q).inserted { out.append(g); touch(q) }; break }
                p = TileMath.parent(q); steps += 1
            }
        }
        return out
    }

    func clearMemory() { resetMemory(); generation += 1 }

    private func resetMemory() {
        decoded = [:]; lru = []; decodedBytes = 0; failed = [:]; queue = []
        loadedCount = 0
    }

    private func pump() {
        while inFlight.count < Self.maxInFlight, !queue.isEmpty {
            let t = queue.removeFirst()
            guard wanted.contains(t), decoded[t] == nil, !inFlight.contains(t) else { continue }
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
        let cached = await Task.detached(priority: .userInitiated) { () -> TileGeometry?? in
            guard let bytes = await cache.read(t) else { return .none }
            return .some(Self.decode(bytes, t))
        }.value
        guard gen == generation else { return }
        if case .some(let g?) = cached { insertLoaded(g); return }
        var data: Data?
        var fromNetwork = false
        if data == nil {
            guard wanted.contains(t), let url = source.url(for: t) else { return }
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
        let result = await Task.detached(priority: .userInitiated) { Self.decode(bytes, t) }.value
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
        if wanted.contains(geometry.id) { loadedCount = wanted.filter { decoded[$0] != nil }.count }
        revision &+= 1
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

    private func insert(_ g: TileGeometry) {
        if let old = decoded[g.id] { decodedBytes -= old.byteCount }
        decoded[g.id] = g
        decodedBytes += g.byteCount
        touch(g.id)
        while decodedBytes > Self.maxDecodedBytes, let victim = lru.first(where: { !wanted.contains($0) }) ?? lru.first {
            lru.removeAll { $0 == victim }
            if let v = decoded.removeValue(forKey: victim) { decodedBytes -= v.byteCount }
            #if DEBUG
            if wanted.contains(victim) { statEvictWanted += 1 }
            #endif
            if victim == g.id { break }
        }
    }

    private func touch(_ t: TileID) {
        if let i = lru.firstIndex(of: t) { lru.remove(at: i) }
        lru.append(t)
    }
}
