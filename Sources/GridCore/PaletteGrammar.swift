import Foundation

/// The command palette's small namespaced grammar. These are *application* commands handled by
/// GRID itself; they are never sent to a shell and never shadow shell commands.
///
///   app Safari          launch an application
///   files ~/Projects    show a folder in Files
///   term ~/Projects     open a new terminal session in a folder
///   web example.com     open a web address (default browser)
///   theme ares          switch theme
///
/// A leading `grid ` is accepted and ignored, so `grid app Safari` also works.
public enum PaletteIntent: Equatable {
    case app(String)
    case files(String)
    case term(String)
    case web(String)
    case theme(String)
    case freeText(String)
}

public enum PaletteGrammar {
    public static let verbs = ["app", "files", "term", "web", "theme"]

    public static func parse(_ raw: String) -> PaletteIntent {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("grid ") { s = String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        let parts = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return .freeText("") }
        let verb = first.lowercased()
        let arg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        // A verb alone ("app") is still free text, so typing an app *named* "Files" keeps working.
        guard !arg.isEmpty else { return .freeText(s) }
        switch verb {
        case "app", "open", "launch": return .app(arg)
        case "files", "cd", "go": return .files(arg)
        case "term", "terminal": return .term(arg)
        case "web", "url": return .web(arg)
        case "theme": return .theme(arg)
        default: return .freeText(s)
        }
    }

    /// Heuristic: does free text look like a filesystem path?
    public static func looksLikePath(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("/") || t.hasPrefix("~") || t.hasPrefix("./") || t.hasPrefix("../")
    }
}
