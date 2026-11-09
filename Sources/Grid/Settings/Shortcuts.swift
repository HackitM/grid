import AppKit
import GridCore
import Observation
import SwiftUI

/// Every app command that has a (rebindable) keyboard shortcut.
enum GridCommand: String, CaseIterable, Identifiable, Codable {
    case palette, newTab, closePane, closeTab, splitRight, splitDown, nextPane, previousPane, nextTab, previousTab,
         clearScrollback, find, findNext, findPrevious,
         showTerminal, showFiles, showApps, showWeb, settings, toggleSidebar, toggleInspector, toggleDeck,
         terminalHere, revealTerminalDirectory, newFolder, goBack, goForward, goUp, goHome, goToFolder, toggleHidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .palette: "Command Palette"; case .newTab: "New Tab"; case .closePane: "Close Pane / Tab"
        case .closeTab: "Close Tab"; case .splitRight: "Split Right"; case .splitDown: "Split Down"
        case .nextPane: "Next Pane"; case .previousPane: "Previous Pane"; case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"; case .clearScrollback: "Clear Scrollback"; case .find: "Find"
        case .findNext: "Find Next"; case .findPrevious: "Find Previous"
        case .showTerminal: "Show Terminal"; case .showFiles: "Show Files"; case .showApps: "Show Applications"
        case .showWeb: "Show Web"; case .settings: "Settings"; case .toggleSidebar: "Files Sidebar"
        case .toggleInspector: "Inspector"; case .toggleDeck: "Widget Deck"
        case .terminalHere: "New Tab in Files Folder"; case .revealTerminalDirectory: "Show Terminal Directory in Files"
        case .newFolder: "New Folder"; case .goBack: "Back"; case .goForward: "Forward"; case .goUp: "Enclosing Folder"
        case .goHome: "Home Folder"; case .goToFolder: "Go to Folder…"; case .toggleHidden: "Show Hidden Files"
        }
    }

    var group: String {
        switch self {
        case .palette, .showTerminal, .showFiles, .showApps, .showWeb, .settings, .toggleSidebar, .toggleInspector, .toggleDeck: "Workspace"
        case .newTab, .closePane, .closeTab, .splitRight, .splitDown, .nextPane, .previousPane, .nextTab, .previousTab,
             .clearScrollback, .find, .findNext, .findPrevious: "Terminal"
        default: "Files"
        }
    }

    var defaultBinding: KeyBinding? {
        switch self {
        case .palette: KeyBinding("p", [.command, .shift])
        case .newTab: KeyBinding("t", [.command])
        case .closePane: KeyBinding("w", [.command])
        case .closeTab: KeyBinding("w", [.command, .shift])
        case .splitRight: KeyBinding("d", [.command])
        case .splitDown: KeyBinding("d", [.command, .shift])
        case .nextPane: KeyBinding("right", [.command, .option])
        case .previousPane: KeyBinding("left", [.command, .option])
        case .nextTab: KeyBinding("]", [.command, .shift])
        case .previousTab: KeyBinding("[", [.command, .shift])
        case .clearScrollback: KeyBinding("k", [.command])
        case .find: KeyBinding("f", [.command])
        case .findNext: KeyBinding("g", [.command])
        case .findPrevious: KeyBinding("g", [.command, .shift])
        case .showTerminal: KeyBinding("1", [.command, .option])
        case .showFiles: KeyBinding("2", [.command, .option])
        case .showApps: KeyBinding("3", [.command, .option])
        case .showWeb: KeyBinding("4", [.command, .option])
        case .settings: KeyBinding(",", [.command])
        case .toggleSidebar: KeyBinding("b", [.command])
        case .toggleInspector: KeyBinding("i", [.command])
        case .toggleDeck: KeyBinding("j", [.command])
        case .terminalHere: KeyBinding("t", [.command, .option])
        case .revealTerminalDirectory: KeyBinding("j", [.command, .shift])
        case .newFolder: KeyBinding("n", [.command, .shift])
        case .goBack: KeyBinding("[", [.command])
        case .goForward: KeyBinding("]", [.command])
        case .goUp: KeyBinding("up", [.command])
        case .goHome: KeyBinding("h", [.command, .shift])
        case .goToFolder: KeyBinding("l", [.command])
        case .toggleHidden: KeyBinding(".", [.command, .shift])
        }
    }
}

