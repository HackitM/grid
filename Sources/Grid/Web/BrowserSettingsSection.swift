import AppKit
import GridCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Browser.
struct BrowserSettingsSection: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let browser = app.browser
        @Bindable var s = browser.settings
        @Bindable var themes = browser.themes
        @Bindable var blocker = browser.adBlocker
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                toggle("Open web links in GRID’s browser (palette, terminal links)", $s.openLinksInGRID)
                toggle("Ask sites for their dark design", $s.requestDark)
                toggle("Web Inspector (developer tools, right-click › Inspect Element)", $s.developerTools)
                HStack(spacing: 12) {
                    Text("Search with").font(GridFont.body).foregroundStyle(theme.textDim).frame(width: 150, alignment: .leading)
                    Picker("", selection: $s.searchEngine) {
                        ForEach(SearchEngine.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 180)
                }
            }
            .onChange(of: s.requestDark) { _, _ in browser.tabs.forEach { $0.applyAppearance() } }

            sub("Site themes")
            VStack(alignment: .leading, spacing: 6) {
                Text("GRID colours and type on well-known sites. Layouts stay the site’s own; toggle any site from the browser’s 🎨 button, and the original is one click away.")
                    .font(GridFont.small).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true)
                toggle("Use GRID themes on every supported site", $themes.allByDefault)
                ForEach(SiteThemeCatalog.entries, id: \.id) { e in
                    HStack(spacing: 10) {
                        Toggle(isOn: Binding(get: { themes.isEnabled(e.id) }, set: { themes.setEnabled(e.id, $0) })) {
                            Text(e.name).font(GridFont.body).foregroundStyle(theme.text)
                        }
                        .toggleStyle(GridToggleStyle())
                        Text(e.hosts.joined(separator: ", ")).font(GridFont.small).foregroundStyle(theme.textMute).lineLimit(1)
                    }
                    .padding(.leading, 12)
                }
            }

            sub("Ad blocking")
            VStack(alignment: .leading, spacing: 6) {
                toggle("Block ads and trackers (uBlock Origin’s default filter lists, WebKit content blocker)", $blocker.enabled)
                HStack(spacing: 8) {
                    Text(statusText).font(GridFont.small).foregroundStyle(statusColor)
                    Spacer()
                    Button("Update Lists Now") { Task { await blocker.update(force: true) } }
                        .buttonStyle(GridButtonStyle(compact: true)).disabled(!blocker.enabled)
                }
                if !blocker.stats.isEmpty { Text(blocker.stats).font(GridFont.small).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true) }
                Text("Lists: " + AdBlocker.sources.map(\.name).joined(separator: " · ") + ". Downloaded from their publishers, refreshed every 4 days. Turn blocking off for one site with the 🛡 button.")
                    .font(GridFont.small).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true)
                if !blocker.disabledSites.isEmpty {
                    Text("OFF ON THESE SITES").font(GridFont.label).tracking(1.2).foregroundStyle(theme.textMute).padding(.top, 4)
                    ForEach(blocker.disabledSites.sorted(), id: \.self) { site in
                        HStack {
                            Text(site).font(GridFont.small).foregroundStyle(theme.text)
                            Spacer()
                            Button("Block Again") { blocker.removeException(site); browser.tabs.forEach { $0.applyContentBlocking() } }
                                .buttonStyle(GridButtonStyle(compact: true))
                        }
                        .padding(.leading, 12)
                    }
                }
            }

            sub("Extensions")
            if #available(macOS 15.4, *) { ExtensionsSettings() } else {
                Text("Browser extensions need macOS 15.4 or later.").font(GridFont.small).foregroundStyle(theme.textMute)
            }

            sub("Privacy")
            HStack(spacing: 8) {
                Text("Cookies, site data, history and your open tabs stay on this Mac in GRID’s own store. Fraudulent-site warnings use Apple’s Safe Browsing service (hashed address prefixes), as in Safari.")
                    .font(GridFont.small).foregroundStyle(theme.textMute)
                Spacer()
                Button("Clear Browsing Data…") {
                    _ = app.present(Confirmation(code: "WEB.CLEAR", title: "Clear browsing data?",
                                                 message: "Signs you out of sites in GRID’s browser and removes cookies, caches, site storage and history. Safari and other browsers aren’t affected.",
                                                 confirmLabel: "Clear", destructive: true, onConfirm: {
                        Task { await browser.clearBrowsingData(); app.flash(.info, "Browsing data cleared") }
                    }))
                }
                .buttonStyle(GridButtonStyle(compact: true))
            }
        }
    }

    private var statusText: String {
        let b = app.browser.adBlocker
        guard b.enabled else { return "Off" }
        switch b.status {
        case .idle: return "Waiting to load lists…"
        case .downloading: return "Downloading lists…"
        case .compiling: return "Compiling rules…"
        case .ready(let n): return "✓ \(n.formatted()) rules active" + (b.lastUpdated.map { " · updated " + $0.formatted(.relative(presentation: .named)) } ?? "")
        case .failed(let e): return "✕ " + e
        }
    }

    private var statusColor: Color {
        if case .failed = app.browser.adBlocker.status { return theme.danger }
        if case .ready = app.browser.adBlocker.status { return theme.ok }
        return theme.textDim
    }

    private func sub(_ title: String) -> some View {
        HStack(spacing: 8) {
            SectionLabel(title, color: theme.textDim)
            Rectangle().fill(theme.line).frame(height: Metrics.hairline)
        }
        .padding(.top, 4)
    }

    private func toggle(_ label: String, _ b: Binding<Bool>) -> some View {
        Toggle(isOn: b) { Text(label).font(GridFont.body).foregroundStyle(theme.text) }.toggleStyle(GridToggleStyle())
    }
}

