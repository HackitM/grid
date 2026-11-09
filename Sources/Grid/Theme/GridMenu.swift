import AppKit
import SwiftUI

// GRID's own menus: right-click (context) menus and "⋯" pull-downs drawn in the app's design
// language instead of the system's. macOS doesn't let apps restyle NSMenu's frame and material,
// so these are small borderless panels that behave like menus: they open at the pointer (or
// under their button), stay on screen, never take keyboard focus from the window, close on any
// click outside, Esc, app switch or window move, and support arrow keys, Return, type-to-select,
// press-drag-release and submenus.
//
// With VoiceOver running, or when the user turns on "macOS menus" in Settings, the same items are
// shown as a standard NSMenu instead, so assistive technology gets the system menu it knows.

// MARK: - Model

struct GridMenuItem: Identifiable {
    enum Kind {
        case action(() -> Void)
        case submenu([GridMenuItem])
        case separator
        case header
    }

    let id = UUID()
    var title: String
    var kind: Kind
    var shortcut = ""
    var enabled = true
    var destructive = false
    var checked = false

    static func action(_ title: String, shortcut: String = "", enabled: Bool = true, destructive: Bool = false,
                       checked: Bool = false, _ perform: @escaping () -> Void) -> GridMenuItem {
        GridMenuItem(title: title, kind: .action(perform), shortcut: shortcut, enabled: enabled, destructive: destructive, checked: checked)
    }

    static func submenu(_ title: String, enabled: Bool = true, @GridMenuBuilder _ items: () -> [GridMenuItem]) -> GridMenuItem {
        let list = GridMenu.normalized(items())
        return GridMenuItem(title: title, kind: .submenu(list), enabled: enabled && !list.isEmpty)
    }

    static var divider: GridMenuItem { GridMenuItem(title: "", kind: .separator) }
    static func header(_ title: String) -> GridMenuItem { GridMenuItem(title: title, kind: .header, enabled: false) }

    /// Rows the highlight can land on.
    var isSelectable: Bool {
        guard enabled else { return false }
        switch kind {
        case .action: return true
        case .submenu(let s): return !s.isEmpty
        case .separator, .header: return false
        }
    }

    var children: [GridMenuItem]? { if case .submenu(let s) = kind { return s } else { return nil } }
}

@resultBuilder
enum GridMenuBuilder {
    static func buildExpression(_ item: GridMenuItem) -> [GridMenuItem] { [item] }
    static func buildExpression(_ items: [GridMenuItem]) -> [GridMenuItem] { items }
    static func buildBlock(_ parts: [GridMenuItem]...) -> [GridMenuItem] { parts.flatMap { $0 } }
    static func buildOptional(_ part: [GridMenuItem]?) -> [GridMenuItem] { part ?? [] }
    static func buildEither(first: [GridMenuItem]) -> [GridMenuItem] { first }
    static func buildEither(second: [GridMenuItem]) -> [GridMenuItem] { second }
    static func buildArray(_ parts: [[GridMenuItem]]) -> [GridMenuItem] { parts.flatMap { $0 } }
    static func buildLimitedAvailability(_ part: [GridMenuItem]) -> [GridMenuItem] { part }
}

// MARK: - Presenter

@MainActor
final class GridMenu {
    static let shared = GridMenu()

    enum Anchor {
        /// Top-left corner at a screen point (the pointer, for context menus).
        case point(NSPoint)
        /// Under a control's screen rectangle, right-aligned to it (for "⋯" buttons).
        case below(NSRect)
    }

    /// Provides the theme, effects and the "macOS menus" preference.
    weak var app: AppState?

    /// True while a GRID menu is on screen.
    var isOpen: Bool { !levels.isEmpty }

    private var levels: [GridMenuLevel] = []
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var onClose: (() -> Void)?
    private var openedAt = Date.distantPast
    private var openedAtMouse = NSPoint.zero
    private var downInMenu = false
    private var typed = ""
    private var typedAt = Date.distantPast
    private var submenuTimer: DispatchWorkItem?
    private var pendingSwitch: DispatchWorkItem?
    private var activating = false
    /// Set while `showModal` runs: the chosen action waits here instead of running async.
    private var modal = false
    private var modalAction: (() -> Void)?

    static let inset: CGFloat = 12          // transparent margin for the shadow and glow
    static let rowHeight: CGFloat = 24
    static let separatorHeight: CGFloat = 9
    static let headerRowHeight: CGFloat = 22
    static let titleHeight: CGFloat = 26
    static let padding: CGFloat = 4

    /// Whether menus are drawn by the system (VoiceOver, or the user's choice).
    var usesSystemMenus: Bool {
        NSWorkspace.shared.isVoiceOverEnabled || (app?.settings.systemMenus ?? false)
    }

    // MARK: Showing

