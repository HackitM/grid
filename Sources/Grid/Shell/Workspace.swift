import AppKit
import GridCore
import Observation
import SwiftUI

/// Layout of the Terminal workspace's dockable panels (Files, Terminal, Widget Deck) as a split
/// tree. Panels can be closed, reopened, re-docked by dragging their title bars, and resized.
/// Persisted as JSON; nil tree = every panel closed.
///
/// Sizing rules: every panel has a minimum size in points (`minimumSize`), enforced for the
/// current `viewport` on every change and again by `SplitTreeView` when rendering; the terminal
/// is the primary panel, so defaults and docking shares favour it (`weight`).
@Observable
@MainActor
final class WorkspaceLayout {
    /// Least size a panel may be rendered at, in points. The terminal needs room for a prompt
    /// (≈ 48 columns at the default font); the side panels for their toolbars and lists.
    static func minimumSize(_ p: WorkspacePanel) -> CGSize {
        switch p {
        case .terminal: CGSize(width: 360, height: 220)
        case .files: CGSize(width: 220, height: 160)
        case .deck: CGSize(width: 240, height: 160)
        }
    }

    /// Relative size when two panels share a split: the terminal takes three parts to one.
    static func weight(_ p: WorkspacePanel) -> Double { p == .terminal ? 3 : 1 }

    /// Share the moved panel takes of the region it is docked into (terminal next to a side
    /// panel: 3/4; side panel next to the terminal: 1/4; two side panels: half each).
    static func dockShare(moving p: WorkspacePanel, onto target: WorkspacePanel) -> Double {
        weight(p) / (weight(p) + weight(target))
    }

    /// Size of the area the tree is laid out in (reported by the view). Changes made by the user
    /// are fitted to it so no panel falls under its minimum; a window resize alone is not
    /// persisted (the view fits what it renders), so shrinking and re-growing the window brings
    /// the saved proportions back.
    var viewport: CGSize = .zero

    private(set) var tree: SplitTree? { didSet { save() } }

    /// Every change goes through here so panels keep their minimum sizes. (Re-balancing inside
    /// `didSet` re-enters the observer under @Observable and could recurse; review finding.)
    private func apply(_ t: SplitTree?) {
        let fitted = t.map(fit)
        if fitted != tree { tree = fitted }
    }

    private func fit(_ t: SplitTree) -> SplitTree {
        guard viewport.width > 0, viewport.height > 0 else { return t }
        return t.fitted(in: viewport, divider: Double(Metrics.gutter)) { id in
            WorkspacePanel(nodeID: id).map(Self.minimumSize) ?? .zero
        }
    }

    @ObservationIgnored private let key = "workspace.v2"
    /// First docking release: its min share of 20 % let the terminal end up as a narrow strip.
    @ObservationIgnored private let legacyKey = "workspace.v1"

    init() {
        let d = UserDefaults.standard
        if let saved = Self.load(d.data(forKey: key)) {
            tree = saved
        } else if let legacy = Self.load(d.data(forKey: legacyKey)) {
            // Repair a squeezed terminal once, then save under the new key.
            tree = legacy.map { Self.repaired($0) }
        } else {
            // First run / migration from the fixed layout: honour the old visibility toggles.
            let files = d.object(forKey: "layout.filesSidebar") as? Bool ?? true
            let deck = d.object(forKey: "layout.deck") as? Bool ?? false
            tree = Self.defaultTree(files: files, deck: deck)
        }
    }

    /// Decodes a saved tree; `.some(nil)` is a saved "all panels closed", nil means unusable or absent.
    private static func load(_ data: Data?) -> SplitTree?? {
        guard let data, let t = try? JSONDecoder().decode(SplitTree?.self, from: data), isUsable(t) else { return nil }
        return .some(t)
    }

    /// Terminal-dominant: 22 % | 56 % | 22 % with both side panels, 26 % for a single one.
    static func defaultTree(files: Bool, deck: Bool) -> SplitTree {
        var children: [SplitTree] = []
        var fractions: [Double] = []
        let side = files && deck ? 0.22 : 0.26
        if files { children.append(.leaf(WorkspacePanel.files.nodeID)); fractions.append(side) }
        children.append(.leaf(WorkspacePanel.terminal.nodeID)); fractions.append(1 - side * Double((files ? 1 : 0) + (deck ? 1 : 0)))
        if deck { children.append(.leaf(WorkspacePanel.deck.nodeID)); fractions.append(side) }
        return children.count == 1 ? children[0] : .split(id: UUID(), axis: .horizontal, children: children, fractions: fractions)
    }

