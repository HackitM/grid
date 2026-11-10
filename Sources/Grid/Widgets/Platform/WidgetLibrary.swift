import AppKit
import CoreServices
import Foundation
import GridCore
import Observation
import Security

/// Third-party widget packages on disk, their approvals, secrets, storage and logs.
///
///   ~/Library/Application Support/GRID/Widgets/Installed/<id>/   copied in by Install…, pinned by digest
///   ~/Library/Application Support/GRID/Widgets/Dev/<name>/       your own, hot-reloaded on save
///   ~/Library/Application Support/GRID/WidgetData/<ref>.json     each widget's grid.storage
///
/// A widget runs only when its approval matches: for installed packages the approval is pinned
/// to the package's SHA-256, so any edit disables it; for Dev packages it's pinned to the
/// declared permissions, so code edits reload but new permissions ask again.
@Observable
@MainActor
final class WidgetLibrary {
    struct Entry: Identifiable, Equatable {
        /// "installed:<id>" or "dev:<id>" (stored in the deck as the card's package).
        let ref: String
        let folder: URL
        let isDev: Bool
        let package: WidgetPackage?
        let error: String?
        var id: String { ref }
        var name: String { package?.manifest.name ?? folder.lastPathComponent }
    }

    struct Approval: Codable, Equatable {
        var digest: String?
        var permissions: String
        var approvedAt: Date
        var disabled = false
    }

    enum Status: Equatable {
        case ready, needsApproval, changed, disabled, invalid(String), missing
        var runnable: Bool { self == .ready }
    }