    func show(_ raw: [GridMenuItem], title: String? = nil, anchor: Anchor, window: NSWindow?, onClose: (() -> Void)? = nil) {
        dismiss()
        let items = Self.normalized(raw)
        guard !items.isEmpty else { onClose?(); return }

        if usesSystemMenus {
            let menu = Self.nativeMenu(items, title: title)
            let p: NSPoint
            switch anchor {
            case .point(let pt): p = pt
            case .below(let r): p = NSPoint(x: r.minX, y: r.minY - 2)
            }
            menu.popUp(positioning: nil, at: p, in: nil)   // modal until the menu closes
            onClose?()
            return
        }

        self.onClose = onClose
        openedAt = Date()
        openedAtMouse = NSEvent.mouseLocation
        downInMenu = false
        typed = ""
        let level = GridMenuLevel(items: items, title: title, depth: 0)
        let screen = Self.screen(for: anchor) ?? window?.screen ?? NSScreen.main
        guard let screen else { return }
        let size = level.contentSize(maxHeight: screen.visibleFrame.height - 16)
        var origin: NSPoint
        let anchorY: CGFloat
        switch anchor {
        case .point(let p):
            anchorY = p.y
            origin = NSPoint(x: p.x, y: p.y - size.height)
            if origin.x + size.width > screen.visibleFrame.maxX { origin.x = p.x - size.width }
            if origin.y < screen.visibleFrame.minY { origin.y = min(p.y, screen.visibleFrame.maxY - size.height) }
        case .below(let r):
            anchorY = r.minY
            origin = NSPoint(x: r.maxX - size.width, y: r.minY - 2 - size.height)
            if origin.y < screen.visibleFrame.minY { origin.y = r.maxY + 2 }
        }
        origin.x = max(screen.visibleFrame.minX + 4, min(origin.x, screen.visibleFrame.maxX - size.width - 4))
        origin.y = max(screen.visibleFrame.minY + 4, min(origin.y, screen.visibleFrame.maxY - size.height - 4))
        // Opened above the pointer (no room below): unfold upwards from the bottom edge.
        level.unfoldsUp = origin.y + size.height / 2 > anchorY
        present(level, contentFrame: NSRect(origin: origin, size: size))
        levels = [level]
        install(window: window)
    }

    /// Shows a menu and tracks events until it closes, like a system menu, then runs the chosen
    /// action before returning. For hosts (WebKit) whose menu items only work while their own
    /// menu is still "open".
    func showModal(_ items: [GridMenuItem], title: String? = nil, anchor: Anchor, window: NSWindow?) {
        modal = true
        modalAction = nil
        defer { modal = false }
        show(items, title: title, anchor: anchor, window: window)
        // Sleeps until an event arrives (dismiss() posts one), so an open menu costs no CPU.
        while isOpen {
            if let e = NSApp.nextEvent(matching: .any, until: .distantFuture, inMode: .eventTracking, dequeue: true) {
                if e.type == .applicationDefined && e.subtype.rawValue == Self.wakeSubtype { continue }
                NSApp.sendEvent(e)
            }
        }
        if let action = modalAction { modalAction = nil; action() }
    }

