import Foundation
import GridCore
import Observation

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    /// Kinds shown in the gallery's built-in list (custom widgets are listed by package).
    static var builtIn: [WidgetKind] { allCases.filter { $0 != .custom } }
    case clock, system, network, storage, battery, sessions, apps, git, notes, folder, inspector, music, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .clock: "Clock"; case .system: "System"; case .network: "Network"; case .storage: "Storage"
        case .battery: "Power"; case .sessions: "Sessions"; case .apps: "Pinned Apps"; case .git: "Git"
        case .notes: "Notes"; case .folder: "Recent Files"; case .inspector: "File Inspector"; case .music: "Now Playing"; case .custom: "Custom"
        }
    }

    var suffix: String {
        switch self {
        case .clock: "time"; case .system: "cpu.mem"; case .network: "net"; case .storage: "disk"
        case .battery: "pwr"; case .sessions: "tty"; case .apps: "launch"; case .git: "repo"
        case .notes: "txt"; case .folder: "recent"; case .inspector: "meta"; case .music: "audio"; case .custom: "ext"
        }
    }

    var symbol: String {
        switch self {
        case .clock: "clock"; case .system: "cpu"; case .network: "arrow.up.arrow.down"; case .storage: "internaldrive"
        case .battery: "battery.75percent"; case .sessions: "terminal"; case .apps: "square.grid.2x2"
        case .git: "arrow.triangle.branch"; case .notes: "note.text"; case .folder: "clock.arrow.circlepath"
        case .inspector: "doc.text.magnifyingglass"; case .music: "music.note"; case .custom: "puzzlepiece.extension"
        }
    }

    var blurb: String {
        switch self {
        case .clock: "Local time and date, plus optional extra time zones."
        case .system: "CPU usage, memory in use, and load average, sampled every 2 s."
        case .network: "Live download / upload rate and local IP for an interface."
        case .storage: "Used and free space on a volume."
        case .battery: "Battery charge, charging state, and time remaining."
        case .sessions: "Your terminal tabs and panes with their folders; click to switch."
        case .apps: "Your pinned applications as a launch strip."
        case .git: "Branch, ahead/behind, and changes for the terminal's folder (or a fixed repo)."
        case .notes: "A local scratchpad, saved automatically."
        case .folder: "Most recently modified items in a folder; click to open."
        case .inspector: "The Files selection in detail: the exact quoted path it inserts, executable/downloaded warnings, text and image facts, and quick actions."
        case .music: "What Apple Music or Spotify is playing, with play/pause and skip. Cover art is redrawn in GRID's colours. Pop it out to keep it above every page."
        case .custom: "A widget package from your Widgets folder."
        }
    }
}

/// One widget on the deck. Configuration is a small string map so new options never break
/// saved layouts.
struct WidgetInstance: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: WidgetKind
    var collapsed = false
    /// Expanded shows more detail (sparklines, extra zones, more rows).
    var expanded = false
    /// Sits beside the previous card in the same deck row (nil/false: starts a new row).
    var beside: Bool?
    var config: [String: String] = [:]

    func bool(_ k: String, _ d: Bool) -> Bool { config[k].map { $0 == "1" } ?? d }
    func int(_ k: String, _ d: Int) -> Int { config[k].flatMap(Int.init) ?? d }
    func string(_ k: String, _ d: String) -> String { config[k] ?? d }
}

