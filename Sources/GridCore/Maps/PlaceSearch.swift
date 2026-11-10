import Foundation

/// A search result or a picked place, from the loaded map tiles or from online search. Both look
/// the same in GRID.
public struct PlaceResult: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable { case place, road, water, poi, address }
    public enum Source: String, Sendable, Equatable { case local, online }

    public var id: String
    public var name: String
    public var kind: Kind
    public var category: POICategory?
    /// What it is, in words ("city", "street", "cafe").
    public var detail: String
    /// The full address line (online results).
    public var address: String?
    public var coordinate: LonLat
    /// Its extent (online results), for framing the map.
    public var bbox: BBox?
    /// "node/123", "way/45", "relation/6" (online results).
    public var osmRef: String?
    public var source: Source
    /// Distance from where the search was made, in metres (nil when unknown).
    public var distance: Double?

    public init(id: String, name: String, kind: Kind, category: POICategory?, detail: String, address: String? = nil,
                coordinate: LonLat, bbox: BBox? = nil, osmRef: String? = nil, source: Source, distance: Double? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.category = category; self.detail = detail; self.address = address
        self.coordinate = coordinate; self.bbox = bbox; self.osmRef = osmRef; self.source = source; self.distance = distance
    }

    /// The element's page on openstreetmap.org (built from the type and numeric id only).
    public var osmURL: URL? {
        guard let r = osmRef else { return nil }
        let parts = r.split(separator: "/")
        guard parts.count == 2, ["node", "way", "relation"].contains(parts[0]), Int64(parts[1]) != nil else { return nil }
        return URL(string: "https://www.openstreetmap.org/\(parts[0])/\(parts[1])")
    }

    /// A zoom that frames it: its box when known, else by kind.
    public var suggestedZoom: Double {
        if let b = bbox, b.isValid {
            let span = max(b.east - b.west, (b.north - b.south) * 1.4)
            if span > 0 { return min(17, max(3, log2(360 / span) + 0.3)) }
        }
        switch kind {
        case .place:
            switch detail {
            case "country": return 5
            case "state", "province", "region": return 6.5
            case "city": return 11
            case "town": return 12.5
            case "village", "suburb": return 14
            default: return 15
            }
        case .water: return 12
        case .road: return 16
        case .poi, .address: return 17
        }
    }
}

/// One name in the loaded map, ready to search.
public struct SearchEntry: Sendable {
    public var name: String
    /// `LocalSearch.fold(name)`, computed once.
    public var folded: String
    public var kind: PlaceResult.Kind
    public var category: POICategory?
    public var detail: String
    public var world: Mercator
    /// 0 (most important) … 100.
    public var importance: Int
    public init(name: String, kind: PlaceResult.Kind, category: POICategory? = nil, detail: String, world: Mercator, importance: Int) {
        self.name = name; self.folded = LocalSearch.fold(name); self.kind = kind; self.category = category
        self.detail = detail; self.world = world; self.importance = max(0, min(100, importance))
    }
}

