import Foundation

/// Errors shared by the ALPR data parsers (DeFlock build/index, Geofabrik catalogue, Overpass,
/// region packages). All remote input is untrusted: parsers throw these and never trap.
public enum ALPRParseError: Error, Equatable {
    case tooLarge
    case truncated
    case malformed(String)
    /// The server reported a runtime problem (Overpass `remark`).
    case serverRemark(String)
}

/// OSM tag interpretation for ALPR (automatic licence plate reader) cameras.
public enum OSMSurveillance {
    static let maxDirections = 8
    static let maxFieldLength = 120
    static let maxVendorLength = 60

    // MARK: Matching

    /// `man_made=surveillance` and `surveillance:type` contains `alpr` as a `;`-separated token.
    public static func isALPR(_ tags: [String: String]) -> Bool {
        guard tags["man_made"]?.trimmingCharacters(in: .whitespaces).lowercased() == "surveillance",
              let type = tags["surveillance:type"] else { return false }
        for tok in type.prefix(512).split(separator: ";", omittingEmptySubsequences: true) {
            if tok.trimmingCharacters(in: .whitespaces).lowercased() == "alpr" { return true }
        }
        return false
    }

    // MARK: Directions

    private static let compassAbbreviations = ["n", "nne", "ne", "ene", "e", "ese", "se", "sse",
                                               "s", "ssw", "sw", "wsw", "w", "wnw", "nw", "nnw"]
    private static let compassWords = ["north", "northnortheast", "northeast", "eastnortheast", "east",
                                       "eastsoutheast", "southeast", "southsoutheast", "south",
                                       "southsouthwest", "southwest", "westsouthwest", "west",
                                       "westnorthwest", "northwest", "northnorthwest"]
    private static let compass: [String: Double] = {
        var d: [String: Double] = [:]
        for i in 0..<16 {
            d[compassAbbreviations[i]] = Double(i) * 22.5
            d[compassWords[i]] = Double(i) * 22.5
        }
        return d
    }()

    /// Whole degrees 0…359 for a raw angle; nil for non-finite or absurd values.
    static func normalizeDegrees(_ v: Double) -> UInt16? {
        guard v.isFinite, abs(v) <= 1e9 else { return nil }
        let r = Int64(v.rounded(.toNearestOrAwayFromZero))
        return UInt16(((r % 360) + 360) % 360)
    }

    private static func parseNumber(_ s: String) -> Double? {
        guard let f = s.unicodeScalars.first, (f >= "0" && f <= "9") || f == "-" || f == "+" || f == "." else { return nil }
        guard let d = Double(s), d.isFinite else { return nil }
        return d
    }

    private static func wrap360(_ v: Double) -> Double {
        let m = v.truncatingRemainder(dividingBy: 360)
        return m < 0 ? m + 360 : m
    }

    private static func degrees(token raw: Substring) -> UInt16? {
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty, t.count <= 40 else { return nil }
        if let d = parseNumber(t) { return normalizeDegrees(d) }
        // Compass words and abbreviations ("NE", "north", "north-northeast").
        let squeezed = t.filter { $0 != "-" && $0 != " " && $0 != "_" }
        if !squeezed.isEmpty, let c = compass[squeezed] { return normalizeDegrees(c) }
        // Range "a-b" (the first '-' after the first character separates the parts): midpoint.
        if let dash = t.dropFirst().firstIndex(of: "-") {
            let l = String(t[t.startIndex..<dash]), r = String(t[t.index(after: dash)...])
            if let a = parseNumber(l), let b = parseNumber(r), abs(a) <= 1e9, abs(b) <= 1e9 {
                let na = wrap360(a)
                var nb = wrap360(b)
                if nb < na { nb += 360 }
                return normalizeDegrees((na + nb) / 2)
            }
        }
        return nil
    }

    /// Parses an OSM `direction` value: numbers, 16-point compass words, ranges, `;` lists.
    /// Whole degrees 0…359, deduplicated, at most 8, garbage dropped.
    public static func directions(_ raw: String) -> [UInt16] {
        var out: [UInt16] = []
        for tok in raw.prefix(1024).split(separator: ";", maxSplits: 63, omittingEmptySubsequences: true) {
            guard let d = degrees(token: tok) else { continue }
            if !out.contains(d) { out.append(d) }
            if out.count >= maxDirections { break }
        }
        return out
    }

