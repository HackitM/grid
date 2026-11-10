import AppKit
import Darwin
import GridCore
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Details + preview for the selected file. All values are read from the filesystem.
struct InspectorView: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        Panel(index: "02.1", title: "Inspector", suffix: "meta", clipped: false) {
            if app.files.selectedIDs.count > 1 {
                MultiSelectionSummary()
            } else if let e = app.files.selectedEntry {
                InspectorContent(entry: e).id(e.id)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("no selection")
                    Text("Select an item to see its details.\n\n↑ ↓   move   ⇧↑↓ extend\n⏎     open   Space quick look\n⌘↑    enclosing folder\n⇧⌘N   new folder\n⌘C ⌘V copy · paste (⌥⌘V move)\n⌘⌫    move to Trash   ⌘Z undo\n⌥⌘T   terminal here")
                        .font(GridFont.small).foregroundStyle(theme.textDim)
                    Spacer()
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct MultiSelectionSummary: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let items = app.files.selectedEntries
        let folders = items.filter(\.isNavigableFolder).count
        let bytes = items.compactMap(\.size).reduce(0, +)
        let urls = items.map(\.url)
        VStack(alignment: .leading, spacing: 12) {
            Text("\(items.count) items selected").font(GridFont.bodyStrong).foregroundStyle(theme.text)
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("contents")
                Text("\(items.count - folders) file\(items.count - folders == 1 ? "" : "s") · \(folders) folder\(folders == 1 ? "" : "s")")
                    .font(GridFont.small).foregroundStyle(theme.text)
                SectionLabel("size of files")
                Text(Formatters.size(bytes) + (folders > 0 ? "  (folders not counted)" : ""))
                    .font(GridFont.small).foregroundStyle(theme.text)
            }
            TerminatedRule()
            VStack(alignment: .leading, spacing: 6) {
                Button("Quick Look") { QuickLook.shared.show(urls) }
                Button("Insert \(items.count) Paths in Terminal") { app.insertPathsIntoTerminal(urls) }
                Button("Copy") { app.fileOps.copyToPasteboard(urls) }
                Button("Copy Paths") { app.files.copyPaths(urls); app.flash(.info, "Copied paths") }
                Button("Move to Trash") { app.fileOps.trash(urls) }
            }
            .buttonStyle(GridButtonStyle(compact: true))
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InspectorContent: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let entry: FileEntry
    @State private var details: FileDetails?
    @State private var preview: Preview = .loading

    enum Preview { case loading, none(String), text(String, truncated: Bool), image(NSImage) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(GridFont.bodyStrong).foregroundStyle(theme.text)
                        .textSelection(.enabled).lineLimit(3)
                    Text(entry.kind).font(GridFont.small).foregroundStyle(theme.textDim)
                }
                previewView
                TerminatedRule()
                if let d = details {
                    VStack(alignment: .leading, spacing: 6) {
                        row("PATH", PathResolver.abbreviate(entry.url.path))
                        if let t = d.symlinkTarget { row("LINK →", t + (entry.isBrokenSymlink ? "  (missing)" : "")) }
                        if let s = d.size { row("SIZE", s) }
                        if let c = d.itemCount { row("ITEMS", c) }
                        if let m = d.modified { row("MODIFIED", m) }
                        if let c = d.created { row("CREATED", c) }
                        if let p = d.permissions { row("MODE", p) }
                        if let o = d.owner { row("OWNER", o) }
                        if let a = d.defaultApp { row("OPENS WITH", a) }
                    }
                }
                TerminatedRule()
                VStack(alignment: .leading, spacing: 6) {
                    Button(entry.isNavigableFolder ? "Open Folder" : "Open") { app.files.activate(entry) }
                    Button(entry.isNavigableFolder ? "Terminal Here" : "Terminal in Enclosing Folder") {
                        app.openTerminalHere(entry.isNavigableFolder ? entry.url : entry.url.deletingLastPathComponent())
                    }
                    Button("Insert Path in Terminal") { app.insertPathsIntoTerminal([entry.url]) }
                    Button("Copy Path") { app.files.copyPaths([entry.url]); app.flash(.info, "Copied path") }
                    Button("Reveal in Finder") { app.files.reveal([entry.url]) }
                }
                .buttonStyle(GridButtonStyle(compact: true))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
    }

