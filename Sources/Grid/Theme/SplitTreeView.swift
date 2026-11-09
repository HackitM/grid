import AppKit
import GridCore
import SwiftUI

/// Renders a `SplitTree`: leaves via `leaf`, splits as rows/columns sized by their fractions, with
/// draggable dividers (double-click a divider to even out that split). Used for terminal panes
/// and for the dockable workspace panels.
///
/// Leaves never render below their minimum size: the stored fractions are passed through
/// `SplitTree.fit` for the space actually available, and dividers stop where a side would go
/// under its minimum (per side, so a 220 pt panel can sit beside a 360 pt one). When the whole
/// tree cannot fit, every leaf shrinks in proportion to its minimum instead of collapsing.
struct SplitTreeView<Leaf: View>: View {
    let node: SplitTree
    var divider: CGFloat = 6
    var dividerFill: Color? = nil
    /// Minimum width and height of a leaf in points, unless `leafMinimum` says otherwise.
    var minLeaf: CGFloat = 120
    /// Per-leaf minimum size in points.
    var leafMinimum: ((UUID) -> CGSize)? = nil
    let onResize: (_ split: UUID, _ divider: Int, _ delta: Double, _ minFraction: Double) -> Void
    let onEqualize: (_ split: UUID) -> Void
    @ViewBuilder let leaf: (UUID) -> Leaf

    private func minimum(_ id: UUID) -> CGSize { leafMinimum?(id) ?? CGSize(width: minLeaf, height: minLeaf) }

    var body: some View {
        switch node {
        case .leaf(let id):
            leaf(id)
        case .split(let sid, let axis, let children, let fractions):
            GeometryReader { geo in
                let horizontal = axis == .horizontal
                let total = max((horizontal ? geo.size.width : geo.size.height) - divider * CGFloat(children.count - 1), 1)
                let mins = children.map { CGFloat($0.minimumLength(along: axis, divider: Double(divider), leafMinimum: minimum)) }
                let f = SplitTree.fit(fractions: fractions, minimums: mins.map(Double.init), total: Double(total))
                let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    ForEach(Array(children.enumerated()), id: \.element.nodeID) { i, child in
                        if i > 0 {
                            SplitDivider(axis: axis, thickness: divider, fill: dividerFill, total: total,
                                         before: f[i - 1], after: f[i],
                                         minBefore: Double(mins[i - 1] / total), minAfter: Double(mins[i] / total)) { delta, minF in
                                onResize(sid, i - 1, delta, minF)
                            } reset: {
                                onEqualize(sid)
                            }
                        }
                        SplitTreeView(node: child, divider: divider, dividerFill: dividerFill, minLeaf: minLeaf, leafMinimum: leafMinimum,
                                      onResize: onResize, onEqualize: onEqualize, leaf: leaf)
                            .frame(width: horizontal ? total * CGFloat(f[i]) : nil,
                                   height: horizontal ? nil : total * CGFloat(f[i]))
                    }
                }
            }
        }
    }
}

/// A draggable gutter between two children of a split.
struct SplitDivider: View {
    @Environment(\.theme) private var theme
    let axis: SplitAxis
    let thickness: CGFloat
    let fill: Color?
    let total: CGFloat
    /// Current fractions of the two neighbours and the least each may have.
    let before: Double
    let after: Double
    let minBefore: Double
    let minAfter: Double
    let onDrag: (_ delta: Double, _ minFraction: Double) -> Void
    let reset: () -> Void
    @State private var last: CGFloat = 0
    @State private var dragging = false
    @State private var hover = false

    /// Clamps a step so neither neighbour drops under its own minimum (a side already under it
    /// can only grow). The tree's own clamp then uses the smaller minimum and never fights this.
    private func move(_ step: Double) {
        let lo = min(minBefore - before, 0), hi = max(after - minAfter, 0)
        let clamped = min(max(step, lo), hi)
        guard clamped != 0 else { return }
        onDrag(clamped, min(minBefore, minAfter))
    }

    var body: some View {
        let horizontal = axis == .horizontal
        Rectangle()
            .fill(fill ?? theme.bg1)
            .frame(width: horizontal ? thickness : nil, height: horizontal ? nil : thickness)
            .overlay(
                Rectangle()
                    .fill(dragging ? theme.accent : (hover ? theme.lineStrong : theme.line))
                    .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
                    .opacity(fill == nil || hover || dragging ? 1 : 0)
            )
            .contentShape(Rectangle())
            .hoverCursor(horizontal ? .resizeLeftRight : .resizeUpDown) { hover = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        let t = horizontal ? v.translation.width : v.translation.height
                        if !dragging { dragging = true; last = 0 }
                        let step = t - last
                        last = t
                        move(Double(step / total))
                    }
                    .onEnded { _ in dragging = false; last = 0 }
            )
            .onTapGesture(count: 2) { reset() }
            .help("Drag to resize · double-click to even out")
            .accessibilityElement()
            .accessibilityLabel("Divider")
            .accessibilityAdjustableAction { dir in move(dir == .increment ? 0.05 : -0.05) }
    }
}