    /// Closes every level without running anything.
    func dismiss() {
        submenuTimer?.cancel(); submenuTimer = nil
        pendingSwitch?.cancel(); pendingSwitch = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        let closing = levels
        levels = []
        activating = false
        closing.forEach { $0.close(fade: app?.settings.effects.motion ?? false) }
        if let cb = onClose { onClose = nil; cb() }
        // Wake showModal's event loop, which may be waiting for the next event.
        if modal, let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: 0, context: nil, subtype: Self.wakeSubtype, data1: 0, data2: 0) {
            NSApp.postEvent(e, atStart: true)
        }
    }

    private static let wakeSubtype: Int16 = 0x6D6E   // "mn"


    private func present(_ level: GridMenuLevel, contentFrame: NSRect) {
        guard let app else { return }
        let fx = app.settings.effects
        let panel = GridMenuPanel(contentRect: contentFrame.insetBy(dx: -Self.inset, dy: -Self.inset))
        let root = GridMenuView(level: level, size: contentFrame.size, owner: self)
            .environment(\.theme, app.settings.themeValue)
            .environment(\.effects, fx)
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
        panel.contentView = host
        level.panel = panel
        level.contentFrame = contentFrame
        // With Motion on, the view unfolds itself (MenuUnfold); its first frame is fully folded.
        panel.orderFrontRegardless()
    }

    private func install(window: NSWindow?) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                              .leftMouseUp, .rightMouseUp, .leftMouseDragged,
                                                              .rightMouseDragged, .mouseMoved, .scrollWheel, .keyDown]) { [weak self] e in
            guard let self else { return e }
            // Local monitors run on the main thread; NSEvent just isn't marked Sendable.
            let box = EventBox(e)
            MainActor.assumeIsolated { box.event = self.handle(box.event!) }
            return box.event
        }
        let nc = NotificationCenter.default
        let close: @Sendable (Notification) -> Void = { [weak self] _ in Task { @MainActor in self?.dismiss() } }
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: close))
        if let window {
            for n in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification,
                      NSWindow.didMiniaturizeNotification, NSWindow.didResignKeyNotification] {
                observers.append(nc.addObserver(forName: n, object: window, queue: .main, using: close))
            }
        }
    }

    // MARK: Events

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard !levels.isEmpty else { return e }
        let mouse = Self.screenLocation(of: e)
        switch e.type {
        case .keyDown:
            handleKey(e)
            return nil
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if hit(mouse) != nil { downInMenu = true; return nil }
            dismiss()
            return nil
        case .leftMouseDragged, .rightMouseDragged, .mouseMoved:
            if let (lvl, idx) = hit(mouse) { hover(lvl, idx) }
            return e.type == .mouseMoved ? e : nil
        case .leftMouseUp, .rightMouseUp:
            let deliberate = downInMenu || Date().timeIntervalSince(openedAt) > 0.3
                || hypot(mouse.x - openedAtMouse.x, mouse.y - openedAtMouse.y) > 5
            defer { downInMenu = false }
            if let (lvl, idx) = hit(mouse) {
                if deliberate, let idx { activate(lvl, idx, viaKeyboard: false) }
                return nil
            }
            // Releasing the opening click outside the menu keeps it open (click-to-open);
            // releasing after a press-drag elsewhere closes it, like a native menu.
            if deliberate && !downInMenu && Date().timeIntervalSince(openedAt) > 0.3 { dismiss() }
            return e.type == .rightMouseUp ? nil : e
        case .scrollWheel:
            if hit(mouse) != nil { return e }
            dismiss()
            return e
        default:
            return e
        }
    }

    /// The level and selectable row under a screen point (`row` is nil over padding or separators).
    private func hit(_ p: NSPoint) -> (Int, Int?)? {
        for (i, lvl) in levels.enumerated().reversed() where lvl.contentFrame.contains(p) {
            return (i, lvl.row(atScreen: p))
        }
        return nil
    }

    fileprivate func hover(_ lvl: Int, _ idx: Int?) {
        guard levels.indices.contains(lvl), !activating else { return }
        let level = levels[lvl]
        if lvl < levels.count - 1 {
            // A submenu is open and the pointer is back on its parent. Switch rows only after a
            // short pause, so crossing other rows on the way to the submenu doesn't close it.
            pendingSwitch?.cancel()
            guard let idx, level.items[idx].isSelectable, level.highlighted != idx else { return }
            let work = DispatchWorkItem { [weak self] in self?.select(lvl, idx) }
            pendingSwitch = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            return
        }
        pendingSwitch?.cancel()
        guard let idx, level.items[idx].isSelectable else { level.highlighted = nil; return }
        if level.highlighted != idx { select(lvl, idx) }
    }

    private func select(_ lvl: Int, _ idx: Int) {
        guard levels.indices.contains(lvl) else { return }
        let level = levels[lvl]
        level.highlighted = idx
        closeLevels(after: lvl)
        submenuTimer?.cancel()
        if level.items[idx].children != nil {
            let work = DispatchWorkItem { [weak self] in self?.openSubmenu(lvl, idx, selectFirst: false) }
            submenuTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }

    fileprivate func click(_ lvl: Int, _ idx: Int) {
        downInMenu = false
        activate(lvl, idx, viaKeyboard: false)
    }

    private func handleKey(_ e: NSEvent) {
        guard let lvl = levels.indices.last else { return }
        let level = levels[lvl]
        switch e.keyCode {
        case 53: // esc
            if lvl > 0 { closeLevels(after: lvl - 1) } else { dismiss() }
        case 125: level.move(1)
        case 126: level.move(-1)
        case 115: level.highlighted = level.items.firstIndex(where: \.isSelectable)          // home
        case 119: level.highlighted = level.items.lastIndex(where: \.isSelectable)           // end
        case 124: // →
            if let h = level.highlighted, level.items[h].children != nil { openSubmenu(lvl, h, selectFirst: true) }
        case 123: // ←
            if lvl > 0 { closeLevels(after: lvl - 1) }
        case 36, 76, 49: // return, enter, space
            if let h = level.highlighted { activate(lvl, h, viaKeyboard: true) }
        default:
            guard e.modifierFlags.intersection([.command, .control]).isEmpty,
                  let chars = e.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " }) else { return }
            if Date().timeIntervalSince(typedAt) > 1 { typed = "" }
            typed += chars
            typedAt = Date()
            if let i = level.items.firstIndex(where: { $0.isSelectable && $0.title.lowercased().hasPrefix(typed) }) {
                level.highlighted = i
            }
        }
    }

    private func activate(_ lvl: Int, _ idx: Int, viaKeyboard: Bool) {
        guard levels.indices.contains(lvl), levels[lvl].items.indices.contains(idx), !activating else { return }
        let level = levels[lvl]
        let item = level.items[idx]
        guard item.isSelectable else { return }
        switch item.kind {
        case .submenu:
            openSubmenu(lvl, idx, selectFirst: viaKeyboard)
        case .action(let perform):
            activating = true
            let finish = { [weak self] in
                guard let self else { return }
                if self.modal { self.modalAction = perform }
                self.dismiss()
                // Run after the menu is gone, so the action can present sheets or take focus.
                if !self.modal { DispatchQueue.main.async { perform() } }
            }
            if app?.settings.effects.motion ?? false {
                // A brief blink of the chosen row, like a system menu.
                level.highlighted = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    level.highlighted = idx
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: finish)
                }
            } else {
                finish()
            }
        case .separator, .header:
            break
        }
    }

    private func openSubmenu(_ lvl: Int, _ idx: Int, selectFirst: Bool) {
        guard levels.indices.contains(lvl) else { return }
        let parent = levels[lvl]
        guard parent.highlighted == idx || selectFirst, let children = parent.items[idx].children,
              let rowRect = parent.screenRect(ofRow: idx) else { return }
        parent.highlighted = idx
        if levels.count > lvl + 1, levels[lvl + 1].parentIndex == idx {
            if selectFirst { levels[lvl + 1].highlighted = children.firstIndex(where: \.isSelectable) }
            return
        }
        closeLevels(after: lvl)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(rowRect.origin) }) ?? NSScreen.main else { return }
        let child = GridMenuLevel(items: children, title: nil, depth: lvl + 1)
        child.parentIndex = idx
        let size = child.contentSize(maxHeight: screen.visibleFrame.height - 16)
        var origin = NSPoint(x: parent.contentFrame.maxX - 2, y: rowRect.maxY + Self.padding - size.height)
        if origin.x + size.width > screen.visibleFrame.maxX { origin.x = parent.contentFrame.minX - size.width + 2 }
        origin.y = max(screen.visibleFrame.minY + 4, min(origin.y, screen.visibleFrame.maxY - size.height - 4))
        if selectFirst { child.highlighted = children.firstIndex(where: \.isSelectable) }
        present(child, contentFrame: NSRect(origin: origin, size: size))
        levels.append(child)
    }

    private func closeLevels(after lvl: Int) {
        while levels.count > lvl + 1 { levels.removeLast().close(fade: false) }
    }

    // MARK: Helpers

    /// Where a mouse event happened, in screen coordinates (falls back to the pointer).
    static func screenLocation(of e: NSEvent) -> NSPoint {
        switch e.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .mouseMoved, .scrollWheel:
            if let w = e.window { return w.convertPoint(toScreen: e.locationInWindow) }
            return e.locationInWindow
        default:
            return NSEvent.mouseLocation
        }
    }

    private static func screen(for anchor: Anchor) -> NSScreen? {
        let p: NSPoint
        switch anchor { case .point(let pt): p = pt; case .below(let r): p = NSPoint(x: r.midX, y: r.midY) }
        return NSScreen.screens.first { $0.frame.contains(p) }
    }

    /// Drops separators at the ends and repeated separators, and headers with nothing under them.
    nonisolated static func normalized(_ items: [GridMenuItem]) -> [GridMenuItem] {
        var out: [GridMenuItem] = []
        for item in items {
            if case .separator = item.kind {
                if let last = out.last, case .separator = last.kind { continue }
                if out.isEmpty { continue }
            }
            out.append(item)
        }
        while let last = out.last {
            switch last.kind {
            case .separator, .header: out.removeLast()
            default: return out
            }
        }
        return out
    }

    /// The same items as a standard menu.
    static func nativeMenu(_ items: [GridMenuItem], title: String?) -> NSMenu {
        let menu = NSMenu(title: title ?? "")
        menu.autoenablesItems = false
        for item in items {
            switch item.kind {
            case .separator:
                menu.addItem(.separator())
            case .header:
                if #available(macOS 14.0, *) { menu.addItem(.sectionHeader(title: item.title)) }
            case .action(let perform):
                let mi = NSMenuItem(title: item.title, action: #selector(GridMenuActionTarget.run(_:)), keyEquivalent: "")
                let target = GridMenuActionTarget(perform)
                mi.target = target
                mi.representedObject = target   // keeps the target alive with the item
                mi.isEnabled = item.enabled
                mi.state = item.checked ? .on : .off
                menu.addItem(mi)
            case .submenu(let children):
                let mi = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                mi.submenu = nativeMenu(children, title: item.title)
                mi.isEnabled = item.enabled
                menu.addItem(mi)
            }
        }
        return menu
    }

    /// Converts a system menu (WebKit's page menu) into GRID items that perform the original items.
    static func items(from menu: NSMenu) -> [GridMenuItem] {
        menu.items.compactMap { mi -> GridMenuItem? in
            if mi.isHidden { return nil }
            if mi.isSeparatorItem { return .divider }
            if mi.isSectionHeader { return .header(mi.title) }
            if let sub = mi.submenu {
                let children = normalized(items(from: sub))
                return GridMenuItem(title: mi.title, kind: .submenu(children), enabled: mi.isEnabled && !children.isEmpty)
            }
            guard let action = mi.action else { return nil }
            return GridMenuItem(title: mi.title, kind: .action({ NSApp.sendAction(action, to: mi.target, from: mi) }),
                                shortcut: keyEquivalentDisplay(mi), enabled: mi.isEnabled, checked: mi.state == .on)
        }
    }

    private static func keyEquivalentDisplay(_ mi: NSMenuItem) -> String {
        guard !mi.keyEquivalent.isEmpty else { return "" }
        var s = ""
        let m = mi.keyEquivalentModifierMask
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) || mi.keyEquivalent != mi.keyEquivalent.lowercased() { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        return s + mi.keyEquivalent.uppercased()
    }
}

