import AppKit
import GridCore
import Observation
import UniformTypeIdentifiers
import WebKit

/// GRID's embedded browser (WebKit). Security model (docs/ARCHITECTURE.md §Web):
/// - Web pages get **no bridge** into GRID: no script message handlers, no shared state with the
///   terminal, files or app launcher. GRID's own scripts (site themes, reader extraction) run in
///   isolated content worlds and only ever return data to GRID when GRID asks.
/// - Only http(s) loads inside; other schemes are refused or handed to macOS after a click and a
///   confirmation. Top-level `data:` and all `file:` / `javascript:` navigations are refused.
/// - Browsing data lives in its own persistent store, separate from anything else, and can be
///   cleared in Settings › Browser. Nothing is sent anywhere by GRID itself.
/// - Downloads always ask first and are quarantined like Safari downloads.
@Observable
@MainActor
final class BrowserModel {
    private(set) var tabs: [BrowserTab] = []
    var activeID: UUID? { didSet { if !initializing { activeTabChanged() } } }
    /// @Observable runs didSet even inside init; restored tabs must not load until the Web page shows.
    @ObservationIgnored private var initializing = true
    /// Address bar focus request (⌘L).
    var focusAddressToken = 0
    var findVisible = false

    let settings = BrowserSettings()
    let adBlocker = AdBlocker()
    let themes = SiteThemes()
    /// Every tab's downloads (kept here so a download outlives the tab that started it).
    @ObservationIgnored let downloads = BrowserDownloads()
    /// Visit history for the new-tab page (local only; cleared with browsing data).
    private(set) var history: [HistoryItem] = []

