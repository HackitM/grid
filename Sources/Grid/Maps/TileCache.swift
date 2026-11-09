import Foundation
import GridCore

/// Raw vector tiles on disk: `Maps/tiles/<sourceKey>/<z>/<x>/<y>.pbf`. Not a trust boundary:
/// every tile read back is decoded by the same validating decoder as a fresh download. Trimmed to
/// `maxBytes` by oldest modification date; Clear Map Data removes the folder.
actor TileCache {
    let sourceKey: String
    let maxBytes: Int64
    private var bytesSinceTrim: Int64 = 0

    static let maxTileBytes = 8 << 20

    init(sourceKey: String, maxBytes: Int64 = 200 << 20) {
        // Keep only safe characters: the source key comes from the tile source's version.
        var key = String(sourceKey.lowercased().unicodeScalars.map { c -> Character in
            (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "-" || c == "_" ? Character(c) : "-"
        }).prefix(64)
        if key.isEmpty { key = "default" }
        self.sourceKey = String(key)
        self.maxBytes = maxBytes
    }

    private var dir: URL { MapStorage.tiles.appendingPathComponent(sourceKey, isDirectory: true) }

    private func file(_ t: TileID) -> URL {
        dir.appendingPathComponent("\(t.z)", isDirectory: true).appendingPathComponent("\(t.x)", isDirectory: true)
            .appendingPathComponent("\(t.y).pbf")
    }

    func read(_ t: TileID) -> Data? {
        guard t.isValid else { return nil }
        return MapStorage.read(file(t), maxBytes: Self.maxTileBytes)
    }

    func write(_ t: TileID, _ data: Data) {
        guard t.isValid, data.count <= Self.maxTileBytes else { return }
        do {
            try MapStorage.write(data, to: file(t))
            bytesSinceTrim += Int64(data.count)
            if bytesSinceTrim > 16 << 20 { bytesSinceTrim = 0; trim() }
        } catch {
            // A full or read-only disk only costs a re-download later.
        }
    }

    /// Removes the oldest tiles until the cache is under 90% of its cap.
    func trim() {
        guard let e = FileManager.default.enumerator(at: MapStorage.tiles, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) else { return }
        var files: [(URL, Int64, Date)] = []
        var total: Int64 = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            let s = Int64(v.fileSize ?? 0)
            total += s
            files.append((u, s, v.contentModificationDate ?? .distantPast))
        }
        guard total > maxBytes else { return }
        for (u, s, _) in files.sorted(by: { $0.2 < $1.2 }) {
            try? FileManager.default.removeItem(at: u)
            total -= s
            if total < maxBytes * 9 / 10 { break }
        }
    }
}
