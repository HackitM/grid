import AppKit
import GridCore
import SwiftTerm

/// SwiftTerm's PTY-backed view plus the few behaviors GRID needs:
/// focus notifications, safe file-path drops, and theme application.
final class GridTerminalView: LocalProcessTerminalView {
    var onFocusChange: ((Bool) -> Void)?
    var onBell: (() -> Void)?
    /// Builds the right-click menu for this pane (set by AppState).
    static var contextMenu: ((GridTerminalView) -> [GridMenuItem])?

    override init(frame: CGRect, font: NSFont?, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options)
        registerForDraggedTypes([.fileURL, Self.gridPathsType])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var hasFocus: Bool {
        didSet { if oldValue != hasFocus { onFocusChange?(hasFocus) } }
    }

    /// BEL from the program: keep SwiftTerm's default (system beep) and flag the pane.
    nonisolated override func bell(source: Terminal) {
        super.bell(source: source)
        DispatchQueue.main.async { [weak self] in self?.onBell?() }
    }

    // MARK: Context menu

    /// Right-click shows GRID's menu unless the running program asked for mouse reports (vim,
    /// htop, tmux…), in which case the click goes to the program as before. Shift+right-click
    /// always shows the menu, matching SwiftTerm's Shift bypass for mouse reporting.
    override func rightMouseDown(with event: NSEvent) {
        let programWantsMouse = allowMouseReporting && currentMouseMode != .off
            && !event.modifierFlags.contains(.shift)
        guard !programWantsMouse, let items = Self.contextMenu?(self) else {
            super.rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        GridMenu.shared.show(items, title: "terminal", anchor: .point(GridMenu.screenLocation(of: event)), window: window)
    }

    override func rightMouseUp(with event: NSEvent) {
        if GridMenu.shared.isOpen { return }
        super.rightMouseUp(with: event)
    }

    // MARK: Theme

    func apply(theme: Theme, font: NSFont, optionAsMeta: Bool) {
        if self.font != font { self.font = font }
        nativeBackgroundColor = theme.termBackground
        nativeForegroundColor = theme.termForeground
        caretColor = theme.termCursor
        selectedTextBackgroundColor = theme.termSelection
        optionAsMetaKey = optionAsMeta
        installColors(Theme.ansi.map(Self.termColor))
        layer?.backgroundColor = theme.termBackground.cgColor
    }

    private static func termColor(_ c: NSColor) -> SwiftTerm.Color {
        let s = c.usingColorSpace(.sRGB) ?? c
        return SwiftTerm.Color(red: UInt16(s.redComponent * 65535), green: UInt16(s.greenComponent * 65535),
                               blue: UInt16(s.blueComponent * 65535))
    }

    // MARK: Drag & drop: insert quoted paths, never execute

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        insertPaths(urls.map(\.path))
        window?.makeFirstResponder(self)
        return true
    }

    /// Inserts shell-quoted paths at the prompt. Quoting removes all control characters; the
    /// paste path additionally brackets the text when the program enabled bracketed paste.
    /// No newline is ever sent, so nothing runs until the user presses Return.
    func insertPaths(_ paths: [String]) {
        let text = ShellQuoting.insertionText(forPaths: paths)
        guard !text.isEmpty else { return }
        pasteText(text)
    }

    /// Multi-item drags from GRID's own file list carry every path in this JSON array.
    static let gridPathsType = NSPasteboard.PasteboardType("local.grid.paths")

    private func fileURLs(from info: NSDraggingInfo) -> [URL] {
        if let data = info.draggingPasteboard.data(forType: Self.gridPathsType),
           let paths = try? JSONDecoder().decode([String].self, from: data), !paths.isEmpty {
            return paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        }
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]) ?? []
    }
}
