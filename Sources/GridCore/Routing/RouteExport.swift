import Foundation

/// A route's turn list for printing or copying: one row per step, with the distance to the next
/// step, the running total and the cameras passed during it.
public struct CueSheet: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public var number: Int
        public var kind: RouteStep.Kind
        public var text: String
        /// Metres to the next step, and from the start to where this step begins.
        public var distance: Double
        public var total: Double
        public var cameras: [CameraExposure.Hit]
    }
    public var rows: [Row]
    public var distance: Double
    public var duration: Double

    public init(path: RoutePath, hits: [CameraExposure.Hit]) {
        var rows: [Row] = []
        for (i, s) in path.steps.enumerated() {
            let next = i + 1 < path.steps.count ? path.steps[i + 1].along : .infinity
            let here = hits.filter { $0.along >= s.along && $0.along < next }
            rows.append(Row(number: i + 1, kind: s.kind, text: s.text, distance: s.distance, total: s.along, cameras: here))
        }
        self.rows = rows
        distance = path.distance
        duration = path.duration
    }

    /// Plain text, one step per line ("01  Turn left onto Main St  0.4 mi  (2.1 mi)") with camera
    /// notes indented under their step.
    public func text(title: String, distance fmt: (Double) -> String, duration dfmt: (Double) -> String,
                     camera note: (CameraExposure.Hit) -> String) -> String {
        var out = "\(title)\n\(fmt(distance)) · \(dfmt(duration))\n\n"
        for r in rows {
            var line = String(format: "%02d  ", r.number) + r.text
            if r.distance > 0 { line += "  \(fmt(r.distance))" }
            if r.number > 1 { line += "  (at \(fmt(r.total)))" }
            out += line + "\n"
            for c in r.cameras { out += "      ⌗ " + note(c) + "\n" }
        }
        return out
    }
}

/// GPX 1.1 for a GPS unit or an offline navigator: the start and end and the mapped cameras the
/// route passes as waypoints, the steps as a route (`rte`), and the full line as a track (`trk`).
public enum GPXWriter {
    public struct Waypoint: Sendable { public var at: LonLat; public var name: String; public var detail: String?
        public init(at: LonLat, name: String, detail: String? = nil) { self.at = at; self.name = name; self.detail = detail }
    }

    public static func document(name: String, steps: [RouteStep], track: [LonLat], waypoints: [Waypoint], created: Date) -> String {
        var x = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="GRID" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>\(escape(name))</name>
            <time>\(iso(created))</time>
          </metadata>

        """
        for w in waypoints {
            x += "  <wpt \(coords(w.at))>\n    <name>\(escape(w.name))</name>\n"
            if let d = w.detail { x += "    <desc>\(escape(d))</desc>\n" }
            x += "  </wpt>\n"
        }
        x += "  <rte>\n    <name>\(escape(name))</name>\n"
        for s in steps { x += "    <rtept \(coords(s.location))><name>\(escape(s.text))</name></rtept>\n" }
        x += "  </rte>\n  <trk>\n    <name>\(escape(name))</name>\n    <trkseg>\n"
        for p in track { x += "      <trkpt \(coords(p))/>\n" }
        x += "    </trkseg>\n  </trk>\n</gpx>\n"
        return x
    }

    static func coords(_ p: LonLat) -> String {
        // Always a point decimal separator, whatever the locale.
        "lat=\"\(fixed(p.lat))\" lon=\"\(fixed(p.lon))\""
    }

    static func fixed(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), v)
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    /// XML text: the five special characters escaped, characters XML 1.0 forbids removed.
    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                let v = u.value
                let allowed = v == 0x9 || v == 0xA || v == 0xD || (0x20...0xD7FF).contains(v) || (0xE000...0xFFFD).contains(v) || (0x10000...0x10FFFF).contains(v)
                if allowed { out.unicodeScalars.append(u) }
            }
        }
        return out
    }
}
