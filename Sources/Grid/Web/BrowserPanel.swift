import AppKit
import GridCore
import SwiftUI
import WebKit

/// The Web page: GRID's embedded browser. Chrome (tabs, address bar, toolbar) is drawn with GRID's
/// components; the page itself is WebKit. Site themes, reader view and ad blocking are toggled
/// from the header strip; extension buttons appear only when an extension is installed.
struct BrowserPanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    private var browser: BrowserModel { app.browser }

    var body: some View {
        let tab = browser.active
        Panel(index: "04", title: "Web", suffix: tab.flatMap { SiteKey.of($0.url) } ?? "www", focused: false) {
            BrowserToolbar(tab: tab)
        } content: {
            VStack(spacing: 0) {
                if !browser.tabs.isEmpty { BrowserTabStrip() }
                AddressBar(tab: tab)
                ProgressLine(tab: tab)
                if browser.findVisible, let tab { BrowserFindBar(tab: tab) }
                ZStack {
                    theme.bg1
                    if let tab {
                        if let article = tab.reader {
                            ReaderView(article: article, theme: theme, fontSize: 13) { url in
                                tab.reader = nil
                                tab.load(url)
                            }
                        } else {
                            BrowserContentView(tab: tab)
                            if let err = tab.loadError {
                                StateBlock(tone: .warning, code: tab.blockedByFilter ? "WEB.BLOCKED" : "WEB.LOAD",
                                           title: tab.blockedByFilter ? "Blocked by ad blocking" : "Couldn't open this page", message: err) {
                                    if tab.blockedByFilter, let site = SiteKey.of(tab.failedURL ?? tab.url) {
                                        Button("Allow This Site") { app.browser.adBlocker.setBlocking(false, for: site); tab.reload() }
                                    }
                                    Button("Try Again") { tab.reload() }
                                    if let u = tab.failedURL ?? tab.url { Button("Open in Default Browser") { NSWorkspace.shared.open(u) } }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(theme.bg1)
                            }
                        }
                    } else {
                        NewTabPage()
                    }
                }
            }
        }
    }
}

// MARK: - Toolbar (header strip trailing controls)

private struct BrowserToolbar: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let tab: BrowserTab?

    var body: some View {
        let browser = app.browser
        HStack(spacing: 2) {
            if #available(macOS 15.4, *) { ExtensionStrip(tab: tab) }
            if let tab, tab.url?.scheme?.hasPrefix("http") == true {
                if let entry = tab.themeEntry {
                    IconButton(symbol: "paintpalette", label: tab.themeActive ? "GRID theme on for \(entry.name) — click for the original" : "Use the GRID theme on \(entry.name)",
                               active: tab.themeActive) { tab.setThemeEnabled(!tab.themeActive) }
                }
                IconButton(symbol: "doc.plaintext", label: tab.reader == nil ? "Reader view (⇧⌘R)" : "Exit reader view (⇧⌘R)",
                           active: tab.reader != nil) { Task { await browser.toggleReader() } }
                if browser.adBlocker.enabled, let site = SiteKey.of(tab.failedURL ?? tab.url) {
                    let on = !browser.adBlocker.disabledSites.contains(site)
                    IconButton(symbol: on ? "shield.lefthalf.filled" : "shield.slash",
                               label: on ? "Ad blocking on for \(site) — click to turn it off here" : "Ad blocking off for \(site) — click to turn it back on",
                               active: on && !browser.adBlocker.ruleLists.isEmpty) {
                        browser.adBlocker.setBlocking(!on, for: site)
                        tab.reload()
                    }
                }
            }
            Menu {
                Button("New Tab  ⌘T") { browser.newTab(); browser.focusAddressToken += 1 }
                if let tab {
                    Button("Reload  ⌘R") { tab.reload() }
                    Button("Find…  ⌘F") { browser.findVisible = true }
                    Divider()
                    Button("Zoom In  ⌘+") { tab.zoom(0.1) }
                    Button("Zoom Out  ⌘−") { tab.zoom(-0.1) }
                    Button("Actual Size  ⌘0") { tab.zoom(nil) }
                    Divider()
                    if let u = tab.url {
                        Button("Open in Default Browser") { NSWorkspace.shared.open(u) }
                        Button("Copy Address") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.absoluteString, forType: .string) }
                    }
                }
                Divider()
                Button("Browser Settings…") { app.show(.settings) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(theme.textDim).frame(width: 22, height: 20)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Browser options")
        }
    }
}