    struct LogLine: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let level: String
        let text: String
    }

    private(set) var entries: [Entry] = []
    private(set) var approvals: [String: Approval] = [:] { didSet { saveApprovals() } }
    /// Bumped when a package's files change, so running cards reload.
    private(set) var generation: [String: Int] = [:]
    private(set) var logs: [String: [LogLine]] = [:]

    /// Runtimes outlive their card views, so hiding the deck can stop them gracefully (and a quick
    /// re-show reuses the running process). Dropped when the card leaves the deck.
    @ObservationIgnored private var runtimes: [UUID: WidgetRuntime] = [:]

    func runtime(for card: UUID) -> WidgetRuntime {
        if let r = runtimes[card] { return r }
        let r = WidgetRuntime(instanceID: card)
        runtimes[card] = r
        return r
    }

    /// PIDs of running widget hosts (never valid targets for a widget's kill command).
    var hostPIDs: [Int32] { runtimes.values.compactMap(\.hostPID) }

    /// Stops and forgets runtimes whose cards were removed.
    func pruneRuntimes(keeping cards: Set<UUID>) {
        for (id, r) in runtimes where !cards.contains(id) {
            r.shutdown()
            runtimes[id] = nil
        }
    }

    @ObservationIgnored private var storage: [String: [String: WidgetJSON]] = [:]
    @ObservationIgnored private var storageSaves: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private let approvalsKey = "widgets.approvals.v1"

    nonisolated static let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // The QA build keeps its own widgets so testing never touches your real ones.
        .appendingPathComponent(Bundle.main.bundleIdentifier?.hasSuffix(".qa") == true ? "GRID-QA" : "GRID", isDirectory: true)
    nonisolated static let widgetsDir = base.appendingPathComponent("Widgets", isDirectory: true)
    nonisolated static let installedDir = widgetsDir.appendingPathComponent("Installed", isDirectory: true)
    nonisolated static let devDir = widgetsDir.appendingPathComponent("Dev", isDirectory: true)
    nonisolated static let dataDir = base.appendingPathComponent("WidgetData", isDirectory: true)

    init() {
        if let d = UserDefaults.standard.data(forKey: approvalsKey), let a = try? JSONDecoder().decode([String: Approval].self, from: d) {
            approvals = a
        }
        for d in [Self.installedDir, Self.devDir, Self.dataDir] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        reload()
        watch()
    }

    private func saveApprovals() {
        if let d = try? JSONEncoder().encode(approvals) { UserDefaults.standard.set(d, forKey: approvalsKey) }
    }

    // MARK: Scanning

    func reload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            let scanned = await Task.detached(priority: .utility) { Self.scan() }.value
            guard let self, !Task.isCancelled else { return }
            let old = Dictionary(uniqueKeysWithValues: self.entries.map { ($0.ref, $0.package?.digest) })
            for e in scanned where old[e.ref] != nil && old[e.ref] != e.package?.digest {
                self.generation[e.ref, default: 0] += 1
            }
            if scanned != self.entries { self.entries = scanned }
        }
    }

    nonisolated static func scan() -> [Entry] {
        var out: [Entry] = []
        for (dir, isDev) in [(installedDir, false), (devDir, true)] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names.sorted() where !name.hasPrefix(".") {
                let folder = dir.appendingPathComponent(name, isDirectory: true)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
                do {
                    let p = try WidgetPackage.load(folder)
                    out.append(Entry(ref: (isDev ? "dev:" : "installed:") + p.manifest.id, folder: folder, isDev: isDev, package: p, error: nil))
                } catch {
                    out.append(Entry(ref: (isDev ? "dev:" : "installed:") + "folder." + name, folder: folder, isDev: isDev, package: nil,
                                     error: (error as? WidgetPackage.LoadError)?.description ?? error.localizedDescription))
                }
            }
        }
        // Two folders claiming the same id: keep the first, report the rest.
        var seen = Set<String>()
        return out.map { e in
            if seen.insert(e.ref).inserted { return e }
            return Entry(ref: e.ref + "#" + e.folder.lastPathComponent, folder: e.folder, isDev: e.isDev, package: nil,
                         error: "Another widget already uses the id \(e.package?.manifest.id ?? "?").")
        }
    }

    func entry(_ ref: String) -> Entry? { entries.first { $0.ref == ref } }

    static func permissionsKey(_ p: WidgetPackage) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        // Settings matter too: a secret's allowed hosts is part of what you approve.
        struct Key: Encodable { let permissions: WidgetPermissions?; let secrets: [String: [String]] }
        let secrets = Dictionary(uniqueKeysWithValues: (p.manifest.settings ?? []).filter { $0.type == "secret" }.map { ($0.key, $0.hosts ?? []) })
        return (try? enc.encode(Key(permissions: p.manifest.permissions, secrets: secrets))).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func status(_ ref: String) -> Status {
        guard let e = entry(ref) else { return .missing }
        guard let p = e.package else { return .invalid(e.error ?? "Unreadable package.") }
        guard let a = approvals[ref] else { return .needsApproval }
        if e.isDev ? a.permissions != Self.permissionsKey(p) : a.digest != p.digest { return .changed }
        if a.disabled { return .disabled }
        return .ready
    }

    /// Approves `ref`, but only if it's still exactly the package that was reviewed.
    func approve(_ ref: String, reviewedDigest: String? = nil) {
        guard let e = entry(ref), let p = e.package else { return }
        if let d = reviewedDigest, d != p.digest { log(ref, "warn", "Not approved: the package changed while you were reviewing it."); return }
        approvals[ref] = Approval(digest: p.digest, permissions: Self.permissionsKey(p), approvedAt: Date())
        log(ref, "log", "Approved \(p.manifest.name) \(p.manifest.version).")
    }

    func setDisabled(_ ref: String, _ disabled: Bool) {
        guard var a = approvals[ref] else { return }
        a.disabled = disabled
        approvals[ref] = a
        if !disabled { generation[ref, default: 0] += 1 }   // restart cards
    }

    func revoke(_ ref: String) { approvals[ref] = nil }

    // MARK: Install / scaffold / remove

    /// Validates a folder the user picked; the caller shows the approval sheet before `install`.
    nonisolated static func inspect(_ folder: URL) -> Result<WidgetPackage, Error> {
        Result { try WidgetPackage.load(folder) }
    }

    /// Copies a package into Installed/<id> (replacing an older copy) and approves exactly what was copied.
    func install(_ pkg: WidgetPackage) throws -> String {
        let dest = Self.installedDir.appendingPathComponent(pkg.manifest.id, isDirectory: true)
        let staging = Self.installedDir.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        // Copy only the files GRID reads, recreated from the validated bytes (no links, no extras).
        let files = try WidgetPackage.collect(pkg.folder)
        for (rel, data) in files {
            let url = staging.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let copied = try WidgetPackage.load(staging)
        guard copied.digest == pkg.digest else { throw NSError(domain: "GRID", code: 2, userInfo: [NSLocalizedDescriptionKey: "The package changed while installing."]) }
        let ref = "installed:" + pkg.manifest.id
        if FileManager.default.fileExists(atPath: dest.path) {
            // A different package under the same id must not inherit the old one's secrets or data.
            if (try? WidgetPackage.load(dest))?.digest != pkg.digest {
                deleteSecrets(ref)
                forgetStorage(ref)
            }
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: staging, to: dest)
        approvals[ref] = Approval(digest: pkg.digest, permissions: Self.permissionsKey(pkg), approvedAt: Date())
        entries = Self.scan()
        generation[ref, default: 0] += 1
        return ref
    }

    /// Moves a package to the Trash and forgets its approval, secrets and storage.
    func remove(_ ref: String) {
        guard let e = entry(ref) else { return }
        try? FileManager.default.trashItem(at: e.folder, resultingItemURL: nil)
        approvals[ref] = nil
        deleteSecrets(ref)
        forgetStorage(ref)
        logs[ref] = nil
        entries = Self.scan()
    }

    /// Creates a starter package in Dev/ and approves its (minimal) permissions.
    func scaffold(name raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespaces).isEmpty ? "My Widget" : String(raw.trimmingCharacters(in: .whitespaces).prefix(40))
        var slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        if slug.isEmpty { slug = "widget" }
        var folder = Self.devDir.appendingPathComponent(slug, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) { folder = Self.devDir.appendingPathComponent("\(slug)-\(n)"); n += 1 }
        let id = "local.dev." + folder.lastPathComponent
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = """
        {
          "api": 1,
          "id": "\(id)",
          "name": "\(name.replacingOccurrences(of: "\"", with: ""))",
          "version": "0.1.0",
          "description": "A starter widget. Edit widget.js; GRID reloads it when you save.",
          "entry": "widget.js",
          "refresh": 0,
          "events": ["files.selection"],
          "settings": [
            { "key": "limit", "type": "number", "label": "Rows", "default": 5, "min": 1, "max": 20 }
          ],
          "permissions": {
            "files.selection": true,
            "terminal.insertPath": true
          }
        }
        """
        let script = """
        // \(name): see docs/WIDGETS.md for every builder and API call.
        grid.widget({
          async render(ctx) {
            const sel = await grid.files.selection();
            if (sel.length === 0) return grid.empty("Nothing selected", "Select files in the Files panel.");
            return grid.stack([
              grid.readout("SELECTED", String(sel.length)),
              grid.list(sel.slice(0, ctx.settings.limit).map((f) => ({
                title: f.name,
                subtitle: f.kind,
                icon: f.path,
                trailing: f.isFolder ? "DIR" : "",
                action: grid.action.insertPath(f.path),
              }))),
            ]);
          },
        });
        """
        try manifest.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try script.write(to: folder.appendingPathComponent("widget.js"), atomically: true, encoding: .utf8)
        try "# \(name)\n\nClick a row to insert that path at the terminal prompt.\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        entries = Self.scan()
        let ref = "dev:" + id
        approve(ref)
        return ref
    }

    // MARK: Hot reload (FSEvents on the widgets folder)

    private func watch() {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let lib = Unmanaged<WidgetLibrary>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { lib.reload() } }
        }
        guard let s = FSEventStreamCreate(nil, cb, &ctx, [Self.widgetsDir.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
        stream = s
    }

    // MARK: Logs (memory only)

    func log(_ ref: String, _ level: String, _ text: String) {
        var l = logs[ref] ?? []
        l.append(LogLine(date: Date(), level: level, text: String(text.prefix(2000))))
        if l.count > 200 { l.removeFirst(l.count - 200) }
        logs[ref] = l
    }

    func clearLogs(_ ref: String) { logs[ref] = [] }

    // MARK: Secrets (Keychain; never given to scripts)

    private static let keychainService = "GRID widget secret"

    func setSecret(_ ref: String, _ key: String, _ value: String?) {
        let account = ref + "/" + key
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        if let value, !value.isEmpty {
            var add = q
            add[kSecValueData as String] = Data(value.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
        secretPresence[account] = (value?.isEmpty == false)
    }

    /// Cached so the settings face can show "set / not set" without hitting the Keychain on every draw.
    private var secretPresence: [String: Bool] = [:]

    func hasSecret(_ ref: String, _ key: String) -> Bool {
        let account = ref + "/" + key
        if let p = secretPresence[account] { return p }
        let p = secret(ref, key) != nil
        secretPresence[account] = p
        return p
    }

    func secret(_ ref: String, _ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService,
                                kSecAttrAccount as String: ref + "/" + key, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func deleteSecrets(_ ref: String) {
        for s in entry(ref)?.package?.manifest.settings ?? [] where s.type == "secret" { setSecret(ref, s.key, nil) }
    }

    // MARK: Storage (grid.storage, 256 KiB per widget)

    static let storageQuota = 256 * 1024

    private func storageURL(_ ref: String) -> URL {
        let safe = ref.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? String($0) : "_" }.joined()
        return Self.dataDir.appendingPathComponent(safe + ".json")
    }

    func storageDict(_ ref: String) -> [String: WidgetJSON] {
        if let s = storage[ref] { return s }
        let s = (try? Data(contentsOf: storageURL(ref))).flatMap { try? JSONDecoder().decode([String: WidgetJSON].self, from: $0) } ?? [:]
        storage[ref] = s
        return s
    }

    /// Deletes a widget's stored data. A debounced write still waiting to run is cancelled first,
    /// or it would put the file back half a second after the widget was removed.
    private func forgetStorage(_ ref: String) {
        storageSaves.removeValue(forKey: ref)?.cancel()
        storage[ref] = nil
        try? FileManager.default.removeItem(at: storageURL(ref))
    }

    /// Applies a change; returns false (and changes nothing) if it would exceed the quota.
    func updateStorage(_ ref: String, _ change: (inout [String: WidgetJSON]) -> Void) -> Bool {
        var s = storageDict(ref)
        change(&s)
        let data = (try? JSONEncoder().encode(s)) ?? Data()
        guard data.count <= Self.storageQuota else { return false }
        storage[ref] = s
        // Writes are debounced so a chatty widget doesn't hammer the disk.
        storageSaves[ref]?.cancel()
        let url = storageURL(ref)
        storageSaves[ref] = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            try? data.write(to: url, options: [.atomic])
        }
        return true
    }
}
