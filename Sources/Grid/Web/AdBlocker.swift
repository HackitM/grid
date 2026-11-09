import Foundation
import GridCore
import Observation
import WebKit

/// Ad and tracker blocking with uBlock Origin's default filter lists, converted to WebKit's native
/// content blocker (fast: rules are compiled once and applied by WebKit itself).
///
/// - Lists are downloaded from their publishers when blocking is on (nothing is bundled), refreshed
///   every 4 days with conditional requests, and kept in Application Support.
/// - Compiled rule lists are cached by a digest of the list contents, so launches don't recompile.
/// - "Off for this site" removes the rule lists from that tab's next load (and reloads).
@Observable
@MainActor
final class AdBlocker {
    struct Source: Identifiable, Hashable {
        let id: String
        let name: String
        let url: URL
    }

    static let sources: [Source] = [
        Source(id: "ublock-filters", name: "uBlock filters", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/filters.min.txt")!),
        Source(id: "ublock-badware", name: "uBlock filters – Badware risks", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/badware.min.txt")!),
        Source(id: "ublock-privacy", name: "uBlock filters – Privacy", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/privacy.min.txt")!),
        Source(id: "ublock-unbreak", name: "uBlock filters – Unbreak", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/unbreak.min.txt")!),
        Source(id: "ublock-quick-fixes", name: "uBlock filters – Quick fixes", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/quick-fixes.min.txt")!),
        Source(id: "easylist", name: "EasyList", url: URL(string: "https://easylist.to/easylist/easylist.txt")!),
        Source(id: "easyprivacy", name: "EasyPrivacy", url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
        Source(id: "peter-lowe", name: "Peter Lowe’s Ad and tracking server list",
               url: URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=0&mimetype=plaintext")!),
    ]

    enum Status: Equatable {
        case idle, downloading, compiling
        case ready(rules: Int)
        case failed(String)
    }

    var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "browser.adblock"); onChange?(); if enabled { start() } } }
    private(set) var disabledSites: Set<String> { didSet { UserDefaults.standard.set(Array(disabledSites).sorted(), forKey: "browser.adblock.off") } }
    private(set) var ruleLists: [WKContentRuleList] = []
    private(set) var status: Status = .idle
    private(set) var lastUpdated: Date? { didSet { UserDefaults.standard.set(lastUpdated, forKey: "browser.adblock.updated") } }
    private(set) var stats = ""
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var updating = false

    nonisolated static let refreshInterval: TimeInterval = 4 * 24 * 3600
    nonisolated static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier?.hasSuffix(".qa") == true ? "GRID-QA" : "GRID")
        .appendingPathComponent("Browser", isDirectory: true)
    nonisolated static var listsDir: URL { dir.appendingPathComponent("Filters", isDirectory: true) }
    nonisolated static var storeDir: URL { dir.appendingPathComponent("RuleLists", isDirectory: true) }

    init() {
        UserDefaults.standard.register(defaults: ["browser.adblock": true])
        enabled = UserDefaults.standard.bool(forKey: "browser.adblock")
        disabledSites = Set(UserDefaults.standard.stringArray(forKey: "browser.adblock.off") ?? [])
        lastUpdated = UserDefaults.standard.object(forKey: "browser.adblock.updated") as? Date
        for d in [Self.listsDir, Self.storeDir] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    private var store: WKContentRuleListStore? { WKContentRuleListStore(url: Self.storeDir) }

    func shouldBlock(on site: String?) -> Bool {
        guard enabled, !ruleLists.isEmpty else { return false }
        return !(site.map { disabledSites.contains($0) } ?? false)
    }

    func setBlocking(_ on: Bool, for site: String) {
        if on { disabledSites.remove(site) } else { disabledSites.insert(site) }
        onChange?()
    }

    func removeException(_ site: String) { setBlocking(true, for: site) }

    /// Loads cached compiled lists, then refreshes in the background if they're stale.
    func start() {
        guard enabled, !started else { return }
        started = true
        Task {
            await loadCached()
            if ruleLists.isEmpty || (lastUpdated.map { Date().timeIntervalSince($0) > Self.refreshInterval } ?? true) {
                await update()
            }
        }
    }

    private func loadCached() async {
        guard let store, let ids = UserDefaults.standard.stringArray(forKey: "browser.adblock.ids"), !ids.isEmpty else { return }
        var lists: [WKContentRuleList] = []
        for id in ids {
            guard let l = try? await store.contentRuleList(forIdentifier: id) else { return }   // incomplete cache: rebuild
            lists.append(l)
        }
        ruleLists = lists
        status = .ready(rules: UserDefaults.standard.integer(forKey: "browser.adblock.count"))
        stats = UserDefaults.standard.string(forKey: "browser.adblock.stats") ?? ""
        onChange?()
    }

    /// Downloads changed lists and recompiles when their contents changed.
    func update(force: Bool = false) async {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        status = .downloading
        var texts: [FilterList] = []
        var failures: [String] = []
        await withTaskGroup(of: (Source, String?).self) { group in
            for s in Self.sources { group.addTask { (s, await Self.fetch(s, force: force)) } }
            for await (s, text) in group {
                if let text { texts.append(FilterList(name: s.id, text: text)) } else { failures.append(s.name) }
            }
        }
        texts.sort { $0.name < $1.name }
        guard !texts.isEmpty else { status = .failed("Couldn't download the filter lists."); return }
        // Unchanged lists: keep the compiled rules (no conversion, no WebKit compile).
        let newDigest = await Task.detached(priority: .utility) { ContentBlockerCompiler.digest(of: texts) }.value
        if !force, newDigest.prefix(16) == (UserDefaults.standard.string(forKey: "browser.adblock.digest") ?? "").prefix(16), !ruleLists.isEmpty {
            lastUpdated = Date()
            status = .ready(rules: UserDefaults.standard.integer(forKey: "browser.adblock.count"))
            return
        }
        status = .compiling
        let output = await Task.detached(priority: .utility) { ContentBlockerCompiler.compile(texts) }.value
        let digest = output.digest
        let oldIDs = UserDefaults.standard.stringArray(forKey: "browser.adblock.ids") ?? []
        guard let store else { status = .failed("Rule store unavailable."); return }
        var lists: [WKContentRuleList] = []
        var ids: [String] = []
        do {
            for (i, chunk) in output.ruleLists.enumerated() {
                let id = "grid.\(digest.prefix(16)).\(i).\(chunk.identifier)"
                if let existing = try? await store.contentRuleList(forIdentifier: id) {
                    lists.append(existing)
                } else if let compiled = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: chunk.json) {
                    lists.append(compiled)
                }
                ids.append(id)
            }
        } catch {
            status = .failed("WebKit rejected the rules: \(error.localizedDescription)")
            return
        }
        for old in oldIDs where !ids.contains(old) { try? await store.removeContentRuleList(forIdentifier: old) }
        let count = output.ruleLists.map(\.ruleCount).reduce(0, +)
        UserDefaults.standard.set(ids, forKey: "browser.adblock.ids")
        UserDefaults.standard.set(digest, forKey: "browser.adblock.digest")
        UserDefaults.standard.set(count, forKey: "browser.adblock.count")
        stats = output.summary + (failures.isEmpty ? "" : " · couldn't refresh: " + failures.joined(separator: ", "))
        UserDefaults.standard.set(stats, forKey: "browser.adblock.stats")
        ruleLists = lists
        lastUpdated = Date()
        status = .ready(rules: count)
        onChange?()
    }

    /// Fetches a list (conditional GET); falls back to the cached copy when offline or unchanged.
    nonisolated static func fetch(_ s: Source, force: Bool) async -> String? {
        let file = listsDir.appendingPathComponent(s.id + ".txt")
        let etagKey = "browser.adblock.etag." + s.id
        var req = URLRequest(url: s.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("GRID", forHTTPHeaderField: "User-Agent")
        if !force, FileManager.default.fileExists(atPath: file.path), let etag = UserDefaults.standard.string(forKey: etagKey) {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let cached = { try? String(contentsOf: file, encoding: .utf8) }
        guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return cached() }
        if http.statusCode == 304 { return cached() }
        guard http.statusCode == 200, data.count < 20_000_000, let text = String(data: data, encoding: .utf8) else { return cached() }
        try? data.write(to: file, options: .atomic)
        if let etag = http.value(forHTTPHeaderField: "ETag") { UserDefaults.standard.set(etag, forKey: etagKey) }
        return text
    }
}
