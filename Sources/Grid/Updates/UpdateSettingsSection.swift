import AppKit
import GridCore
import SwiftUI

/// Settings › Updates.
struct UpdateSettingsSection: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let u = app.updates
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("GRID").font(GridFont.body).foregroundStyle(theme.textDim).frame(width: 150, alignment: .leading)
                if let r = u.available, let v = r.version {
                    Text("\(u.current.description) → \(v.description)").font(GridFont.bodyStrong).foregroundStyle(theme.text)
                    if let date = r.publishedAt { Text("released \(Self.day.string(from: date))").font(GridFont.small).foregroundStyle(theme.textDim) }
                    Tag(u.isSkipped ? "skipped" : "available", color: u.isSkipped ? theme.textMute : theme.accent)
                } else {
                    Text(u.current.description).font(GridFont.bodyStrong).foregroundStyle(theme.text)
                    statusTag(u)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                toggle("Check GitHub for new versions once a day", u.checksDaily) { u.setCheckDaily($0) }
                toggle("Include pre-releases", u.includePrereleases) { u.setIncludePrereleases($0) }
                HStack(spacing: 10) {
                    Button(u.status == .checking ? "Checking…" : "Check Now") { Task { await u.check(manual: true) } }
                        .buttonStyle(GridButtonStyle(compact: true))
                        .disabled(u.status == .checking)
                    Text(lastChecked(u)).font(GridFont.small).foregroundStyle(theme.textMute)
                }
                Text("A check is one plain request to api.github.com with a generic “GRID” user agent: no version, account, token or install ID. Nothing installs by itself.")
                    .font(GridFont.small).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let msg) = u.status {
                Text("✕ UPD-ERR  \(msg)").font(GridFont.small).foregroundStyle(theme.danger)
            }
            if let r = u.available {
                ReleaseCard(release: r)
            }
        }
    }

    @ViewBuilder private func statusTag(_ u: UpdateChecker) -> some View {
        switch u.status {
        case .checking: Tag("checking", color: theme.textMute)
        case .upToDate: Tag("up to date", color: theme.ok)
        case .failed: Tag("check failed", color: theme.danger)
        case .idle: if u.lastCheck != nil { Tag("up to date", color: theme.ok) }
        }
    }

    private func lastChecked(_ u: UpdateChecker) -> String {
        guard let d = u.lastCheck else { return u.needsConsent ? "never checked · off until you choose" : "never checked" }
        if abs(d.timeIntervalSinceNow) < 60 { return "checked just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "checked " + f.localizedString(for: d, relativeTo: Date())
    }

    private func toggle(_ label: String, _ value: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { value }, set: set)) { Text(label).font(GridFont.body).foregroundStyle(theme.text) }
            .toggleStyle(GridToggleStyle())
    }

    static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
}

/// The available release: notes and actions.
private struct ReleaseCard: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let release: GitHubRelease

    var body: some View {
        let u = app.updates
        let v = release.version?.description ?? release.tagName
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionLabel("what's new in \(v)", color: theme.accent)
                TerminatedRule()
            }
            ScrollView {
                ReleaseNotesText(markdown: release.body ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
            }
            .frame(maxHeight: 240)
            DownloadStatus(state: u.download, release: release)
            HStack(spacing: 8) {
                Button("View on GitHub ↗") { u.openReleasePage() }
                    .buttonStyle(GridButtonStyle(compact: true))
                Button("Download & Verify") { UpdateDownloader.run(u) }
                    .buttonStyle(GridButtonStyle(prominent: true, compact: true))
                    .disabled(u.download.busy || release.appAsset == nil || release.checksumAsset == nil)
                    .help(release.appAsset == nil ? "This release has no GRID zip" : "Download to Downloads, check the SHA-256, unzip and show it in Finder")
                if u.isSkipped {
                    Button("Don't Skip") { u.unskip() }.buttonStyle(GridButtonStyle(compact: true))
                } else {
                    Button("Skip \(v)") { u.skipAvailable() }.buttonStyle(GridButtonStyle(compact: true))
                }
                Button("Later") { u.later() }.buttonStyle(GridButtonStyle(compact: true))
                    .help("No reminder for 7 days")
            }
        }
        .padding(12)
        .background(theme.bg2.opacity(0.5))
        .clipShape(ClippedRect(cut: 8, topRight: true))
        .overlay(ClippedRect(cut: 8, topRight: true).stroke(theme.lineStrong.opacity(0.6), lineWidth: Metrics.hairline))
    }
}

