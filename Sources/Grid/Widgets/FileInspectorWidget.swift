import AppKit
import GridCore
import SwiftUI

/// Deck widget: everything worth knowing about the Files selection before handing it to a shell:
/// exactly what will be inserted at the prompt, whether it's executable (and by which
/// interpreter), whether it came from the internet, what's inside, and quick actions.
/// Reads happen off the main thread, debounced while you arrow through a list.
struct FileInspectorWidget: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let widget: WidgetInstance

    var body: some View {
        let entries = app.files.selectedEntries
        Group {
            if entries.count > 1 {
                MultiInspector(entries: entries)
            } else if let e = entries.first {
                SingleInspector(entry: e, widget: widget).id(e.id)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No selection").font(GridFont.bodyStrong).foregroundStyle(theme.textDim)
                    Text("Select an item in Files to inspect it before dragging it into the terminal.")
                        .font(GridFont.small).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true)
                    WidgetFootnote(text: "files panel · " + PathResolver.abbreviate(app.files.currentURL.path))
                        .lineLimit(1).truncationMode(.head).padding(.top, 2)
                }
            }
        }
    }
}

// MARK: - Single item

private struct SingleInspector: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let entry: FileEntry
    let widget: WidgetInstance

    @State private var details: FileDetails?
    @State private var facts: FileFacts?
    @State private var preview: InspectorContent.Preview?
    @State private var measure: MeasureState = .idle

    enum MeasureState: Equatable { case idle, running, done(FolderMeasure.Result) }

    private var showPreview: Bool { widget.expanded && widget.bool("preview", true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            identity
            tags
            insertionPreview
            if let p = preview, showPreview { previewView(p) }
            facts.map(cautions)
            TerminatedRule()
            rows
            actions
        }
        .task {
            // Debounce: arrowing through a list shouldn't read every file it passes.
            try? await Task.sleep(for: .milliseconds(140))
            if Task.isCancelled { return }
            let e = entry
            async let d = Task.detached(priority: .utility) { FileDetails.read(e) }.value
            async let f = Task.detached(priority: .utility) { FileFacts.read(path: e.url.path) }.value
            let (dd, ff) = await (d, f)
            if Task.isCancelled { return }
            details = dd; facts = ff
        }
        .task(id: showPreview) {
            guard showPreview, preview == nil else { return }
            try? await Task.sleep(for: .milliseconds(160))
            if Task.isCancelled { return }
            preview = await InspectorContent.makePreview(entry)
        }
    }

    // Icon + name; dragging the icon or name drops the file into the terminal (quoted, not run).
    private var identity: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(GridFont.bodyStrong).foregroundStyle(theme.text)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                Text(entry.kind).font(GridFont.small).foregroundStyle(theme.textDim).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(object: entry.url as NSURL) }
        .hoverCursor(.openHand)
        .help("Drag into the terminal to insert the quoted path (nothing runs)")
    }

    @ViewBuilder private var tags: some View {
        let list = tagList
        if !list.isEmpty {
            HStack(spacing: 4) {
                ForEach(list, id: \.0) { t in Tag(t.0, color: t.1) }
                Spacer(minLength: 0)
            }
        }
    }

    private var tagList: [(String, Color)] {
        var t: [(String, Color)] = []
        if entry.isBrokenSymlink { t.append(("BROKEN LINK", theme.danger)) } else if entry.isSymlink { t.append(("LINK", theme.accent)) }
        if entry.isPackage { t.append(("PACKAGE", theme.accent)) } else if entry.isNavigableFolder { t.append(("FOLDER", theme.accent)) }
        if !entry.isRegularFile && !entry.isDirectory && !entry.isSymlink { t.append(("SPECIAL", theme.warn)) }
        if facts?.isExecutable == true { t.append(("EXEC", theme.warn)) }
        if facts?.quarantineAgent != nil || facts?.quarantineDate != nil { t.append(("DOWNLOADED", theme.warn)) }
        if entry.isHidden { t.append(("HIDDEN", theme.textMute)) }
        if entry.isRegularFile, facts != nil, facts?.text == nil, facts?.pixelWidth == nil, (entry.size ?? 0) > 0 { t.append(("BINARY", theme.textMute)) }
        return t
    }

    /// Exactly what Insert / drag will put at the prompt.
    private var insertionPreview: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel("inserts as")
            Text(ShellQuoting.insertionText(forPaths: [entry.url.path]))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(theme.accent)
                .lineLimit(widget.expanded ? 4 : 2).truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(theme.bg1)
                .overlay(Rectangle().stroke(theme.line, lineWidth: Metrics.hairline))
        }
    }

    @ViewBuilder private func cautions(_ f: FileFacts) -> some View {
        let notes = cautionNotes(f)
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(notes, id: \.self) { n in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("△").font(GridFont.small).foregroundStyle(theme.warn)
                        Text(n).font(GridFont.small).foregroundStyle(theme.textDim).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func cautionNotes(_ f: FileFacts) -> [String] {
        var n: [String] = []
        if let s = f.shebang { n.append("Runs with \(s.dropFirst(2).trimmingCharacters(in: .whitespaces)) when executed.") }
        else if f.isExecutable && entry.isRegularFile { n.append("Executable: running it starts a program.") }
        if f.quarantineAgent != nil || f.quarantineDate != nil {
            let who = f.quarantineAgent.map { "with \($0)" } ?? ""
            let when = f.quarantineDate.map { Formatters.date($0) } ?? ""
            n.append(["Downloaded", who, when.isEmpty ? "" : "· \(when)"].filter { !$0.isEmpty }.joined(separator: " ") + ".")
        }
        if entry.isBrokenSymlink { n.append("The link's target is missing.") }
        return n
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let d = details {
                if let s = d.size { kv("SIZE", s) }
                if entry.isNavigableFolder { folderRows(d) }
                if let t = facts?.text {
                    kv("TEXT", "\(t.isComplete ? "" : "≥ ")\(t.lines.formatted()) lines · \(t.encoding) · \(t.lineEndings)")
                }
                if let w = facts?.pixelWidth, let h = facts?.pixelHeight { kv("PIXELS", "\(w) × \(h)") }
                if let m = d.modified { kv("MODIFIED", m) }
                if let p = d.permissions { kv("MODE", p) }
                if let a = d.defaultApp { kv("OPENS IN", a) }
                if let t = d.symlinkTarget { kv("LINK →", t) }
                if widget.expanded {
                    if let c = d.created { kv("CREATED", c) }
                    if let o = d.owner { kv("OWNER", o) }
                    if let u = entry.typeIdentifier { kv("TYPE", u) }
                    if let f = facts {
                        ForEach(f.whereFrom, id: \.self) { kv("FROM", $0) }
                        if !f.otherAttributes.isEmpty { kv("XATTR", f.otherAttributes.joined(separator: ", ")) }
                    }
                    kv("PATH", PathResolver.abbreviate(entry.url.deletingLastPathComponent().path))
                }
            } else {
                Text("Reading…").font(GridFont.small).foregroundStyle(theme.textMute)
            }
        }
    }

    @ViewBuilder private func folderRows(_ d: FileDetails) -> some View {
        if let c = d.itemCount { kv("ITEMS", c) }
        HStack(spacing: 6) {
            SectionLabel("TOTAL").frame(width: 70, alignment: .leading)
            switch measure {
            case .idle:
                Button("Measure") { measure = .running }
                    .buttonStyle(GridButtonStyle(compact: true))
            case .running:
                Text("measuring…").font(GridFont.small).foregroundStyle(theme.textMute)
                Button("Stop") { measure = .idle }.buttonStyle(GridButtonStyle(compact: true))
            case .done(let r):
                Text(Formatters.size(r.bytes) + " · \(r.files.formatted()) files" + (r.truncated ? " (stopped early)" : "")
                     + (r.unreadable > 0 ? " · \(r.unreadable) unreadable" : ""))
                    .font(GridFont.small).foregroundStyle(theme.text).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .task(id: measure == .running) {
            guard measure == .running else { return }
            let url = entry.url
            // Runs off-main and stops promptly when cancelled (card hidden, selection changed, Stop).
            let flag = CancelFlag()
            let r = await withTaskCancellationHandler {
                await Task.detached(priority: .utility) { FolderMeasure.measure(url, isCancelled: { flag.isSet }) }.value
            } onCancel: { flag.set() }
            if !Task.isCancelled { measure = .done(r) }
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            SectionLabel(k).frame(width: 70, alignment: .leading)
            Text(v).font(GridFont.small).foregroundStyle(theme.text)
                .lineLimit(widget.expanded ? 4 : 1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func previewView(_ p: InspectorContent.Preview) -> some View {
        switch p {
        case .loading: EmptyView()
        case .none(let why): Text(why).font(GridFont.small).foregroundStyle(theme.textMute)
        case .text(let s, let truncated):
            Text(String(s.prefix(2400)) + (truncated || s.count > 2400 ? "\n…" : ""))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.textDim)
                .lineLimit(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6).background(theme.bg1)
                .overlay(Rectangle().stroke(theme.line, lineWidth: Metrics.hairline))
        case .image(let img):
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 160)
                .background(theme.bg1)
                .overlay(Rectangle().stroke(theme.line, lineWidth: Metrics.hairline))
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button("Insert") { app.insertPathsIntoTerminal([entry.url]) }
                .buttonStyle(GridButtonStyle(prominent: true, compact: true))
                .help("Insert the quoted path at the terminal prompt (nothing runs)")
            Button("Copy") { app.files.copyPaths([entry.url]); app.flash(.info, "Copied path") }
                .help("Copy the path")
            Button("Look") { QuickLook.shared.show([entry.url]) }
                .help("Quick Look")
            Button(entry.isNavigableFolder ? "cd" : "Term") {
                app.openTerminalHere(entry.isNavigableFolder ? entry.url : entry.url.deletingLastPathComponent())
            }
            .help(entry.isNavigableFolder ? "New terminal in this folder" : "New terminal in the enclosing folder")
            Spacer(minLength: 0)
        }
        .buttonStyle(GridButtonStyle(compact: true))
    }
}

/// Thread-safe cancellation flag for work running on a detached task.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

// MARK: - Several items

private struct MultiInspector: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let entries: [FileEntry]

    var body: some View {
        let folders = entries.filter(\.isNavigableFolder).count
        let bytes = entries.compactMap(\.size).reduce(0, +)
        let urls = entries.map(\.url)
        VStack(alignment: .leading, spacing: 8) {
            Readout(label: "items", value: "\(entries.count)", detail: "\(entries.count - folders) files · \(folders) folders")
            Readout(label: "size", value: Formatters.size(bytes), detail: folders > 0 ? "folders not counted" : "")
            VStack(alignment: .leading, spacing: 3) {
                SectionLabel("inserts as")
                Text(ShellQuoting.insertionText(forPaths: urls.map(\.path)))
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(theme.accent)
                    .lineLimit(3).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(theme.bg1)
                    .overlay(Rectangle().stroke(theme.line, lineWidth: Metrics.hairline))
            }
            HStack(spacing: 4) {
                Button("Insert \(entries.count)") { app.insertPathsIntoTerminal(urls) }
                    .buttonStyle(GridButtonStyle(prominent: true, compact: true))
                Button("Copy") { app.files.copyPaths(urls); app.flash(.info, "Copied paths") }
                Button("Look") { QuickLook.shared.show(urls) }
                Spacer(minLength: 0)
            }
            .buttonStyle(GridButtonStyle(compact: true))
        }
    }
}
