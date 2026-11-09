#if DEBUG
import AppKit
import GridCore

/// DEBUG-ONLY automation hooks used by scripts/qa.
///
/// Defense in depth, because these commands can type into a shell:
/// - Compiled out of release builds (`#if DEBUG`).
/// - Even in debug builds, only enabled when GRID is launched with `--qa`
///   (`open build/GRID.app --args --qa`); the status bar then shows "QA HOOKS".
/// - Transport is a Unix-domain socket inside the per-user temp directory
///   (`$DARWIN_USER_TEMP_DIR`, mode 0700, unreachable from other users and from sandboxed
///   apps), the socket itself is 0600, and every connection's peer UID is checked.
///   (A distributed notification was used before; any app in the session can post those.)
///
/// Protocol: connect, write one JSON object, close. E.g. {"cmd":"snapshot","path":"/tmp/a.png"}.
@MainActor
enum DebugHooks {
    static var enabled: Bool { CommandLine.arguments.contains("--qa") }
    static var socketPath: String { (NSTemporaryDirectory() as NSString).appendingPathComponent("grid-qa.sock") }
    private static var server: QASocketServer?

    static func install(_ app: AppState) {
        guard enabled else { return }
        server = QASocketServer(path: socketPath) { text in
            guard let data = text.data(using: .utf8),
                  let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { handle(cmd, app) } }
        }
    }

    static func uninstall() {
        server?.stop()
        server = nil
    }

    private static var window: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    static func handle(_ c: [String: Any], _ app: AppState) {
        let path = c["path"] as? String
        switch c["cmd"] as? String {
        case "snapshot":
            guard let w = window, let v = w.contentView, let path else { return }
            // Render the window's view hierarchy (includes the terminal) into a PNG.
            // Render the CALayer tree (captures SwiftTerm's layer-backed drawing, which
            // cacheDisplay misses). No screen-recording permission involved: own window only.
            guard let layer = v.layer else { return }
            let scale = w.backingScaleFactor
            let px = NSSize(width: v.bounds.width * scale, height: v.bounds.height * scale)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
            let cg = ctx.cgContext
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: 0, y: v.bounds.height); cg.scaleBy(x: 1, y: -1)
            layer.render(in: cg)
            // Terminal views draw on demand (draw(_:)); composite them explicitly on top.
            for s in app.terminals.sessions where s.view.window != nil && !s.view.isHiddenOrHasHiddenAncestor
                && !app.paletteOpen && app.confirmation == nil {
                let tv = s.view
                let r = tv.convert(tv.bounds, to: v)
                guard let trep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds) else { continue }
                tv.cacheDisplay(in: tv.bounds, to: trep)
                if let img = trep.cgImage {
                    let y = v.isFlipped ? r.minY : v.bounds.height - r.maxY
                    cg.saveGState()
                    cg.translateBy(x: r.minX, y: y + r.height); cg.scaleBy(x: 1, y: -1)
                    cg.draw(img, in: CGRect(origin: .zero, size: r.size))
                    cg.restoreGState()
                }
            }
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        case "screen":
            // Real composited pixels of our own window (no Screen Recording permission needed
            // for an app's own windows).
            guard let w = window, let path else { return }
            if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber),
                                                 [.boundsIgnoreFraming, .bestResolution]) {
                let rep = NSBitmapImageRep(cgImage: img)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        case "snapshotTerm":
            guard let v = app.terminals.active?.view, let path,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        case "panel":
            if let p = PanelID(rawValue: c["value"] as? String ?? "") { app.show(p) }
        case "palette":
            app.paletteOpen = (c["open"] as? Bool) ?? !app.paletteOpen
        case "type":
            if let t = c["text"] as? String { app.terminals.active?.view.send(txt: t) }
        case "drop":
            if let paths = c["paths"] as? [String] { app.terminals.active?.view.insertPaths(paths) }
        case "resize":
            if let w = window, let width = c["w"] as? Double, let height = c["h"] as? Double {
                var f = w.frame
                f.size = NSSize(width: width, height: height)
                w.setFrame(f, display: true)
            }
        case "newSession":
            app.newTerminal(at: c["dir"] as? String)
        case "closeSession":
            if let id = app.terminals.activeID { app.requestCloseTerminal(id) }
        case "confirm":
            if let conf = app.confirmation { app.confirmation = nil; conf.onConfirm() }
        case "setting":
            let on = (c["value"] as? Bool) ?? false
            switch c["key"] as? String {
            case "grid": app.settings.gridBackdrop = on
            case "glow": app.settings.glow = on
            case "motion": app.settings.motion = on
            default: break
            }
        case "click":
            if let id = c["id"] as? String { app.files.click(id, command: (c["command"] as? Bool) ?? false, shift: (c["shift"] as? Bool) ?? false) }
        case "fileop":
            let ops = app.fileOps
            let urls = app.files.selectedEntries.map(\.url)
            switch c["op"] as? String {
            case "newFolder": ops.newFolder()
            case "rename":
                if let e = app.files.selectedEntry, let name = c["name"] as? String {
                    let err = ops.rename(e, to: name)
                    app.flash(err == nil ? .info : .error, err ?? "renamed")
                    app.files.renamingID = nil
                }
            case "trash": ops.trash(urls)
            case "duplicate": ops.duplicate(urls)
            case "copy": ops.copyToPasteboard(urls)
            case "paste": ops.pasteFromPasteboard(into: app.files.currentURL, move: (c["move"] as? Bool) ?? false)
            case "transfer":
                if let paths = c["paths"] as? [String], let dir = c["dir"] as? String {
                    ops.transfer(paths.map { URL(fileURLWithPath: $0) }, into: URL(fileURLWithPath: dir), move: (c["move"] as? Bool) ?? false)
                }
            case "undo": ops.undo()
            case "alternate":
                if let conf = app.confirmation { app.confirmation = nil; conf.onAlternate() }
            default: break
            }
        case "split":
            app.split((c["axis"] as? String) == "down" ? .vertical : .horizontal)
        case "closeTab":
            if let id = app.terminals.activeTabID { app.requestCloseTab(id) }
        case "deck":
            app.deckVisible = (c["value"] as? Bool) ?? !app.deckVisible
        case "addWidget":
            if let k = WidgetKind(rawValue: c["kind"] as? String ?? "") { _ = app.widgets.add(k) }
        case "widget":
            // {"cmd":"widget","index":0,"op":"remove"|"expand"|"collapse"|"moveToEnd"|"set","key":..,"value":..}
            let idx = (c["index"] as? Int) ?? 0
            guard app.widgets.widgets.indices.contains(idx) else { break }
            let w = app.widgets.widgets[idx]
            switch c["op"] as? String {
            case "remove": app.widgets.remove(w.id)
            case "expand": app.widgets.update(w.id) { $0.expanded.toggle() }
            case "collapse": app.widgets.update(w.id) { $0.collapsed.toggle() }
            case "moveToEnd": app.widgets.move(w.id, before: nil)
            case "set": app.widgets.set(w.id, c["key"] as? String ?? "", c["value"] as? String)
            default: break
            }
        case "cancel":
            if let conf = app.confirmation { app.confirmation = nil; conf.onCancel() }
        case "present":
            app.present(Confirmation(code: "QA.TEST", title: "QA", message: "test", confirmLabel: "OK", destructive: false, onConfirm: {}))
        case "files":
            if let d = c["dir"] as? String { app.files.navigate(to: URL(fileURLWithPath: d)) }
            if let q = c["query"] as? String { app.files.query = q }
            if let m = c["mode"] as? String, let mode = FileSearchMode(rawValue: m) { app.files.mode = mode }
            if let sel = c["select"] as? String { app.files.selectionID = sel }
        case "sidebar":
            app.filesSidebar = (c["value"] as? Bool) ?? !app.filesSidebar
        case "theme":
            if let t = ThemeID(rawValue: c["value"] as? String ?? "") { app.setTheme(t) }
        case "openFile":
            if let p = c["path"] as? String { app.files.open(URL(fileURLWithPath: p)) }
        case "revealCwd":
            app.revealTerminalDirectoryInFiles()
        case "launch":
            if let name = c["name"] as? String, let r = app.apps.ranked(name).first { app.apps.launch(r) }
        case "state":
            guard let path else { return }
            let sessions: [[String: Any]] = app.terminals.sessions.map { s in
                s.refresh()
                return ["number": s.number, "pid": s.shellPID, "cwd": s.cwd ?? "", "fg": s.foregroundName ?? "",
                        "cols": s.columns, "rows": s.rows, "exited": s.exited, "exitCode": s.exitCode.map { Int($0) } ?? -999,
                        "title": s.programTitle, "focus": s.hasFocus, "bell": s.bellPending, "metal": s.view.isUsingMetalRenderer,
                        "screen": (s.view.terminalContentSnapshot(region: .viewport)?.rows.map { r in
                            var t = r.text; while t.last == " " { t.removeLast() }; return t } ?? []), "descendants": ProcessInspector.descendants(of: s.shellPID).map { Int($0) }]
            }
            let errorText: String = app.files.error.map { "\($0)" } ?? ""
            let st: [String: Any] = [
                "panel": app.panel.rawValue, "sessions": sessions, "active": app.terminals.active?.number ?? 0,
                "files": ["dir": app.files.currentURL.path, "count": app.files.visible.count, "error": errorText,
                          "deep": app.files.deepResults.count, "deepRunning": app.files.deepRunning,
                          "selected": app.files.selectionID ?? "", "selectedCount": app.files.selectedIDs.count,
                          "renaming": app.files.renamingID ?? "", "busy": app.fileOps.busy ?? "",
                          "undo": app.fileOps.undoLabel ?? ""],
                "apps": app.apps.records.count, "confirmation": app.confirmation?.code ?? "",
                "tabs": app.terminals.tabs.map { t in ["panes": t.panes.map(\.number), "axis": t.axis == .horizontal ? "h" : "v",
                                                         "focused": t.focused?.number ?? 0, "title": t.title] },
                "widgets": app.widgets.widgets.map { ["kind": $0.kind.rawValue, "expanded": $0.expanded, "collapsed": $0.collapsed] },
                "deck": app.deckVisible,
                "notice": app.notice?.text ?? "", "recents": app.apps.recents,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: st, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }
}
#endif
