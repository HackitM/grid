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
        String(DisplayText.stripped(q, keepingBidi: true).trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
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
        let matcher = NameMatcher(q)
        var hits: [(score: Double, entry: Int, dist: Double)] = []
        for (i, e) in entries.enumerated() {
            // Only whole-name, prefix, whole-word and initials matches (and long near-matches):
            // a scattered subsequence is noise in a map.
            guard let s = matcher.score(e.folded), s >= 500 else { continue }
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

    /// Scores folded names against one query exactly as `FuzzyMatch.score` does, but without its
    /// per-name work (two `lowercased()` copies and several Foundation searches for every one of
    /// 100 000 names on every keystroke). Names and queries that are plain ASCII (nearly all,
    /// once folded) are compared as bytes; anything else goes to `FuzzyMatch`.
    struct NameMatcher {
        private let query: String
        /// The query lowercased, when it is ASCII (nil: every name takes the slow path).
        private let ascii: [UInt8]?

        init(_ foldedQuery: String) {
            query = foldedQuery
            var bytes: [UInt8] = []
            for b in foldedQuery.trimmingCharacters(in: .whitespaces).utf8 {
                guard Self.isPlain(b) else { ascii = nil; return }
                bytes.append(Self.lower(b))
            }
            ascii = bytes.isEmpty ? nil : bytes
        }

        /// Printable ASCII or a space: one byte is one character, and lowercasing is a bit flip.
        @inline(__always) private static func isPlain(_ b: UInt8) -> Bool { b >= 0x20 && b < 0x7F }
        @inline(__always) private static func lower(_ b: UInt8) -> UInt8 { b >= 0x41 && b <= 0x5A ? b | 0x20 : b }
        /// The characters `FuzzyMatch` treats as starting a new word.
        @inline(__always) private static func isBoundary(_ b: UInt8) -> Bool {
            b == 0x20 || b == 0x2D || b == 0x5F || b == 0x2E || b == 0x2F || b == 0x28      // space - _ . / (
        }

        func score(_ folded: String) -> Int? {
            if let ascii, let s = folded.utf8.withContiguousStorageIfAvailable({ Self.score(ascii, in: $0) }), let s { return s.value }
            return FuzzyMatch.score(query, in: folded)
        }

        /// A score (or "no match"); nil from `score(_:in:)` itself means "not ASCII, ask FuzzyMatch".
        private struct Outcome { var value: Int? }

        private static func score(_ q: [UInt8], in name: UnsafeBufferPointer<UInt8>) -> Outcome? {
            for b in name where !isPlain(b) { return nil }
            let n = name.count, m = q.count
            @inline(__always) func c(_ i: Int) -> UInt8 { lower(name[i]) }
            func matches(at i: Int) -> Bool {
                for k in 0..<m where c(i + k) != q[k] { return false }
                return true
            }
            // Whole name, then prefix.
            if n >= m, matches(at: 0) { return Outcome(value: n == m ? 1000 : 900 - min(n - m, 100)) }
            // The first occurrence that starts a word, else the first occurrence anywhere.
            var first = -1
            if n > m {
                for i in 1...(n - m) where c(i) == q[0] && matches(at: i) {
                    if isBoundary(c(i - 1)) { return Outcome(value: 700 - min(i, 100)) }
                    if first < 0 { first = i }
                }
            }
            if first >= 0 { return Outcome(value: 500 - min(first, 100)) }
            // The words' initials ("mlk" for "martin luther king").
            var initial = 0, previous: UInt8 = 0x20
            var isInitials = true
            for i in 0..<n {
                let ch = c(i)
                if isBoundary(previous) && !isBoundary(ch) {
                    if initial < m && ch != q[initial] { isInitials = false; break }
                    initial += 1
                    if initial >= m { break }
                }
                previous = ch
            }
            if isInitials && initial >= m { return Outcome(value: 600) }
            // The letters in order, scattered.
            var matched = 0, score = 100, run = 0
            for i in 0..<n {
                guard matched < m else { break }
                if c(i) == q[matched] { run += 1; score += run * 2; matched += 1 } else { run = 0; score -= 1 }
            }
            return Outcome(value: matched == m ? max(score, 1) : nil)
        }
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
