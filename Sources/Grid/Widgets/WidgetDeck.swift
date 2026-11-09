import AppKit
import GridCore
import SwiftUI

/// The widget deck: a column of user-arranged widgets docked beside the terminal (⌘J).
struct WidgetDeck: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    @State private var editing: Set<UUID> = []
    @State private var showGallery = false

    var body: some View {
        let store = app.widgets
        Panel(index: "01.2", title: "Deck", suffix: "widgets", clipped: false) {
            HStack(spacing: 2) {
                IconButton(symbol: showGallery ? "xmark" : "plus", label: showGallery ? "Close gallery" : "Add widget", active: showGallery) {
                    showGallery.toggle()
                }
                Menu {
                    Button("Reset to Default Widgets") { store.resetToDefaults(); editing = [] }
                    Button("Hide Deck  ⌘J") { app.deckVisible = false }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(theme.textDim).frame(width: 22, height: 20)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Deck options")
            }
        } content: {
            ScrollView {
                VStack(spacing: 8) {
                    if showGallery {
                        WidgetGallery { kind in
                            let id = store.add(kind)
                            showGallery = false
                            if [.clock, .git, .folder, .storage, .network].contains(kind) { editing.insert(id) }
                        }
                    }
                    if store.widgets.isEmpty && !showGallery {
                        StateBlock(code: "DECK.EMPTY", title: "No widgets",
                                   message: "Add clocks, live system readouts, git status, notes, and more. Drag cards to reorder; use ⚙ to configure and × to remove.") {
                            Button("Add Widget") { showGallery = true }
                        }
                    }
                    ForEach(Array(store.widgets.enumerated()), id: \.element.id) { i, w in
                        WidgetCard(widget: w, index: i, editing: editing.contains(w.id)) {
                            if editing.contains(w.id) { editing.remove(w.id) } else { editing.insert(w.id) }
                        }
                    }
                    if !store.widgets.isEmpty {
                        // Drop zone to move a card to the end.
                        Rectangle().fill(Color.clear).frame(height: 28)
                            .dockTarget(.widgetEnd)
                    }
                }
                .padding(8)
            }
        }
    }
}

private struct WidgetGallery: View {
    @Environment(\.theme) private var theme
    let onAdd: (WidgetKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("add widget", color: theme.accent)
                TerminatedRule()
            }
            .padding(.bottom, 6)
            ForEach(WidgetKind.allCases) { kind in
                GalleryRow(kind: kind) { onAdd(kind) }
            }
        }
        .padding(8)
        .background(theme.bg3)
        .overlay(Rectangle().stroke(theme.lineStrong.opacity(0.5), lineWidth: Metrics.hairline))
    }
}

private struct GalleryRow: View {
    @Environment(\.theme) private var theme
    let kind: WidgetKind
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: kind.symbol).font(.system(size: 12)).foregroundStyle(theme.accent).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title.uppercased()).font(GridFont.label).tracking(1.2).foregroundStyle(theme.text)
                    Text(kind.blurb).font(GridFont.small).foregroundStyle(theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text("+").font(GridFont.bodyStrong).foregroundStyle(hover ? theme.accent : theme.textMute)
            }
            .padding(.vertical, 6).padding(.horizontal, 6)
            .background(hover ? theme.bg2 : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("Add \(kind.title) widget")
    }
}

