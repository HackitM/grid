import Foundation

public enum SplitAxis: String, Codable, Sendable {
    /// Children side by side (split "right").
    case horizontal
    /// Children stacked (split "down").
    case vertical
}

/// Which edge of a node a dragged pane is dropped on.
public enum DropEdge: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom

    /// The axis of the split that places something on this edge.
    public var axis: SplitAxis {
        switch self {
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        }
    }

    /// True when the dropped pane goes before the target in reading order (left / top).
    public var isLeading: Bool {
        switch self {
        case .left, .top: true
        case .right, .bottom: false
        }
    }
}

/// Layout of the panes in one terminal tab: leaves are pane IDs, inner nodes split their area
/// along an axis by fractions (which always sum to 1). Pure value type; the app maps leaf IDs
/// to sessions.
public indirect enum SplitTree: Equatable, Sendable {
    case leaf(UUID)
    case split(id: UUID, axis: SplitAxis, children: [SplitTree], fractions: [Double])

    /// Pane IDs in reading order (depth-first).
    public var leaves: [UUID] {
        switch self {
        case .leaf(let id): [id]
        case .split(_, _, let children, _): children.flatMap(\.leaves)
        }
    }

    public func contains(_ id: UUID) -> Bool { leaves.contains(id) }

    /// Stable identity for views: the pane ID for a leaf, the split's own ID otherwise.
    public var nodeID: UUID {
        switch self {
        case .leaf(let id): id
        case .split(let id, _, _, _): id
        }
    }

    /// The node (leaf or split) whose `nodeID` is `id`, searched depth-first.
    public func node(_ id: UUID) -> SplitTree? {
        if nodeID == id { return self }
        guard case .split(_, _, let children, _) = self else { return nil }
        for child in children {
            if let found = child.node(id) { return found }
        }
        return nil
    }

    // MARK: Validity

    /// True iff every split has at least two children, one positive finite fraction per child
    /// summing to 1 (±1e-6), and no pane ID appears twice.
    public var isValid: Bool {
        let all = leaves
        return structurallyValid && Set(all).count == all.count
    }

    private var structurallyValid: Bool {
        guard case .split(_, _, let children, let fractions) = self else { return true }
        guard children.count >= 2, fractions.count == children.count,
              fractions.allSatisfy({ $0.isFinite && $0 > 0 }),
              abs(fractions.reduce(0, +) - 1) <= 1e-6
        else { return false }
        return children.allSatisfy(\.structurallyValid)
    }

    // MARK: Split

    /// Splits pane `target` along `axis`, putting `new` right after it. If `target` already sits
    /// in a split with the same axis, the new pane joins that split (taking half of `target`'s
    /// share) instead of nesting another level.
    public func splitting(_ target: UUID, axis: SplitAxis, with new: UUID) -> SplitTree {
        switch self {
        case .leaf(let id):
            guard id == target else { return self }
            return .split(id: UUID(), axis: axis, children: [self, .leaf(new)], fractions: [0.5, 0.5])
        case .split(let sid, let a, let children, let fractions):
            if a == axis, let i = children.firstIndex(of: .leaf(target)) {
                var c = children, f = fractions
                let half = f[i] / 2
                f[i] = half
                c.insert(.leaf(new), at: i + 1)
                f.insert(half, at: i + 1)
                return .split(id: sid, axis: a, children: c, fractions: f)
            }
            return .split(id: sid, axis: a, children: children.map { $0.splitting(target, axis: axis, with: new) }, fractions: fractions)
        }
    }

    // MARK: Remove

    /// Removes pane `target`. Its share goes to the neighbouring child; a split left with one
    /// child collapses into it, and a child split with the same axis as its parent is flattened.
    /// Returns nil when the last pane is removed.
    public func removing(_ target: UUID) -> SplitTree? {
        switch self {
        case .leaf(let id):
            return id == target ? nil : self
        case .split(let sid, let axis, let children, let fractions):
            var c: [SplitTree] = []
            var f: [Double] = []
            var orphaned = 0.0
            for (child, frac) in zip(children, fractions) {
                if let kept = child.removing(target) {
                    c.append(kept); f.append(frac)
                } else {
                    orphaned += frac
                    // Give the removed share to the previous sibling, or (if first) the next one.
                    if let last = f.indices.last { f[last] += orphaned; orphaned = 0 }
                }
            }
            if orphaned > 0, !f.isEmpty { f[0] += orphaned }
            if c.isEmpty { return nil }
            if c.count == 1 { return c[0] }
            return SplitTree.split(id: sid, axis: axis, children: c, fractions: f).flattened()
        }
    }

    /// Merges same-axis child splits into their parent (proportionally).
    func flattened() -> SplitTree {
        guard case .split(let sid, let axis, let children, let fractions) = self else { return self }
        var c: [SplitTree] = []
        var f: [Double] = []
        for (child, frac) in zip(children, fractions) {
            if case .split(_, let ca, let cc, let cf) = child, ca == axis {
                c += cc; f += cf.map { $0 * frac }
            } else {
                c.append(child); f.append(frac)
            }
        }
        return .split(id: sid, axis: axis, children: c, fractions: f)
    }

    // MARK: Resize

    /// Moves divider `index` (between children `index` and `index + 1`) of split `splitID` by
    /// `delta` (a fraction of that split's length), keeping both sides at least `minFraction`.
    public func resizing(splitID: UUID, divider index: Int, by delta: Double, minFraction: Double = 0.1) -> SplitTree {
        switch self {
        case .leaf: return self
        case .split(let sid, let axis, let children, let fractions):
            if sid == splitID, fractions.indices.contains(index + 1) {
                var f = fractions
                let pair = f[index] + f[index + 1]
                let lo = min(minFraction, pair / 2)
                let a = min(max(f[index] + delta, lo), pair - lo)
                f[index] = a
                f[index + 1] = pair - a
                return .split(id: sid, axis: axis, children: children, fractions: f)
            }
            return .split(id: sid, axis: axis, children: children.map { $0.resizing(splitID: splitID, divider: index, by: delta, minFraction: minFraction) }, fractions: fractions)
        }
    }

    /// Guarantees every child of every split at least `minFraction` of its split (capped at an
    /// equal share), borrowing from the largest siblings. Keeps fractions summing to 1.
    public func balanced(minFraction: Double) -> SplitTree {
        guard case .split(let sid, let axis, let children, let fractions) = self else { return self }
        let floor = min(minFraction, 1 / Double(children.count))
        var f = fractions
        // Tolerance keeps this idempotent: values a rounding error below the floor count as at it.
        for i in f.indices where f[i] < floor - 1e-9 {
            var need = floor - f[i]
            f[i] = floor
            // Take from the largest siblings that stay above the floor.
            while need > 1e-12 {
                guard let j = f.indices.filter({ $0 != i && f[$0] > floor + 1e-12 }).max(by: { f[$0] < f[$1] }) else { break }
                let give = min(need, f[j] - floor)
                f[j] -= give
                need -= give
            }
        }
        let sum = f.reduce(0, +)
        if sum > 0, abs(sum - 1) > 1e-9 { f = f.map { $0 / sum } }
        return .split(id: sid, axis: axis, children: children.map { $0.balanced(minFraction: minFraction) }, fractions: f)
    }

    // MARK: Minimum sizes (points)

    /// Shares for children of one split whose length is `total` points so that each child gets at
    /// least its minimum (`minimums[i]` points) when they all fit, borrowing from the others in
    /// proportion to their current fractions. When the minimums alone exceed `total`, every child
    /// gets its minimum's share of the sum instead, so nothing collapses to zero. Idempotent.
    public static func fit(fractions: [Double], minimums: [Double], total: Double) -> [Double] {
        let n = fractions.count
        guard n > 0, minimums.count == n, total > 0, total.isFinite else { return fractions }
        let mins = minimums.map { $0.isFinite ? max($0, 0) : 0 }
        let minSum = mins.reduce(0, +)
        if minSum >= total { return minSum > 0 ? mins.map { $0 / minSum } : fractions }
        var lengths = fractions.map { $0 * total }
        var fixed = [Bool](repeating: false, count: n)
        for _ in 0..<n {
            var changed = false
            for i in 0..<n where !fixed[i] && lengths[i] < mins[i] - 1e-9 {
                fixed[i] = true; lengths[i] = mins[i]; changed = true
            }
            if !changed { break }
            // Because minSum < total, at least one child stays free to absorb the difference.
            let free = (0..<n).filter { !fixed[$0] }
            let remaining = total - (0..<n).filter { fixed[$0] }.map { lengths[$0] }.reduce(0, +)
            let weight = free.map { fractions[$0] }.reduce(0, +)
            for i in free { lengths[i] = weight > 0 ? remaining * fractions[i] / weight : remaining / Double(free.count) }
        }
        return lengths.map { $0 / total }
    }

    /// The least this subtree can measure along `axis`: a leaf's own minimum; for a split along
    /// `axis`, its children's minimums plus the dividers between them; across it, the largest child.
    public func minimumLength(along axis: SplitAxis, divider: Double, leafMinimum: (UUID) -> CGSize) -> Double {
        switch self {
        case .leaf(let id):
            let m = leafMinimum(id)
            return axis == .horizontal ? m.width : m.height
        case .split(_, let a, let children, _):
            let parts = children.map { $0.minimumLength(along: axis, divider: divider, leafMinimum: leafMinimum) }
            return a == axis ? parts.reduce(0, +) + divider * Double(children.count - 1) : (parts.max() ?? 0)
        }
    }

    /// Repairs every split's fractions so each leaf gets at least `leafMinimum` points when the
    /// tree is rendered in `size` (see `fit`). Trees that already satisfy the minimums are returned
    /// unchanged.
    public func fitted(in size: CGSize, divider: Double, leafMinimum: (UUID) -> CGSize) -> SplitTree {
        guard case .split(let sid, let axis, let children, let fractions) = self else { return self }
        let horizontal = axis == .horizontal
        let total = max((horizontal ? size.width : size.height) - divider * Double(children.count - 1), 1)
        let mins = children.map { $0.minimumLength(along: axis, divider: divider, leafMinimum: leafMinimum) }
        let f = Self.fit(fractions: fractions, minimums: mins, total: total)
        let kids = zip(children, f).map { child, frac in
            child.fitted(in: horizontal ? CGSize(width: frac * total, height: size.height) : CGSize(width: size.width, height: frac * total),
                         divider: divider, leafMinimum: leafMinimum)
        }
        return .split(id: sid, axis: axis, children: kids, fractions: f)
    }

    /// The share leaf `id` gets from its parent split (nil for the root or a missing leaf).
    public func share(of id: UUID) -> Double? {
        guard case .split(_, _, let children, let fractions) = self else { return nil }
        if let i = children.firstIndex(of: .leaf(id)) { return fractions[i] }
        for child in children { if let s = child.share(of: id) { return s } }
        return nil
    }

    /// Gives leaf `id` at least `fraction` of its parent split, scaling the siblings down in
    /// proportion. Unchanged when the leaf is the root, missing, or already has that share.
    public func ensuring(_ id: UUID, atLeast fraction: Double) -> SplitTree {
        guard case .split(let sid, let axis, let children, let fractions) = self else { return self }
        if let i = children.firstIndex(of: .leaf(id)) {
            guard fraction.isFinite, fraction > 0, fraction < 1, fractions[i] < fraction else { return self }
            var f = fractions
            let scale = (1 - fraction) / (1 - f[i])
            for j in f.indices where j != i { f[j] *= scale }
            f[i] = fraction
            return .split(id: sid, axis: axis, children: children, fractions: f)
        }
        return .split(id: sid, axis: axis, children: children.map { $0.ensuring(id, atLeast: fraction) }, fractions: fractions)
    }

    /// Sets the fractions of the split that directly holds leaf `id` in proportion to `weight`
    /// of each child node (a split child is weighted as a whole). Unchanged when the leaf is the
    /// root or missing, or the weights are not all positive and finite.
    public func reweighting(splitContaining id: UUID, weight: (SplitTree) -> Double) -> SplitTree {
        guard case .split(let sid, let axis, let children, let fractions) = self else { return self }
        if children.contains(.leaf(id)) {
            let w = children.map(weight)
            let sum = w.reduce(0, +)
            guard w.allSatisfy({ $0.isFinite && $0 > 0 }), sum > 0 else { return self }
            return .split(id: sid, axis: axis, children: children, fractions: w.map { $0 / sum })
        }
        return .split(id: sid, axis: axis, children: children.map { $0.reweighting(splitContaining: id, weight: weight) }, fractions: fractions)
    }

    /// Resets one split's children to equal shares.
    public func equalizing(splitID: UUID) -> SplitTree {
        switch self {
        case .leaf: return self
        case .split(let sid, let axis, let children, let fractions):
            if sid == splitID {
                return .split(id: sid, axis: axis, children: children, fractions: Array(repeating: 1 / Double(children.count), count: children.count))
            }
            return .split(id: sid, axis: axis, children: children.map { $0.equalizing(splitID: splitID) }, fractions: fractions)
        }
    }

    // MARK: Insert (drop)

    /// Places a new pane `new` on `edge` of the node whose `nodeID` is `target` (a pane or a split,
    /// the root included). When the target already sits in a split along `edge.axis`, the new pane
    /// joins that split right before / after it and takes `share` of the target's fraction.
    /// Otherwise the target is replaced by a fresh split along `edge.axis` holding both, where the
    /// new pane gets `share` of the area. Unchanged when `target` is missing or `new` is already
    /// a node of the tree. `share` outside (0, 1) falls back to one half.
    public func inserting(_ new: UUID, at target: UUID, edge: DropEdge, share: Double = 0.5) -> SplitTree {
        guard node(target) != nil, node(new) == nil else { return self }
        let share = (share.isFinite && share > 0 && share < 1) ? share : 0.5
        return inserted(new, at: target, edge: edge, share: share)
    }

    private func inserted(_ new: UUID, at target: UUID, edge: DropEdge, share: Double) -> SplitTree {
        if nodeID == target {
            // Dropping on the edge of a split that already runs along `edge.axis` just extends it,
            // keeping its identity; anything else gets wrapped in a fresh split.
            if case .split(let sid, let axis, let children, let fractions) = self, axis == edge.axis {
                let scaled = fractions.map { $0 * (1 - share) }
                let c = edge.isLeading ? [.leaf(new)] + children : children + [.leaf(new)]
                let f = edge.isLeading ? [share] + scaled : scaled + [share]
                return .split(id: sid, axis: axis, children: c, fractions: f)
            }
            let c: [SplitTree] = edge.isLeading ? [.leaf(new), self] : [self, .leaf(new)]
            let f = edge.isLeading ? [share, 1 - share] : [1 - share, share]
            return .split(id: UUID(), axis: edge.axis, children: c, fractions: f)
        }
        guard case .split(let sid, let axis, let children, let fractions) = self else { return self }
        if axis == edge.axis, let i = children.firstIndex(where: { $0.nodeID == target }) {
            var c = children, f = fractions
            let whole = f[i]
            f[i] = whole * (1 - share)
            let at = edge.isLeading ? i : i + 1
            c.insert(.leaf(new), at: at)
            f.insert(whole * share, at: at)
            return .split(id: sid, axis: axis, children: c, fractions: f)
        }
        return SplitTree.split(id: sid, axis: axis,
                               children: children.map { $0.inserted(new, at: target, edge: edge, share: share) },
                               fractions: fractions).flattened()
    }

    // MARK: Move (drag)

    /// Moves pane `id` next to node `target` on `edge`: `removing(id)` followed by `inserting`.
    /// Unchanged when `id == target`, `id` is not a pane of the tree, `target` is missing, the
    /// tree would be left empty, or `target` is a split that no longer exists once `id` is gone.
    public func moving(_ id: UUID, to target: UUID, edge: DropEdge, share: Double = 0.5) -> SplitTree {
        guard id != target, contains(id), node(target) != nil,
              let remaining = removing(id), remaining.node(target) != nil
        else { return self }
        return remaining.inserting(id, at: target, edge: edge, share: share)
    }
}

