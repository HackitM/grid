import Foundation

/// The road classes GRID routes on (car), in order of importance.
public enum RoadClass: UInt8, Sendable, CaseIterable {
    case motorway, trunk, primary, secondary, tertiary, unclassified, residential, livingStreet, service,
         motorwayLink, trunkLink, primaryLink, secondaryLink, tertiaryLink, road

    public var isLink: Bool { [.motorwayLink, .trunkLink, .primaryLink, .secondaryLink, .tertiaryLink].contains(self) }
    public var isHighway: Bool { self == .motorway || self == .trunk }

    /// Typical travel speed in km/h when the way has no usable `maxspeed`.
    var defaultSpeed: Double {
        switch self {
        case .motorway: 105; case .trunk: 85; case .primary: 65; case .secondary: 55; case .tertiary: 45
        case .unclassified: 40; case .residential: 30; case .livingStreet: 10; case .service: 15
        case .motorwayLink: 60; case .trunkLink: 50; case .primaryLink: 45; case .secondaryLink: 40; case .tertiaryLink: 35
        case .road: 30
        }
    }
}

/// What a way means for a car: speeds each way (0 = not allowed), class, flags and name.
public struct RoadAttributes: Equatable, Sendable {
    public var forwardKmh: UInt8
    public var backwardKmh: UInt8
    public var roadClass: RoadClass
    public var roundabout: Bool
    public var toll: Bool
    public var name: String?
}

/// Car profile over OSM tags: which ways are drivable, in which directions and how fast.
public enum RoadProfile {
    static let classes: [String: RoadClass] = [
        "motorway": .motorway, "trunk": .trunk, "primary": .primary, "secondary": .secondary, "tertiary": .tertiary,
        "unclassified": .unclassified, "residential": .residential, "living_street": .livingStreet, "service": .service,
        "motorway_link": .motorwayLink, "trunk_link": .trunkLink, "primary_link": .primaryLink,
        "secondary_link": .secondaryLink, "tertiary_link": .tertiaryLink, "road": .road,
    ]
    static let closed: Set<String> = ["no", "private", "agricultural", "forestry", "delivery", "military", "emergency", "customers"]
    static let open: Set<String> = ["yes", "designated", "permissive", "destination"]
    /// Every tag key `attributes` reads (the graph builder asks the PBF reader for these only).
    static let tagKeys: Set<String> = ["highway", "area", "motorcar", "motor_vehicle", "vehicle", "access", "service", "oneway",
                                       "maxspeed", "junction", "name", "ref", "toll"]

    /// nil when a car can't use the way.
    public static func attributes(_ t: [String: String]) -> RoadAttributes? {
        guard let hw = t["highway"], let cls = classes[hw] else { return nil }
        if t["area"] == "yes" { return nil }
        // Access: the most specific tag wins (motorcar, then motor_vehicle, then vehicle, then access).
        for key in ["motorcar", "motor_vehicle", "vehicle", "access"] {
            if let v = t[key]?.lowercased() {
                if closed.contains(v) { return nil }
                if open.contains(v) { break }
            }
        }
        if let s = t["service"], ["emergency_access"].contains(s) { return nil }
        if t["oneway"] == "reversible" || t["oneway"] == "alternating" { return nil }

        var kmh = cls.defaultSpeed
        if cls == .service, let s = t["service"], ["parking_aisle", "driveway", "drive-through"].contains(s) { kmh = 10 }
        if let m = t["maxspeed"].flatMap(maxspeed) { kmh = min(kmh * 1.25, max(5, m * (cls.isHighway ? 0.92 : 0.85))) }
        let v = UInt8(clamping: Int(min(130, max(5, kmh)).rounded()))

        let roundabout = t["junction"] == "roundabout" || t["junction"] == "circular"
        var fwd = v, back = v
        switch t["oneway"]?.lowercased() {
        case "yes", "true", "1": back = 0
        case "-1", "reverse": fwd = 0
        case "no", "false", "0": break
        default: if roundabout || cls == .motorway || cls == .motorwayLink { back = 0 }
        }
        let name: String? = {
            let n = clean(t["name"]), r = clean(t["ref"])
            if cls.isHighway || cls == .motorwayLink, let r { return n.map { "\($0) (\(r))" } ?? r }
            return n ?? r
        }()
        return RoadAttributes(forwardKmh: fwd, backwardKmh: back, roadClass: cls, roundabout: roundabout,
                              toll: t["toll"] == "yes", name: name)
    }

    /// `maxspeed` in km/h ("50", "30 mph", "none"); nil when not a number.
    public static func maxspeed(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s == "none" { return 130 }
        let mph = s.hasSuffix("mph")
        let digits = s.prefix { $0.isNumber || $0 == "." }
        guard let n = Double(digits), n > 0, n < 300 else { return nil }
        return mph ? n * 1.609344 : n
    }

    /// A name fit to show: no control or bidi characters, trimmed, at most 80 characters; nil when nothing is left.
    static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let c = DisplayText.stripped(s).trimmingCharacters(in: .whitespaces)
        return c.isEmpty ? nil : String(c.prefix(80))
    }
}