private final class EventBox: @unchecked Sendable {
    var event: NSEvent?
    init(_ e: NSEvent) { event = e }
}

private final class GridMenuActionTarget: NSObject {
    let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
    @objc func run(_ sender: Any?) { perform() }
}

/// A borderless, non-activating panel at menu level: it never becomes key, so the window keeps
/// keyboard focus (and the terminal its cursor) while a menu is open.
private final class GridMenuPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false   // GridMenu closes itself when the app deactivates
        acceptsMouseMovedEvents = true
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Level (one open menu or submenu)

@Observable
@MainActor
final class GridMenuLevel {
    let items: [GridMenuItem]
    let title: String?
    let depth: Int
    /// Whether any row can show a check mark; the check column is only reserved then.
    let hasChecks: Bool
    var highlighted: Int?
    @ObservationIgnored var parentIndex: Int?
    @ObservationIgnored fileprivate var panel: NSPanel?
    @ObservationIgnored fileprivate var contentFrame = NSRect.zero
    @ObservationIgnored fileprivate var rowFrames: [Int: CGRect] = [:]   // content coords, top-left origin
    @ObservationIgnored fileprivate var scrolls = false
    /// Unfold from the bottom edge (the menu sits above its anchor).
    @ObservationIgnored fileprivate var unfoldsUp = false
    /// Set when the menu closes with Motion on: the view folds back into a line.
    fileprivate var closing = false

