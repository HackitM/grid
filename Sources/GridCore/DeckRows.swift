import Foundation

/// The deck's arrangement: cards in reading order, each either starting a new row or sitting
/// beside the card before it. Rows are laid out top to bottom; cards in a row side by side.
///
/// Kept as an ordered list plus a "beside" flag (rather than a tree) so it round-trips through the
/// existing saved deck, and so every card keeps a stable reading order for keyboard moves and the
/// W01, W02… numbering.
public struct DeckItem<ID: Hashable>: Equatable {
    public var id: ID
    /// True: same row as the previous card. The first card always starts a row.
    public var beside: Bool
    public init(id: ID, beside: Bool) { self.id = id; self.beside = beside }
}

public enum DeckRows {
    /// Most cards one row may hold.
    public static let maxPerRow = 6

    /// Rows of ids, top to bottom.
    public static func rows<ID>(_ items: [DeckItem<ID>]) -> [[ID]] {
        var out: [[ID]] = []
        for (i, it) in items.enumerated() {
            if i == 0 || !it.beside || out.isEmpty { out.append([it.id]) } else { out[out.count - 1].append(it.id) }
        }
        return out
    }

    /// Rebuilds items from rows (inverse of `rows`).
    public static func items<ID>(_ rows: [[ID]]) -> [DeckItem<ID>] {
        rows.flatMap { row in row.enumerated().map { DeckItem(id: $0.element, beside: $0.offset > 0) } }
    }

    /// Normalizes: the first card starts a row, and no row exceeds `maxPerRow` (overflow wraps).
    public static func normalized<ID>(_ items: [DeckItem<ID>]) -> [DeckItem<ID>] {
        Self.items(rows(items).flatMap { row in stride(from: 0, to: row.count, by: maxPerRow).map { Array(row[$0..<min($0 + maxPerRow, row.count)]) } })
    }

    /// Removes `id`; a row keeps its other cards.
    public static func removing<ID>(_ id: ID, from items: [DeckItem<ID>]) -> [DeckItem<ID>] {
        Self.items(rows(items).map { $0.filter { $0 != id } }.filter { !$0.isEmpty })
    }

    /// Moves `id` next to `target`: left/right puts it beside the target in the target's row (if
    /// that row has room; otherwise it gets its own row on that side), top/bottom gives it its own
    /// row above/below the target's row. `target == nil` moves it to a new last row.
    public static func moving<ID>(_ id: ID, to target: ID?, edge: DropEdge?, in items: [DeckItem<ID>]) -> [DeckItem<ID>] {
        guard items.contains(where: { $0.id == id }), id != target else { return items }
        var r = rows(removing(id, from: items))
        guard let target, let ri = r.firstIndex(where: { $0.contains(target) }), let ci = r[ri].firstIndex(of: target) else {
            r.append([id])
            return Self.items(r)
        }
        switch edge ?? .bottom {
        case .left, .right:
            let at = edge == .left ? ci : ci + 1
            if r[ri].count < maxPerRow { r[ri].insert(id, at: at) }
            else { r.insert([id], at: edge == .left ? ri : ri + 1) }
        case .top: r.insert([id], at: ri)
        case .bottom: r.insert([id], at: ri + 1)
        }
        return Self.items(r)
    }

    /// Every card in one row (wrapping at `maxPerRow`).
    public static func sideBySide<ID>(_ items: [DeckItem<ID>]) -> [DeckItem<ID>] {
        normalized(items.enumerated().map { DeckItem(id: $0.element.id, beside: $0.offset > 0) })
    }

    /// Every card on its own row.
    public static func stacked<ID>(_ items: [DeckItem<ID>]) -> [DeckItem<ID>] {
        items.map { DeckItem(id: $0.id, beside: false) }
    }

    /// Splits `count` cards into lines that fit `width`: as many per line as fit at `minWidth`,
    /// never more than the row has. Returns the number of cards on each line.
    public static func lines(count: Int, width: Double, minWidth: Double, spacing: Double) -> [Int] {
        guard count > 0 else { return [] }
        // Layout can propose an infinite width; `Int(_:)` traps on a value it can't represent.
        let ratio = (width + spacing) / (minWidth + spacing)
        let fit = ratio.isFinite ? max(1, Int(min(ratio, Double(count)).rounded(.down))) : count
        let perLine = min(count, fit)
        var out: [Int] = []
        var left = count
        while left > 0 { out.append(min(perLine, left)); left -= perLine }
        return out
    }
}