/// Installed extensions' buttons, drawn as monochrome GRID glyphs. Absent when none are installed;
/// more than three collapse into a single EXT menu so the header never fills with icons.
@available(macOS 15.4, *)
private struct ExtensionStrip: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let tab: BrowserTab?

    var body: some View {
        if let ext = app.browser.extensions {
            let actions = ext.actions(for: tab)
            if actions.count > 3 {
                Menu {
                    ForEach(actions, id: \.item.id) { a in
                        Button(a.action.label.isEmpty ? a.item.name : a.action.label) { ext.perform(a.item, tab: tab) }
                            .disabled(!a.action.isEnabled)
                    }
                } label: {
                    Text("EXT \(actions.count)").font(GridFont.label).tracking(1.2).foregroundStyle(theme.textDim)
                        .frame(height: 20).padding(.horizontal, 4)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Extensions")
                .background(PopoverAnchor { v in actions.forEach { ext.popoverAnchors[$0.item.id] = v } })
            } else {
                ForEach(actions, id: \.item.id) { a in
                    ExtensionButton(item: a.item, action: a.action) { ext.perform(a.item, tab: tab) }
                        .background(PopoverAnchor { ext.popoverAnchors[a.item.id] = $0 })
                }
            }
            if !actions.isEmpty { Rectangle().fill(theme.line).frame(width: Metrics.hairline, height: 14).padding(.horizontal, 3) }
        }
    }
}

@available(macOS 15.4, *)
private struct ExtensionButton: View {
    @Environment(\.theme) private var theme
    let item: BrowserExtensions.Item
    let action: WKWebExtension.Action
    let perform: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: perform) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let icon = Self.glyph(action.icon(for: CGSize(width: 16, height: 16))) {
                        // Template rendering: the icon's shape in GRID's colours, never its own.
                        Image(nsImage: icon).renderingMode(.template).resizable().interpolation(.high).frame(width: 13, height: 13)
                    } else {
                        Text(String(item.name.prefix(1)).uppercased()).font(GridFont.label)
                    }
                }
                .foregroundStyle(action.isEnabled ? (hover ? theme.accent : theme.textDim) : theme.textMute.opacity(0.5))
                .frame(width: 22, height: 20)
                if !action.badgeText.isEmpty {
                    Text(String(action.badgeText.prefix(3))).font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.textOnAccent).padding(.horizontal, 2).background(theme.accent).offset(x: 2, y: -1)
                }
            }
            .background(hover ? theme.bg2 : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .disabled(!action.isEnabled)
        .help(action.label.isEmpty ? item.name : action.label)
        .accessibilityLabel(action.label.isEmpty ? item.name : action.label)
    }

    static func glyph(_ image: NSImage?) -> NSImage? {
        guard let image, let copy = image.copy() as? NSImage else { return nil }
        copy.isTemplate = true
        return copy
    }
}

/// Captures an NSView to anchor extension popovers under their button.
private struct PopoverAnchor: NSViewRepresentable {
    let set: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { set(v) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

// MARK: - Tabs

private struct BrowserTabStrip: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.effects) private var effects
    @Namespace private var selector

    var body: some View {
        let browser = app.browser
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(browser.tabs.enumerated()), id: \.element.id) { i, t in
                        BrowserTabItem(tab: t, position: i, active: t.id == browser.activeID, selector: selector)
                    }
                }
            }
            Button { browser.newTab(); browser.focusAddressToken += 1 } label: {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.textDim).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain).help("New tab (⌘T)")
        }
        .frame(height: 26)
        .background(theme.bg1)
        .animation(effects.motion ? GridMotion.snap : nil, value: browser.activeID)
    }
}