    init(items: [GridMenuItem], title: String?, depth: Int) {
        self.items = items; self.title = title; self.depth = depth
        hasChecks = items.contains(where: \.checked)
    }

    func height(of item: GridMenuItem) -> CGFloat {
        switch item.kind {
        case .separator: GridMenu.separatorHeight
        case .header: GridMenu.headerRowHeight
        default: GridMenu.rowHeight
        }
    }

    fileprivate func contentSize(maxHeight: CGFloat) -> CGSize {
        let body = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let key = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
        let label = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)
        func w(_ s: String, _ f: NSFont, kern: CGFloat = 0) -> CGFloat {
            ceil((s as NSString).size(withAttributes: [.font: f, .kern: kern]).width)
        }
        var titleW: CGFloat = 0, trailW: CGFloat = 0
        for item in items {
            switch item.kind {
            case .separator: continue
            case .header: titleW = max(titleW, w(item.title.uppercased(), label, kern: 1.2) - 22)
            case .submenu: titleW = max(titleW, w(item.title, body)); trailW = max(trailW, 10)
            case .action:
                titleW = max(titleW, w(item.title, body))
                if !item.shortcut.isEmpty { trailW = max(trailW, w(item.shortcut, key) + 10) }
            }
        }
        // Matches GridMenuRow: 12 leading pad, optional 14pt check column + 6 spacing, the title,
        // 6 spacing + a spacer of at least 20 (always present), then 6 spacing + the shortcut or ▸
        // when there is one, 12 trailing pad. A few points of slack keep text rendering
        // differences from truncating a label.
        var width = 12 + (hasChecks ? 20 : 0) + titleW + 26 + (trailW > 0 ? 6 + trailW : 0) + 12 + 6
        if let title { width = max(width, w(title.uppercased(), label, kern: 1.4) + 60) }
        width = min(max(width, 190), 440)
        let rows = items.reduce(0) { $0 + height(of: $1) }
        let full = rows + GridMenu.padding * 2 + (title == nil ? 0 : GridMenu.titleHeight)
        scrolls = full > maxHeight
        return CGSize(width: width, height: min(full, maxHeight))
    }

    func move(_ d: Int) {
        let selectable = items.indices.filter { items[$0].isSelectable }
        guard !selectable.isEmpty else { return }
        guard let h = highlighted, let pos = selectable.firstIndex(of: h) else {
            highlighted = d > 0 ? selectable.first : selectable.last
            return
        }
        highlighted = selectable[(pos + d + selectable.count) % selectable.count]
    }

    fileprivate func row(atScreen p: NSPoint) -> Int? {
        let local = CGPoint(x: p.x - contentFrame.minX, y: contentFrame.maxY - p.y)
        // Only the visible list area: rows scrolled out of view keep frames under the title.
        let top = GridMenu.padding + (title == nil ? 0 : GridMenu.titleHeight)
        guard local.y >= top, local.y <= contentFrame.height - GridMenu.padding else { return nil }
        return rowFrames.first { $0.value.contains(local) }?.key
    }

    fileprivate func screenRect(ofRow i: Int) -> NSRect? {
        guard let r = rowFrames[i] else { return nil }
        return NSRect(x: contentFrame.minX + r.minX, y: contentFrame.maxY - r.maxY, width: r.width, height: r.height)
    }

    fileprivate func close(fade: Bool) {
        guard let panel else { return }
        self.panel = nil
        if fade {
            // The view folds up (MenuUnfold in reverse); the panel goes once that has played. It
            // already ignores the mouse, so nothing waits on the animation.
            panel.ignoresMouseEvents = true
            closing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + MenuUnfold.closeDuration + 0.02) { panel.orderOut(nil) }
        } else {
            panel.orderOut(nil)
        }
    }
}