@available(macOS 15.4, *)
private struct ExtensionsSettings: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        if let ext = app.browser.extensions {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("WebExtensions (Chrome / Safari format) from a folder, .zip or .crx. Their buttons appear in the browser header as GRID glyphs only while installed.")
                        .font(GridFont.small).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Install Extension…") { pick(ext) }.buttonStyle(GridButtonStyle(compact: true))
                }
                if ext.items.isEmpty {
                    Text("No extensions installed.").font(GridFont.small).foregroundStyle(theme.textDim)
                }
                ForEach(ext.items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 10) {
                            Toggle(isOn: Binding(get: { item.enabled }, set: { ext.setEnabled(item.id, $0) })) {
                                Text(item.name).font(GridFont.body).foregroundStyle(theme.text)
                            }
                            .toggleStyle(GridToggleStyle())
                            Text(item.version).font(GridFont.small).foregroundStyle(theme.textMute)
                            Spacer()
                            Button("Remove…") {
                                _ = app.present(Confirmation(code: "EXT.REMOVE", title: "Remove “\(item.name)”?",
                                                             message: "Deletes the extension and its data from GRID.", confirmLabel: "Remove",
                                                             destructive: true, onConfirm: { ext.remove(item.id) }))
                            }
                            .buttonStyle(GridButtonStyle(compact: true))
                        }
                        ForEach(item.errors.prefix(3), id: \.self) { e in
                            Text("△ " + e).font(GridFont.small).foregroundStyle(theme.warn).lineLimit(2)
                        }
                    }
                    .padding(.leading, 12)
                }
            }
        }
    }

    private func pick(_ ext: BrowserExtensions) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowedContentTypes = [.zip, .folder, UTType(filenameExtension: "crx") ?? .data]
        p.message = "Choose an unpacked extension folder (with manifest.json), a .zip or a .crx"
        p.prompt = "Review"
        guard p.runModal() == .OK, let url = p.url else { return }
        Task { await ext.install(from: url, app: app) }
    }
}
