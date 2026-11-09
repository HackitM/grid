import Foundation

public enum SplitAxis: String, Codable, Sendable {
    /// Children side by side (split "right").
    case horizontal
    /// Children stacked (split "down").
    case vertical
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
}