// MARK: - View

private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct GridMenuView: View {
    @Environment(\.theme) private var theme
    @Environment(\.effects) private var effects
    let level: GridMenuLevel
    let size: CGSize
    let owner: GridMenu
    /// Unfold progress (MenuUnfold): 0 = a point at the anchor edge, 1 = fully open.
    @State private var unfold: CGFloat = 0

    private static let space = "grid.menu"

    var body: some View {
        VStack(spacing: 0) {
            if let title = level.title {
                HStack(spacing: 6) {
                    // Ares text band: the title types on as the menu unfolds.
                    TypeOnText(text: title.uppercased(), font: GridFont.label, color: theme.accent, tracking: 1.2, duration: 0.18)
                        .lineLimit(1)
                    TerminatedRule()
                }
                .padding(.horizontal, 10)
                .frame(height: GridMenu.titleHeight)
            }
            if level.scrolls {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) { rows }
                        .scrollIndicators(.automatic)
                        .onChange(of: level.highlighted) { _, h in if let h { proxy.scrollTo(h) } }
                }
            } else {
                rows
            }
        }
        .padding(.vertical, GridMenu.padding)
        .frame(width: size.width, height: size.height, alignment: .top)
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(RowFramesKey.self) { frames in
            MainActor.assumeIsolated { level.rowFrames = frames }
        }
        .background(
            ClippedRect(cut: 8, topRight: true)
                .fill(theme.bg1)
                .shadow(color: .black.opacity(0.55), radius: 10, y: 4)
        )
        .overlay(
            ClippedRect(cut: 8, topRight: true)
                .stroke(theme.lineStrong, lineWidth: Metrics.hairline)
                .shadow(color: effects.glow ? theme.glow.opacity(0.45) : .clear, radius: 5)
                .allowsHitTesting(false)
        )
        .padding(GridMenu.inset)
        .modifier(MenuUnfold(p: effects.motion ? unfold : 1, size: size, up: level.unfoldsUp,
                             accent: theme.accent, glow: effects.glow ? theme.glow : .clear))
        .onAppear {
            guard effects.motion else { return }
            withAnimation(MenuUnfold.openCurve) { unfold = 1 }
        }
        .onChange(of: level.closing) { _, closing in
            guard closing, effects.motion else { return }
            withAnimation(.timingCurve(0.5, 0, 0.9, 0.6, duration: MenuUnfold.closeDuration)) { unfold = 0 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(level.title ?? "Menu")
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(level.items.enumerated()), id: \.element.id) { i, item in
                GridMenuRow(item: item, highlighted: level.highlighted == i, checkColumn: level.hasChecks)
                    .id(i)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: RowFramesKey.self, value: [i: g.frame(in: .named(Self.space))])
                    })
                    .onHover { inside in if inside { owner.hover(level.depth, i) } }
                    .onTapGesture { if item.isSelectable { owner.click(level.depth, i) } }
                    .accessibilityAction { if item.isSelectable { owner.click(level.depth, i) } }
            }
        }
    }
}