    private func row(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionLabel(k)
            Text(v).font(GridFont.small).foregroundStyle(theme.text).textSelection(.enabled)
        }
    }

    @ViewBuilder private var previewView: some View {
        switch preview {
        case .loading:
            Rectangle().fill(theme.bg3).frame(height: 60).overlay(SectionLabel("reading…"))
        case .none(let why):
            Text(why).font(GridFont.small).foregroundStyle(theme.textMute)
        case .text(let s, let truncated):
            VStack(alignment: .leading, spacing: 4) {
                Text(s)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(theme.bg3)
                    .overlay(Rectangle().stroke(theme.line, lineWidth: Metrics.hairline))
                    .textSelection(.enabled)
                if truncated { SectionLabel("preview truncated") }
            }
        case .image(let img):
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 220)
                .background(theme.bg3)
                .overlay(Rectangle().stroke(theme.line, lineWidth: Metrics.hairline))
        }
    }

    private func load() async {
        let e = entry
        details = await Task.detached { FileDetails.read(e) }.value
        preview = await Self.makePreview(e)
    }

    static func makePreview(_ e: FileEntry) async -> Preview {
        if e.isBrokenSymlink { return .none("Broken link — nothing to preview.") }
        if e.isNavigableFolder { return .none("Folder") }
        if e.isPackage { return .none("Package") }
        // Never read pipes, sockets, or devices: opening a FIFO with no writer, or reading
        // /dev/zero or a tty, can block forever.
        guard e.isRegularFile else { return .none("Special file (pipe, socket, or device): not previewed.") }
        let type = e.typeIdentifier.flatMap(UTType.init)
        let url = e.url
        if let type, type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml) {
            let r = await Task.detached { () -> (String, Bool)? in readText(url, limit: 12_000) }.value
            if let (s, t) = r { return .text(s, truncated: t) }
        }
        // QuickLook thumbnails cover images, PDFs, videos, Office docs, etc.
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 520, height: 400), scale: 2,
                                               representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
            return .image(rep.nsImage)
        }
        // Unknown types that are actually plain text (e.g. dotfiles, Makefile).
        if (e.size ?? 0) < 2_000_000, let (s, t) = await Task.detached(operation: { readText(url, limit: 12_000) }).value {
            return .text(s, truncated: t)
        }
        return .none("No preview available.")
    }

    /// First `limit` bytes as UTF-8, rejecting binary (NUL bytes) content.
    nonisolated static func readText(_ url: URL, limit: Int) -> (String, Bool)? {
        // O_NONBLOCK: belt and braces in case the file was swapped for a FIFO after listing.
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { Darwin.close(fd); return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? h.read(upToCount: limit + 1), !data.isEmpty else { return nil }
        let truncated = data.count > limit
        let slice = data.prefix(limit)
        if slice.contains(0) { return nil }
        var s = String(decoding: slice, as: UTF8.self)
        if s.contains("\u{FFFD}") && String(data: slice, encoding: .utf8) == nil && !truncated { return nil }
        if truncated, let lastNL = s.lastIndex(of: "\n") { s = String(s[..<lastNL]) }
        return (s, truncated)
    }
}

struct FileDetails {
    var size: String?
    var itemCount: String?
    var modified: String?
    var created: String?
    var permissions: String?
    var owner: String?
    var symlinkTarget: String?
    var defaultApp: String?

    static func read(_ e: FileEntry) -> FileDetails {
        var d = FileDetails()
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: e.url.path) {  // does not follow links
            if let p = attrs[.posixPermissions] as? Int {
                d.permissions = FileListing.permissionString(p, isDirectory: e.isDirectory, isSymlink: e.isSymlink) + String(format: "  %o", p)
            }
            if let o = attrs[.ownerAccountName] as? String { d.owner = o + ((attrs[.groupOwnerAccountName] as? String).map { ":" + $0 } ?? "") }
            if let c = attrs[.creationDate] as? Date { d.created = Formatters.date(c) }
        }
        if let m = e.modified { d.modified = Formatters.date(m) }
        if let s = e.size { d.size = "\(Formatters.size(s))  (\(s.formatted()) bytes)" }
        if e.isSymlink { d.symlinkTarget = try? fm.destinationOfSymbolicLink(atPath: e.url.path) }
        if e.isNavigableFolder {
            if let n = try? fm.contentsOfDirectory(atPath: e.url.path).count { d.itemCount = "\(n)" } else { d.itemCount = "unreadable" }
        } else if !e.isBrokenSymlink, let app = NSWorkspace.shared.urlForApplication(toOpen: e.url) {
            d.defaultApp = app.deletingPathExtension().lastPathComponent
        }
        return d
    }
}
