import Foundation
import Observation

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case clock, system, network, storage, battery, sessions, apps, git, notes, folder
    var id: String { rawValue }

    var title: String {
        switch self {
        case .clock: "Clock"; case .system: "System"; case .network: "Network"; case .storage: "Storage"
        case .battery: "Power"; case .sessions: "Sessions"; case .apps: "Pinned Apps"; case .git: "Git"
        case .notes: "Notes"; case .folder: "Recent Files"
        }
    }

    var suffix: String {
        switch self {
        case .clock: "time"; case .system: "cpu.mem"; case .network: "net"; case .storage: "disk"
        case .battery: "pwr"; case .sessions: "tty"; case .apps: "launch"; case .git: "repo"
        case .notes: "txt"; case .folder: "recent"
        }
    }

    var symbol: String {
        switch self {
        case .clock: "clock"; case .system: "cpu"; case .network: "arrow.up.arrow.down"; case .storage: "internaldrive"
        case .battery: "battery.75percent"; case .sessions: "terminal"; case .apps: "square.grid.2x2"
        case .git: "arrow.triangle.branch"; case .notes: "note.text"; case .folder: "clock.arrow.circlepath"
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
    var config: [String: String] = [:]

    func bool(_ k: String, _ d: Bool) -> Bool { config[k].map { $0 == "1" } ?? d }
    func int(_ k: String, _ d: Int) -> Int { config[k].flatMap(Int.init) ?? d }
    func string(_ k: String, _ d: String) -> String { config[k] ?? d }
}

/// The deck's widgets, in order. Persisted to UserDefaults as JSON on every change.
@Observable
@MainActor
final class WidgetStore {
    private(set) var widgets: [WidgetInstance] = [] { didSet { save() } }
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

    func add(_ kind: WidgetKind) -> UUID {
        let w = WidgetInstance(kind: kind)
        widgets.append(w)
        return w.id
    }

    func remove(_ id: UUID) { widgets.removeAll { $0.id == id } }

    /// Moves `id` to sit just before `target` (or to the end when target is nil).
    func move(_ id: UUID, before target: UUID?) {
        guard id != target, let from = widgets.firstIndex(where: { $0.id == id }) else { return }
        let w = widgets.remove(at: from)
        if let target, let to = widgets.firstIndex(where: { $0.id == target }) {
            widgets.insert(w, at: to)
        } else {
            widgets.append(w)
        }
    }

    func shift(_ id: UUID, by delta: Int) {
        guard let i = widgets.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(widgets.count - 1, i + delta))
        guard i != j else { return }
        widgets.swapAt(i, j)
    }

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
        widgets = [WidgetInstance(kind: .clock), WidgetInstance(kind: .system), WidgetInstance(kind: .git),
                   WidgetInstance(kind: .sessions)]
    }
}
