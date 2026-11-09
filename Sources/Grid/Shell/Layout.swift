import AppKit
import Observation
import SwiftUI

/// Persisted workspace layout: panel widths and visibility, last Files folder.
@Observable
@MainActor
final class LayoutState {
    @ObservationIgnored private let d = UserDefaults.standard
    var sidebarWidth: CGFloat { didSet { d.set(Double(sidebarWidth), forKey: "layout.sidebarWidth") } }
    var inspectorWidth: CGFloat { didSet { d.set(Double(inspectorWidth), forKey: "layout.inspectorWidth") } }
    var deckWidth: CGFloat { didSet { d.set(Double(deckWidth), forKey: "layout.deckWidth") } }

    init() {
        d.register(defaults: ["layout.sidebarWidth": 300.0, "layout.inspectorWidth": 290.0, "layout.deckWidth": 300.0])
        sidebarWidth = CGFloat(d.double(forKey: "layout.sidebarWidth"))
        inspectorWidth = CGFloat(d.double(forKey: "layout.inspectorWidth"))
        deckWidth = CGFloat(d.double(forKey: "layout.deckWidth"))
    }
}

/// Draggable divider in the gutter between two panels. Double-click resets the width.
/// `edge`: which side of the handle the resized panel sits on.
struct ResizeHandle: View {
    @Environment(\.theme) private var theme
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    let defaultValue: CGFloat
    let edge: HorizontalEdge
    @State private var start: CGFloat?
    @State private var hover = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: Metrics.gutter)
            .overlay(
                Rectangle()
                    .fill(start != nil ? theme.accent : theme.lineStrong.opacity(0.6))
                    .frame(width: 1)
                    .opacity(hover || start != nil ? 1 : 0)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                hover = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if start == nil { start = width }
                        let delta = edge == .leading ? v.translation.width : -v.translation.width
                        width = min(max((start ?? width) + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in start = nil }
            )
            .onTapGesture(count: 2) { width = defaultValue }
            .help("Drag to resize · double-click to reset")
            .accessibilityElement()
            .accessibilityLabel("Resize panel")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { dir in
                switch dir {
                case .increment: width = min(width + 20, range.upperBound)
                case .decrement: width = max(width - 20, range.lowerBound)
                @unknown default: break
                }
            }
    }
}