    @ObservationIgnored weak var app: AppState?
    @ObservationIgnored let dataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "6F3C0000-0000-4000-8000-00000000B0B5")!)
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var extensionsBox: AnyObject?
    /// Last real click or keypress inside a page (to tell user-driven navigations from scripted ones).
    @ObservationIgnored private(set) var lastUserInteraction = Date.distantPast
    @ObservationIgnored private var interactionMonitor: Any?

    struct HistoryItem: Codable, Equatable, Identifiable {
        var url: String
        var title: String
        var date: Date
        var id: String { url }
    }

    var active: BrowserTab? { tabs.first { $0.id == activeID } }

    init() {
        if let d = UserDefaults.standard.data(forKey: "browser.history"), let h = try? JSONDecoder().decode([HistoryItem].self, from: d) {
            history = h
        }
        // Before any web view exists: every page's configuration needs the extension controller.
        if #available(macOS 15.4, *) { extensionsBox = BrowserExtensions(model: self) }
        // Restore the last session's tabs without loading them (each loads when first shown).
        for s in UserDefaults.standard.stringArray(forKey: "browser.tabs") ?? [] {
            if let u = URL(string: s), BrowserNavigationPolicy.decide(u, isMainFrame: true, userInitiated: true) == .allow {
                tabs.append(BrowserTab(model: self, pendingURL: u))
            }
        }
        activeID = tabs.first?.id
        downloads.model = self
        adBlocker.onChange = { [weak self] in self?.tabs.forEach { $0.applyContentBlocking() } }
        themes.onChange = { [weak self] in self?.tabs.forEach { $0.refreshThemeScripts() } }
        initializing = false
    }

    func attach(_ app: AppState) {
        self.app = app
        adBlocker.start()
        interactionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) { [weak self] e in
            MainActor.assumeIsolated {
                if let w = self?.active?.webViewIfLoaded, e.window === w.window,
                   e.type == .keyDown || w.bounds.contains(w.convert(e.locationInWindow, from: nil)) {
                    self?.lastUserInteraction = Date()
                }
            }
            return e
        }
    }

    var recentlyInteracted: Bool { Date().timeIntervalSince(lastUserInteraction) < 2 }

    @available(macOS 15.4, *)
    var extensions: BrowserExtensions? { extensionsBox as? BrowserExtensions }

    // MARK: Tabs

    @discardableResult
    func newTab(_ url: URL? = nil, activate: Bool = true, configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let tab = BrowserTab(model: self, pendingURL: url, configuration: configuration)
        if let i = tabs.firstIndex(where: { $0.id == activeID }) { tabs.insert(tab, at: i + 1) } else { tabs.append(tab) }
        if activate { activeID = tab.id }
        if #available(macOS 15.4, *) { extensions?.didOpen(tab) }
        scheduleSave()
        return tab
    }

    func close(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: i)
        if #available(macOS 15.4, *) { extensions?.didClose(tab) }
        tab.tearDown()
        if activeID == id { activeID = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id }
        scheduleSave()
    }

    func select(_ id: UUID) { if tabs.contains(where: { $0.id == id }) { activeID = id } }

    func cycle(_ delta: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == activeID }), !tabs.isEmpty else { return }
        activeID = tabs[(i + delta + tabs.count) % tabs.count].id
    }

    func move(_ id: UUID, before target: UUID?) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let t = tabs.remove(at: from)
        if let target, let to = tabs.firstIndex(where: { $0.id == target }) { tabs.insert(t, at: to) } else { tabs.append(t) }
        scheduleSave()
    }

    private func activeTabChanged() {
        active?.activate()
        if #available(macOS 15.4, *), let t = active { extensions?.didActivate(t) }
    }

    /// Opens typed text (address or search) in the active tab, or a new one.
    func go(_ text: String, newTab: Bool = false) {
        switch BrowserAddress.interpret(text, engine: settings.searchEngine) {
        case .open(let u), .search(let u):
            if newTab || active == nil { self.newTab(u) } else { active?.load(u) }
        case .refused(let why):
            app?.flash(.error, why)
        }
    }

    /// Reader view on/off for the active tab.
    func toggleReader() async {
        guard let tab = active else { return }
        if tab.reader != nil { tab.reader = nil; return }
        guard tab.isLoaded else { return }
        if let a = await Reader.extract(from: tab.webView) { tab.reader = a } else {
            app?.flash(.error, "No article found on this page for reader view.")
        }
    }

    func open(_ url: URL, newTab: Bool = true) {
        if newTab || active == nil { self.newTab(url) } else { active?.load(url) }
        app?.show(.web)
    }

    // MARK: History + persistence

    func recordVisit(_ url: URL, title: String) {
        guard url.scheme == "https" || url.scheme == "http" else { return }
        history.removeAll { $0.url == url.absoluteString }
        history.insert(HistoryItem(url: url.absoluteString, title: title, date: Date()), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        scheduleSave()
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            UserDefaults.standard.set(self.tabs.compactMap { ($0.url ?? $0.pendingURL)?.absoluteString }, forKey: "browser.tabs")
            if let d = try? JSONEncoder().encode(self.history) { UserDefaults.standard.set(d, forKey: "browser.history") }
        }
    }

    /// Clears cookies, caches, site storage and history (Settings › Browser).
    func clearBrowsingData() async {
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        history = []
        UserDefaults.standard.removeObject(forKey: "browser.history")
    }

    // MARK: Configuration

    func makeConfiguration(base: WKWebViewConfiguration? = nil) -> WKWebViewConfiguration {
        let c = base ?? WKWebViewConfiguration()
        c.websiteDataStore = dataStore
        // Each tab has its own controller so per-site blocking and themes never leak across tabs.
        c.userContentController = WKUserContentController()
        c.preferences.isFraudulentWebsiteWarningEnabled = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        c.preferences.isElementFullscreenEnabled = true
        c.mediaTypesRequiringUserActionForPlayback = .audio
        c.applicationNameForUserAgent = "Version/18.4 Safari/605.1.15"
        if #available(macOS 15.4, *), let ext = extensions { c.webExtensionController = ext.controller }
        return c
    }
}

/// Browser preferences (UserDefaults).
@Observable
@MainActor
final class BrowserSettings {
    private let d = UserDefaults.standard
    var searchEngine: SearchEngine { didSet { d.set(searchEngine.rawValue, forKey: "browser.search") } }
    /// Ask sites for their dark designs (prefers-color-scheme: dark).
    var requestDark: Bool { didSet { d.set(requestDark, forKey: "browser.dark") } }
    /// Links opened from the palette and terminal open in GRID's browser (else the default browser).
    var openLinksInGRID: Bool { didSet { d.set(openLinksInGRID, forKey: "browser.openInGRID") } }
    var developerTools: Bool { didSet { d.set(developerTools, forKey: "browser.devtools") } }