/// The deck's widgets, in order. Persisted to UserDefaults as JSON on every change.
@Observable
@MainActor
final class WidgetStore {
    private(set) var widgets: [WidgetInstance] = [] { didSet { save(); onChange?() } }
    /// Runs after every change (AppState keeps floating windows and Now Playing in step).
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let key = "widgets.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([WidgetInstance].self, from: data) {
            widgets = saved
        } else {
            widgets = [WidgetInstance(kind: .clock), WidgetInstance(kind: .system), WidgetInstance(kind: .git),
                       WidgetInstance(kind: .sessions)]
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(widgets) { UserDefaults.standard.set(data, forKey: key) }
    }

    func add(_ kind: WidgetKind, config: [String: String] = [:]) -> UUID {
        let w = WidgetInstance(kind: kind, config: config)
        widgets.append(w)
        return w.id
    }

    func remove(_ id: UUID) {
        apply(DeckRows.removing(id, from: items))
        onRemove?(Set(widgets.map(\.id)))
    }

    // MARK: Deck rows (see DeckRows in GridCore)

    private var items: [DeckItem<UUID>] { widgets.map { DeckItem(id: $0.id, beside: $0.beside ?? false) } }

    /// Reorders and re-flags the cards to match `new` (same ids).
    private func apply(_ new: [DeckItem<UUID>]) {
        let byID = Dictionary(uniqueKeysWithValues: widgets.map { ($0.id, $0) })
        let next = new.compactMap { it -> WidgetInstance? in
            guard var w = byID[it.id] else { return nil }
            w.beside = it.beside ? true : nil
            return w
        }
        if next != widgets { widgets = next }
    }

    /// Cards grouped into rows, top to bottom.
    var rows: [[WidgetInstance]] {
        let byID = Dictionary(uniqueKeysWithValues: widgets.map { ($0.id, $0) })
        return DeckRows.rows(items).map { $0.compactMap { byID[$0] } }
    }

    /// Drops `id` on `target`'s edge: left/right beside it, top/bottom on a row of its own;
    /// nil target = a new last row.
    func place(_ id: UUID, at target: UUID?, edge: DropEdge?) {
        apply(DeckRows.moving(id, to: target, edge: edge, in: items))
    }

    func arrangeSideBySide() { apply(DeckRows.sideBySide(items)) }
    func arrangeStacked() { apply(DeckRows.stacked(items)) }

    /// Keyboard/menu moves: up/down jump rows, left/right swap within a row.
    func nudge(_ id: UUID, _ edge: DropEdge) {
        let r = DeckRows.rows(items)
        guard let ri = r.firstIndex(where: { $0.contains(id) }), let ci = r[ri].firstIndex(of: id) else { return }
        switch edge {
        case .left where ci > 0: place(id, at: r[ri][ci - 1], edge: .left)
        case .right where ci < r[ri].count - 1: place(id, at: r[ri][ci + 1], edge: .right)
        case .top where ri > 0: place(id, at: r[ri - 1][0], edge: .top)
        case .bottom where ri < r.count - 1: place(id, at: r[ri + 1][0], edge: .bottom)
        case .bottom where r[ri].count > 1: place(id, at: r[ri][0], edge: .bottom)   // leave a shared row
        default: break
        }
    }

    /// Where a card can still move (for enabling menu items).
    func canNudge(_ id: UUID, _ edge: DropEdge) -> Bool {
        let r = DeckRows.rows(items)
        guard let ri = r.firstIndex(where: { $0.contains(id) }), let ci = r[ri].firstIndex(of: id) else { return false }
        switch edge {
        case .left: return ci > 0
        case .right: return ci < r[ri].count - 1
        case .top: return ri > 0
        case .bottom: return ri < r.count - 1 || r[ri].count > 1
        }
    }

    /// Lets the widget platform stop a removed card's process right away.
    @ObservationIgnored var onRemove: ((Set<UUID>) -> Void)?

    func update(_ id: UUID, _ change: (inout WidgetInstance) -> Void) {
        guard let i = widgets.firstIndex(where: { $0.id == id }) else { return }
        var w = widgets[i]
        change(&w)
        if w != widgets[i] { widgets[i] = w }
    }

    func set(_ id: UUID, _ key: String, _ value: String?) {
        update(id) { $0.config[key] = value }
    }

    func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: key)
        defer { onRemove?(Set(widgets.map(\.id))) }
        widgets = [WidgetInstance(kind: .clock), WidgetInstance(kind: .system), WidgetInstance(kind: .git),
                   WidgetInstance(kind: .sessions)]
    }
}
