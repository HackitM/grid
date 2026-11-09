import Foundation

/// A keyboard shortcut as data: a key name plus modifiers. Key names are a single lowercase
/// character ("d", ",", "[") or one of the special names below.
public struct KeyBinding: Codable, Hashable, Sendable {
    public enum Modifier: String, Codable, CaseIterable, Sendable { case control, option, shift, command }

    public var key: String
    public var modifiers: Set<Modifier>

    public init(_ key: String, _ modifiers: Set<Modifier>) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = modifiers
    }

    public static let specialKeys: [String: String] = [
        "up": "↑", "down": "↓", "left": "←", "right": "→", "space": "Space", "return": "↩",
        "tab": "⇥", "delete": "⌫", "escape": "⎋", "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
        "f1": "F1", "f2": "F2", "f3": "F3", "f4": "F4", "f5": "F5", "f6": "F6", "f7": "F7", "f8": "F8",
        "f9": "F9", "f10": "F10", "f11": "F11", "f12": "F12",
    ]

    public var isFunctionKey: Bool { key.count >= 2 && key.hasPrefix("f") && Int(key.dropFirst()) != nil }

    /// Menu-style display in Apple's modifier order: ⌃⌥⇧⌘ then the key.
    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + (Self.specialKeys[key] ?? key.uppercased())
    }

    /// Why this binding can't be used for an app command, or nil if it can.
    /// - Must include ⌘ (or be a function key): bare and ⌃/⌥ combinations belong to programs
    ///   running in the terminal (⌃C, ⌃R, ⌥←…), and app shortcuts are matched before them.
    /// - System / editing / tab-switching combinations are reserved.
    public var problem: String? {
        if !modifiers.contains(.command) && !isFunctionKey {
            return "Include ⌘ (or use F1–F12): other combinations are reserved for programs in the terminal."
        }
        if Self.reserved.contains(self) { return "\(display) is reserved by macOS or for editing." }
        if modifiers == [.command], let d = Int(key), (1...9).contains(d) { return "⌘1–⌘9 are reserved for switching tabs." }
        return nil
    }

    static let reserved: Set<KeyBinding> = [
        KeyBinding("q", [.command]), KeyBinding("h", [.command]), KeyBinding("h", [.command, .option]),
        KeyBinding("m", [.command]), KeyBinding("c", [.command]), KeyBinding("v", [.command]),
        KeyBinding("x", [.command]), KeyBinding("a", [.command]), KeyBinding("z", [.command]),
        KeyBinding("z", [.command, .shift]), KeyBinding("`", [.command]), KeyBinding("tab", [.command]),
        KeyBinding("space", [.command]), KeyBinding("escape", [.command, .option]),
    ]
}