    init() {
        d.register(defaults: ["browser.search": SearchEngine.duckduckgo.rawValue, "browser.dark": true,
                              "browser.openInGRID": true, "browser.devtools": false])
        searchEngine = SearchEngine(rawValue: d.string(forKey: "browser.search") ?? "") ?? .duckduckgo
        requestDark = d.bool(forKey: "browser.dark")
        openLinksInGRID = d.bool(forKey: "browser.openInGRID")
        developerTools = d.bool(forKey: "browser.devtools")
    }
}

// MARK: - Tab

@Observable
@MainActor
final class BrowserTab: Identifiable {
    let id = UUID()
    private(set) var title = ""
    private(set) var url: URL?
    private(set) var progress: Double = 0
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isSecure = false
    private(set) var loadError: String?
    /// The last main-frame load was stopped by ad blocking (the address is on a filter list).
    private(set) var blockedByFilter = false
    /// The address that failed to load (a failed load never becomes `url`).
    private(set) var failedURL: URL?
    /// Reader view (extracted article drawn in GRID's style).
    var reader: ReaderArticle?
    var readerError: String?
    /// Address not loaded yet (restored tab, or created in the background).
    @ObservationIgnored private(set) var pendingURL: URL?

    @ObservationIgnored private weak var model: BrowserModel?
    @ObservationIgnored private var configuration: WKWebViewConfiguration?
    @ObservationIgnored private var _webView: WKWebView?
    @ObservationIgnored private var coordinator: BrowserTabCoordinator?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// The rule lists currently installed in this tab's content controller.
    @ObservationIgnored private var appliedRuleLists: [WKContentRuleList] = []
    @ObservationIgnored var alertTimes: [Date] = []

    init(model: BrowserModel, pendingURL: URL?, configuration: WKWebViewConfiguration? = nil) {
        self.model = model
        self.pendingURL = pendingURL
        self.configuration = configuration
        self.url = pendingURL
        self.title = pendingURL.flatMap(SiteKey.of) ?? ""
        // A popup WebKit asked for must get its web view right away.
        if configuration != nil { _ = webView }
    }

    var isLoaded: Bool { _webView != nil }
    var webViewIfLoaded: WKWebView? { _webView }
    /// One-shot permission for GRID/extension-initiated loads of extension pages (webkit-extension:).
    @ObservationIgnored var allowExtensionPageOnce = false
    @ObservationIgnored var crashReloads: [Date] = []

    /// The page's web view, created on first use.
    var webView: WKWebView {
        if let w = _webView { return w }
        let model = model!
        let config = model.makeConfiguration(base: configuration)
        configuration = nil
        // Added before the web view exists, so nothing has to be removed from its content
        // controller afterwards (see `refreshThemeScripts` for why removing is best avoided).
        config.userContentController.addUserScript(themeScript(model))
        let w = GridWebView(frame: .zero, configuration: config)
        w.allowsBackForwardNavigationGestures = true
        w.allowsMagnification = true
        w.isInspectable = model.settings.developerTools
        let c = BrowserTabCoordinator(tab: self)
        coordinator = c
        w.navigationDelegate = c
        w.uiDelegate = c
        _webView = w
        applyAppearance()
        refreshThemeState()
        observe(w)
        return w
    }

    /// A new tab that hasn't been pointed anywhere yet: shows the new tab page instead of a web view.
    var isBlank: Bool {
        url == nil && pendingURL == nil && !isLoading && loadError == nil && reader == nil && (_webView?.url == nil)
    }

    func activate() {
        if let u = pendingURL {
            pendingURL = nil
            load(u)
        }
    }

    func load(_ url: URL) {
        reader = nil
        loadError = nil
        pendingURL = nil
        prepareBlocking(for: url)
        webView.load(URLRequest(url: url))
    }