private struct DownloadStatus: View {
    @Environment(\.theme) private var theme
    let state: UpdateDownloader.State
    let release: GitHubRelease

    var body: some View {
        switch state {
        case .none: EmptyView()
        case .downloading(let p):
            HStack(spacing: 8) {
                Text("DOWNLOADING").font(GridFont.label).tracking(1).foregroundStyle(theme.textDim)
                SegmentBar(value: p, segments: 32, warnAbove: 2)
                Text("\(Int(p * 100))%").font(GridFont.small).foregroundStyle(theme.textDim).monospacedDigit()
            }
        case .verifying: label("◆ VERIFYING SHA-256…", theme.textDim)
        case .unpacking: label("◆ UNPACKING…", theme.textDim)
        case .done(let url):
            VStack(alignment: .leading, spacing: 4) {
                label("✓ VERIFIED · SHA-256 MATCHES THE RELEASE", theme.ok)
                Text("Shown in Finder: \(url.deletingLastPathComponent().lastPathComponent)/GRID.app. To update: quit GRID, drag the new GRID.app into Applications (replace the old one), then open it. macOS asks once more (System Settings › Privacy & Security › Open Anyway) because this build isn't notarized yet.")
                    .font(GridFont.small).foregroundStyle(theme.textDim).fixedSize(horizontal: false, vertical: true)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(GridButtonStyle(compact: true))
            }
        case .failed(let msg): label("✕ \(msg)", theme.danger)
        }
    }

    private func label(_ t: String, _ c: Color) -> some View {
        Text(t).font(GridFont.small).foregroundStyle(c).fixedSize(horizontal: false, vertical: true)
    }
}

/// Release notes from GitHub, drawn as GRID text: headings, bullets and inline Markdown only.
/// Images are skipped (nothing remote is loaded) and links open only when clicked, in GRID's
/// browser or the default one (Settings › Browser), and only for https.
struct ReleaseNotesText: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let markdown: String

    private enum Block { case heading(String), bullet(String), numbered(String, String), paragraph(String), gap }

    private var blocks: [Block] {
        var out: [Block] = []
        for raw in markdown.prefix(12_000).split(separator: "\n", omittingEmptySubsequences: false).prefix(160) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { if case .gap? = out.last {} else { out.append(.gap) }; continue }
            if line.hasPrefix("![") { continue }
            if line.hasPrefix("#") { out.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let indent = raw.prefix { $0 == " " }.count
                out.append(.bullet((indent >= 2 ? "  " : "") + String(line.dropFirst(2)))); continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].hasPrefix(" ") {
                out.append(.numbered(String(line[...dot]), line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces))); continue
            }
            out.append(.paragraph(line))
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let t):
                    SectionLabel(t, color: theme.text).padding(.top, 4)
                case .bullet(let t):
                    HStack(alignment: .top, spacing: 6) {
                        Text(t.hasPrefix("  ") ? "·" : "▪").foregroundStyle(theme.accent)
                        inline(t.trimmingCharacters(in: .whitespaces))
                    }
                    .padding(.leading, t.hasPrefix("  ") ? 14 : 0)
                case .numbered(let n, let t):
                    HStack(alignment: .top, spacing: 6) {
                        Text(n).foregroundStyle(theme.accent).monospacedDigit()
                        inline(t)
                    }
                case .paragraph(let t): inline(t)
                case .gap: Color.clear.frame(height: 2)
                }
            }
        }
        .font(GridFont.small)
        .foregroundStyle(theme.textDim)
        .tint(theme.accent)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "https" else { return .discarded }
            app.openURL(url.absoluteString)
            return .handled
        })
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> some View {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let a = (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
        return Text(a).fixedSize(horizontal: false, vertical: true)
    }
}
