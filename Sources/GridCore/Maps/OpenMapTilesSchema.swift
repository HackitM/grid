import Foundation

/// Maps OpenMapTiles-schema features (the layers OpenFreeMap serves) to GRID's render classes and
/// label anchors. Pure functions over decoded tags; unknown values map to nil (the feature is not
/// drawn), never to a crash.
public enum OpenMapTilesSchema {
    /// The layers v1 decodes; every other layer is skipped without parsing its features.
    public static let layers: Set<String> = [
        "water", "waterway", "landuse", "landcover", "park", "building", "transportation",
        "transportation_name", "place", "water_name", "boundary", "aeroway",
    ]

    private static func str(_ tags: [String: MVTValue], _ key: String) -> String? { tags[key]?.string }

    // MARK: Fills (polygons)

    public static func fillClass(layer: String, tags: [String: MVTValue]) -> RenderClass? {
        let cls = str(tags, "class") ?? ""
        switch layer {
        case "water":
            return .water
        case "park":
            return .park
        case "landcover":
            switch cls {
            case "grass", "wood", "wetland": return .park
            default: return nil          // farmland, sand, rock, ice: too subtle to draw
            }
        case "landuse":
            switch cls {
            case "cemetery", "playground", "pitch", "track", "garden", "grass", "village_green", "recreation_ground":
                return .park
            case "": return nil
            default: return .landuse     // residential, industrial, commercial, retail, hospital, …
            }
        case "building":
            return .building
        case "aeroway":
            return cls == "runway" ? .aeroway : nil
        default:
            return nil                   // transportation polygons are dropped (lines only)
        }
    }

    // MARK: Lines

    public static func lineClass(layer: String, tags: [String: MVTValue]) -> (RenderClass, UInt16)? {
        let cls = str(tags, "class") ?? ""
        switch layer {
        case "waterway":
            switch cls {
            case "river", "canal", "stream", "drain", "ditch": return (.waterway, 0)
            default: return nil
            }
        case "transportation":
            guard let rc = roadClass(cls) else { return nil }
            var flags: UInt16 = 0
            switch str(tags, "brunnel") {
            case "tunnel": flags |= LineVertex.tunnel
            case "bridge": flags |= LineVertex.bridge
            default: break
            }
            return (rc, flags)
        case "boundary":
            guard let level = tags["admin_level"]?.number, level >= 1, level <= 4 else { return nil }
            if let m = tags["maritime"]?.number, m == 1 { return nil }
            if case .bool(true)? = tags["maritime"] { return nil }
            return (.boundary, 0)
        case "aeroway":
            return cls == "runway" || cls == "taxiway" ? (.aeroway, 0) : nil
        default:
            return nil
        }
    }

    static func roadClass(_ cls: String) -> RenderClass? {
        switch cls {
        case "motorway": return .motorway
        case "trunk": return .trunk
        case "primary": return .primary
        case "secondary": return .secondary
        case "tertiary": return .tertiary
        case "minor", "raceway", "busway": return .minor
        case "service": return .service
        case "track", "path": return .path
        case "rail": return .rail
        default: return nil              // transit, ferry, aerialway, *_construction, …
        }
    }

    // MARK: Labels

    public static func label(layer: String, tags: [String: MVTValue]) -> (text: String, kind: LabelKind, priority: Int, minZoom: Float)? {
        guard let text = name(tags) else { return nil }
        let cls = str(tags, "class") ?? ""
        let rank = Int(max(0, min(99, tags["rank"]?.number ?? 50)))
        switch layer {
        case "place":
            let (zoom, base): (Float, Int)
            switch cls {
            case "country": (zoom, base) = (2, 0)
            case "state": (zoom, base) = (5, 100)
            case "city": (zoom, base) = (4, 200)
            case "town": (zoom, base) = (8, 300)
            case "village": (zoom, base) = (11, 400)
            case "suburb": (zoom, base) = (13, 500)
            case "neighbourhood": (zoom, base) = (13, 600)
            default: return nil
            }
            return (text, .place, base + rank, zoom)
        case "water_name":
            let zoom: Float
            switch cls {
            case "ocean": zoom = 1
            case "sea": zoom = 3
            case "lake": zoom = 7
            default: zoom = 10
            }
            return (text, .water, 800 + rank, zoom)
        case "transportation_name":
            let order: [String: Int] = ["motorway": 0, "trunk": 1, "primary": 2, "secondary": 3, "tertiary": 4, "minor": 5, "service": 6]
            guard let o = order[cls] else { return nil }
            return (text, .road, 900 + o, 15)
        default:
            return nil
        }
    }

    /// Display name: `name_en`, then `name:latin`, then `name`; trimmed, non-empty, at most 64
    /// characters, control characters removed.
    static func name(_ tags: [String: MVTValue]) -> String? {
        for key in ["name_en", "name:latin", "name"] {
            guard let raw = tags[key]?.string else { continue }
            let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return String(cleaned.prefix(64)) }
        }
        return nil
    }

    // MARK: Buildings

    /// Roof height in metres: `render_height` clamped to 0…500, default 10 when absent.
    public static func buildingHeight(_ tags: [String: MVTValue]) -> Float {
        guard let h = tags["render_height"]?.number, h.isFinite else { return 10 }
        return Float(max(0, min(500, h)))
    }

    /// Wall base height in metres (`render_min_height`, clamped to 0…500, default 0).
    static func buildingMinHeight(_ tags: [String: MVTValue]) -> Float {
        guard let h = tags["render_min_height"]?.number, h.isFinite else { return 0 }
        return Float(max(0, min(500, h)))
    }
}
