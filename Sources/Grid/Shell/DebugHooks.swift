#if DEBUG
import AppKit
import GridCore

/// DEBUG-ONLY automation hooks used by scripts/qa. Compiled out of release builds, so a shipped
/// GRID has no externally reachable control channel.
///
/// Commands arrive as a JSON string in the `object` of the distributed notification
/// "local.grid.debug", e.g. {"cmd":"snapshot","path":"/tmp/a.png"}.
@MainActor
enum DebugHooks {
    static func install(_ app: AppState) {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.grid.debug"), object: nil, queue: .main) { n in
            guard let s = n.object as? String, let data = s.data(using: .utf8),
                  let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            MainActor.assumeIsolated { handle(cmd, app) }
        }
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
                        "title": s.programTitle, "focus": s.hasFocus, "metal": s.view.isUsingMetalRenderer,
                        "screen": (s.view.terminalContentSnapshot(region: .viewport)?.rows.map { r in
                            var t = r.text; while t.last == " " { t.removeLast() }; return t } ?? []), "descendants": ProcessInspector.descendants(of: s.shellPID).map { Int($0) }]
            }
            let errorText: String = app.files.error.map { "\($0)" } ?? ""
            let st: [String: Any] = [
                "panel": app.panel.rawValue, "sessions": sessions, "active": app.terminals.active?.number ?? 0,
                "files": ["dir": app.files.currentURL.path, "count": app.files.visible.count, "error": errorText,
                          "deep": app.files.deepResults.count, "deepRunning": app.files.deepRunning,
                          "selected": app.files.selectionID ?? ""],
                "apps": app.apps.records.count, "confirmation": app.confirmation?.code ?? "",
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
