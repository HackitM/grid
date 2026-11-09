import Foundation

public enum OverpassQuery {
    /// Overpass QL for ALPR nodes and ways inside `box` (south, west, north, east order in QL).
    public static func alpr(_ box: BBox, timeout: Int = 90) -> String {
        func f(_ v: Double, _ lo: Double, _ hi: Double) -> String {
            String(format: "%.6f", v.isFinite ? max(lo, min(hi, v)) : 0)
        }
        let s = f(box.south, -90, 90), w = f(box.west, -180, 180), n = f(box.north, -90, 90), e = f(box.east, -180, 180)
        let t = max(1, min(300, timeout))
        let filter = "[\"man_made\"=\"surveillance\"][\"surveillance:type\"~\"alpr\",i]"
        return "[out:json][timeout:\(t)];(node\(filter)(\(s),\(w),\(n),\(e));way\(filter)(\(s),\(w),\(n),\(e)););out meta center qt;"
    }

    /// Boxes (one per z-tile that intersects the polygon, clipped to the polygon's bbox) to query
    /// one at a time. At most `limit`; `count == limit` may mean the region needs more.
    public static func chunks(_ p: GeoPolygon, z: Int = 7, limit: Int = 60) -> [BBox] {
        let bounds = p.bbox
        return p.tileCover(z: z, limit: limit).compactMap { t in
            let g = TileMath.geoBounds(t)
            let b = BBox(west: max(g.west, bounds.west), south: max(g.south, bounds.south),
                         east: min(g.east, bounds.east), north: min(g.north, bounds.north))
            return b.west <= b.east && b.south <= b.north ? b : nil
        }
    }

    /// Parses an Overpass JSON response. Throws on a `runtime error` remark; other remarks are
    /// returned. Elements without coordinates or that aren't ALPR cameras are skipped.
    public static func parse(_ data: Data, maxElements: Int = 200_000) throws -> (cameras: [ALPRCamera], osmBase: Date?, remark: String?) {
        guard data.count <= 256 << 20 else { throw ALPRParseError.tooLarge }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ALPRParseError.malformed("not JSON")
        }
        let remark = (root["remark"] as? String).map { String($0.prefix(300)) }
        if let r = remark, r.lowercased().contains("runtime error") { throw ALPRParseError.serverRemark(r) }
        guard let elements = root["elements"] as? [Any] else { throw ALPRParseError.malformed("no elements") }
        guard elements.count <= maxElements else { throw ALPRParseError.tooLarge }
        let base = ((root["osm3s"] as? [String: Any])?["timestamp_osm_base"] as? String).flatMap(OSMSurveillance.parseISO8601)
        var cams: [ALPRCamera] = []
        for e in elements {
            guard let el = e as? [String: Any], let type = el["type"] as? String,
                  let idNum = el["id"] as? NSNumber, let tagsAny = el["tags"] as? [String: Any] else { continue }
            let idD = idNum.doubleValue
            guard idD.isFinite, idD == idD.rounded(), abs(idD) < 9e15 else { continue }
            let id: OSMElementID
            switch type {
            case "node": id = .node(Int64(idD))
            case "way": id = .way(Int64(idD))
            default: continue
            }
            var tags: [String: String] = [:]
            for (k, v) in tagsAny { if let s = v as? String, k.utf8.count <= 128 { tags[k] = String(s.prefix(1024)) } }
            guard OSMSurveillance.isALPR(tags) else { continue }
            let src: [String: Any]? = type == "node" ? el : el["center"] as? [String: Any]
            guard let s = src, let la = (s["lat"] as? NSNumber)?.doubleValue, let lo = (s["lon"] as? NSNumber)?.doubleValue else { continue }
            let ll = LonLat(lon: lo, lat: la)
            guard ll.isValid else { continue }
            let edited = (el["timestamp"] as? String).flatMap(OSMSurveillance.parseISO8601)
            if let c = OSMSurveillance.camera(id: id, at: ll, tags: tags, edited: edited) { cams.append(c) }
        }
        return (cams, base, remark)
    }
}