    func reload() {
        reader = nil; loadError = nil
        if let f = failedURL { failedURL = nil; load(f); return }    // retry what failed, not the page before it
        if isLoaded { webView.reload() } else { activate() }
    }
    func stop() { _webView?.stopLoading() }
    func goBack() { reader = nil; _webView?.goBack() }
    func goForward() { reader = nil; _webView?.goForward() }

    func tearDown() {
        observations.removeAll()
        _webView?.stopLoading()
        _webView?.navigationDelegate = nil
        _webView?.uiDelegate = nil
        _webView?.removeFromSuperview()
        _webView = nil
        appliedRuleLists = []
    }

    private func observe(_ w: WKWebView) {
        func on<V>(_ kp: KeyPath<WKWebView, V>, _ apply: @escaping (BrowserTab, WKWebView) -> Void) {
            observations.append(w.observe(kp, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { if let self { apply(self, wv) } }
            })
        }
        on(\.title) { t, wv in t.title = wv.title?.isEmpty == false ? wv.title! : (SiteKey.of(wv.url) ?? "") }
        on(\.url) { t, wv in
            t.url = wv.url
            t.model?.scheduleSave()
            t.refreshThemeState()
        }
        on(\.estimatedProgress) { t, wv in t.progress = wv.estimatedProgress }
        on(\.isLoading) { t, wv in t.isLoading = wv.isLoading }
        on(\.canGoBack) { t, wv in t.canGoBack = wv.canGoBack }
        on(\.canGoForward) { t, wv in t.canGoForward = wv.canGoForward }
        on(\.hasOnlySecureContent) { t, wv in t.isSecure = wv.hasOnlySecureContent && wv.url?.scheme == "https" }
    }

    // MARK: Appearance + themes

    func applyAppearance() {
        guard let w = _webView, let model else { return }
        w.appearance = model.settings.requestDark ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
        if let app = model.app { w.underPageBackgroundColor = NSColor(app.settings.themeValue.bg1) }
    }

    /// Whether a GRID theme is currently applied to this page.
    private(set) var themeActive = false

    var themeEntry: SiteThemeEntry? { SiteThemeCatalog.entry(for: url) }

    private func themeScript(_ model: BrowserModel) -> WKUserScript {
        model.themes.userScript(theme: model.app?.settings.themeValue ?? Theme.make(.legacy))
    }

    /// Replaces the theme script after a theme or per-site setting changed. WebKit can only remove
    /// user scripts all at once, which also drops scripts other parts of WebKit added to this
    /// controller, so this runs only on an actual change, never when a tab is created.
    func refreshThemeScripts() {
        guard let w = _webView, let model else { return }
        let ucc = w.configuration.userContentController
        ucc.removeAllUserScripts()
        let script = themeScript(model)
        ucc.addUserScript(script)
        refreshThemeState()
        // Apply to the page that's already loaded too (the user script only runs on the next load).
        if w.url != nil { w.evaluateJavaScript(script.source, in: nil, in: SiteThemes.world) { _ in } }
    }

    private func refreshThemeState() {
        guard let model else { return }
        themeActive = themeEntry.map { model.themes.isEnabled($0.id) } ?? false
    }

    func setThemeEnabled(_ on: Bool) {
        guard let e = themeEntry, let model else { return }
        model.themes.setEnabled(e.id, on)    // onChange refreshes every tab
    }

    // MARK: Content blocking

    /// Adds or removes the ad-blocking rule lists for the page about to load. Called for every
    /// main-frame navigation, so it does nothing when the right lists are already installed:
    /// re-adding them made WebKit hand every list to the page's processes again on each click.
    func prepareBlocking(for url: URL?) {
        guard let w = _webView, let model else { return }
        let wanted = model.adBlocker.shouldBlock(on: SiteKey.of(url)) ? model.adBlocker.ruleLists : []
        guard !wanted.elementsEqual(appliedRuleLists, by: ===) else { return }
        let ucc = w.configuration.userContentController
        ucc.removeAllContentRuleLists()
        wanted.forEach { ucc.add($0) }
        appliedRuleLists = wanted
    }

    /// Re-applies blocking after settings or lists change (takes effect on the next load).
    func applyContentBlocking() { prepareBlocking(for: url) }

    var blockingActive: Bool { model?.adBlocker.shouldBlock(on: SiteKey.of(url)) ?? false }