/// User shortcut overrides, persisted as JSON. A command maps to a binding, or to "none"
/// (explicitly unassigned); commands without an override use their default.
@Observable
@MainActor
final class ShortcutStore {
    private enum Override: Codable, Equatable { case binding(KeyBinding), none }
    private var overrides: [GridCommand: Override] = [:] { didSet { save() } }
    @ObservationIgnored private let key = "shortcuts.v1"

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: key), let saved = try? JSONDecoder().decode([GridCommand: Override].self, from: data) {
            overrides = saved
        } else if let old = d.string(forKey: "palette.shortcut") {
            // Migrate the earlier palette-only setting.
            switch old {
            case "cmdK": overrides = [.palette: .binding(KeyBinding("k", [.command])), .clearScrollback: .none]
            case "cmdShiftSpace": overrides = [.palette: .binding(KeyBinding("space", [.command, .shift]))]
            default: break
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(overrides) { UserDefaults.standard.set(data, forKey: key) }
    }

    func binding(_ c: GridCommand) -> KeyBinding? {
        switch overrides[c] {
        case .binding(let b): b
        case .none?: nil
        case nil: c.defaultBinding
        }
    }

    func isCustom(_ c: GridCommand) -> Bool { overrides[c] != nil }

    /// Command currently using `b`, if any.
    func owner(of b: KeyBinding, excluding: GridCommand? = nil) -> GridCommand? {
        GridCommand.allCases.first { $0 != excluding && binding($0) == b }
    }

    /// Assigns a binding. Returns an error message instead if it's invalid or already in use.
    func assign(_ b: KeyBinding, to c: GridCommand) -> String? {
        if let p = b.problem { return p }
        if let other = owner(of: b, excluding: c) { return "\(b.display) is already used by “\(other.title)”. Change that one first." }
        overrides[c] = b == c.defaultBinding ? nil : .binding(b)
        return nil
    }

    func unassign(_ c: GridCommand) { overrides[c] = .none }
    func reset(_ c: GridCommand) {
        // Restoring a default must not create a duplicate.
        if let d = c.defaultBinding, let other = owner(of: d, excluding: c) { overrides[other] = .none }
        overrides[c] = nil
    }
    func resetAll() { overrides = [:] }

    // MARK: SwiftUI glue

    func shortcut(_ c: GridCommand) -> KeyboardShortcut? { binding(c).flatMap(Self.keyboardShortcut) }
    /// "(⌘D)" for tooltips, or "" when unassigned.
    func hint(_ c: GridCommand) -> String { binding(c).map { " (\($0.display))" } ?? "" }
    func display(_ c: GridCommand) -> String { binding(c)?.display ?? "" }

    static func keyboardShortcut(_ b: KeyBinding) -> KeyboardShortcut? {
        let key: KeyEquivalent
        switch b.key {
        case "up": key = .upArrow; case "down": key = .downArrow; case "left": key = .leftArrow; case "right": key = .rightArrow
        case "space": key = .space; case "return": key = .return; case "tab": key = .tab; case "delete": key = .delete
        case "escape": key = .escape; case "home": key = .home; case "end": key = .end
        case "pageup": key = .pageUp; case "pagedown": key = .pageDown
        default:
            if b.isFunctionKey, let n = Int(b.key.dropFirst()), (1...12).contains(n),
               let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
                key = KeyEquivalent(Character(scalar))
            } else if let ch = b.key.first, b.key.count == 1 {
                key = KeyEquivalent(ch)
            } else { return nil }
        }
        var mods: EventModifiers = []
        if b.modifiers.contains(.command) { mods.insert(.command) }
        if b.modifiers.contains(.option) { mods.insert(.option) }
        if b.modifiers.contains(.shift) { mods.insert(.shift) }
        if b.modifiers.contains(.control) { mods.insert(.control) }
        return KeyboardShortcut(key, modifiers: mods)
    }

    /// Builds a binding from a key-down event (for the recorder).
    static func binding(from e: NSEvent) -> KeyBinding? {
        var mods: Set<KeyBinding.Modifier> = []
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if f.contains(.command) { mods.insert(.command) }
        if f.contains(.option) { mods.insert(.option) }
        if f.contains(.shift) { mods.insert(.shift) }
        if f.contains(.control) { mods.insert(.control) }
        let special: [UInt16: String] = [126: "up", 125: "down", 123: "left", 124: "right", 49: "space", 36: "return",
                                         48: "tab", 51: "delete", 53: "escape", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
                                         122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
                                         101: "f9", 109: "f10", 103: "f11", 111: "f12"]
        if let name = special[e.keyCode] { return KeyBinding(name, mods) }
        // Use the unshifted character so ⇧⌘[ records as "[" + shift, matching menu semantics.
        guard let ch = (e.characters(byApplyingModifiers: []) ?? e.charactersIgnoringModifiers)?.lowercased(), ch.count == 1, !ch.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
        return KeyBinding(ch, mods)
    }
}
