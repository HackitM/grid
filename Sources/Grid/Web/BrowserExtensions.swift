import AppKit
import GridCore
import Observation
import WebKit

/// Browser extensions (Chrome/Safari WebExtensions) via WebKit's WKWebExtension API (macOS 15.4+).
///
/// Extensions are installed only from a folder or .zip the user picks, after a review listing what
/// they ask for; they're copied into GRID's own folder and loaded each launch. They act on web
/// pages (that's their job) but get nothing from GRID itself: no terminal, files or app launching.
@available(macOS 15.4, *)
@Observable
@MainActor
final class BrowserExtensions: NSObject {
    struct Installed: Codable, Identifiable, Equatable {
        var id: String          // context unique identifier
        var folder: String      // directory name under Extensions/
        var enabled: Bool
        /// What the user approved at install (WebKit keeps grants in memory only, so they're
        /// re-applied on every launch). Anything the extension asks for later is prompted.
        var permissions: [String] = []
        var matchPatterns: [String] = []

        init(id: String, folder: String, enabled: Bool, permissions: [String] = [], matchPatterns: [String] = []) {
            self.id = id; self.folder = folder; self.enabled = enabled; self.permissions = permissions; self.matchPatterns = matchPatterns
        }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id); folder = try c.decode(String.self, forKey: .folder)
            enabled = try c.decode(Bool.self, forKey: .enabled)
            permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
            matchPatterns = try c.decodeIfPresent([String].self, forKey: .matchPatterns) ?? []
        }
    }

    struct Item: Identifiable {
        let id: String
        let name: String
        let version: String
        let context: WKWebExtensionContext?
        let enabled: Bool
        let errors: [String]
    }

    private(set) var installed: [Installed] { didSet { save() } }
    private(set) var items: [Item] = []
    /// Bumped when an extension's toolbar action changes (icon, badge, enabled).
    private(set) var actionRevision = 0

    @ObservationIgnored let controller: WKWebExtensionController
    @ObservationIgnored private weak var model: BrowserModel?
    @ObservationIgnored private var tabAdapters: [UUID: ExtTab] = [:]
    @ObservationIgnored private lazy var window = ExtWindow(owner: self)
    @ObservationIgnored var popoverAnchors: [String: NSView] = [:]

    static var dir: URL { AdBlocker.dir.appendingPathComponent("Extensions", isDirectory: true) }

    init(model: BrowserModel) {
        self.model = model
        let cfg = WKWebExtensionController.Configuration(identifier: UUID(uuidString: "6F3C0000-0000-4000-8000-0000000E7E45")!)
        cfg.defaultWebsiteDataStore = model.dataStore
        controller = WKWebExtensionController(configuration: cfg)
        installed = (UserDefaults.standard.data(forKey: "browser.extensions")).flatMap { try? JSONDecoder().decode([Installed].self, from: $0) } ?? []
        super.init()
        controller.delegate = self
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        Task { await loadAll() }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(installed) { UserDefaults.standard.set(d, forKey: "browser.extensions") }
    }

    var hasAny: Bool { items.contains { $0.enabled && $0.context?.isLoaded == true } }

    /// Loaded, enabled extensions with a toolbar action, for the given tab.
    func actions(for tab: BrowserTab?) -> [(item: Item, action: WKWebExtension.Action)] {
        _ = actionRevision
        let t = tab.map(adapter)
        return items.compactMap { item in
            guard item.enabled, let c = item.context, c.isLoaded, let a = c.action(for: t) else { return nil }
            return (item, a)
        }
    }

    func perform(_ item: Item, tab: BrowserTab?) {
        item.context?.performAction(for: tab.map(adapter))
    }

    // MARK: Loading

    private func loadAll() async {
        var out: [Item] = []
        for entry in installed {
            out.append(await load(entry))
        }
        items = out
        // Let extensions know about tabs that already exist.
        model?.tabs.forEach { didOpen($0) }
        if let t = model?.active { didActivate(t) }
    }

    private func load(_ entry: Installed) async -> Item {
        let url = Self.dir.appendingPathComponent(entry.folder, isDirectory: true)
        do {
            guard UUID(uuidString: entry.folder) != nil else { throw NSError(domain: "GRID", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid extension folder."]) }
            try Self.validateTree(url)     // re-checked at every launch
            let ext = try await WKWebExtension(resourceBaseURL: url)
            let ctx = WKWebExtensionContext(for: ext)
            ctx.uniqueIdentifier = entry.id
            ctx.isInspectable = model?.settings.developerTools ?? false
            // Re-grant exactly what was approved at install, and only what the extension still asks for.
            for p in ext.requestedPermissions where entry.permissions.contains(p.rawValue) { ctx.setPermissionStatus(.grantedExplicitly, for: p) }
            for m in ext.allRequestedMatchPatterns where entry.matchPatterns.contains(m.string) { ctx.setPermissionStatus(.grantedExplicitly, for: m) }
            if entry.enabled { try controller.load(ctx) }
            return Item(id: entry.id, name: ext.displayName ?? entry.folder, version: ext.displayVersion ?? ext.version ?? "",
                        context: ctx, enabled: entry.enabled, errors: (ext.errors + ctx.errors).map(\.localizedDescription))
        } catch {
            return Item(id: entry.id, name: entry.folder, version: "", context: nil, enabled: entry.enabled, errors: [error.localizedDescription])
        }
    }

    // MARK: Install / remove

    /// Installs from a folder, .zip or .crx the user picked: unpack, check, review, copy, load.
    func install(from source: URL, app: AppState) async {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("grid-ext-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            // Unpacking and walking the tree can take seconds for a large extension: off the main thread.
            let root = try await BlockingWork.run { Result { try Self.unpackedRoot(of: source, staging: staging) } }.get()
            let probe = try await WKWebExtension(resourceBaseURL: root)
            let name = probe.displayName ?? root.lastPathComponent
            let perms = probe.requestedPermissions.map(\.rawValue).sorted()
            let hosts = probe.allRequestedMatchPatterns.map(\.string).sorted()
            guard await confirm(app, name: name, version: probe.displayVersion ?? "", perms: perms, hosts: hosts) else { return }
            let id = UUID().uuidString
            let dest = Self.dir.appendingPathComponent(id, isDirectory: true)
            try await BlockingWork.run { Result { try Self.copyValidated(root, to: dest) } }.get()
            // Approve exactly what was reviewed (re-applied on every launch by `load`).
            let entry = Installed(id: id, folder: id, enabled: true, permissions: perms, matchPatterns: hosts)
            installed.append(entry)
            let item = await load(entry)
            items.append(item)
            model?.tabs.forEach { didOpen($0) }
            app.flash(.info, "Installed \(name)")
        } catch {
            app.flash(.error, "Couldn't install: \(error.localizedDescription)")
        }
    }

    nonisolated private static func failure(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "GRID", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// The folder holding manifest.json: `source` itself, or an archive unpacked into `staging`.
    /// The tree is validated before it is returned. Runs off the main thread.
    nonisolated private static func unpackedRoot(of source: URL, staging: URL) throws -> URL {
        let fm = FileManager.default
        var root = source
        let kind = source.pathExtension.lowercased()
        if kind == "zip" || kind == "crx" {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let zip = kind == "crx" ? try stripCRXHeader(source, into: staging) : source
            root = staging.appendingPathComponent("x")
            try unzip(zip, to: root)
            // An archive with a single top folder: use it.
            if !fm.fileExists(atPath: root.appendingPathComponent("manifest.json").path),
               let only = try? fm.contentsOfDirectory(atPath: root.path).filter({ !$0.hasPrefix(".") }), only.count == 1 {
                root = root.appendingPathComponent(only[0])
            }
        }
        guard fm.fileExists(atPath: root.appendingPathComponent("manifest.json").path) else {
            throw failure(2, "No manifest.json: not a browser extension.")
        }
        try validateTree(root)
        return root
    }

    /// Unpacks with ditto, run directly with an argument list (no shell). Links inside the
    /// archive are extracted as links and then refused by `validateTree`.
    nonisolated private static func unzip(_ zip: URL, to destination: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, destination.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw failure(1, "Couldn't unpack the archive.") }
    }

    /// Copies the reviewed tree into GRID's folder and checks the copy too, in case the source
    /// changed between the review and the copy. Runs off the main thread.
    nonisolated private static func copyValidated(_ root: URL, to dest: URL) throws {
        try FileManager.default.copyItem(at: root, to: dest)
        do { try validateTree(dest) } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }

    private func confirm(_ app: AppState, name: String, version: String, perms: [String], hosts: [String]) async -> Bool {
        var lines: [String] = []
        if hosts.contains(where: { $0 == "<all_urls>" || $0.hasPrefix("*://*/") || $0 == "*://*/*" }) {
            lines.append("△ Read and change every website you visit")
        } else if !hosts.isEmpty {
            lines.append("△ Read and change: " + hosts.prefix(6).joined(separator: ", ") + (hosts.count > 6 ? " +\(hosts.count - 6) more" : ""))
        }
        if !perms.isEmpty { lines.append("Uses: " + perms.joined(separator: ", ")) }
        lines.append("It runs only inside GRID's browser and can't reach your terminal, files or apps.")
        return await withCheckedContinuation { c in
            let shown = app.present(Confirmation(code: "EXT.INSTALL", title: "Install “\(name)” \(version)?",
                                                 message: lines.joined(separator: "\n"), confirmLabel: "Install", destructive: false,
                                                 onConfirm: { c.resume(returning: true) }, onCancel: { c.resume(returning: false) }))
            if !shown { c.resume(returning: false) }
        }
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let i = installed.firstIndex(where: { $0.id == id }), let j = items.firstIndex(where: { $0.id == id }) else { return }
        installed[i].enabled = on
        if let ctx = items[j].context {
            if on { try? controller.load(ctx); model?.tabs.forEach { didOpen($0) } } else { try? controller.unload(ctx) }
        }
        let it = items[j]
        items[j] = Item(id: it.id, name: it.name, version: it.version, context: it.context, enabled: on, errors: it.errors)
    }

    func remove(_ id: String) {
        if let it = items.first(where: { $0.id == id }), let ctx = it.context, ctx.isLoaded { try? controller.unload(ctx) }
        if let e = installed.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(e.folder, isDirectory: true))
        }
        installed.removeAll { $0.id == id }
        items.removeAll { $0.id == id }
    }

    /// An extension may contain only regular files and folders: a symbolic link (or a special
    /// file) could let it serve files from outside its folder, e.g. `l -> ~/.ssh`.
    nonisolated static func validateTree(_ root: URL) throws {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey],
                                                     options: [], errorHandler: { _, _ in false }) else {
            throw NSError(domain: "GRID", code: 6, userInfo: [NSLocalizedDescriptionKey: "Couldn't read the extension."])
        }
        var count = 0
        for case let u as URL in e {
            count += 1
            guard count < 20_000 else { throw NSError(domain: "GRID", code: 7, userInfo: [NSLocalizedDescriptionKey: "Extension has too many files."]) }
            let v = try u.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            if v.isSymbolicLink == true || !(v.isRegularFile == true || v.isDirectory == true) {
                throw NSError(domain: "GRID", code: 8, userInfo: [NSLocalizedDescriptionKey: "The extension contains a link or special file (\(u.lastPathComponent)), which isn't allowed."])
            }
            guard u.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base + "/") else {
                throw NSError(domain: "GRID", code: 9, userInfo: [NSLocalizedDescriptionKey: "The extension contains a file outside its folder."])
            }
        }
    }

    /// CRX3: "Cr24" + version + header length + header, then a zip.
    nonisolated static func stripCRXHeader(_ crx: URL, into dir: URL) throws -> URL {
        let d = try Data(contentsOf: crx)
        guard d.count > 16, d.prefix(4) == Data("Cr24".utf8) else { throw NSError(domain: "GRID", code: 3, userInfo: [NSLocalizedDescriptionKey: "Not a .crx file."]) }
        let version = d.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        var offset: Int
        if version == 3 {
            let hl = Int(d.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            offset = 12 + hl
        } else {
            let kl = Int(d.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            let sl = Int(d.subdata(in: 12..<16).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            offset = 16 + kl + sl
        }
        guard offset < d.count else { throw NSError(domain: "GRID", code: 4, userInfo: [NSLocalizedDescriptionKey: "Damaged .crx file."]) }
        let out = dir.appendingPathComponent("ext.zip")
        try d.subdata(in: offset..<d.count).write(to: out)
        return out
    }

    // MARK: Tabs (keep extensions informed)

    fileprivate func adapter(_ tab: BrowserTab) -> ExtTab {
        if let a = tabAdapters[tab.id] { return a }
        let a = ExtTab(tab: tab, owner: self)
        tabAdapters[tab.id] = a
        return a
    }

    fileprivate var browserTabs: [BrowserTab] { model?.tabs ?? [] }
    fileprivate var activeBrowserTab: BrowserTab? { model?.active }
    fileprivate var browserModel: BrowserModel? { model }

    func didOpen(_ tab: BrowserTab) {
        guard !items.isEmpty else { return }
        controller.didOpenTab(adapter(tab))
    }

    func didClose(_ tab: BrowserTab) {
        guard let a = tabAdapters.removeValue(forKey: tab.id) else { return }
        controller.didCloseTab(a, windowIsClosing: false)
    }

    func didActivate(_ tab: BrowserTab) {
        guard !items.isEmpty else { return }
        controller.didActivateTab(adapter(tab), previousActiveTab: nil)
    }

    func didChange(_ tab: BrowserTab) {
        guard !items.isEmpty, let a = tabAdapters[tab.id] else { return }
        controller.didChangeTabProperties([.URL, .title, .loading], for: a)
    }
}

// MARK: - Controller delegate

@available(macOS 15.4, *)
extension BrowserExtensions: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        guard let model else { completionHandler(nil, nil); return }
        if let url = configuration.url {
            let isExtensionPage = url.scheme == "webkit-extension" && extensionContext.baseURL.host == url.host
            guard isExtensionPage || BrowserNavigationPolicy.decide(url, isMainFrame: true, userInitiated: true) == .allow else {
                completionHandler(nil, NSError(domain: "GRID", code: 10, userInfo: [NSLocalizedDescriptionKey: "That address can't be opened."])); return
            }
            if isExtensionPage {
                let tab = model.newTab(nil, activate: configuration.shouldBeActive, configuration: extensionContext.webViewConfiguration)
                tab.allowExtensionPageOnce = true
                tab.webView.load(URLRequest(url: url))
                completionHandler(adapter(tab), nil); return
            }
        }
        let tab = model.newTab(configuration.url, activate: configuration.shouldBeActive)
        completionHandler(adapter(tab), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        if let url = extensionContext.optionsPageURL, let model {
            let tab = model.newTab(nil, activate: true, configuration: extensionContext.webViewConfiguration)
            tab.allowExtensionPageOnce = true
            tab.webView.load(URLRequest(url: url))
            model.app?.show(.web)
        }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let name = extensionContext.webExtension.displayName ?? "An extension"
        ask("\(name) wants more access", "Permissions: " + permissions.map(\.rawValue).sorted().joined(separator: ", ")) {
            completionHandler($0 ? permissions : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let name = extensionContext.webExtension.displayName ?? "An extension"
        ask("\(name) wants to access sites", urls.compactMap(\.host).sorted().joined(separator: ", ")) {
            completionHandler($0 ? urls : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let name = extensionContext.webExtension.displayName ?? "An extension"
        ask("\(name) wants to access sites", matchPatterns.map(\.string).sorted().joined(separator: ", ")) {
            completionHandler($0 ? matchPatterns : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        actionRevision &+= 1
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popover = action.popupPopover else { completionHandler(nil); return }
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.behavior = .transient
        if let anchor = popoverAnchors[context.uniqueIdentifier], anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let content = NSApp.keyWindow?.contentView {
            popover.show(relativeTo: NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - 80, width: 1, height: 1), of: content, preferredEdge: .minY)
        }
        completionHandler(nil)
    }

    private func ask(_ title: String, _ message: String, _ done: @escaping (Bool) -> Void) {
        guard let app = model?.app else { done(false); return }
        let shown = app.present(Confirmation(code: "EXT.PERMISSION", title: title, message: message, confirmLabel: "Allow",
                                             destructive: false, onConfirm: { done(true) }, onCancel: { done(false) }))
        if !shown { done(false) }
    }
}

// MARK: - Adapters (WebKit's tab/window protocols are Objective-C)

@available(macOS 15.4, *)
@MainActor
final class ExtTab: NSObject, WKWebExtensionTab {
    weak var tab: BrowserTab?
    weak var owner: BrowserExtensions?
    init(tab: BrowserTab, owner: BrowserExtensions) { self.tab = tab; self.owner = owner }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        owner.map { $0.windowAdapter }
    }
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab, let owner else { return 0 }
        return owner.browserTabs.firstIndex { $0.id == tab.id } ?? 0
    }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { tab?.isLoaded == true ? tab?.webView : nil }
    func title(for context: WKWebExtensionContext) -> String? { tab?.title }
    func url(for context: WKWebExtensionContext) -> URL? { tab?.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(tab?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { tab?.id == owner?.activeBrowserTab?.id }
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let tab { owner?.browserModel?.select(tab.id) }
        completionHandler(nil)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let tab { owner?.browserModel?.close(tab.id) }
        completionHandler(nil)
    }
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if BrowserNavigationPolicy.decide(url, isMainFrame: true, userInitiated: true) == .allow { tab?.load(url) }
        completionHandler(nil)
    }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.reload(); completionHandler(nil)
    }
    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) { tab?.goBack(); completionHandler(nil) }
    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) { tab?.goForward(); completionHandler(nil) }
}

@available(macOS 15.4, *)
extension BrowserExtensions {
    fileprivate var windowAdapter: ExtWindow { window }
}

@available(macOS 15.4, *)
@MainActor
final class ExtWindow: NSObject, WKWebExtensionWindow {
    weak var owner: BrowserExtensions?
    init(owner: BrowserExtensions) { self.owner = owner }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let owner else { return [] }
        return owner.browserTabs.map { owner.adapter($0) }
    }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let owner, let t = owner.activeBrowserTab else { return nil }
        return owner.adapter(t)
    }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { NSApp.mainWindow?.frame ?? .zero }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { NSApp.mainWindow?.screen?.frame ?? .zero }
    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        owner?.browserModel?.app?.show(.web); completionHandler(nil)
    }
}