// MARK: - Codable

extension SplitTree: Codable {
    /// JSON shape: `{"leaf": "<uuid>"}` or
    /// `{"split": "<uuid>", "axis": "horizontal", "children": [...], "fractions": [...]}`.
    private enum CodingKeys: String, CodingKey {
        case leaf, split, axis, children, fractions
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let id):
            try container.encode(id, forKey: .leaf)
        case .split(let id, let axis, let children, let fractions):
            try container.encode(id, forKey: .split)
            try container.encode(axis, forKey: .axis)
            try container.encode(children, forKey: .children)
            try container.encode(fractions, forKey: .fractions)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func corrupted(_ message: String) -> DecodingError {
            .dataCorrupted(DecodingError.Context(codingPath: container.codingPath, debugDescription: message))
        }
        if container.contains(.leaf) {
            self = .leaf(try container.decode(UUID.self, forKey: .leaf))
            return
        }
        guard container.contains(.split) else {
            throw corrupted("SplitTree node needs a \"leaf\" or \"split\" key")
        }
        let id = try container.decode(UUID.self, forKey: .split)
        let axis = try container.decode(SplitAxis.self, forKey: .axis)
        let children = try container.decode([SplitTree].self, forKey: .children)
        var fractions = try container.decode([Double].self, forKey: .fractions)
        guard children.count >= 2 else {
            throw corrupted("split \(id) has \(children.count) child(ren); needs at least 2")
        }
        guard fractions.count == children.count else {
            throw corrupted("split \(id) has \(fractions.count) fractions for \(children.count) children")
        }
        guard fractions.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw corrupted("split \(id) has a fraction that is not a positive finite number")
        }
        let sum = fractions.reduce(0, +)
        if sum != 1 { fractions = fractions.map { $0 / sum } }
        let tree = SplitTree.split(id: id, axis: axis, children: children, fractions: fractions)
        let all = tree.leaves
        guard Set(all).count == all.count else {
            throw corrupted("split \(id) contains a duplicate pane ID")
        }
        self = tree
    }
}