/// One widget: header strip with controls, then its live content or its settings face.
private struct WidgetCard: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.effects) private var effects
    let widget: WidgetInstance
    let index: Int
    let editing: Bool
    let toggleEditing: () -> Void
    @State private var hover = false

    var body: some View {
        let store = app.widgets
        VStack(spacing: 0) {
            // Widest first: full header; without the ".SUFFIX"; then only the ⋯ menu beside the
            // title (the folded buttons live in the menu too), so the title never disappears.
            ViewThatFits(in: .horizontal) {
                header(store, showSuffix: true, compact: false)
                header(store, showSuffix: false, compact: false)
                header(store, showSuffix: false, compact: true)
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(theme.bg2.opacity(0.7))
            if !widget.collapsed {
                Rectangle().fill(editing ? theme.warn.opacity(0.5) : theme.line).frame(height: Metrics.hairline)
                Group {
                    if editing {
                        WidgetSettings(widget: widget, done: toggleEditing)
                    } else {
                        WidgetContent(widget: widget)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.bg3)
        .clipShape(ClippedRect(cut: 6))
        .overlay(ClippedRect(cut: 6).stroke(editing ? theme.warn.opacity(0.6) : (hover ? theme.lineStrong.opacity(0.5) : theme.line), lineWidth: Metrics.hairline))
        .onHover { hover = $0 }
        // A card dropped here moves before this one (GRID drag tracking; see DockDrag).
        .dockTarget(.widget(widget.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(widget.kind.title) widget")
    }

    private func header(_ store: WidgetStore, showSuffix: Bool, compact: Bool) -> some View {
        HStack(spacing: 6) {
            // Drag handle: the card's ID travels as the drag payload.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hover ? theme.textDim : theme.textMute)
                .frame(width: 14, height: 16)
                .contentShape(Rectangle())
                .dockDragSource(.widget(widget.id), label: widget.kind.title)
                .hoverCursor(.openHand)
                .help("Drag to reorder")
            Text(String(format: "W%02d", index + 1)).font(GridFont.label).foregroundStyle(editing ? theme.warn : theme.accent)
            HStack(spacing: 0) {
                Text(widget.kind.title.uppercased()).foregroundStyle(theme.text)
                if showSuffix { Text(" ." + widget.kind.suffix.uppercased()).foregroundStyle(theme.textMute) }
            }
            .font(GridFont.label).tracking(1.2).lineLimit(1)
            .layoutPriority(compact ? 1 : 0)
            Spacer(minLength: 4)
            if !compact {
                if !widget.collapsed && !editing {
                    smallButton(widget.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                widget.expanded ? "Compact" : "Expand") {
                        store.update(widget.id) { $0.expanded.toggle() }
                    }
                }
                smallButton("gearshape", editing ? "Done configuring" : "Configure", active: editing) { toggleEditing() }
                smallButton(widget.collapsed ? "chevron.down" : "chevron.up", widget.collapsed ? "Show" : "Collapse") {
                    store.update(widget.id) { $0.collapsed.toggle() }
                }
            }
            Menu {
                if compact {
                    Button(widget.collapsed ? "Show" : "Collapse") { store.update(widget.id) { $0.collapsed.toggle() } }
                    Button(widget.expanded ? "Compact" : "Expand") { store.update(widget.id) { $0.expanded.toggle() } }
                        .disabled(widget.collapsed || editing)
                    Button(editing ? "Done Configuring" : "Configure…") { toggleEditing() }
                    Divider()
                }
                Button("Move Up") { store.shift(widget.id, by: -1) }.disabled(index == 0)
                Button("Move Down") { store.shift(widget.id, by: 1) }.disabled(index == store.widgets.count - 1)
                Divider()
                Button("Remove Widget") { store.remove(widget.id) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 9)).foregroundStyle(theme.textDim).frame(width: 16, height: 16)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(compact ? "Widget actions" : "Move or remove")
            smallButton("xmark", "Remove widget") { withAnimation(effects.motion ? .easeOut(duration: 0.15) : nil) { store.remove(widget.id) } }
        }
    }

    private func smallButton(_ symbol: String, _ label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .medium))
                .foregroundStyle(active ? theme.warn : theme.textDim)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Shared widget building blocks

/// Segmented level bar (value 0...1) with the number printed beside it.
struct SegmentBar: View {
    @Environment(\.theme) private var theme
    let value: Double
    var segments = 24
    var warnAbove: Double = 0.85

    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 2
            let w = (size.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
            let filled = Int((min(max(value, 0), 1) * Double(segments)).rounded())
            for i in 0..<segments {
                let r = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: size.height)
                let color: Color = i < filled ? (value > warnAbove ? theme.warn : theme.accent) : theme.line
                ctx.fill(Path(r), with: .color(color))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// Line chart of recent samples (0...max). Real history only; empty until samples arrive.
struct Sparkline: View {
    @Environment(\.theme) private var theme
    let values: [Double]
    var maxValue: Double? = 1

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let top = max(maxValue ?? (values.max() ?? 1), 0.0001)
            let n = SystemMonitor.historyLength
            let step = size.width / CGFloat(n - 1)
            let offset = CGFloat(n - values.count) * step
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: offset + CGFloat(i) * step, y: size.height - CGFloat(min(v / top, 1)) * size.height)
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: offset, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(theme.accent.opacity(0.10)))
            ctx.stroke(line, with: .color(theme.accent), lineWidth: 1)
            // baseline
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: size.height - 0.5)); $0.addLine(to: CGPoint(x: size.width, y: size.height - 0.5)) },
                       with: .color(theme.line), lineWidth: 1)
        }
        .frame(height: 34)
        .accessibilityHidden(true)
    }
}

struct Readout: View {
    @Environment(\.effects) private var effects
    @Environment(\.theme) private var theme
    let label: String
    let value: String
    var detail: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            SectionLabel(label).frame(width: 46, alignment: .leading)
            // Measured values roll to their new number instead of jumping.
            Text(value).font(GridFont.mono(15, .medium)).foregroundStyle(theme.text).monospacedDigit()
                .contentTransition(.numericText())
                .animation(effects.motion ? .easeOut(duration: 0.3) : nil, value: value)
            if !detail.isEmpty { Text(detail).font(GridFont.small).foregroundStyle(theme.textDim).lineLimit(1) }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct WidgetFootnote: View {
    @Environment(\.theme) private var theme
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 8.5, weight: .medium, design: .monospaced)).tracking(1)
            .foregroundStyle(theme.textMute)
    }
}
