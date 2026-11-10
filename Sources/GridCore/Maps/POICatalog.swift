import Foundation
import simd

/// What kind of place a point of interest is, for its glyph, its filter chip and search results.
public enum POICategory: UInt8, CaseIterable, Sendable, Codable, Hashable {
    case food = 1, shops, fuel, transit, health, lodging, leisure, culture, services, other

    public var title: String {
        switch self {
        case .food: "Food & drink"; case .shops: "Shops"; case .fuel: "Fuel & charging"; case .transit: "Transit"
        case .health: "Health"; case .lodging: "Lodging"; case .leisure: "Parks & sport"; case .culture: "Sights & culture"
        case .services: "Services"; case .other: "Other"
        }
    }

    /// Short chip label.
    public var short: String {
        switch self {
        case .food: "Food"; case .shops: "Shops"; case .fuel: "Fuel"; case .transit: "Transit"; case .health: "Health"
        case .lodging: "Lodging"; case .leisure: "Parks"; case .culture: "Sights"; case .services: "Services"; case .other: "Other"
        }
    }

    /// SF Symbol drawn as the place's glyph (all available on macOS 15).
    public var symbol: String {
        switch self {
        case .food: "fork.knife"; case .shops: "bag"; case .fuel: "fuelpump"; case .transit: "tram"
        case .health: "cross.case"; case .lodging: "bed.double"; case .leisure: "tree"; case .culture: "building.columns"
        case .services: "building.2"; case .other: "mappin"
        }
    }
}

/// A point of interest from a map tile, in tile-local coordinates. Lower `rank` = more important.
public struct POIAnchor: Sendable, Equatable {
    public var name: String
    public var category: POICategory
    /// What it is, in words ("fast food", "bus stop"): the tile's subclass, readable.
    public var detail: String
    public var rank: Int
    public var pos: SIMD2<Float>
    /// Minimum camera zoom at which its glyph may show.
    public var minZoom: Float
    public init(name: String, category: POICategory, detail: String, rank: Int, pos: SIMD2<Float>, minZoom: Float) {
        self.name = name; self.category = category; self.detail = detail; self.rank = rank; self.pos = pos; self.minZoom = minZoom
    }
}

/// OpenMapTiles `poi` classes (and OSM tags from online search) → GRID's categories.
public enum POICatalog {
    /// Points that are too small or too many to be worth a glyph or a search result.
    static let skipped: Set<String> = [
        "entrance", "toilets", "drinking_water", "information", "bench", "waste_basket", "recycling",
        "parking", "bicycle_parking", "motorcycle_parking", "vending_machine", "shelter", "post_box",
        "cemetery", "grave_yard", "telephone", "fountain", "hunting_stand", "picnic_table",
    ]

    private static let table: [String: POICategory] = {
        var t: [String: POICategory] = [:]
        func put(_ c: POICategory, _ keys: String) { for k in keys.split(separator: " ") { t[String(k)] = c } }
        put(.food, "restaurant fast_food food_court cafe bar beer pub biergarten nightclub ice_cream bakery")
        put(.shops, """
            shop grocery supermarket convenience department_store marketplace mall alcohol_shop alcohol beverages wine \
            clothing_store clothes shoes bag music books butcher florist furniture gift jewelry mobile_phone hairdresser \
            laundry dry_cleaning bicycle hardware doityourself electronics optician kiosk deli greengrocer chemist \
            sports outdoor toys pet stationery
            """)
        put(.fuel, "fuel charging_station")
        put(.transit, "bus bus_stop bus_station railway station halt tram_stop subway_entrance train_station_entrance aerialway ferry_terminal harbor marina")
        put(.health, "hospital clinic pharmacy doctors dentist veterinary nursing_home")
        put(.lodging, "lodging hotel motel hostel guest_house bed_and_breakfast chalet alpine_hut campsite camp_site caravan_site")
        put(.leisure, "park playground dog_park garden golf golf_course stadium swimming swimming_pool swimming_area zoo pitch sports_centre theme_park water_park ice_rink nature_reserve")
        put(.culture, "attraction viewpoint art_gallery museum theatre cinema castle monument memorial arts_centre gallery artwork ruins")
        put(.services, """
            town_hall townhall community_centre courthouse post post_office police fire_station library school kindergarten \
            college university bank atm place_of_worship office embassy car car_repair car_rental car_wash bicycle_rental
            """)
        return t
    }()

    /// The category of a tile POI (`class`, then `subclass`); nil for points GRID skips.
    public static func category(class cls: String, subclass: String?) -> POICategory? {
        let c = cls.lowercased(), s = subclass?.lowercased() ?? ""
        if skipped.contains(c) || skipped.contains(s) { return nil }
        // The subclass is the specific one ("shop" / "bakery" is food).
        if let hit = table[s] { return hit }
        if let hit = table[c] { return hit }
        return c.isEmpty && s.isEmpty ? nil : .other
    }

    /// The category of an online result from its OSM key and value (`amenity=cafe`); nil for
    /// places, roads, boundaries and anything without a fitting category.
    public static func category(osmKey key: String, value: String) -> POICategory? {
        let k = key.lowercased(), v = value.lowercased()
        switch k {
        case "place", "boundary", "highway", "natural", "waterway", "landuse", "building", "water": return nil
        case "shop": return skipped.contains(v) ? nil : (table[v] ?? .shops)
        case "tourism":
            if let hit = table[v] { return hit }
            return ["hotel", "motel", "hostel", "guest_house", "apartment", "camp_site"].contains(v) ? .lodging : .culture
        case "amenity", "leisure", "railway", "public_transport", "aeroway", "historic", "office", "healthcare", "craft":
            if skipped.contains(v) { return nil }
            if let hit = table[v] { return hit }
            switch k {
            case "railway", "public_transport", "aeroway": return .transit
            case "historic": return .culture
            case "healthcare": return .health
            case "leisure": return .leisure
            default: return .other
            }
        default: return nil
        }
    }

    /// "fast_food" → "fast food".
    public static func describe(_ raw: String) -> String {
        let s = raw.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return String(s.prefix(40))
    }

    /// Zoom at which a POI of `rank` starts to show (rank 1 = the most important in its area).
    public static func minZoom(rank: Int) -> Float {
        rank <= 3 ? 14.5 : (rank <= 12 ? 15.5 : 16.5)
    }
}