/// Name search over what the map has loaded. Nothing leaves the Mac.
public enum LocalSearch {
    /// Lowercased, accents removed, whitespace collapsed ("Zürich  HB" → "zurich hb").
    public static func fold(_ s: String) -> String {
        let f = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return f.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Search text as sent anywhere: trimmed, control characters removed, at most 200 characters.
    public static func clean(_ q: String) -> String {
        let s = String(String.UnicodeScalarView(q.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        return String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }

    /// Ground distance in metres between two world positions.
    public static func meters(_ a: Mercator, _ b: Mercator) -> Double {
        let p = TileMath.unproject(a), q = TileMath.unproject(b)
        let r = 6_371_000.0, p1 = p.lat * .pi / 180, p2 = q.lat * .pi / 180
        let dp = (q.lat - p.lat) * .pi / 180, dl = (q.lon - p.lon) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// Two hits with the same name and kind closer than this are the same thing (a road cut
    /// across tiles, a town in tiles of several zoom levels).
    static func sameThingRadius(_ k: PlaceResult.Kind) -> Double {
        switch k {
        case .place: 25_000
        case .water: 10_000
        case .road: 3_000
        case .poi, .address: 300
        }
    }

    /// Ranked matches for `query` near `near`: whole-name and prefix matches first, then words
    /// and substrings; more important places and nearer ones rank higher. Duplicates collapse to
    /// the best one.
    public static func search(_ query: String, in entries: [SearchEntry], near: Mercator, limit: Int = 20) -> [PlaceResult] {
        let q = fold(clean(query))
        guard !q.isEmpty else { return [] }
        var hits: [(score: Double, entry: Int, dist: Double)] = []
        for (i, e) in entries.enumerated() {
            guard let s = FuzzyMatch.score(q, in: e.folded) else { continue }
            // Only real substring or initials matches: a scattered subsequence is noise in a map.
            guard s >= 500 || (s == 600 && q.count >= 2) else { continue }
            let d = meters(e.world, near)
            var score = Double(s)
            switch e.kind {
            case .place: score += Double(300 - 3 * e.importance)
            case .water: score += 40
            // A street outranks the bus stops and shops named after it.
            case .road: score += 35
            case .poi, .address: score += Double(20 - e.importance / 4)
            }
            // Nearer is better, gently (a city across the world still beats a café with that word in it).
            score -= min(260, 36 * log2(1 + d / 1000))
            hits.append((score, i, d))
        }
        hits.sort { $0.score > $1.score || ($0.score == $1.score && $0.dist < $1.dist) }
        var out: [PlaceResult] = []
        var taken: [(String, PlaceResult.Kind, Mercator)] = []
        for h in hits {
            let e = entries[h.entry]
            if taken.contains(where: { $0.0 == e.folded && $0.1 == e.kind && meters($0.2, e.world) < sameThingRadius(e.kind) }) { continue }
            taken.append((e.folded, e.kind, e.world))
            let ll = TileMath.unproject(e.world)
            out.append(PlaceResult(id: String(format: "local:%@:%.5f,%.5f", e.kind.rawValue, ll.lat, ll.lon) + ":" + e.folded,
                                   name: e.name, kind: e.kind, category: e.category, detail: e.detail,
                                   coordinate: ll, source: .local, distance: h.dist))
            if out.count >= limit { break }
        }
        return out
    }

    /// Search entries for one decoded tile: its place, water and road names and its POIs.
    public static func entries(for g: TileGeometry) -> [SearchEntry] {
        let (nw, se) = TileMath.bounds(g.id)
        let w = se.x - nw.x, h = se.y - nw.y
        func world(_ p: SIMD2<Float>) -> Mercator { Mercator(x: nw.x + Double(p.x) * w, y: nw.y + Double(p.y) * h) }
        var out: [SearchEntry] = []
        out.reserveCapacity(g.labels.count + g.pois.count)
        for a in g.labels {
            switch a.kind {
            case .place:
                let cls = OpenMapTilesSchema.placeClass(priority: a.priority)
                out.append(SearchEntry(name: a.text, kind: .place, detail: cls, world: world(a.pos), importance: min(100, a.priority / 7)))
            case .water:
                out.append(SearchEntry(name: a.text, kind: .water, detail: "water", world: world(a.pos), importance: 50))
            case .road:
                // Contour heights are road-kind labels without a road priority; skip them.
                guard a.priority >= 900, a.priority < 1000 else { continue }
                out.append(SearchEntry(name: a.text, kind: .road, detail: "street", world: world(a.pos), importance: 60))
            }
        }
        for p in g.pois {
            out.append(SearchEntry(name: p.name, kind: .poi, category: p.category, detail: p.detail, world: world(p.pos), importance: min(100, p.rank)))
        }
        return out
    }
}