private struct BrowserTabItem: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let tab: BrowserTab
    let position: Int
    let active: Bool
    let selector: Namespace.ID
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Text(String(format: "%02d", position + 1)).font(GridFont.label).foregroundStyle(active ? theme.accent : theme.textMute)
            if tab.isLoading { Text("◆").font(.system(size: 7)).foregroundStyle(theme.accent).accessibilityLabel("loading") }
            Text(tab.title.isEmpty ? "New Tab" : tab.title)
                .font(GridFont.small).foregroundStyle(active ? theme.text : theme.textDim)
                .lineLimit(1).frame(maxWidth: 170, alignment: .leading)
            if tab.themeActive { Tag("themed", color: theme.accent.opacity(0.85)) }
            Button { app.browser.close(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14).foregroundStyle(theme.textDim)
            }
            .buttonStyle(.plain).opacity(hover || active ? 1 : 0).help("Close tab (⌘W)")
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(active ? theme.bg2 : (hover ? theme.bg2.opacity(0.5) : .clear))
        .overlay(alignment: .top) {
            if active { Rectangle().fill(theme.accent).frame(height: 2).matchedGeometryEffect(id: "web.tab.active", in: selector) }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(theme.line).frame(width: Metrics.hairline) }
        .contentShape(Rectangle())
        .onTapGesture { app.browser.select(tab.id) }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Reload") { tab.reload() }
            if let u = tab.url { Button("Open in Default Browser") { NSWorkspace.shared.open(u) } }
            Divider()
            Button("Close Tab") { app.browser.close(tab.id) }
        }
        .help(tab.url?.absoluteString ?? "")
    }
}

// MARK: - Address bar

private struct AddressBar: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let tab: BrowserTab?
    @State private var text = ""
    /// The user has typed into the field since it last showed the page's address. Only then is
    /// the text kept when the page navigates; otherwise it always shows where the page really is
    /// (even while focused, e.g. a link opened from the terminal into a fresh tab).
    @State private var edited = false
    @FocusState private var focused: Bool

    var body: some View {
        let browser = app.browser
        HStack(spacing: 4) {
            IconButton(symbol: "chevron.left", label: "Back (⌘[)", disabled: !(tab?.canGoBack ?? false)) { tab?.goBack() }
            IconButton(symbol: "chevron.right", label: "Forward (⌘])", disabled: !(tab?.canGoForward ?? false)) { tab?.goForward() }
            IconButton(symbol: tab?.isLoading == true ? "xmark" : "arrow.clockwise", label: tab?.isLoading == true ? "Stop" : "Reload (⌘R)",
                       disabled: tab == nil) { tab?.isLoading == true ? tab?.stop() : tab?.reload() }
            HStack(spacing: 6) {
                Text(prompt).font(GridFont.label).tracking(1).foregroundStyle(promptColor)
                    .help(promptHelp)
                TextField("", text: Binding(get: { text }, set: { if $0 != text { text = $0; edited = true } }), prompt: Text("search or address").foregroundStyle(theme.textMute))
                    .textFieldStyle(.plain).font(GridFont.body).foregroundStyle(theme.text)
                    .focused($focused)
                    .onSubmit {
                        browser.go(text)
                        edited = false
                        focused = false
                    }
                    .onExitCommand { focused = false; showAddress(tab?.url) }
                if tab?.reader != nil { Tag("reader") }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(theme.bg3)
            .overlay(Rectangle().stroke(focused ? theme.lineStrong : theme.line, lineWidth: Metrics.hairline))
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(theme.bg1)
        .onAppear { showAddress(tab?.url); if tab == nil { focused = true } }
        .onChange(of: tab?.url) { _, u in if !edited { showAddress(u) } }
        .onChange(of: tab?.failedURL) { _, u in if !edited, let u { showAddress(u) } }
        .onChange(of: tab?.id) { _, _ in showAddress(tab?.url) }
        .onChange(of: browser.focusAddressToken) { _, _ in
            showAddress(tab?.url)
            focused = true
        }
        .onChange(of: focused) { _, f in if !f { showAddress(tab?.url) } }
    }

    private func showAddress(_ u: URL?) {
        text = BrowserAddress.display(u)
        edited = false
    }

    private var prompt: String {
        guard let u = tab?.url, u.scheme?.hasPrefix("http") == true else { return "GO ▸" }
        return tab?.isSecure == true ? "TLS ▸" : (u.scheme == "https" ? "TLS ▸" : "HTTP ▸")
    }
    private var promptColor: Color {
        guard let u = tab?.url, u.scheme?.hasPrefix("http") == true else { return theme.accent }
        return u.scheme == "https" ? theme.accent : theme.warn
    }
    private var promptHelp: String {
        guard let u = tab?.url else { return "" }
        if u.scheme == "http" { return "△ Not encrypted: anyone on the network can read or change this page." }
        return tab?.isSecure == true ? "Encrypted connection (HTTPS)" : "HTTPS page with some unencrypted content"
    }
}

/// Load progress: an accent line across the top of the page while loading (no idle animation).
private struct ProgressLine: View {
    @Environment(\.theme) private var theme
    let tab: BrowserTab?
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(theme.line)
                if let tab, tab.isLoading {
                    Rectangle().fill(theme.accent).frame(width: g.size.width * max(0.04, tab.progress))
                }
            }
        }
        .frame(height: 1)
    }
}

