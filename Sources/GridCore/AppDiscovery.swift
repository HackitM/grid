import Foundation

public struct AppRecord: Identifiable, Hashable, Codable, Sendable {
    public var id: String { path }
    public let name: String
    public let bundleID: String?
    public let path: String
    public let version: String?

    public init(name: String, bundleID: String?, path: String, version: String?) {
        self.name = name; self.bundleID = bundleID; self.path = path; self.version = version
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

/// Finds installed applications by scanning the standard application folders.
///
/// A directory scan is deterministic and works even when Spotlight indexing is disabled; it covers
/// the App Store, drag-installed apps, and Homebrew casks (which install into /Applications).
public enum AppDiscovery {
    public static func standardRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
            home.appendingPathComponent("Applications"),
            // Finder lives here; it is not in /System/Applications.
            URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
        ]
    }

    /// Scans roots up to `maxDepth` folder levels (e.g. /Applications/Utilities, vendor folders).
    /// Never descends into a bundle.
    public static func scan(roots: [URL], maxDepth: Int = 3) -> [AppRecord] {
        var seen = Set<String>()
        var out: [AppRecord] = []
        let fm = FileManager.default

        func visit(_ dir: URL, depth: Int) {
            if dir.pathExtension == "app" {
                let real = dir.resolvingSymlinksInPath().path
                if seen.insert(real).inserted, let r = record(for: dir) { out.append(r) }
                return
            }
            guard depth < maxDepth,
                  let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return }
            for item in items {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if item.pathExtension == "app" || isDir { visit(item, depth: depth + 1) }
            }
        }
        for root in roots { visit(root, depth: 0) }
        return out
    }

    public static func record(for appURL: URL) -> AppRecord? {
        guard let bundle = Bundle(url: appURL) else { return nil }
        let info = bundle.localizedInfoDictionary ?? [:]
        let base = bundle.infoDictionary ?? [:]
        // Skip helper/agent bundles that are not meant to be launched by users.
        if (base["LSBackgroundOnly"] as? Bool) == true { return nil }
        let name = (info["CFBundleDisplayName"] as? String)
            ?? FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
        return AppRecord(name: name, bundleID: bundle.bundleIdentifier, path: appURL.path,
                         version: base["CFBundleShortVersionString"] as? String)
    }

    /// For records sharing a display name, a short location hint to tell them apart.
    public static func disambiguators(for records: [AppRecord]) -> [String: String] {
        var byName: [String: [AppRecord]] = [:]
        for r in records { byName[r.name.lowercased(), default: []].append(r) }
        var out: [String: String] = [:]
        for (_, group) in byName where group.count > 1 {
            for r in group {
                let parent = URL(fileURLWithPath: r.path).deletingLastPathComponent().path
                var hint = PathResolver.abbreviate(parent)
                if let v = r.version { hint += " · v\(v)" }
                out[r.path] = hint
            }
        }
        return out
    }

    /// Ranks apps for a query. Favorites and recently launched apps get a modest boost so they
    /// win ties without overriding a clearly better name match.
    public static func rank(_ records: [AppRecord], query: String, favorites: Set<String>, recents: [String]) -> [AppRecord] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let recentIndex = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var scored: [(AppRecord, Int)] = []
        for r in records {
            guard let base = FuzzyMatch.score(q, in: r.name) else { continue }
            var s = base
            if favorites.contains(r.path) { s += 40 }
            if let i = recentIndex[r.path] { s += max(0, 30 - i * 3) }
            scored.append((r, s))
        }
        return scored.sorted { a, b in
            a.1 != b.1 ? a.1 > b.1 : a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
        }.map(\.0)
    }
}
