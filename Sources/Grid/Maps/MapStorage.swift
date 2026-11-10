import Foundation
import GridCore

/// GRID Maps' folder: `~/Library/Application Support/GRID[-QA]/Maps/` with `tiles/`, `alpr/` and
/// `regions/`. Every write goes through here: the folder (and each parent we create) must not be
/// a symlink and must stay inside Application Support; writes are atomic; only integers and
/// `RegionDescriptor.storageKey` values become path components.
enum MapStorage {
    static let root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier?.hasSuffix(".qa") == true ? "GRID-QA" : "GRID", isDirectory: true)
        .appendingPathComponent("Maps", isDirectory: true)

    static var tiles: URL { root.appendingPathComponent("tiles", isDirectory: true) }
    static var alpr: URL { root.appendingPathComponent("alpr", isDirectory: true) }
    static var regions: URL { root.appendingPathComponent("regions", isDirectory: true) }
    static var terrain: URL { root.appendingPathComponent("terrain", isDirectory: true) }

    enum StorageError: LocalizedError {
        case unsafePath(String), noSpace, denied(String), io(String)
        var errorDescription: String? {
            switch self {
            case .unsafePath(let p): "Refused to write outside GRID's Maps folder (\(p))."
            case .noSpace: "The disk is full."
            case .denied(let p): "No permission to write \(p)."
            case .io(let m): m
            }
        }
    }

    /// Creates `dir` (inside `root`) if needed, refusing symlinks anywhere from `root` down.
    static func ensureDirectory(_ dir: URL) throws {
        try checkInside(dir)
        let fm = FileManager.default
        var chain: [URL] = []
        var u = dir.standardizedFileURL
        let top = root.deletingLastPathComponent().standardizedFileURL
        while u.path.count > top.path.count { chain.insert(u, at: 0); u = u.deletingLastPathComponent() }
        for c in chain {
            var isDir: ObjCBool = false
            if let attrs = try? fm.attributesOfItem(atPath: c.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                throw StorageError.unsafePath(c.path)
            }
            if fm.fileExists(atPath: c.path, isDirectory: &isDir) {
                guard isDir.boolValue else { throw StorageError.unsafePath(c.path) }
            } else {
                do { try fm.createDirectory(at: c, withIntermediateDirectories: false) }
                catch { throw map(error, c.path) }
            }
        }
    }

    /// Atomic write of `data` to `file` (inside `root`).
    static func write(_ data: Data, to file: URL) throws {
        try checkInside(file)
        try ensureDirectory(file.deletingLastPathComponent())
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            throw StorageError.unsafePath(file.path)
        }
        do { try data.write(to: file, options: [.atomic]) } catch { throw map(error, file.path) }
    }

    /// Reads a regular file inside `root` (never through a symlink), up to `maxBytes`.
    static func read(_ file: URL, maxBytes: Int) -> Data? {
        guard (try? checkInside(file)) != nil,
              let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.intValue <= maxBytes else { return nil }
        return try? Data(contentsOf: file, options: [.mappedIfSafe])
    }

    /// Notes that a cached file was used, so that trimming a cache by oldest date removes what
    /// hasn't been used for longest rather than what was downloaded first. The date moves at
    /// most once a day per file, which keeps this to one cheap check on almost every read.
    static func markUsed(_ file: URL, now: Date = Date()) {
        guard (try? checkInside(file)) != nil,
              let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let modified = attrs[.modificationDate] as? Date, now.timeIntervalSince(modified) > 86_400 else { return }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }

    /// Removes `dir` (inside `root`) without following symlinks out of it.
    static func remove(_ dir: URL) throws {
        try checkInside(dir)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) || (try? fm.attributesOfItem(atPath: dir.path)) != nil else { return }
        // removeItem deletes symlinks themselves, never their targets.
        do { try fm.removeItem(at: dir) } catch { throw map(error, dir.path) }
    }

    /// Bytes used under `dir` (regular files only; symlinks not followed).
    static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
                                                     options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true { e.skipDescendants(); continue }
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    private static func checkInside(_ url: URL) throws {
        let p = url.standardizedFileURL.path
        let r = root.standardizedFileURL.path
        guard p == r || p.hasPrefix(r + "/"), !p.contains("/../") else { throw StorageError.unsafePath(p) }
    }

    private static func map(_ error: Error, _ path: String) -> Error {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileWriteOutOfSpaceError) { return StorageError.noSpace }
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError) {
            return StorageError.denied(path)
        }
        if let posix = ns.userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain {
            if posix.code == Int(ENOSPC) { return StorageError.noSpace }
            if posix.code == Int(EACCES) || posix.code == Int(EPERM) { return StorageError.denied(path) }
        }
        return StorageError.io(ns.localizedDescription)
    }
}