    /// A terminal under 30 % of its split was squeezed by the old rules; give it half.
    static func repaired(_ t: SplitTree) -> SplitTree {
        let term = WorkspacePanel.terminal.nodeID
        guard let share = t.share(of: term), share < 0.3 else { return t }
        return t.ensuring(term, atLeast: 0.5)
    }

    /// Only known panels, each at most once.
    private static func isUsable(_ t: SplitTree?) -> Bool {
        guard let t else { return true }
        let leaves = t.leaves
        return t.isValid && Set(leaves).count == leaves.count && leaves.allSatisfy { WorkspacePanel(nodeID: $0) != nil }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tree) { UserDefaults.standard.set(data, forKey: key) }
    }

    var visiblePanels: [WorkspacePanel] { tree?.leaves.compactMap(WorkspacePanel.init(nodeID:)) ?? [] }
    func contains(_ p: WorkspacePanel) -> Bool { tree?.contains(p.nodeID) ?? false }

    /// Reopens a panel in its natural place: Files at the left edge, the deck at the right edge,
    /// the terminal right of Files (or at the left when Files is closed), taking most of the room.
    func show(_ p: WorkspacePanel) {
        guard !contains(p) else { return }
        guard let t = tree else { apply(.leaf(p.nodeID)); return }
        switch p {
        case .files: apply(t.inserting(p.nodeID, at: t.nodeID, edge: .left, share: 0.22))
        case .deck: apply(t.inserting(p.nodeID, at: t.nodeID, edge: .right, share: 0.22))
        case .terminal:
            let inserted = contains(.files)
                ? t.inserting(p.nodeID, at: WorkspacePanel.files.nodeID, edge: .right, share: Self.dockShare(moving: .terminal, onto: .files))
                : t.inserting(p.nodeID, at: t.nodeID, edge: .left, share: 0.7)
            apply(Self.reweighted(inserted))
        }
    }

    /// Re-balances the row or column holding the terminal by `weight` (3 : 1 : 1), used whenever
    /// the terminal joins a split: `inserting` only hands it a share of its neighbour's fraction,
    /// which in a crowded row leaves it narrow.
    private static func reweighted(_ t: SplitTree) -> SplitTree {
        t.reweighting(splitContaining: WorkspacePanel.terminal.nodeID) { node in
            node.leaves.compactMap(WorkspacePanel.init(nodeID:)).map(weight).max() ?? 1
        }
    }

    func hide(_ p: WorkspacePanel) { apply(tree?.removing(p.nodeID)) }
    func toggle(_ p: WorkspacePanel) { if contains(p) { hide(p) } else { show(p) } }

    /// A side panel docked beside the terminal takes `dockShare` of it. Docking the terminal
    /// itself re-balances its new row or column by `weight` (3 : 1 : 1), since joining an existing
    /// split would otherwise only give it a share of the target's fraction and leave it narrow.
    func move(_ p: WorkspacePanel, to target: WorkspacePanel, edge: DropEdge) {
        guard p != target, let t = tree else { return }
        let moved = t.moving(p.nodeID, to: target.nodeID, edge: edge, share: Self.dockShare(moving: p, onto: target))
        apply(p == .terminal ? Self.reweighted(moved) : moved)
    }

    /// `minFraction` comes from the view, which already keeps both sides of the divider at their
    /// own minimums; the tree's clamp is only a backstop.
    func resize(split: UUID, divider: Int, by delta: Double, minFraction: Double) {
        apply(tree?.resizing(splitID: split, divider: divider, by: delta, minFraction: minFraction))
    }
    func equalize(split: UUID) { apply(tree?.equalizing(splitID: split)) }
    func reset() { apply(Self.defaultTree(files: true, deck: false)) }
}

/// The dockable panels of the Terminal workspace.
enum WorkspacePanel: String, CaseIterable, Codable, Identifiable {
    case files, terminal, deck
    var id: String { rawValue }

    /// Fixed IDs so a saved layout tree maps back to panels.
    var nodeID: UUID {
        switch self {
        case .files: UUID(uuidString: "6F3C0000-0000-4000-8000-00000000F11E")!
        case .terminal: UUID(uuidString: "6F3C0000-0000-4000-8000-0000000007E2")!
        case .deck: UUID(uuidString: "6F3C0000-0000-4000-8000-00000000DEC0")!
        }
    }

    init?(nodeID: UUID) {
        guard let p = Self.allCases.first(where: { $0.nodeID == nodeID }) else { return nil }
        self = p
    }

    var title: String {
        switch self { case .files: "Files"; case .terminal: "Terminal"; case .deck: "Widget Deck" }
    }

    var toggleCommand: GridCommand {
        switch self { case .files: .toggleSidebar; case .terminal: .toggleTerminalPanel; case .deck: .toggleDeck }
    }
}
