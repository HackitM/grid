import Foundation

// DeFlock / FlockHopper hourly camera data: the TileJSON ("build"), the national index (FHIX) and
// the z11 camera tiles. Everything here is parsed from untrusted remote input.

// MARK: - Build (TileJSON)

public struct DeFlockBuild: Sendable, Equatable {
    public let build: String
    public let tileTemplate: String
    public let indexURL: URL
    public let bounds: BBox
    public let maxZoom: Int

    static func allowedHost(_ h: String?) -> Bool {
        // Exactly the two published hosts (a wildcard would also admit placeholder or attacker
        // subdomains of the zone).
        guard let h = h?.lowercased() else { return false }
        return h == "deflock.dontgetflocked.com" || h == "tiles.dontgetflocked.com"
    }

    private static func safeHTTPS(_ c: URLComponents) -> Bool {
        c.scheme?.lowercased() == "https" && c.user == nil && c.password == nil && c.port == nil && allowedHost(c.host)
    }

    /// Parses the build's TileJSON. Hosts must be `*.dontgetflocked.com` over https with no
    /// userinfo or port; the tile template and index must share one host.
    public static func parse(_ data: Data, from url: URL, maxBytes: Int = 1 << 20) throws -> DeFlockBuild {
        guard data.count <= maxBytes else { throw ALPRParseError.tooLarge }
        guard let fromC = URLComponents(url: url, resolvingAgainstBaseURL: false), safeHTTPS(fromC) else {
            throw ALPRParseError.malformed("source URL")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ALPRParseError.malformed("not JSON")
        }
        guard let build = root["build"] as? String, validBuild(build) else { throw ALPRParseError.malformed("build id") }
        guard let tiles = root["tiles"] as? [Any], let template = tiles.first as? String,
              template.utf8.count <= 512, let tc = URLComponents(string: template), safeHTTPS(tc) else {
            throw ALPRParseError.malformed("tile template")
        }
        guard template.contains("{z}/{x}/{y}"),
              !template.replacingOccurrences(of: "{z}", with: "").replacingOccurrences(of: "{x}", with: "")
                .replacingOccurrences(of: "{y}", with: "").contains(where: { $0 == "{" || $0 == "}" }) else {
            throw ALPRParseError.malformed("template placeholders")
        }
        guard let idx = root["index_bin"] as? String, idx.utf8.count <= 512, let ic = URLComponents(string: idx),
              safeHTTPS(ic), ic.host?.lowercased() == tc.host?.lowercased(), let indexURL = ic.url else {
            throw ALPRParseError.malformed("index URL")
        }
        guard let b = root["bounds"] as? [Any], b.count == 4 else { throw ALPRParseError.malformed("bounds") }
        let nums = b.compactMap { ($0 as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue } }
        guard nums.count == 4 else { throw ALPRParseError.malformed("bounds") }
        let box = BBox(west: nums[0], south: nums[1], east: nums[2], north: nums[3])
        guard box.isValid else { throw ALPRParseError.malformed("bounds") }
        var maxZoom = 14
        if let mz = root["maxzoom"] { guard let n = mz as? NSNumber, n.doubleValue.isFinite else { throw ALPRParseError.malformed("maxzoom") }; maxZoom = Int(max(0, min(22, n.doubleValue))) }
        return DeFlockBuild(build: build, tileTemplate: template, indexURL: indexURL, bounds: box, maxZoom: maxZoom)
    }

    private static func validBuild(_ s: String) -> Bool {
        s.utf8.count >= 6 && s.utf8.count <= 40 && s.unicodeScalars.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }
    }

    /// The tile's URL, from the validated template only (integer substitution).
    public func tileURL(_ t: TileID) -> URL? {
        guard t.isValid, Int(t.z) <= maxZoom else { return nil }
        let s = tileTemplate.replacingOccurrences(of: "{z}", with: String(t.z))
            .replacingOccurrences(of: "{x}", with: String(t.x))
            .replacingOccurrences(of: "{y}", with: String(t.y))
        guard let c = URLComponents(string: s), Self.safeHTTPS(c) else { return nil }
        return c.url
    }
}

// MARK: - National index (FHIX)

/// `"FHIX"`, u32 LE version = 1, u32 LE count, u32 reserved (0), then lat int32 ×1e-6 (count),
/// lon int32 ×1e-6 (count), brandId u8 (count). Total length is exactly 16 + 9·count (the live
/// files, checked 2026-11-09); a 12-byte header without the reserved field is also accepted.
public struct DeFlockIndex: Sendable {
    private let lat: [Int32]
    private let lon: [Int32]
    private let brand: [UInt8]

    public var count: Int { lat.count }

