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
                GridMenuButton(help: "Deck options") {
                    GridMenuItem.action("Place All Side by Side") { store.arrangeSideBySide() }
                    GridMenuItem.action("Stack All Vertically") { store.arrangeStacked() }
                    GridMenuItem.divider
                    GridMenuItem.action("Reset to Default Widgets") { store.resetToDefaults(); editing = [] }
                    GridMenuItem.action("Hide Deck", shortcut: app.shortcuts.display(.toggleDeck)) { app.deckVisible = false }
                }
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
                                   message: "Add clocks, live system readouts, git status, notes, and more. Drag a card by its title onto another card's edge to place it beside or above/below; use ⚙ to configure and × to remove.") {
                            Button("Add Widget") { showGallery = true }
                        }
                    }
                    // Rows of cards: side by side when there's room, wrapping when the deck is narrow.
                    let number = Dictionary(uniqueKeysWithValues: store.widgets.enumerated().map { ($0.element.id, $0.offset) })
                    ForEach(store.rows, id: \.first?.id) { row in
                        DeckRowLayout {
                            ForEach(row) { w in
                                WidgetCard(widget: w, index: number[w.id] ?? 0, editing: editing.contains(w.id)) {
                                    if editing.contains(w.id) { editing.remove(w.id) } else { editing.insert(w.id) }
                                }
                            }
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
            .dockClipToBounds()
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
            ForEach(WidgetKind.builtIn) { kind in
                GalleryRow(kind: kind) { onAdd(kind) }
            }
            CustomWidgetGallery()
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

    /// Built-in kinds use their own title; custom cards show the package's name.
    private var title: String {
        guard widget.kind == .custom else { return widget.kind.title }
        return app.widgetLibrary.entry(widget.string("package", ""))?.name ?? "Missing widget"
    }
    /// DEV for your own packages, 3RD for installed ones (so a card can't pass itself off as GRID's).
    private var origin: String? {
        guard widget.kind == .custom else { return nil }
        return widget.string("package", "").hasPrefix("dev:") ? "DEV" : "3RD"
    }

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
        // Cards in a row share the row's height (collapsed ones stay a header strip).
        .frame(maxHeight: widget.collapsed ? nil : .infinity, alignment: .top)
        .background(theme.bg3)
        .clipShape(ClippedRect(cut: 6))
        .overlay(ClippedRect(cut: 6).stroke(editing ? theme.warn.opacity(0.6) : (hover ? theme.lineStrong.opacity(0.5) : theme.line), lineWidth: Metrics.hairline))
        .onHover { hover = $0 }
        // A card dropped here moves before this one (GRID drag tracking; see DockDrag).
        .dockTarget(.widget(widget.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) widget")
    }

    private func header(_ store: WidgetStore, showSuffix: Bool, compact: Bool) -> some View {
        HStack(spacing: 6) {
            // Title bar: drag it (handle, number or title) onto another card's edge, like a panel.
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hover ? theme.textDim : theme.textMute)
                    .frame(width: 14, height: 16)
                Text(String(format: "W%02d", index + 1)).font(GridFont.label).foregroundStyle(editing ? theme.warn : theme.accent)
                HStack(spacing: 0) {
                    Text(title.uppercased()).foregroundStyle(theme.text)
                    if showSuffix && origin == nil { Text(" ." + widget.kind.suffix.uppercased()).foregroundStyle(theme.textMute) }
                }
                .font(GridFont.label).tracking(1.2).lineLimit(1)
                if let origin { Tag(origin, color: origin == "DEV" ? theme.warn : theme.textMute).help(origin == "DEV" ? "Your development widget" : "Third-party widget") }
                Spacer(minLength: 4)
            }
            .layoutPriority(compact ? 1 : 0)
            .contentShape(Rectangle())
            .dockDragSource(.widget(widget.id), label: title)
            .hoverCursor(.openHand)
            .help("Drag onto another card's edge to place it beside, above or below")
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
            GridMenuButton(help: compact ? "Widget actions" : "Move or remove", size: 9, frame: CGSize(width: 16, height: 16)) {
                if compact {
                    GridMenuItem.action(widget.collapsed ? "Show" : "Collapse") { store.update(widget.id) { $0.collapsed.toggle() } }
                    GridMenuItem.action(widget.expanded ? "Compact" : "Expand", enabled: !(widget.collapsed || editing)) {
                        store.update(widget.id) { $0.expanded.toggle() }
                    }
                    GridMenuItem.action(editing ? "Done Configuring" : "Configure…") { toggleEditing() }
                    GridMenuItem.divider
                }
                GridMenuItem.action("Move Up", enabled: store.canNudge(widget.id, .top)) { store.nudge(widget.id, .top) }
                GridMenuItem.action("Move Down", enabled: store.canNudge(widget.id, .bottom)) { store.nudge(widget.id, .bottom) }
                GridMenuItem.action("Move Left", enabled: store.canNudge(widget.id, .left)) { store.nudge(widget.id, .left) }
                GridMenuItem.action("Move Right", enabled: store.canNudge(widget.id, .right)) { store.nudge(widget.id, .right) }
                GridMenuItem.divider
                GridMenuItem.action("Remove Widget", destructive: true) { store.remove(widget.id) }
            }
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
    /// Fixed fill color (overrides the accent / warn split).
    var color: Color? = nil

    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 2
            let w = (size.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
            let filled = Int((min(max(value, 0), 1) * Double(segments)).rounded())
            for i in 0..<segments {
                let r = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: size.height)
                let fill: Color = color ?? (value > warnAbove ? theme.warn : theme.accent)
                let color: Color = i < filled ? fill : theme.line
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
    /// Horizontal slots (values fill from the right); defaults to the system monitor's history.
    var slots: Int = SystemMonitor.historyLength

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let top = max(maxValue ?? (values.max() ?? 1), 0.0001)
            let n = max(slots, values.count)
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
    @Environment(\.theme) private var theme
    let label: String
    let value: String
    var detail: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            SectionLabel(label).frame(width: 46, alignment: .leading)
            // Updates in place. (Rolling digits looked nice but every animation frame made SwiftUI
            // re-rasterize the whole deck on the CPU: ~40% of a core for a value refreshed every 2 s.)
            Text(value).font(GridFont.mono(15, .medium)).foregroundStyle(theme.text).monospacedDigit()
                .lineLimit(1).fixedSize()
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

// MARK: - Row layout

/// One deck row: cards side by side at equal widths and the row's height. When the deck is too
/// narrow for them all (under `minWidth` each), the row wraps onto more lines.
struct DeckRowLayout: Layout {
    var spacing: CGFloat = 8
    var minWidth: CGFloat = 190

    struct Line { var range: Range<Int>; var cardWidth: CGFloat; var height: CGFloat }
    struct Cache { var width: CGFloat = -1; var lines: [Line] = [] }

    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    /// Lines for a definite width, measured once per width.
    private func lines(_ width: CGFloat, _ subviews: Subviews, _ cache: inout Cache) -> [Line] {
        if cache.width == width { return cache.lines }
        var out: [Line] = []
        var i = 0
        for n in DeckRows.lines(count: subviews.count, width: Double(width), minWidth: Double(minWidth), spacing: Double(spacing)) {
            let w = max(0, (width - spacing * CGFloat(n - 1)) / CGFloat(n))
            let h = subviews[i..<i + n].map { $0.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }.max() ?? 0
            out.append(Line(range: i..<i + n, cardWidth: w, height: h))
            i += n
        }
        cache.width = width
        cache.lines = out
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let width = proposal.width, width.isFinite, width > 0 else {
            // Ideal size: like an HStack of the cards at their own ideal sizes (no made-up width,
            // which would measure cards in a state they're never shown in).
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            return CGSize(width: sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1)),
                          height: sizes.map(\.height).max() ?? 0)
        }
        let rows = lines(width, subviews, &cache)
        return CGSize(width: width, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var y = bounds.minY
        for line in lines(bounds.width, subviews, &cache) {
            var x = bounds.minX
            for i in line.range {
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: line.cardWidth, height: line.height))
                x += line.cardWidth + spacing
            }
            y += line.height + spacing
        }
    }
}
