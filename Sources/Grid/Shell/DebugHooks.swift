#if DEBUG
import AppKit
import GridCore

/// DEBUG-ONLY automation hooks used by scripts/qa.
///
/// Defense in depth, because these commands can type into a shell:
/// - Compiled out of release builds (`#if DEBUG`).
/// - Even in debug builds, only enabled when GRID is launched with `--qa`
///   (`open build/GRID.app --args --qa`); the status bar then shows "QA HOOKS".
///   Add `--qa-quiet` to hide that badge (for README screenshots).
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
        // Records every system menu that starts tracking (to catch native menus slipping through).
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
            guard let m = n.object as? NSMenu, m.supermenu == nil, m !== NSApp.mainMenu else { return }
            let titles = m.items.map { $0.isSeparatorItem ? "—" : $0.title }
            MainActor.assumeIsolated { nativeMenusShown.append("begin: " + titles.joined(separator: " | ")) }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { n in
            guard let m = n.object as? NSMenu, m.supermenu == nil, m !== NSApp.mainMenu else { return }
            let titles = m.items.map { $0.isSeparatorItem ? "—" : $0.title }
            MainActor.assumeIsolated { nativeMenusShown.append("end: [\(titles.count) items] " + titles.joined(separator: " | ")) }
        }
    }

    /// System menus that began tracking since launch (titles of their items).
    static var nativeMenusShown: [String] = []

    /// Compact text form of a split tree, e.g. "H[1 0.50 | V[2 0.50 / 3 0.50] 0.50]".
    static func describe(_ t: SplitTree, _ tab: TerminalTab) -> String {
        switch t {
        case .leaf(let id): return "\(tab.session(id)?.number ?? 0)"
        case .split(_, let axis, let children, let f):
            let parts = zip(children, f).map { describe($0.0, tab) + String(format: " %.2f", $0.1) }
            return (axis == .horizontal ? "H[" : "V[") + parts.joined(separator: axis == .horizontal ? " | " : " / ") + "]"
        }
    }

    /// The location state's name only: QA output never contains coordinates.
    static func locationCase(_ s: LocationProvider.State) -> String {
        switch s {
        case .idle: "idle"; case .explaining: "explaining"; case .asking: "asking"; case .locating: "locating"
        case .fix: "fix"; case .denied: "denied"; case .restricted: "restricted"; case .servicesOff: "servicesOff"
        case .failed: "failed"
        }
    }

    static func describePanels(_ t: SplitTree) -> String {
        switch t {
        case .leaf(let id): return WorkspacePanel(nodeID: id)?.rawValue ?? "?"
        case .split(_, let axis, let children, let f):
            let parts = zip(children, f).map { describePanels($0.0) + String(format: " %.2f", $0.1) }
            return (axis == .horizontal ? "H[" : "V[") + parts.joined(separator: axis == .horizontal ? " | " : " / ") + "]"
        }
    }

    static func target(_ s: String, _ app: AppState) -> DockTarget? {
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "panel": return parts.count == 2 ? WorkspacePanel(rawValue: parts[1]).map { .panel($0) } : nil
        case "pane":   // by session number in the active tab
            guard parts.count == 2, let n = Int(parts[1]), let s = app.terminals.activeTab?.panes.first(where: { $0.number == n }) else { return nil }
            return .pane(s.id)
        case "tab":    // by position (1-based)
            guard parts.count == 2, let n = Int(parts[1]), app.terminals.tabs.indices.contains(n - 1) else { return nil }
            return .tab(app.terminals.tabs[n - 1].id)
        case "tabBar": return .tabBar
        case "widgetEnd": return .widgetEnd
        case "widget":    // by deck position (1-based)
            guard parts.count == 2, let n = Int(parts[1]), app.widgets.widgets.indices.contains(n - 1) else { return nil }
            return .widget(app.widgets.widgets[n - 1].id)
        default: return nil
        }
    }

    /// CGWindowListCreateImage is marked unavailable from the macOS 15 SDK on, but still works for an
    /// app's own windows without Screen Recording permission (ScreenCaptureKit always asks). QA only.
    static func captureWindow(_ id: CGWindowID) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        let opts = CGWindowListOption.optionIncludingWindow.rawValue
        let image = CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue
        return fn(.null, opts, id, image)?.takeRetainedValue()
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
            if let img = DebugHooks.captureWindow(CGWindowID(w.windowNumber)) {
                let rep = NSBitmapImageRep(cgImage: img)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        case "windows":
            // {"cmd":"windows","path":"<dir>"}: real pixels of every visible GRID window (menus,
            // floating widgets), one PNG each, plus frames.json (screen frames, bottom-left origin).
            guard let dir = c["path"] as? String else { return }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var frames: [[String: Any]] = []
            for (i, w) in NSApp.windows.enumerated() where w.isVisible && w.windowNumber > 0 {
                guard let img = DebugHooks.captureWindow(CGWindowID(w.windowNumber)) else { continue }
                let name = "w\(i).png"
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/" + name))
                frames.append(["file": name, "class": String(describing: type(of: w)), "frame": [w.frame.minX, w.frame.minY, w.frame.width, w.frame.height]])
            }
            if let data = try? JSONSerialization.data(withJSONObject: frames) { try? data.write(to: URL(fileURLWithPath: dir + "/frames.json")) }
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
            case "systemMenus": app.settings.systemMenus = on
            case "globeActive": GlobeView.debugForceActive = on
            case "globeNoLabels": GlobeRenderer.debugNoLabels = on
            case "mapActive": MapRenderer.debugForceActive = on
            case "filesGrid": app.settings.filesGrid = on; CascadeClock.shared.start()
            case "startup": app.settings.startupAnimation = on
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
        case "shortcut":
            // {"cmd":"shortcut","command":"splitRight","key":"e","mods":["command","option"]} | "reset":true | "resetAll":true
            if (c["resetAll"] as? Bool) == true { app.shortcuts.resetAll(); app.flash(.info, "reset all"); break }
            guard let cmd = GridCommand(rawValue: c["command"] as? String ?? "") else { break }
            if (c["reset"] as? Bool) == true { app.shortcuts.reset(cmd); app.flash(.info, "reset"); break }
            let mods = Set(((c["mods"] as? [String]) ?? []).compactMap(KeyBinding.Modifier.init(rawValue:)))
            let err = app.shortcuts.assign(KeyBinding(c["key"] as? String ?? "", mods), to: cmd)
            app.flash(err == nil ? .info : .error, err ?? "assigned")
        case "pressKeyEquiv":
            // A key equivalent the way a real keypress travels: the window's views first (a focused
            // web page sees it there), then the menu bar. {"chars":"w","mods":["command"],"focusWeb":true,"path":..}
            guard let w = window, let chars = c["chars"] as? String else { break }
            var flags: NSEvent.ModifierFlags = []
            for m in (c["mods"] as? [String]) ?? [] {
                switch m { case "command": flags.insert(.command); case "option": flags.insert(.option)
                case "shift": flags.insert(.shift); case "control": flags.insert(.control); default: break }
            }
            if (c["focusWeb"] as? Bool) == true, let wv = app.browser.active?.webViewIfLoaded { w.makeFirstResponder(wv) }
            var owners: [String] = []
            func walk(_ m: NSMenu) {
                m.update()
                for item in m.items {
                    if item.keyEquivalent == chars && item.keyEquivalentModifierMask == flags { owners.append("\(item.title) enabled=\(item.isEnabled)") }
                    if let sub = item.submenu { walk(sub) }
                }
            }
            if let main = NSApp.mainMenu { walk(main) }
            let responder = w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let fileMenu = NSApp.mainMenu?.items.first { $0.submenu?.title == "File" }?.submenu
            let fileItems = fileMenu?.items.map { "\($0.title) [\($0.keyEquivalent)|\($0.keyEquivalentModifierMask.rawValue)] enabled=\($0.isEnabled)" } ?? []
            if let path {
                let info: [String: Any] = ["owners": owners, "firstResponder": responder, "file": fileItems]
                if let data = try? JSONSerialization.data(withJSONObject: info) { try? data.write(to: URL(fileURLWithPath: path)) }
            }
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: 13) {
                if !w.performKeyEquivalent(with: e) { _ = NSApp.mainMenu?.performKeyEquivalent(with: e) }
            }
        case "menuKeys":
            // Writes the live menu bar's key equivalents for the given item titles.
            guard let path, let titles = c["titles"] as? [String] else { break }
            var out: [String: String] = [:]
            func walk(_ m: NSMenu) {
                for item in m.items {
                    if titles.contains(item.title) {
                        let f = item.keyEquivalentModifierMask
                        out[item.title] = (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") +
                            (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "") + item.keyEquivalent
                    }
                    if let sub = item.submenu { walk(sub) }
                }
            }
            // Let menus refresh first, exactly as AppKit does before showing or matching them.
            func refresh(_ m: NSMenu) {
                m.delegate?.menuNeedsUpdate?(m)
                m.update()
                for item in m.items { if let sub = item.submenu { refresh(sub) } }
            }
            if let main = NSApp.mainMenu { refresh(main); walk(main) }
            if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) { try? data.write(to: URL(fileURLWithPath: path)) }
        case "keyEquiv":
            // Sends a key-down through the menu bar's key-equivalent matching, like a real keypress.
            // {"cmd":"keyEquiv","chars":"e","mods":["command","option"],"path":...}
            guard let path, let chars = c["chars"] as? String, let w = window else { break }
            var flags: NSEvent.ModifierFlags = []
            for m in (c["mods"] as? [String]) ?? [] {
                switch m { case "command": flags.insert(.command); case "option": flags.insert(.option)
                case "shift": flags.insert(.shift); case "control": flags.insert(.control); default: break }
            }
            let fkeys: [String: Int] = ["f6": NSF6FunctionKey]
            let ch = fkeys[chars].flatMap { UnicodeScalar($0).map { String(Character($0)) } } ?? chars
            let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: w.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                      isARepeat: false, keyCode: UInt16((c["keyCode"] as? Int) ?? (chars == "f6" ? 97 : 0)))
            // Dispatch like a real keypress (window → menus), not by calling the menu directly.
            if let ev { NSApp.sendEvent(ev) }
            try? "sent".write(toFile: path, atomically: true, encoding: .utf8)
        case "workspace":
            // {"cmd":"workspace","op":"move","panel":"deck","target":"files","edge":"left"} | "hide"/"show" panel | "reset"
            let ws = app.workspace
            let panel = WorkspacePanel(rawValue: c["panel"] as? String ?? "")
            switch c["op"] as? String {
            case "move":
                if let panel, let t = WorkspacePanel(rawValue: c["target"] as? String ?? ""), let e = DropEdge(rawValue: c["edge"] as? String ?? "") {
                    ws.move(panel, to: t, edge: e)
                }
            case "hide": if let panel { app.closePanel(panel) }
            case "show": if let panel { ws.show(panel) }
            case "reset": ws.reset()
            default: break
            }
        case "dockDrag":
            // Simulates a GRID drag through the real controller (hit testing + drop):
            // {"cmd":"dockDrag","payload":"grid-panel:deck","to":"panel:files","edge":"left"}
            //   picks a point inside the target's registered frame near that edge.
            // or {"cmd":"dockDrag","payload":"...","points":[[x,y],...],"commit":true} in window coordinates.
            guard let p = DragPayload(c["payload"] as? String ?? "") else { break }
            var pts: [CGPoint] = ((c["points"] as? [[Double]]) ?? []).map { CGPoint(x: $0[0], y: $0[1]) }
            if pts.isEmpty, let to = c["to"] as? String, let t = DebugHooks.target(to, app), let r = DockDrag.shared.frame(of: t) {
                let e = DropEdge(rawValue: c["edge"] as? String ?? "")
                var pt = CGPoint(x: r.midX, y: r.midY)
                switch e { case .left?: pt.x = r.minX + r.width * 0.1; case .right?: pt.x = r.maxX - r.width * 0.1
                case .top?: pt.y = r.minY + r.height * 0.1; case .bottom?: pt.y = r.maxY - r.height * 0.1; case nil: break }
                pts = [CGPoint(x: pt.x + 30, y: pt.y + 30), pt]
            }
            DockDrag.shared.simulate(p, label: (c["label"] as? String) ?? "qa", points: pts,
                                     commit: (c["commit"] as? Bool) ?? true, hold: (c["hold"] as? Bool) ?? false)
        case "dockEnd":
            DockDrag.shared.finishSimulated(commit: (c["commit"] as? Bool) ?? true)
        case "movePane":
            // {"cmd":"movePane","from":<session number>,"to":<session number>,"edge":"bottom"} within the active tab
            if let t = app.terminals.activeTab, let f = c["from"] as? Int, let to = c["to"] as? Int, let e = DropEdge(rawValue: c["edge"] as? String ?? ""),
               let a = t.panes.first(where: { $0.number == f }), let b = t.panes.first(where: { $0.number == to }) {
                t.movePane(a.id, to: b.id, edge: e)
            }
        case "find":
            // {"cmd":"find","query":"x","regex":false,"case":false} ; {"cmd":"find","op":"next"|"prev"|"close"}
            guard let s = app.terminals.active else { break }
            switch c["op"] as? String {
            case "next": s.find.next(s.view)
            case "prev": s.find.previous(s.view)
            case "close": s.find.close(s.view)
            default:
                s.find.open()
                s.find.regex = (c["regex"] as? Bool) ?? false
                s.find.caseSensitive = (c["case"] as? Bool) ?? false
                s.find.query = (c["query"] as? String) ?? ""
                s.find.update(s.view)
            }
        case "resizePane":
            // {"cmd":"resizePane","delta":0.2}: moves the first divider of the active tab's root split
            if let t = app.terminals.activeTab, case .split(let sid, _, _, _) = t.layout {
                t.resize(split: sid, divider: 0, by: (c["delta"] as? Double) ?? 0.1, minFraction: 0.1)
            }
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
            case "moveToEnd": app.widgets.place(w.id, at: nil, edge: nil)
            case "sideBySide": app.widgets.arrangeSideBySide()
            case "stack": app.widgets.arrangeStacked()
            case "set": app.widgets.set(w.id, c["key"] as? String ?? "", c["value"] as? String)
            default: break
            }
        case "menu":
            // GRID menus. {"op":"rightClick","x":..,"y":..,"shift":bool} (window points, top-left origin)
            // | {"op":"hover"|"click","sx":..,"sy":..} (screen points) | {"op":"key","key":"down|up|left|right|return|esc"|"char":"x"}
            // | {"op":"state","path":..} | {"op":"shot","path":"<dir>"} (one PNG per open level) | {"op":"dismiss"}
            let menu = GridMenu.shared
            func post(_ type: NSEvent.EventType, screen p: NSPoint, in w: NSWindow, flags: NSEvent.ModifierFlags = []) {
                let local = w.convertPoint(fromScreen: p)
                if let e = NSEvent.mouseEvent(with: type, location: local, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            func windowAt(_ p: NSPoint) -> NSWindow? {
                NSApp.windows.filter { $0.isVisible && $0.frame.contains(p) }.max { $0.level.rawValue < $1.level.rawValue } ?? window
            }
            switch c["op"] as? String {
            case "rightClick":
                guard let w = window, let x = c["x"] as? Double, let y = c["y"] as? Double else { break }
                let p = w.convertPoint(toScreen: NSPoint(x: x, y: w.frame.height - y))
                let flags: NSEvent.ModifierFlags = (c["shift"] as? Bool) == true ? [.shift] : []
                post(.rightMouseDown, screen: p, in: w, flags: flags)
                post(.rightMouseUp, screen: p, in: w, flags: flags)
            case "hover", "click":
                guard let x = c["sx"] as? Double, let y = c["sy"] as? Double else { break }
                let p = NSPoint(x: x, y: y)
                guard let w = windowAt(p) else { break }
                if c["op"] as? String == "hover" {
                    post(.mouseMoved, screen: p, in: w)
                } else {
                    post(.leftMouseDown, screen: p, in: w)
                    post(.leftMouseUp, screen: p, in: w)
                }
            case "key":
                let codes: [String: UInt16] = ["down": 125, "up": 126, "left": 123, "right": 124, "return": 36, "esc": 53]
                let ch = c["char"] as? String ?? ""
                let code = codes[c["key"] as? String ?? ""] ?? 0
                if let w = window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: w.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                                            isARepeat: false, keyCode: code) {
                    NSApp.postEvent(e, atStart: false)
                }
            case "dismiss":
                menu.dismiss()
            case "state":
                guard let path else { break }
                func kind(_ i: GridMenuItem) -> String {
                    switch i.kind { case .action: "action"; case .submenu: "submenu"; case .separator: "separator"; case .header: "header" }
                }
                let st: [String: Any] = [
                    "open": menu.isOpen,
                    "native": DebugHooks.nativeMenusShown,
                    "globeFrames": GlobeRenderer.debugFrames,
                    "window": window.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? [],
                    "levels": menu.debugLevels.map { l in [
                        "title": l.title ?? "", "highlighted": l.highlighted ?? -1,
                        "frame": [l.frame.minX, l.frame.minY, l.frame.width, l.frame.height],
                        "items": l.items.map { ["title": $0.title, "kind": kind($0), "enabled": $0.enabled, "shortcut": $0.shortcut,
                                                "destructive": $0.destructive, "checked": $0.checked] },
                    ] as [String: Any] },
                ]
                if let data = try? JSONSerialization.data(withJSONObject: st, options: [.prettyPrinted]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            case "shot":
                guard let path else { break }
                // Renders each menu panel's views (works while the screen is locked or asleep).
                for (i, l) in menu.debugLevels.enumerated() {
                    guard let w = NSApp.window(withWindowNumber: l.windowNumber), let v = w.contentView, let layer = v.layer else { continue }
                    let scale = w.backingScaleFactor
                    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * scale), pixelsHigh: Int(v.bounds.height * scale),
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { continue }
                    let cg = ctx.cgContext
                    cg.scaleBy(x: scale, y: scale)
                    cg.translateBy(x: 0, y: v.bounds.height); cg.scaleBy(x: 1, y: -1)
                    layer.render(in: cg)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + "/level-\(i).png"))
                }
            default: break
            }
        case "browser":
            // {"cmd":"browser","op":"open|go|close|reader|theme|block|eval|state|reload|find","url":..,"js":..,"path":..}
            let b = app.browser
            switch c["op"] as? String {
            case "open": if let u = (c["url"] as? String).flatMap(URL.init(string:)) { b.open(u, newTab: (c["newTab"] as? Bool) ?? true) }
            case "go": b.go(c["text"] as? String ?? "")
            case "close": if let t = b.active { b.close(t.id) }
            case "reload": b.active?.reload()
            case "reader": Task { await b.toggleReader() }
            case "theme": b.active?.setThemeEnabled((c["on"] as? Bool) ?? !(b.active?.themeActive ?? false))
            case "block": if let t = b.active, let site = SiteKey.of(t.failedURL ?? t.url) { b.adBlocker.setBlocking((c["on"] as? Bool) ?? true, for: site); t.reload() }
            case "eval":
                guard let t = b.active, t.isLoaded, let js = c["js"] as? String, let path else { break }
                t.webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { r in
                    let out: String
                    switch r {
                    case .success(let v): out = (v as? String) ?? String(describing: v)
                    case .failure(let e): out = "ERROR: \(e)"
                    }
                    try? out.write(toFile: path, atomically: true, encoding: .utf8)
                }
            case "installExtension":
                if #available(macOS 15.4, *), let ext = b.extensions, let p = c["path"] as? String {
                    Task { await ext.install(from: URL(fileURLWithPath: p), app: app) }
                }
            case "extAction":
                if #available(macOS 15.4, *), let ext = b.extensions, let a = ext.actions(for: b.active).first { ext.perform(a.item, tab: b.active) }
            case "snapReader":
                guard let w = ReaderView.lastWebView, let path else { break }
                w.takeSnapshot(with: nil) { img, _ in
                    guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            case "snap":
                // WebKit's own snapshot (works while the window is in the background).
                guard let t = b.active, t.isLoaded, let path else { break }
                t.webView.takeSnapshot(with: nil) { img, _ in
                    guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            case "state":
                guard let path else { break }
                var st: [String: Any] = ["tabs": b.tabs.map { t -> [String: Any] in
                    ["url": t.url?.absoluteString ?? "", "title": t.title, "loading": t.isLoading, "loaded": t.isLoaded,
                     "theme": t.themeActive, "blocking": t.blockingActive, "reader": t.reader?.title ?? "", "error": t.loadError ?? "",
                     "active": t.id == b.activeID]
                }]
                st["popoverWindows"] = NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).lowercased().contains("popover") }.map { "\(type(of: $0)) \(Int($0.frame.width))x\(Int($0.frame.height))" }
                // Page / reader view rectangles in window points (top-left origin), for screenshot compositing.
                func rect(_ v: NSView?) -> [Double] {
                    guard let v, let win = v.window else { return [] }
                    let r = v.convert(v.bounds, to: nil)
                    return [Double(r.minX), Double(win.frame.height - r.maxY), Double(r.width), Double(r.height), Double(win.frame.width), Double(win.frame.height)]
                }
                st["webFrame"] = rect(b.active?.webViewIfLoaded)
                st["readerFrame"] = rect(ReaderView.lastWebView)
                st["adblock"] = "\(b.adBlocker.status)"
                st["adblockLists"] = b.adBlocker.ruleLists.count
                st["adblockStats"] = b.adBlocker.stats
                st["notice"] = app.notice?.text ?? ""
                st["confirmation"] = app.confirmation?.title ?? ""
                if #available(macOS 15.4, *) {
                    st["extensions"] = b.extensions?.items.map { item -> String in
                        let ctx = item.context
                        let url = b.active?.url
                        return "\(item.name) enabled=\(item.enabled) loaded=\(ctx?.isLoaded ?? false) access=\(url.map { ctx?.hasAccess(to: $0) ?? false } ?? false) granted=\(ctx?.grantedPermissionMatchPatterns.keys.map(\.string) ?? []) errors=\(item.errors + (ctx?.errors.map(\.localizedDescription) ?? []))"
                    } ?? []
                    st["tabHasController"] = b.active.map { $0.isLoaded && $0.webView.configuration.webExtensionController != nil } ?? false
                }
                if let d = try? JSONSerialization.data(withJSONObject: st, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: path)) }
            default: break
            }
        case "addCustom":
            if let r = c["ref"] as? String { _ = app.widgets.add(.custom, config: ["package": r]) }
        case "approveWidget":
            if let r = c["ref"] as? String { app.widgetLibrary.approve(r) }
        case "approvePending":
            if let r = app.widgetApproval { app.widgetApproval = nil; if (c["approve"] as? Bool) ?? true { r.onApprove() } }
        case "reviewWidget":
            if let r = c["ref"] as? String { WidgetApprovalRequest.review(r, app: app) }
        case "widgetReload":
            app.widgetLibrary.reload()
        case "widgetPerform":
            // {"cmd":"widgetPerform","index":<card>,"action":<n-th clickable action in its tree>}
            let idx = (c["index"] as? Int) ?? 0
            guard app.widgets.widgets.indices.contains(idx), let rt = WidgetRuntime.live[app.widgets.widgets[idx].id]?.value else { break }
            let acts = rt.actionsForQA
            let n = (c["action"] as? Int) ?? 0
            if acts.indices.contains(n) { rt.perform(acts[n]) }
        case "widgets":
            guard let path else { break }
            let lib = app.widgetLibrary
            var cards: [[String: Any]] = []
            for w in app.widgets.widgets {
                var d: [String: Any] = ["kind": w.kind.rawValue]
                if w.kind == .custom {
                    let ref = w.string("package", "")
                    d["ref"] = ref
                    d["status"] = "\(lib.status(ref))"
                    if let rt = WidgetRuntime.live[w.id]?.value {
                        d["phase"] = "\(rt.phase)"
                        d["tree"] = rt.tree.map { String(describing: $0).prefix(3000).description } ?? ""
                        d["actions"] = rt.actionsForQA.map { "\($0.kind):\($0.value ?? "")" }
                    }
                }
                cards.append(d)
            }
            let out: [String: Any] = [
                "entries": lib.entries.map { ["ref": $0.ref, "error": $0.error ?? "", "status": "\(lib.status($0.ref))"] },
                "cards": cards,
                "logs": lib.logs.mapValues { $0.suffix(30).map { "[\($0.level)] \($0.text)" } },
                "approvalPending": app.widgetApproval?.package.manifest.id ?? "",
                "confirmation": app.confirmation?.title ?? "",
                "notice": app.notice?.text ?? "",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
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
            // Outline: {"expand":"/path","recursive":true} | {"collapse":"/path"} | {"key":"left"|"right","option":true}
            if let p = c["expand"] as? String { app.files.expand(p, recursive: (c["recursive"] as? Bool) ?? false) }
            if let p = c["collapse"] as? String { app.files.collapse(p) }
            switch c["key"] as? String {
            case "right": app.files.expandOrDescend(option: (c["option"] as? Bool) ?? false)
            case "left": app.files.collapseOrAscend()
            case "down": app.files.moveSelection(1)
            case "up": app.files.moveSelection(-1)
            default: break
            }
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
                return ["id": s.id.uuidString, "number": s.number, "pid": s.shellPID, "cwd": s.cwd ?? "", "fg": s.foregroundName ?? "",
                        "cols": s.columns, "rows": s.rows, "exited": s.exited, "exitCode": s.exitCode.map { Int($0) } ?? -999,
                        "title": s.programTitle, "focus": s.hasFocus, "bell": s.bellPending,
                        "find": ["visible": s.find.visible, "index": s.find.index, "total": s.find.total, "invalid": s.find.invalidPattern], "metal": s.view.isUsingMetalRenderer,
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
                          "undo": app.fileOps.undoLabel ?? "", "expanded": app.files.expandedVisibleCount,
                          "rows": app.files.rows.map { r -> String in
                              let name: String
                              switch r.kind { case .entry(let e): name = e.name; case .loading: name = "(loading…)"; case .error(let m): name = "(error: \(m))" }
                              return String(repeating: "  ", count: r.depth) + (r.isExpanded ? "▾ " : "") + name
                          }],
                "apps": app.apps.records.count, "confirmation": app.confirmation?.code ?? "",
                "tabs": app.terminals.tabs.map { t in ["id": t.id.uuidString, "panes": t.panes.map(\.number), "layout": DebugHooks.describe(t.layout, t),
                                                         "focused": t.focused?.number ?? 0, "title": t.title] },
                "widgets": app.widgets.widgets.map { ["id": $0.id.uuidString, "kind": $0.kind.rawValue, "expanded": $0.expanded, "collapsed": $0.collapsed, "beside": $0.beside ?? false] },
                "deckRows": app.widgets.rows.map { $0.map(\.kind.rawValue).joined(separator: " | ") },
                "deck": app.deckVisible,
                "workspace": app.workspace.tree.map { DebugHooks.describePanels($0) } ?? "(empty)",
                "workspaceViewport": [app.workspace.viewport.width, app.workspace.viewport.height],
                "windowInfo": window.map { w in ["frame": NSStringFromRect(w.frame), "minSize": NSStringFromSize(w.minSize), "contentMinSize": NSStringFromSize(w.contentMinSize), "fitting": NSStringFromSize(w.contentView?.fittingSize ?? .zero)] } ?? [:],
                "drag": DockDrag.shared.payload?.string ?? "",
                "dockTargets": DockDrag.shared.debugFrames,
                "notice": app.notice?.text ?? "", "recents": app.apps.recents,
                "nowPlaying": ["player": app.nowPlaying.player?.name ?? "", "title": app.nowPlaying.track?.title ?? "",
                               "playing": app.nowPlaying.playing, "art": app.nowPlaying.artwork != nil, "active": app.nowPlaying.isActive,
                               "access": app.nowPlaying.access.map { "\($0.key.name)=\($0.value)" }.sorted(),
                               "position": app.nowPlaying.position(at: Date()) ?? -1],
                "floating": app.floatingWidgets.debugFrames(),
                "filesGrid": app.settings.filesGrid,
                "map": app.mapsIfLoaded.map { m -> [String: Any] in
                    let ll = TileMath.unproject(m.camera.center)
                    return ["enabled": m.enabled, "lon": ll.lon, "lat": ll.lat, "zoom": m.camera.zoom, "bearing": m.camera.bearing, "pitch": m.camera.pitch,
                            "viewport": [m.viewport.x, m.viewport.y],
                            "tilesLoaded": m.tiles.loadedCount, "tilesWanted": m.tiles.wantedCount, "tileErrors": m.tiles.errorCount,
                            "generation": m.tiles.generation, "source": m.tiles.source?.version ?? "", "sourceError": m.tiles.sourceError ?? "",
                            "cameras": m.alpr.index.cameras.count, "selected": m.selected ?? -1, "notice": m.notice ?? "", "alprError": m.alpr.lastError ?? "",
                            "catalog": m.alpr.catalog?.regions.count ?? 0, "catalogState": m.alpr.catalogState ?? "",
                            "regions": m.alpr.regions.map { ["id": $0.id, "name": $0.meta.descriptor.name, "count": $0.meta.cameraCount,
                                                             "status": "\($0.status)", "sources": $0.meta.sources.map(\.rawValue), "requests": $0.meta.requests] },
                            "location": Self.locationCase(m.location.state), "inView": m.camerasInViewCount(),
                            "loader": m.tiles.debugStats, "search": m.search.debugState,
                            "place": m.place.map { "\($0.name)|\($0.kind.rawValue)|\($0.detail)|\($0.source.rawValue)" } ?? "",
                            "showPlaces": m.showPlaces, "drawCount": MapContainerView.debugCurrent?.renderer.debugDrawCount ?? -1,
                            "drawnZoom": MapContainerView.debugCurrent?.renderer.debugDrawnZoom ?? -1,
                            "windowVisible": MapContainerView.debugCurrent?.window?.occlusionState.contains(.visible) ?? false, "hiddenCategories": m.hiddenCategories.map(\.short).sorted()]
                } ?? [:],
                "updates": ["current": app.updates.current.description, "latest": app.updates.latest?.tagName ?? "",
                            "available": app.updates.available?.tagName ?? "", "notice": app.updates.showsNotice,
                            "consent": app.updates.needsConsent ? "ask" : (app.updates.checksDaily ? "daily" : "off"),
                            "status": "\(app.updates.status)", "download": "\(app.updates.download)",
                            "lastCheck": app.updates.lastCheck.map { ISO8601DateFormatter().string(from: $0) } ?? ""],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: st, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        case "nowPlaying":
            // {"cmd":"nowPlaying","title":..,"artist":..,"album":..,"duration":s,"position":s,"playing":bool,"art":"<image path>","player":"music|spotify"}
            // Injects a track as if the player had announced it (no Apple Events, no audio).
            let player: NowPlaying.Player = (c["player"] as? String) == "spotify" ? .spotify : .music
            let art = (c["art"] as? String).flatMap { NSImage(contentsOfFile: $0) }?.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(ArtMatrix.init)
            app.nowPlaying.debugInject(player: player, title: c["title"] as? String, artist: c["artist"] as? String ?? "",
                                       album: c["album"] as? String ?? "", duration: c["duration"] as? Double,
                                       position: c["position"] as? Double, playing: (c["playing"] as? Bool) ?? true, art: art)
        case "slowMotion":
            // {"cmd":"slowMotion","factor":10} stretches the startup build-on and menu unfold.
            GridMotion.debugSlow = (c["factor"] as? Double) ?? 1
        case "replayStartup":
            NotificationCenter.default.post(name: .gridQAReplayStartup, object: nil)
        case "updates":
            // {"cmd":"updates","current":"0.4.0","feed":"<json path>"|"","reset":true,"check":true,"consent":true|false,"download":true}
            let u = app.updates
            if (c["reset"] as? Bool) == true { u.debugReset() }
            if let v = c["current"] as? String { u.debugSetCurrent(v) }
            if let f = c["feed"] as? String { u.debugFeed = f.isEmpty ? nil : URL(fileURLWithPath: f) }
            if let on = c["consent"] as? Bool { u.setCheckDaily(on) }
            if (c["check"] as? Bool) == true { Task { await u.check(manual: true) } }
            if (c["download"] as? Bool) == true { UpdateDownloader.run(u) }
            if (c["view"] as? Bool) == true { app.settingsSection = "updates"; app.show(.settings) }
        case "map":
            // {"cmd":"map","op":"enable"|"disable"|"camera"|"download"|"remove"|"select"|"clear"|"catalog"|"check"|"locate",
            //  "lon","lat","zoom","bearing","pitch", "rect":[w,s,e,n], "region":"us/rhode-island", "index":n, "id":regionId}
            let m = app.maps
            switch c["op"] as? String {
            case "enable": m.enabled = true; m.appeared()
            case "disable": m.enabled = false
            case "camera":
                var cam = m.camera
                if let lon = c["lon"] as? Double, let lat = c["lat"] as? Double { cam.center = TileMath.project(LonLat(lon: lon, lat: lat)) }
                if let z = c["zoom"] as? Double { cam.zoom = z }
                if let b = c["bearing"] as? Double { cam.bearing = b }
                if let p = c["pitch"] as? Double { cam.pitch = p }
                m.setCamera(cam)
            case "download":
                if let r = c["rect"] as? [Double], r.count == 4 {
                    let box = BBox(west: r[0], south: r[1], east: r[2], north: r[3])
                    let d = RegionDescriptor(id: "rect-qa-\(Int(r[0] * 100))", name: c["name"] as? String ?? "QA Area", parent: nil, iso3166_1: [], iso3166_2: [])
                    m.requestDownload(d, polygon: .rectangle(box), isRectangle: true)
                } else if let id = c["region"] as? String {
                    Task {
                        await m.alpr.loadCatalog()
                        if let cat = m.alpr.catalog, let r = cat.regions.first(where: { $0.id == id }), let poly = cat.polygon(id) {
                            m.requestDownload(r, polygon: poly, isRectangle: false)
                        }
                    }
                }
            case "remove": if let id = c["id"] as? String { m.alpr.remove(id) }
            case "select": m.select(c["index"] as? Int)
            case "clear": m.clearAllData()
            case "catalog": Task { await m.alpr.loadCatalog() }
            case "check": Task { await m.alpr.checkFreshness(manual: true) }
            case "locate": m.locate()
            case "gesture":
                // {"op":"gesture","seconds":4,"pan":[vx,vy],"zoom":dz/s,"rotate":deg/s,"pitch":deg/s,"fling":bool,"hz":120,
                //  "settle":8,"path":"<json out>"}: the deltas go through the map view's own gesture path
                // (view-local camera, renderer, model) at `hz`; the result has frame times, label lag
                // and tile coverage while moving and after the stop.
                guard let v = MapContainerView.debugCurrent, v.debugProbe == nil, let path = c["path"] as? String else { break }
                var spec = MapGestureProbe.Spec()
                if let s = c["seconds"] as? Double { spec.seconds = s }
                if let h = c["hz"] as? Double { spec.hz = h }
                if let p = c["pan"] as? [Double], p.count == 2 { spec.pan = SIMD2(p[0], p[1]) }
                if let z = c["zoom"] as? Double { spec.zoom = z }
                if let r = c["rotate"] as? Double { spec.rotate = r }
                if let p = c["pitch"] as? Double { spec.pitch = p }
                if let f = c["fling"] as? Bool { spec.fling = f }
                if let s = c["settle"] as? Double { spec.settle = s }
                let probe = MapGestureProbe(spec, view: v)
                let uploads0 = v.renderer.debugUploads, uploadMs0 = v.renderer.debugUploadMs
                probe.coverage = { [weak v] cam in
                    let cover = TileMath.cover(cam, viewport: m.viewport, maxZoom: m.tiles.source?.maxZoom ?? 14, limit: 48)
                    let (missing, holes) = m.tiles.debugCoverage(cover)
                    let drawn = v?.renderer.debugFrameTiles ?? []
                    var drawnMissing = 0, drawnHoles = 0
                    for t in cover where !drawn.contains(t) {
                        drawnMissing += 1
                        var p = TileMath.parent(t), steps = 0, found = false
                        while let q = p, steps < 8 { if drawn.contains(q) { found = true; break }; p = TileMath.parent(q); steps += 1 }
                        if !found { drawnHoles += 1 }
                    }
                    return ["cover": cover.count, "missing": missing, "holes": holes, "drawnMissing": drawnMissing, "drawnHoles": drawnHoles]
                }
                probe.done = { [weak v] result in
                    var r = result
                    r["gpuUploads"] = (v?.renderer.debugUploads ?? 0) - uploads0
                    r["gpuUploadMs"] = (v?.renderer.debugUploadMs ?? 0) - uploadMs0
                    r["loader"] = m.tiles.debugStats
                    if let data = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: URL(fileURLWithPath: path))
                    }
                }
                v.debugProbe = probe
                probe.begin()
            case "exaggeration": if let x = c["value"] as? Double { m.terrainExaggeration = x }
            case "search":
                // {"op":"search","query":"zermatt"} types into the search box; "online":true also searches
                // online (as ⌘⏎); "choose":n picks result n; "clear":true empties it.
                if c["clear"] as? Bool == true { m.search.clear() }
                if let q = c["query"] as? String { m.search.query = q }
                if c["online"] as? Bool == true { m.search.submit(forceOnline: true) }
                if let n = c["choose"] as? Int, m.search.results.indices.contains(n) { m.search.choose(m.search.results[n]) }
            case "click":
                if let x = c["x"] as? Double, let y = c["y"] as? Double { m.handle(.click(SIMD2(x, y))) }
            case "context":
                // Right-click menu at a view point (QA of the menu and terrain picking).
                if let x = c["x"] as? Double, let y = c["y"] as? Double { m.handle(.contextMenu(SIMD2(x, y), screen: SIMD2(400, 400))) }
            case "layer":
                if let k = c["key"] as? String, let on = c["value"] as? Bool {
                    switch k { case "cameras": m.showCameras = on; case "regions": m.showRegions = on; case "buildings": m.showBuildings = on; case "grid": m.showGrid = on; case "terrain": m.showTerrain = on; case "places": m.showPlaces = on; default: break }
                }
            default: break
            }
        case "floatShot":
            // {"cmd":"floatShot","path":"<dir>"}: one PNG per floating widget window (rendered layer tree).
            if let dir = c["path"] as? String { app.floatingWidgets.debugSnapshot(dir: dir) }
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }
}
#endif
