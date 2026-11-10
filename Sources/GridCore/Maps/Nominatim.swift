import Foundation

/// Online place search on a Nominatim server (OpenStreetMap's geocoder). Only the request URL and
/// the parsing live here; GRID sends a search only when asked (⏎ or the "Search online" row), at
/// most once a second, and caches answers in memory for 24 hours, as the public server's usage
/// policy requires.
public enum Nominatim {
    public static let defaultEndpoint = "https://nominatim.openstreetmap.org"
    public static let maxResponseBytes = 512 << 10
    public static let maxResults = 10

    /// A usable endpoint from user input: https, a host, no user name, port, query or fragment.
    /// Trailing slashes and a trailing "/search" are dropped (the search path is added later).
    public static func endpoint(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.lowercased().hasSuffix("/search") { s.removeLast(7) }
        guard let u = URL(string: s), u.scheme == "https", let h = u.host, !h.isEmpty,
              u.user == nil, u.password == nil, u.port == nil, u.query == nil, u.fragment == nil else { return nil }
        return u
    }

    /// The search request: `q`, JSON v2, a bias toward the visible area (not a limit), and the
    /// reader's language. nil when the query is empty after cleaning.
    public static func searchURL(endpoint: URL, query: String, viewbox: BBox?, language: String?, limit: Int = maxResults) -> URL? {
        let q = LocalSearch.clean(query)
        guard !q.isEmpty, var c = URLComponents(url: endpoint.appendingPathComponent("search"), resolvingAgainstBaseURL: false) else { return nil }
        var items = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "format", value: "jsonv2"),
                     URLQueryItem(name: "limit", value: "\(max(1, min(maxResults, limit)))")]
        if let b = viewbox, b.isValid, b.east - b.west > 1e-4, b.north - b.south > 1e-4 {
            items.append(URLQueryItem(name: "viewbox", value: String(format: "%.4f,%.4f,%.4f,%.4f", b.west, b.north, b.east, b.south)))
        }
        if let lang = language?.filter({ $0.isLetter || $0 == "-" }).prefix(12), !lang.isEmpty {
            items.append(URLQueryItem(name: "accept-language", value: String(lang)))
        }
        c.queryItems = items
        return c.url
    }

    public enum ParseError: Error, Equatable { case tooLarge, notJSON }

    /// Results from a JSON v2 answer. Untrusted: size-capped, at most `maxResults`, coordinates
    /// range-checked, strings cleaned and capped; anything malformed is skipped.
    public static func parse(_ data: Data, near: Mercator? = nil) throws -> [PlaceResult] {
        guard data.count <= maxResponseBytes else { throw ParseError.tooLarge }
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { throw ParseError.notJSON }
        var out: [PlaceResult] = []
        for case let o as [String: Any] in arr.prefix(50) {
            guard let lat = number(o["lat"]), let lon = number(o["lon"]) else { continue }
            let ll = LonLat(lon: lon, lat: lat)
            guard ll.isValid else { continue }
            let display = text(o["display_name"], max: 300)
            let key = text(o["category"] ?? o["class"], max: 40) ?? ""
            let value = text(o["type"], max: 40) ?? ""
            let name = text(o["name"], max: 120).flatMap { $0.isEmpty ? nil : $0 }
                ?? display.map { String($0.split(separator: ",").first ?? Substring($0)).trimmingCharacters(in: .whitespaces) }
            guard let name, !name.isEmpty else { continue }
            var osmRef: String?
            if let t = text(o["osm_type"], max: 10)?.lowercased(), ["node", "way", "relation"].contains(t),
               let id = number(o["osm_id"]), id >= 0, id < 1e15, id == id.rounded() {
                osmRef = "\(t)/\(Int64(id))"
            }
            var bbox: BBox?
            if let b = o["boundingbox"] as? [Any], b.count == 4,
               let s = number(b[0]), let n = number(b[1]), let w = number(b[2]), let e = number(b[3]) {
                let box = BBox(west: w, south: s, east: e, north: n)
                if box.isValid { bbox = box }
            }
            let category = POICatalog.category(osmKey: key, value: value)
            let kind: PlaceResult.Kind
            switch key {
            case "place", "boundary": kind = .place
            case "highway": kind = .road
            case "natural" where ["water", "bay", "strait"].contains(value), "waterway", "water": kind = .water
            default: kind = category != nil ? .poi : (key == "building" ? .address : .place)
            }
            // Boundaries say "administrative"; `addresstype` says what the place is ("town").
            let addressType = text(o["addresstype"], max: 40) ?? ""
            let raw = kind == .place && !addressType.isEmpty ? addressType : (value.isEmpty || value == "yes" ? key : value)
            let detail = POICatalog.describe(raw)
            let dist = near.map { LocalSearch.meters($0, TileMath.project(ll)) }
            out.append(PlaceResult(id: "online:" + (osmRef ?? String(format: "%.6f,%.6f", lat, lon)), name: String(name.prefix(120)), kind: kind,
                                   category: category, detail: detail.isEmpty ? "place" : detail, address: display,
                                   coordinate: ll, bbox: bbox, osmRef: osmRef, source: .online, distance: dist))
            if out.count >= maxResults { break }
        }
        return out
    }

    private static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d.isFinite ? d : nil }
        if let n = v as? NSNumber { let d = n.doubleValue; return d.isFinite ? d : nil }
        if let s = v as? String, s.count <= 32, let d = Double(s) { return d.isFinite ? d : nil }
        return nil
    }

    private static func text(_ v: Any?, max: Int) -> String? {
        guard let s = v as? String else { return nil }
        let cleaned = DisplayText.stripped(s.unicodeScalars.prefix(max * 2))
        return String(cleaned.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
    }
}

/// Keeps requests at least `interval` apart (Nominatim: one a second).
public struct RequestSpacer: Sendable {
    public let interval: TimeInterval
    private var last: Date?
    public init(interval: TimeInterval) { self.interval = interval }
    /// Seconds to wait before a request made at `now`, and books that slot.
    public mutating func reserve(now: Date) -> TimeInterval {
        let start = max(now, last.map { $0.addingTimeInterval(interval) } ?? now)
        last = start
        return start.timeIntervalSince(now)
    }
}

/// A small in-memory cache whose entries expire (search answers: 24 h, at most `capacity`).
public struct ExpiringCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    public let ttl: TimeInterval
    public let capacity: Int
    private var entries: [Key: (Date, Value)] = [:]
    public init(ttl: TimeInterval, capacity: Int) { self.ttl = ttl; self.capacity = max(1, capacity) }
    public func value(_ k: Key, now: Date) -> Value? {
        guard let (t, v) = entries[k], now.timeIntervalSince(t) < ttl else { return nil }
        return v
    }
    public mutating func set(_ k: Key, _ v: Value, now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.0) < ttl }
        if entries.count >= capacity, let oldest = entries.min(by: { $0.value.0 < $1.value.0 })?.key { entries[oldest] = nil }
        entries[k] = (now, v)
    }
    public mutating func removeAll() { entries = [:] }
    public var count: Int { entries.count }
}