/// The menu's build-on, after the Ares board-room screens: a bright line draws across the edge
/// nearest the pointer, the plate unfolds from it with a scan band lighting each row as it is
/// uncovered, and the line fades. Closing plays it backwards: the plate folds into the line and
/// the line shrinks away, like a CRT switching off. Rows are live from the first frame.
private struct MenuUnfold: ViewModifier, Animatable {
    static var openCurve: Animation { .timingCurve(0.2, 0.8, 0.3, 1, duration: 0.22 * GridMotion.debugSlow) }
    static var closeDuration: Double { 0.13 * GridMotion.debugSlow }

    var p: CGFloat
    let size: CGSize      // the menu plate, without the shadow inset
    let up: Bool
    let accent: Color
    let glow: Color
    var animatableData: CGFloat { get { p } set { p = newValue } }

    func body(content: Content) -> some View {
        let inset = GridMenu.inset
        let total = CGSize(width: size.width + inset * 2, height: size.height + inset * 2)
        // The line draws first (0…0.3), the plate unfolds over the rest.
        let line = min(1, max(0, p / 0.3))
        let open = min(1, max(0, (p - 0.16) / 0.84))
        let h = size.height * open
        let edge = up ? total.height - inset - h : inset + h     // y of the moving edge
        content
            .mask(alignment: .topLeading) {
                if p >= 1 {
                    Rectangle()
                } else {
                    Rectangle()
                        .frame(width: total.width, height: h + inset)
                        .offset(y: up ? edge : 0)
                }
            }
            .overlay(alignment: .topLeading) {
                if p < 1 {
                    ZStack(alignment: .topLeading) {
                        // Scan band just inside the moving edge: lights the rows it passes.
                        LinearGradient(colors: [accent.opacity(0), accent.opacity(0.22)],
                                       startPoint: up ? .bottom : .top, endPoint: up ? .top : .bottom)
                            .frame(width: size.width, height: min(22, h))
                            .offset(x: inset, y: up ? edge : edge - min(22, h))
                            .opacity(Double(sin(open * .pi)))
                        // The edge line.
                        Rectangle().fill(accent)
                            .frame(width: max(0, size.width * line), height: 1.5)
                            .shadow(color: glow, radius: 4)
                            .offset(x: inset, y: edge - 0.75)
                            .opacity(Double(1 - open * open))
                    }
                    .frame(width: total.width, height: total.height, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}

private struct GridMenuRow: View {
    @Environment(\.theme) private var theme
    let item: GridMenuItem
    let highlighted: Bool
    let checkColumn: Bool

    var body: some View {
        switch item.kind {
        case .separator:
            Rectangle().fill(theme.line).frame(height: Metrics.hairline)
                .padding(.horizontal, 8)
                .frame(height: GridMenu.separatorHeight)
                .accessibilityHidden(true)
        case .header:
            Text(item.title.uppercased())
                .font(GridFont.label).tracking(1.2).foregroundStyle(theme.textMute)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
                .frame(height: GridMenu.headerRowHeight, alignment: .bottom)
                .padding(.bottom, 0)
                .accessibilityAddTraits(.isHeader)
        default:
            let lit = highlighted && item.isSelectable
            HStack(spacing: 6) {
                if checkColumn {
                    Text(item.checked ? "✓" : "")
                        .font(GridFont.bodyStrong).foregroundStyle(theme.accent)
                        .frame(width: 14)
                }
                Text(item.title)
                    .font(GridFont.body)
                    .foregroundStyle(titleColor(lit))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 20)
                if item.children != nil {
                    Text("▸").font(GridFont.small).foregroundStyle(lit ? theme.accent : theme.textMute)
                } else if !item.shortcut.isEmpty {
                    KeyCap(item.shortcut).opacity(item.enabled ? 1 : 0.5)
                }
            }
            .padding(.leading, 12).padding(.trailing, 12)
            .frame(maxWidth: .infinity, minHeight: GridMenu.rowHeight, maxHeight: GridMenu.rowHeight)
            .gridRowBackground(selected: lit, hovered: false, theme: theme)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.title + (item.checked ? ", checked" : "") + (item.children != nil ? ", submenu" : ""))
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(lit ? .isSelected : [])
        }
    }

    private func titleColor(_ lit: Bool) -> Color {
        if !item.enabled { return theme.textMute }
        if item.destructive { return theme.danger }
        return lit ? theme.text : theme.text.opacity(0.92)
    }
}

// MARK: - Attaching menus to views

/// Holds the AppKit view behind a SwiftUI control so its menu can be placed on screen.
@MainActor
final class GridMenuAnchor {
    weak var view: NSView?
    var screenRect: NSRect? {
        guard let v = view, let w = v.window else { return nil }
        return w.convertToScreen(v.convert(v.bounds, to: nil))
    }
}

/// Transparent AppKit view laid over a SwiftUI view. It answers hit tests only for a right-click or
/// Control-click, so ordinary clicks, hovers, drags and scrolling pass straight through.
private final class ContextClickView: NSView {
    var onMenu: ((NSPoint) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let e = NSApp.currentEvent else { return nil }
        let wants = e.type == .rightMouseDown || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
        return wants ? super.hitTest(point) : nil
    }
    override func rightMouseDown(with event: NSEvent) { onMenu?(GridMenu.screenLocation(of: event)) }
    override func mouseDown(with event: NSEvent) { onMenu?(GridMenu.screenLocation(of: event)) }   // Control-click only
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

private struct ContextClickCatcher: NSViewRepresentable {
    let anchor: GridMenuAnchor
    let onMenu: (NSPoint) -> Void
    func makeNSView(context: Context) -> ContextClickView {
        let v = ContextClickView()
        anchor.view = v
        v.onMenu = onMenu
        return v
    }
    func updateNSView(_ v: ContextClickView, context: Context) {
        anchor.view = v
        v.onMenu = onMenu
    }
}

/// Reports the AppKit view behind a control without taking any events.
private struct AnchorReader: NSViewRepresentable {
    let anchor: GridMenuAnchor
    final class V: NSView { override func hitTest(_ p: NSPoint) -> NSView? { nil } }
    func makeNSView(context: Context) -> V { let v = V(); anchor.view = v; return v }
    func updateNSView(_ v: V, context: Context) { anchor.view = v }
}

private struct GridContextMenuModifier: ViewModifier {
    @Environment(\.theme) private var theme
    let title: () -> String?
    let items: () -> [GridMenuItem]
    @State private var anchor = GridMenuAnchor()
    @State private var open = false

    func body(content: Content) -> some View {
        content
            .overlay {
                // Marks what the open menu acts on (like Finder's outline).
                if open {
                    Rectangle().stroke(theme.accent.opacity(0.7), lineWidth: Metrics.hairline)
                        .allowsHitTesting(false)
                }
            }
            .overlay(ContextClickCatcher(anchor: anchor) { present(at: $0) })
            .accessibilityAction(.showMenu) {
                guard let r = anchor.screenRect else { return }
                present(at: NSPoint(x: r.midX, y: r.midY))
            }
    }

    private func present(at p: NSPoint) {
        open = true
        GridMenu.shared.show(items(), title: title(), anchor: .point(p), window: anchor.view?.window) { open = false }
    }
}

extension View {
    /// A right-click (and Control-click) menu drawn in GRID's style. Items are built when the menu
    /// opens, so they always reflect the current state.
    func gridContextMenu(title: @autoclosure @escaping () -> String? = nil,
                         @GridMenuBuilder _ items: @escaping () -> [GridMenuItem]) -> some View {
        modifier(GridContextMenuModifier(title: title, items: items))
    }
}

/// A button that opens a GRID menu under itself (the "⋯" menus).
struct GridMenuButton<Label: View>: View {
    @Environment(\.theme) private var theme
    let help: String
    var title: String? = nil
    let items: () -> [GridMenuItem]
    let label: () -> Label
    @State private var anchor = GridMenuAnchor()
    @State private var open = false

    init(help: String, title: String? = nil, @GridMenuBuilder items: @escaping () -> [GridMenuItem],
         @ViewBuilder label: @escaping () -> Label) {
        self.help = help; self.title = title; self.items = items; self.label = label
    }

    var body: some View {
        Button {
            if open { GridMenu.shared.dismiss(); return }
            guard let r = anchor.screenRect else { return }
            open = true
            GridMenu.shared.show(items(), title: title, anchor: .below(r), window: anchor.view?.window) { open = false }
        } label: {
            label()
                .background(open ? theme.bg2 : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(AnchorReader(anchor: anchor))
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
    }
}

extension GridMenuButton where Label == GridMenuEllipsis {
    /// The standard "⋯" button.
    init(help: String, title: String? = nil, size: CGFloat = 11, frame: CGSize = CGSize(width: 22, height: 20),
         @GridMenuBuilder items: @escaping () -> [GridMenuItem]) {
        self.init(help: help, title: title, items: items) { GridMenuEllipsis(size: size, frame: frame) }
    }
}

struct GridMenuEllipsis: View {
    @Environment(\.theme) private var theme
    let size: CGFloat
    let frame: CGSize
    var body: some View {
        Image(systemName: "ellipsis").font(.system(size: size)).foregroundStyle(theme.textDim)
            .frame(width: frame.width, height: frame.height)
    }
}

#if DEBUG
extension GridMenu {
    struct DebugLevel {
        let title: String?
        let items: [GridMenuItem]
        let highlighted: Int?
        let frame: NSRect          // content frame, screen coordinates
        let windowNumber: Int
    }
    var debugLevels: [DebugLevel] {
        levels.map { DebugLevel(title: $0.title, items: $0.items, highlighted: $0.highlighted,
                                frame: $0.contentFrame, windowNumber: $0.panel?.windowNumber ?? 0) }
    }
}
#endif