// MARK: - Find

private struct BrowserFindBar: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let tab: BrowserTab
    @State private var query = ""
    @State private var found: Bool?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("FIND").font(GridFont.label).tracking(1.2).foregroundStyle(theme.accent)
            TextField("", text: $query, prompt: Text("text on this page").foregroundStyle(theme.textMute))
                .textFieldStyle(.plain).font(GridFont.body).foregroundStyle(theme.text)
                .focused($focused)
                .onSubmit { run(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onExitCommand { close() }
            if let found { Text(found ? "" : "no match").font(GridFont.small).foregroundStyle(theme.warn) }
            IconButton(symbol: "chevron.up", label: "Previous (⇧↩)") { run(backwards: true) }
            IconButton(symbol: "chevron.down", label: "Next (↩)") { run(backwards: false) }
            IconButton(symbol: "xmark", label: "Close (esc)") { close() }
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(theme.bg2)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line).frame(height: Metrics.hairline) }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func run(backwards: Bool) {
        let q = query
        Task { found = await tab.find(q, backwards: backwards) }
    }
    private func close() { app.browser.findVisible = false }
}

// MARK: - New tab page

private struct NewTabPage: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let browser = app.browser
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StateBlock(code: "WEB.READY", title: "Type an address or a search",
                           message: "Pages run in WebKit, isolated from your terminal and files. ⌘T new tab · ⌘L address · ⇧⌘R reader view. Ad blocking: \(browser.adBlocker.enabled ? "on" : "off").")
                if !browser.history.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            SectionLabel("Recent", color: theme.accent)
                            Rectangle().fill(theme.line).frame(height: Metrics.hairline)
                        }
                        .padding(.bottom, 4)
                        ForEach(browser.history.prefix(14)) { h in
                            HistoryRow(item: h) { if let u = URL(string: h.url) { browser.open(u, newTab: browser.active == nil) } }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct HistoryRow: View {
    @Environment(\.theme) private var theme
    let item: BrowserModel.HistoryItem
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 8) {
            Text("↗").foregroundStyle(theme.accent)
            Text(item.title.isEmpty ? item.url : item.title).foregroundStyle(theme.text).lineLimit(1)
            Spacer(minLength: 8)
            Text(URL(string: item.url)?.host ?? "").foregroundStyle(theme.textMute).lineLimit(1)
        }
        .font(GridFont.small)
        .padding(.horizontal, 8).frame(height: Metrics.rowHeight)
        .gridRowBackground(selected: false, hovered: hover, theme: theme)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Page view

/// Hosts the active tab's WKWebView (each tab keeps its own web view; only the active one is attached).
struct BrowserContentView: NSViewRepresentable {
    let tab: BrowserTab

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ container: NSView, context: Context) {
        let w = tab.webView
        tab.activate()
        guard w.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        w.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(w)
        NSLayoutConstraint.activate([
            w.leadingAnchor.constraint(equalTo: container.leadingAnchor), w.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            w.topAnchor.constraint(equalTo: container.topAnchor), w.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