    // MARK: Find + zoom

    func find(_ text: String, backwards: Bool = false) async -> Bool {
        guard let w = _webView, !text.isEmpty else { return false }
        let c = WKFindConfiguration()
        c.backwards = backwards
        c.wraps = true
        c.caseSensitive = false
        return (try? await w.find(text, configuration: c).matchFound) ?? false
    }

    func zoom(_ delta: Double?) {
        guard let w = _webView else { return }
        w.pageZoom = delta.map { min(max(w.pageZoom + $0, 0.5), 3) } ?? 1
    }

    // MARK: Called by the coordinator

    func didFinish() {
        loadError = nil
        blockedByFilter = false
        failedURL = nil
        if let u = url { model?.recordVisit(u, title: title) }
    }

    func didFail(_ error: Error) {
        let e = error as NSError
        if e.code == NSURLErrorCancelled || (e.domain == "WebKitErrorDomain" && e.code == 102) { return }   // cancelled / policy change
        failedURL = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? (e.userInfo["NSErrorFailingURLKey"] as? URL)
        // WebKit error 104: the load was blocked by a content blocker (our filter lists).
        blockedByFilter = e.domain == "WebKitErrorDomain" && e.code == 104
        loadError = blockedByFilter
            ? "This address is on an ad or tracker filter list, so ad blocking stopped it. If you trust it, turn blocking off for this site."
            : e.localizedDescription
    }

    var browserModel: BrowserModel? { model }
}

// MARK: - Delegate

