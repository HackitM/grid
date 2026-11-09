import Foundation

/// Geofabrik `index-v1.json` (a GeoJSON FeatureCollection): regions with their polygons.
/// Feature geometry may be a Polygon or MultiPolygon in lon/lat. Features with bad geometry stay
/// in the list without a polygon.
public struct RegionCatalog: Sendable {
    public let regions: [RegionDescriptor]
    private let polygons: [String: GeoPolygon]

    static let maxFeatures = 20_000
    static let maxRingPoints = 2_000_000

    public static func parse(_ data: Data, maxBytes: Int = 16 << 20) throws -> RegionCatalog {
        guard data.count <= maxBytes else { throw ALPRParseError.tooLarge }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let features = root["features"] as? [Any] else { throw ALPRParseError.malformed("not a FeatureCollection") }
        guard features.count <= maxFeatures else { throw ALPRParseError.tooLarge }
        var regions: [RegionDescriptor] = []
        var polys: [String: GeoPolygon] = [:]
        var seen = Set<String>()
        for f in features {
            guard let feat = f as? [String: Any], let props = feat["properties"] as? [String: Any],
                  let id = props["id"] as? String, validID(id), !seen.contains(id) else { continue }
            seen.insert(id)
            let name = OSMSurveillance.cap(props["name"] as? String) ?? id
            let parent = (props["parent"] as? String).flatMap { validID($0) ? $0 : nil }
            regions.append(RegionDescriptor(id: id, name: name, parent: parent,
                                            iso3166_1: codes(props["iso3166-1:alpha2"]),
                                            iso3166_2: codes(props["iso3166-2"])))
            if let g = feat["geometry"] as? [String: Any], let poly = geometry(g) { polys[id] = poly }
        }
        return RegionCatalog(regions: regions, polygons: polys)
    }

    public func polygon(_ id: String) -> GeoPolygon? { polygons[id] }

    /// Direct children of a region, or the top-level entries (continents) for `nil`; sorted by name.
    public func children(of id: String?) -> [RegionDescriptor] {
        regions.filter { $0.parent == id }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Helpers

    private static func validID(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 100, !s.contains("..") else { return false }
        return s.unicodeScalars.allSatisfy {
            ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") || $0 == "/" || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    private static func codes(_ any: Any?) -> [String] {
        guard let a = any as? [Any] else { return [] }
        return a.prefix(16).compactMap { ($0 as? String).flatMap { $0.count <= 16 && !$0.isEmpty ? $0 : nil } }
    }

    private static func number(_ any: Any) -> Double? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// nil when any coordinate is malformed or out of range.
    private static func ring(_ any: Any, budget: inout Int) -> [LonLat]? {
        guard let arr = any as? [Any] else { return nil }
        budget -= arr.count
        guard budget >= 0 else { return nil }
        var out: [LonLat] = []
        out.reserveCapacity(arr.count)
        for p in arr {
            guard let c = p as? [Any], c.count >= 2, let lon = number(c[0]), let lat = number(c[1]) else { return nil }
            let ll = LonLat(lon: lon, lat: lat)
            guard ll.isValid else { return nil }
            out.append(ll)
        }
        if out.count > 1, out.first == out.last { out.removeLast() }
        return out.count >= 3 ? out : nil
    }

    private static func polygon(_ any: Any, budget: inout Int) -> [[LonLat]]? {
        guard let rings = any as? [Any], let first = rings.first, let ext = ring(first, budget: &budget) else { return nil }
        var out = [ext]
        for h in rings.dropFirst() { if let r = ring(h, budget: &budget) { out.append(r) } }
        return out
    }

    private static func geometry(_ g: [String: Any]) -> GeoPolygon? {
        var budget = maxRingPoints
        var polys: [[[LonLat]]] = []
        switch g["type"] as? String {
        case "Polygon":
            if let c = g["coordinates"], let p = polygon(c, budget: &budget) { polys.append(p) }
        case "MultiPolygon":
            if let list = g["coordinates"] as? [Any] {
                for item in list { if let p = polygon(item, budget: &budget) { polys.append(p) } }
            }
        default: break
        }
        return polys.isEmpty ? nil : GeoPolygon(polygons: polys)
    }
}

/// Chooses where a region's cameras come from.
public enum ALPRSourcePlanner {
    /// - Parameters:
    ///   - r: The catalogue region, or nil / a `rect-…` descriptor for a user-drawn rectangle.
    ///   - us, ca: The bounds of the DeFlock US and Canadian builds (nil when unknown).
    /// For catalogue regions the source follows the ISO code / id. A rectangle may return several
    /// sources: DeFlock for the parts over the US / Canada, Overpass when it reaches beyond both
    /// builds' bounds.
    public static func sources(for r: RegionDescriptor?, polygon: GeoPolygon, us: BBox?, ca: BBox?) -> [ALPRSource] {
        if let r, !r.id.hasPrefix("rect-") {
            if r.iso3166_2.contains(where: { $0.hasPrefix("US-") }) || r.id == "us" || r.id.hasPrefix("us/") { return [.deflockUS] }
            if r.iso3166_2.contains(where: { $0.hasPrefix("CA-") }) || r.id == "canada" || r.id.hasPrefix("canada/")
                || r.parent == "canada" { return [.deflockCA] }
            return [.overpass]
        }
        let box = polygon.bbox
        var out: [ALPRSource] = []
        let hitsUS = us.map { box.intersects($0) } ?? false
        let hitsCA = ca.map { box.intersects($0) } ?? false
        if hitsUS { out.append(.deflockUS) }
        if hitsCA { out.append(.deflockCA) }
        func within(_ outer: BBox?) -> Bool {
            guard let o = outer else { return false }
            return box.west >= o.west && box.east <= o.east && box.south >= o.south && box.north <= o.north
        }
        if !(within(us) || within(ca)) { out.append(.overpass) }
        return out
    }
}