    // MARK: Vendor

    private static let wikidata: [String: ALPRVendor] = [
        "Q108485435": .flock, "Q634815": .motorola, "Q30295174": .genetec,
        "Q910379": .leonardo, "Q2347731": .axis,
    ]

    public static func vendor(brand: String?) -> ALPRVendor {
        guard let brand else { return .unknown }
        let trimmed = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }
        let lower = trimmed.lowercased()
        if lower.contains("flock") { return .flock }
        let tokens = lower.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        func has(_ w: String) -> Bool { tokens.contains(w) }
        if has("motorola") { return .motorola }
        if has("genetec") { return .genetec }
        if has("leonardo") { return .leonardo }
        if has("axis") { return .axis }
        if has("rekor") { return .rekor }
        if has("axon") { return .axon }
        if has("neology") { return .neology }
        return .other(String(trimmed.prefix(maxVendorLength)))
    }

    public static func vendor(_ tags: [String: String]) -> ALPRVendor {
        for key in ["manufacturer:wikidata", "brand:wikidata"] {
            if let q = tags[key]?.trimmingCharacters(in: .whitespaces).uppercased(), let v = wikidata[q] { return v }
        }
        var firstOther: ALPRVendor?
        for key in ["manufacturer", "brand"] {
            let v = vendor(brand: tags[key])
            switch v {
            case .unknown: continue
            case .other: if firstOther == nil { firstOther = v }
            default: return v
            }
        }
        return firstOther ?? .unknown
    }

    // MARK: Camera

    static func cap(_ s: String?, _ n: Int = maxFieldLength) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(n))
    }

    public static func camera(id: OSMElementID, at: LonLat, tags: [String: String], edited: Date?) -> ALPRCamera? {
        guard isALPR(tags), at.isValid else { return nil }
        let dirRaw = tags["direction"] ?? tags["camera:direction"]
        return ALPRCamera(id: id, coordinate: at, directions: dirRaw.map(directions) ?? [], vendor: vendor(tags),
                          operatorName: cap(tags["operator"]), mount: cap(tags["camera:mount"]),
                          zone: cap(tags["surveillance:zone"]), lastEdited: edited)
    }

    // MARK: Time

    /// `YYYY-MM-DDTHH:MM:SS[.fff](Z|±HH:MM|±HHMM)` (a space may replace the `T`). Nil when malformed.
    static func parseISO8601(_ s: String) -> Date? {
        let b = Array(s.utf8)
        guard b.count >= 19, b.count <= 40 else { return nil }
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= b.count else { return nil }
            var v = 0
            for i in from..<(from + len) { guard b[i] >= 48, b[i] <= 57 else { return nil }; v = v * 10 + Int(b[i] - 48) }
            return v
        }
        guard b[4] == 45, b[7] == 45, b[10] == 84 || b[10] == 32, b[13] == 58, b[16] == 58,
              let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
              let h = num(11, 2), let mi = num(14, 2), let se = num(17, 2),
              y >= 1900, y <= 2200, (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, se < 61 else { return nil }
        var i = 19
        var frac = 0.0
        if i < b.count, b[i] == 46 {
            i += 1
            var scale = 0.1
            let start = i
            while i < b.count, b[i] >= 48, b[i] <= 57 { frac += Double(b[i] - 48) * scale; scale /= 10; i += 1 }
            guard i > start else { return nil }
        }
        var offset = 0
        if i < b.count {
            if b[i] == 90 { i += 1 }
            else if b[i] == 43 || b[i] == 45 {
                let sign = b[i] == 45 ? -1 : 1
                guard let oh = num(i + 1, 2) else { return nil }
                var om = 0
                var j = i + 3
                if j < b.count, b[j] == 58 { j += 1 }
                if j < b.count { guard let m = num(j, 2) else { return nil }; om = m; j += 2 }
                guard oh < 24, om < 60 else { return nil }
                offset = sign * (oh * 3600 + om * 60)
                i = j
            } else { return nil }
        }
        guard i == b.count else { return nil }
        // days from civil (Howard Hinnant)
        let yy = mo <= 2 ? y - 1 : y
        let era = yy / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        let secs = days * 86400 + h * 3600 + mi * 60 + se - offset
        return Date(timeIntervalSince1970: Double(secs) + frac)
    }
}