@MainActor
final class BrowserTabCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var tab: BrowserTab?

    init(tab: BrowserTab) { self.tab = tab }

    private var model: BrowserModel? { tab?.browserModel }
    private var app: AppState? { model?.app }

    // MARK: Navigation policy

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = action.request.url else { return (.cancel, preferences) }
        let isMain = action.targetFrame?.isMainFrame ?? true
        // Extension pages: only when GRID or an extension opened them, or from another extension page.
        if url.scheme == "webkit-extension" {
            let fromExtension = action.sourceFrame.securityOrigin.protocol == "webkit-extension"
            if tab?.allowExtensionPageOnce == true || fromExtension {
                tab?.allowExtensionPageOnce = false
                return (.allow, preferences)
            }
            return (.cancel, preferences)
        }
        // A click on a link, or anything within 2 s of a real click/keypress in the page; scripted
        // navigations (e.g. form.submit() on load) don't count.
        let user = action.navigationType == .linkActivated || (model?.recentlyInteracted ?? false)
        let decision = BrowserNavigationPolicy.decide(url, isMainFrame: isMain, userInitiated: user)
        if action.shouldPerformDownload { return (decision == .allow ? .download : .cancel, preferences) }
        switch decision {
        case .allow:
            if isMain { tab?.prepareBlocking(for: url) }
            // ⌘-click / middle-click: background tab.
            if action.navigationType == .linkActivated && (action.modifierFlags.contains(.command) || action.buttonNumber == 4) {
                model?.newTab(url, activate: action.modifierFlags.contains(.shift))
                return (.cancel, preferences)
            }
            return (.allow, preferences)
        case .askToOpenExternally(let scheme):
            askToOpenExternally(url, scheme: scheme)
            return (.cancel, preferences)
        case .refuse(let why):
            if isMain { app?.flash(.error, why) }
            return (.cancel, preferences)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if response.isForMainFrame, !response.canShowMIMEType { return .download }
        if let http = response.response as? HTTPURLResponse,
           (http.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    // Downloads are handed to the browser's own delegate, which outlives this tab (BrowserDownloads).
    // Without a model there is nobody to confirm or quarantine, so the download is cancelled.
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { adopt(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { adopt(download) }

    private func adopt(_ download: WKDownload) {
        if let downloads = model?.downloads { downloads.adopt(download) } else { download.cancel { _ in } }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { tab?.didFinish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { tab?.didFail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { tab?.didFail(error) }
    /// The page's process crashed: reload the visible tab at most twice a minute, else show an error.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab else { return }
        let now = Date()
        tab.crashReloads = tab.crashReloads.filter { now.timeIntervalSince($0) < 60 }
        if tab.id == model?.activeID, tab.crashReloads.count < 2 {
            tab.crashReloads.append(now)
            webView.reload()
        } else {
            tab.didFail(NSError(domain: "GRID", code: 1, userInfo: [NSLocalizedDescriptionKey: "This page stopped working (its process crashed). Try again when you're ready."]))
        }
    }

    private func askToOpenExternally(_ url: URL, scheme: String) {
        guard let app else { return }
        let appName = NSWorkspace.shared.urlForApplication(toOpen: url).map { $0.deletingPathExtension().lastPathComponent } ?? "another app"
        _ = app.present(Confirmation(code: "WEB.EXTERNAL", title: "Open in \(appName)?",
                                     message: "A page wants to open a \(scheme): link:\n\(String(url.absoluteString.prefix(200)))",
                                     confirmLabel: "Open", destructive: false, onConfirm: { NSWorkspace.shared.open(url) }))
    }

    // MARK: Popups

    // Only for user-initiated window.open/target=_blank (WebKit enforces the gesture).

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let model, let url = action.request.url else { return nil }
        // about:blank popups are allowed (pages fill them in); anything else follows the normal rules.
        if url.absoluteString != "about:blank" && !url.absoluteString.isEmpty,
           BrowserNavigationPolicy.decide(url, isMainFrame: true, userInitiated: true) != .allow { return nil }
        let tab = model.newTab(nil, activate: true, configuration: configuration)
        let w = tab.webView
        tab.prepareBlocking(for: url)     // before WebKit starts the popup's first load
        return w
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let t = tab { model?.close(t.id) }
    }

    // MARK: Page dialogs

    // Drawn by GRID, clearly labelled as coming from the page; rate-limited.

    /// Who's talking: the frame's host, else the page's, else "This page" (blank/sandboxed frames).
    static func origin(_ frame: WKFrameInfo, _ webView: WKWebView) -> String {
        let h = frame.securityOrigin.host
        if !h.isEmpty { return h }
        if let h = webView.url?.host, !h.isEmpty { return h }
        return "This page"
    }

    private func allowDialog() -> Bool {
        guard let tab else { return false }
        let now = Date()
        tab.alertTimes = tab.alertTimes.filter { now.timeIntervalSince($0) < 10 } + [now]
        return tab.alertTimes.count <= 3
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        guard allowDialog(), let app else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let shown = app.present(Confirmation(code: "PAGE.ALERT", title: "\(Self.origin(frame, webView)) says", message: "The page says:\n" + String(message.prefix(1000)),
                                                 confirmLabel: "OK", destructive: false, onConfirm: { c.resume() }, onCancel: { c.resume() }))
            if !shown { c.resume() }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard allowDialog(), let app else { return false }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let shown = app.present(Confirmation(code: "PAGE.CONFIRM", title: "\(Self.origin(frame, webView)) asks", message: "The page asks:\n" + String(message.prefix(1000)),
                                                 confirmLabel: "OK", destructive: false, onConfirm: { c.resume(returning: true) }, onCancel: { c.resume(returning: false) }))
            if !shown { c.resume(returning: false) }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        nil   // text prompts aren't supported
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.message = "Choose a file to upload to \(frame.securityOrigin.host)"
        return panel.runModal() == .OK ? panel.urls : nil
    }

    /// Camera and microphone: always WebKit's own per-site prompt, never granted silently.
    /// The name must match the delegate's async signature exactly, or WebKit never calls it
    /// (an earlier spelling only "nearly matched" and was silently unused).
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        .prompt
    }

    // MARK: Quarantine

    /// Marks a download as coming from the internet so Gatekeeper checks it on first open.
    static func quarantine(_ file: URL, from source: URL?) {
        let value = String(format: "0083;%08lx;GRID;", Int(Date().timeIntervalSince1970))
        _ = value.withCString { setxattr(file.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        if let s = source?.absoluteString,
           let d = try? PropertyListSerialization.data(fromPropertyList: [s], format: .binary, options: 0) {
            _ = d.withUnsafeBytes { setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, d.count, 0, 0) }
        }
    }
}
