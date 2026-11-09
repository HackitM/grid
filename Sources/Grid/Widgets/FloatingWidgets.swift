import AppKit
import SwiftUI

/// Widgets popped out of the deck into their own small always-on-top windows, so they stay on
/// screen whichever page (terminal, files, browser) is showing, and optionally above other apps.
///
/// A floating widget is still the same deck card (same id and settings, `float=1` in its config);
/// the deck keeps a "floating" stub in its place and docking it back just clears the flag.
/// Built-in widgets only: custom widgets run in their own sandboxed host tied to the deck.
@MainActor
final class FloatingWidgets: NSObject, NSWindowDelegate {
    weak var app: AppState?
    private var panels: [UUID: FloatingWidgetPanel] = [:]

    static func canFloat(_ w: WidgetInstance) -> Bool { w.kind != .custom }
    var openIDs: Set<UUID> { Set(panels.keys) }

    /// Opens, updates and closes windows to match the deck's `float` flags.
    func sync() {
        guard let app else { return }
        let want = app.widgets.widgets.filter { Self.canFloat($0) && $0.bool("float", false) }
        let ids = Set(want.map(\.id))
        for (id, p) in panels where !ids.contains(id) {
            panels[id] = nil
            p.delegate = nil
            p.orderOut(nil)
        }
        for w in want {
            if let p = panels[w.id] { p.apply(aboveAllApps: w.bool("floatAll", true)) } else { open(w, app) }
        }
    }

    func popOut(_ id: UUID) { app?.widgets.set(id, "float", "1") }
    func dock(_ id: UUID) { app?.widgets.set(id, "float", nil) }

    private func open(_ w: WidgetInstance, _ app: AppState) {
        let root = FloatingWidgetRoot(id: w.id).environment(app)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        let panel = FloatingWidgetPanel(contentViewController: host)
        panel.widgetID = w.id
        // Registered before it is positioned: moving it saves its origin, which changes the deck
        // and calls sync() again, which must find it already open.
        panels[w.id] = panel
        panel.apply(aboveAllApps: w.bool("floatAll", true))
        let size = host.view.fittingSize
        if let saved = w.config["floatOrigin"].map(NSPointFromString), Self.onScreen(NSRect(origin: saved, size: size)) {
            panel.setFrameOrigin(saved)
        } else {
            // First time: top-right of the screen GRID is on, below the menu bar.
            let screen = NSApp.mainWindow?.screen ?? NSScreen.main
            let vf = screen?.visibleFrame ?? .zero
            let offset = CGFloat(panels.count) * 24
            panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 24 - offset, y: vf.maxY - size.height - 24 - offset))
        }
        panel.delegate = self
        panel.orderFrontRegardless()
    }

    private static func onScreen(_ r: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(r.insetBy(dx: 20, dy: 20)) }
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ n: Notification) {
        guard let p = n.object as? FloatingWidgetPanel, let id = p.widgetID else { return }
        app?.widgets.set(id, "floatOrigin", NSStringFromPoint(p.frame.origin))
    }

    #if DEBUG
    func debugFrames() -> [[String: Any]] {
        panels.map { id, p in
            ["id": id.uuidString, "x": p.frame.minX, "y": p.frame.minY, "w": p.frame.width, "h": p.frame.height,
             "level": p.level.rawValue, "hidesOnDeactivate": p.hidesOnDeactivate, "visible": p.isVisible]
        }
    }

    func debugSnapshot(dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (i, p) in panels.values.enumerated() {
            guard let v = p.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/float-\(i).png"))
        }
    }
    #endif
}

/// A borderless panel that floats above normal windows. It doesn't activate GRID when clicked
/// (pressing play over another app leaves that app in front), but can take keyboard focus when
/// a field inside needs it (the Notes widget).
final class FloatingWidgetPanel: NSPanel {
    var widgetID: UUID?

    convenience init(contentViewController: NSViewController) {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.contentViewController = contentViewController
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = false   // moved by its title strip (WindowDragHandle)
        animationBehavior = .utilityWindow
    }

    /// Above every app (and on every Space), or above GRID's window only and hidden while
    /// another app is in front.
    func apply(aboveAllApps: Bool) {
        level = .floating
        hidesOnDeactivate = !aboveAllApps
        collectionBehavior = aboveAllApps ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                                          : [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The floating window's content: a GRID card with its own title strip.
private struct FloatingWidgetRoot: View {
    @Environment(AppState.self) private var app
    let id: UUID

    var body: some View {
        let theme = app.settings.themeValue
        let fx = app.settings.effects
        if let w = app.widgets.widgets.first(where: { $0.id == id }) {
            FloatingCard(widget: w, number: (app.widgets.widgets.firstIndex { $0.id == id } ?? 0) + 1)
                .environment(\.theme, theme)
                .environment(\.effects, fx)
                .preferredColorScheme(.dark)
                .tint(theme.accent)
        }
    }
}

private struct FloatingCard: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.effects) private var effects
    let widget: WidgetInstance
    let number: Int
    @State private var hover = false

    var body: some View {
        let store = app.widgets
        let above = widget.bool("floatAll", true)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hover ? theme.textDim : theme.textMute)
                Text(String(format: "W%02d", number)).font(GridFont.label).foregroundStyle(theme.accent)
                HStack(spacing: 0) {
                    Text(widget.kind.title.uppercased()).foregroundStyle(theme.text)
                    Text(" .FLOAT").foregroundStyle(theme.textMute)
                }
                .font(GridFont.label).tracking(1.2).lineLimit(1)
                Spacer(minLength: 4)
                button(above ? "pin.fill" : "pin", above ? "Floating above all apps: click to float above GRID only"
                                                         : "Floating above GRID only: click to float above all apps", active: above) {
                    store.set(widget.id, "floatAll", above ? "0" : "1")
                }
                button(widget.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       widget.expanded ? "Compact" : "Expand") { store.update(widget.id) { $0.expanded.toggle() } }
                button("rectangle.portrait.and.arrow.forward", "Dock back in the deck") { app.floatingWidgets.dock(widget.id) }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(WindowDragHandle())
            .background(theme.bg2.opacity(0.7))
            .help("Drag to move")
            Rectangle().fill(theme.line).frame(height: Metrics.hairline)
            WidgetContent(widget: widget)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: widget.expanded ? 360 : 290)
        .background(theme.bg1)
        .clipShape(ClippedRect(cut: 8, topRight: true))
        .overlay(
            ClippedRect(cut: 8, topRight: true)
                .stroke(hover ? theme.lineStrong : theme.lineStrong.opacity(0.6), lineWidth: Metrics.hairline)
                .allowsHitTesting(false)
        )
        .buildOn(cut: 8, headerRule: 24)
        .onHover { hover = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Floating \(widget.kind.title) widget")
    }

    private func button(_ symbol: String, _ label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .medium))
                .foregroundStyle(active ? theme.accent : theme.textDim)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Moves its window when dragged (a borderless window has no title bar to drag).
private struct WindowDragHandle: NSViewRepresentable {
    final class V: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context: Context) -> V { V() }
    func updateNSView(_ v: V, context: Context) {}
}
