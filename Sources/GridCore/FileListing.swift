import Foundation
import UniformTypeIdentifiers

public struct FileEntry: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let isDirectory: Bool       // true for real dirs and for symlinks that point at dirs
    public let isPackage: Bool         // .app, .bundle, ... (opened, not entered)
    public let isSymlink: Bool
    public let isBrokenSymlink: Bool
    public let isHidden: Bool
    public let size: Int64?
    public let modified: Date?
    public let kind: String            // localized type description, e.g. "PNG image"
    public let typeIdentifier: String?

    public init(url: URL, name: String, isDirectory: Bool, isPackage: Bool, isSymlink: Bool,
                isBrokenSymlink: Bool, isHidden: Bool, size: Int64?, modified: Date?, kind: String,
                typeIdentifier: String?) {
        self.url = url; self.name = name; self.isDirectory = isDirectory; self.isPackage = isPackage
        self.isSymlink = isSymlink; self.isBrokenSymlink = isBrokenSymlink; self.isHidden = isHidden
        self.size = size; self.modified = modified; self.kind = kind; self.typeIdentifier = typeIdentifier
    }

    /// Navigable as a folder in the browser (packages open with their app instead).
    public var isNavigableFolder: Bool { isDirectory && !isPackage }

    public var fileExtension: String { url.pathExtension.lowercased() }
}

public enum FileSortKey: String, CaseIterable, Codable, Sendable {
    case name, kind, size, modified
    public var label: String {
        switch self { case .name: "NAME"; case .kind: "TYPE"; case .size: "SIZE"; case .modified: "MODIFIED" }
    }
}

public enum ListingError: Error, Equatable, Sendable {
    case permissionDenied(String)
    case notFound(String)
    case notADirectory(String)
    case other(String, String)

    public static func from(_ error: Error, path: String) -> ListingError {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoPermissionError: return .permissionDenied(path)
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .notFound(path)
            default: break
            }
        }
        if ns.domain == NSPOSIXErrorDomain {
            switch Int32(ns.code) {
            case EACCES, EPERM: return .permissionDenied(path)
            case ENOENT: return .notFound(path)
            case ENOTDIR: return .notADirectory(path)
            default: break
            }
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, Int32(underlying.code) == EPERM || Int32(underlying.code) == EACCES {
            return .permissionDenied(path)
        }
        return .other(path, ns.localizedDescription)
    }
}

public enum FileListing {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey,
        .totalFileAllocatedSizeKey, .contentModificationDateKey, .contentTypeKey, .localizedTypeDescriptionKey,
    ]

    /// Lists one directory level. Throws `ListingError`.
    public static func list(_ dir: URL, showHidden: Bool) throws -> [FileEntry] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir) else { throw ListingError.notFound(dir.path) }
        guard isDir.boolValue else { throw ListingError.notADirectory(dir.path) }
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                              options: showHidden ? [] : [.skipsHiddenFiles])
        } catch {
            throw ListingError.from(error, path: dir.path)
        }
        // Re-root children under the directory URL as the user typed it (e.g. /tmp, not the
        // /private/tmp the system may return), so paths, breadcrumbs, and selection stay consistent.
        return urls.map { entry(for: $0, displayURL: dir.appendingPathComponent($0.lastPathComponent)) }
    }

    public static func entry(for url: URL, displayURL: URL? = nil) -> FileEntry {
        let v = try? url.resourceValues(forKeys: Set(keys))
        let isLink = v?.isSymbolicLink ?? false
        var isDir = v?.isDirectory ?? false
        var isPackage = v?.isPackage ?? false
        var broken = false
        var type = v?.contentType
        var kind = v?.localizedTypeDescription ?? ""
        if isLink {
            // resourceValues describe the link itself; follow it to describe the target.
            // fileExists follows the link; resolvingSymlinksInPath returns the link itself when the
            // target is missing, so it cannot be used to detect a dangling link.
            let target = url.resolvingSymlinksInPath()
            if FileManager.default.fileExists(atPath: url.path),
               let tv = try? target.resourceValues(forKeys: Set(keys)) {
                isDir = tv.isDirectory ?? false
                isPackage = tv.isPackage ?? false
                type = tv.contentType ?? type
                kind = tv.localizedTypeDescription ?? kind
            } else {
                broken = true
            }
        }
        let name = url.lastPathComponent
        let size: Int64? = isDir ? nil : (v?.fileSize).map(Int64.init)
        return FileEntry(url: displayURL ?? url, name: name, isDirectory: isDir, isPackage: isPackage, isSymlink: isLink,
                         isBrokenSymlink: broken, isHidden: (v?.isHidden ?? false) || name.hasPrefix("."),
                         size: size, modified: v?.contentModificationDate,
                         kind: broken ? "Broken link" : (kind.isEmpty ? (isDir ? "Folder" : "Document") : kind),
                         typeIdentifier: type?.identifier)
    }

    /// Folders first, then by key. Name comparison matches Finder (numeric-aware, localized).
    public static func sorted(_ entries: [FileEntry], by key: FileSortKey, ascending: Bool, foldersFirst: Bool = true) -> [FileEntry] {
        entries.sorted { a, b in
            if foldersFirst, a.isNavigableFolder != b.isNavigableFolder { return a.isNavigableFolder }
            let byName = a.name.localizedStandardCompare(b.name)
            let primary: ComparisonResult
            switch key {
            case .name: primary = byName
            case .kind:
                let k = a.kind.localizedStandardCompare(b.kind)
                primary = k == .orderedSame ? byName : k
            case .size:
                let sa = a.size ?? -1, sb = b.size ?? -1
                primary = sa == sb ? byName : (sa < sb ? .orderedAscending : .orderedDescending)
            case .modified:
                let da = a.modified ?? .distantPast, db = b.modified ?? .distantPast
                primary = da == db ? byName : (da < db ? .orderedAscending : .orderedDescending)
            }
            if primary == .orderedSame { return false }
            return ascending ? primary == .orderedAscending : primary == .orderedDescending
        }
    }

    public static func filter(_ entries: [FileEntry], query: String) -> [FileEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// `drwxr-xr-x`-style string from POSIX permissions.
    public static func permissionString(_ perms: Int, isDirectory: Bool, isSymlink: Bool) -> String {
        let t = isSymlink ? "l" : (isDirectory ? "d" : "-")
        let chars = ["r", "w", "x"]
        var s = t
        for shift in stride(from: 8, through: 0, by: -1) {
            s += (perms >> shift) & 1 == 1 ? chars[(8 - shift) % 3] : "-"
        }
        return s
    }
}