    public init(_ data: Data) throws {
        guard data.count >= 12 else { throw ALPRParseError.truncated }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x46, bytes[1] == 0x48, bytes[2] == 0x49, bytes[3] == 0x58 else { throw ALPRParseError.malformed("magic") }
        func u32(_ o: Int) -> UInt32 { UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24 }
        guard u32(4) == 1 else { throw ALPRParseError.malformed("version") }
        let n = Int(u32(8))
        // n < 2^32, so 16 + 9n cannot overflow Int (64-bit).
        let header: Int
        if bytes.count == 16 + 9 * n { header = 16 } else if bytes.count == 12 + 9 * n { header = 12 } else {
            throw ALPRParseError.malformed("length")
        }
        var lat = [Int32](repeating: 0, count: n), lon = lat
        var brand = [UInt8](repeating: 0, count: n)
        let latBase = header, lonBase = header + 4 * n, brandBase = header + 8 * n
        for i in 0..<n {
            let a = Int32(bitPattern: u32(latBase + 4 * i)), o = Int32(bitPattern: u32(lonBase + 4 * i))
            guard abs(Int(a)) <= 90_000_000, abs(Int(o)) <= 180_000_000 else { throw ALPRParseError.malformed("coordinate") }
            lat[i] = a; lon[i] = o; brand[i] = bytes[brandBase + i]
        }
        self.lat = lat; self.lon = lon; self.brand = brand
    }

    /// Cameras inside the polygon (exact containment, not just the bbox).
    public func count(in p: GeoPolygon) -> Int {
        var n = 0
        forEachInside(p) { _ in n += 1 }
        return n
    }

    /// Non-empty tiles at zoom `z` (0…22): tiles holding at least one camera inside the polygon.
    /// Sorted row-major.
    public func nonEmptyTiles(z: Int, in p: GeoPolygon) -> [TileID] {
        guard z >= 0, z <= 22 else { return [] }
        var set = Set<UInt64>()
        forEachInside(p) { i in
            let t = TileMath.tile(containing: TileMath.project(LonLat(lon: Double(lon[i]) * 1e-6, lat: Double(lat[i]) * 1e-6)), z: z)
            set.insert(UInt64(t.y) << 32 | UInt64(t.x))
        }
        return set.sorted().map { TileID(z: z, x: Int($0 & 0xFFFF_FFFF), y: Int($0 >> 32)) }
    }

    private func forEachInside(_ p: GeoPolygon, _ body: (Int) -> Void) {
        let prep = PreparedGeoPolygon(p)
        guard !prep.polys.isEmpty else { return }
        let b = prep.bbox
        let minLat = Int32(clamping: Int((b.south * 1e6).rounded(.down))), maxLat = Int32(clamping: Int((b.north * 1e6).rounded(.up)))
        let minLon = Int32(clamping: Int((b.west * 1e6).rounded(.down))), maxLon = Int32(clamping: Int((b.east * 1e6).rounded(.up)))
        for i in 0..<lat.count {
            let la = lat[i], lo = lon[i]
            guard la >= minLat, la <= maxLat, lo >= minLon, lo <= maxLon else { continue }
            if prep.contains(lon: Double(lo) * 1e-6, lat: Double(la) * 1e-6) { body(i) }
        }
    }
}

// MARK: - Camera tiles

public enum DeFlockTile {
    /// Cameras from the decoded tile's `cameras` layer (point features). Coordinates are converted
    /// from layer integer space (y down) through the tile's Mercator bounds.
    public static func cameras(_ tile: MVTTile, id: TileID) -> [ALPRCamera] {
        guard id.isValid, let layer = tile.layer("cameras"), layer.extent > 0 else { return [] }
        let (nw, se) = TileMath.bounds(id)
        let extent = Double(layer.extent)
        var out: [ALPRCamera] = []
        for f in layer.features {
            guard case .points(let pts) = f.geometry, let osm = osmID(f.tags) else { continue }
            for p in pts {
                let m = Mercator(x: nw.x + Double(p.x) / extent * (se.x - nw.x), y: nw.y + Double(p.y) / extent * (se.y - nw.y))
                let ll = TileMath.unproject(m)
                guard ll.isValid else { continue }
                out.append(ALPRCamera(id: osm, coordinate: ll, directions: directions(f.tags),
                                      vendor: OSMSurveillance.vendor(brand: f.tags["brand"]?.string),
                                      operatorName: OSMSurveillance.cap(f.tags["operator"]?.string),
                                      mount: OSMSurveillance.cap(f.tags["mountType"]?.string),
                                      zone: OSMSurveillance.cap(f.tags["surveillanceZone"]?.string),
                                      lastEdited: f.tags["osmTimestamp"]?.string.flatMap(OSMSurveillance.parseISO8601)))
            }
        }
        return out
    }

    private static func osmID(_ tags: [String: MVTValue]) -> OSMElementID? {
        guard let d = tags["osmId"]?.number, d.isFinite, d == d.rounded(), d >= 1, d < 9e15 else { return nil }
        return tags["osmType"]?.string?.lowercased() == "way" ? .way(Int64(d)) : .node(Int64(d))
    }

    /// `directions` (string) wins over numeric `direction`; `directionCardinal` is the last resort.
    private static func directions(_ tags: [String: MVTValue]) -> [UInt16] {
        if let s = tags["directions"]?.string {
            let d = OSMSurveillance.directions(s)
            if !d.isEmpty { return d }
        }
        if let n = tags["direction"]?.number, let d = OSMSurveillance.normalizeDegrees(n) { return [d] }
        if let s = tags["directionCardinal"]?.string { return OSMSurveillance.directions(s) }
        return []
    }
}
