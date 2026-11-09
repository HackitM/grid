import AppKit
import GridCore
import SwiftUI

/// Renders a validated widget view tree with GRID's own components, so third-party widgets match
/// the app's design language (fonts, tones, hairlines, readouts) without any styling of their own.
/// Widgets can't supply colors, images, fonts or layout beyond these components.
struct WidgetNodeView: View {
    @Environment(\.theme) private var theme
    let node: WidgetNode
    /// Called when the user clicks a button or row.
    let perform: (WidgetActionSpec) -> Void
    /// Inside a horizontal stack: texts stay on one line (short ones never shrink to a column).
    var inRow = false

    var body: some View {
        switch node {
        case .stack(let axis, let gap, let children):
            if axis == "h" {
                HStack(alignment: .center, spacing: gap) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, c in WidgetNodeView(node: c, perform: perform, inRow: true) }
                }
            } else {
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, c in WidgetNodeView(node: c, perform: perform) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .text(let s, let style, let tone, let lines):
            Text(style == "label" ? s.uppercased() : s)
                .font(font(style)).tracking(style == "label" ? 1.4 : 0)
                .foregroundStyle(color(tone, fallback: style == "label" ? theme.textMute : theme.text))
                .lineLimit(inRow ? (lines ?? 1) : lines)
                .fixedSize(horizontal: inRow && s.count <= 16, vertical: !inRow && lines == nil)
                .layoutPriority(inRow && s.count <= 16 ? 1 : 0)
                .textSelection(.enabled)
        case .readout(let label, let value, let detail):
            if inRow {
                // Side by side: label above value, sized to content.
                VStack(alignment: .leading, spacing: 1) {
                    SectionLabel(label)
                    Text(value).font(GridFont.mono(15, .medium)).foregroundStyle(theme.text).monospacedDigit()
                        .lineLimit(1).fixedSize()
                    if !detail.isEmpty { Text(detail).font(GridFont.small).foregroundStyle(theme.textDim).lineLimit(1) }
                }
                .padding(.trailing, 8)
            } else {
                Readout(label: label, value: value, detail: detail)
            }
        case .bar(let v, let warn, let tone):
            SegmentBar(value: v, warnAbove: tone == nil ? warn : 2, color: tone.map { color($0, fallback: theme.accent) })
        case .display(let value, let detail, let tone):
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(size: 30, weight: .light, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(color(tone, fallback: theme.text)).lineLimit(1).minimumScaleFactor(0.5)
                if !detail.isEmpty { Text(detail).font(GridFont.small).foregroundStyle(theme.textDim).lineLimit(2) }
            }
        case .spacer:
            Spacer(minLength: 0)
        case .sparkline(let values, let maxValue):
            Sparkline(values: values, maxValue: maxValue, slots: max(values.count, 2))
        case .kv(let rows):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        SectionLabel(r.0).frame(width: 70, alignment: .leading)
                        Text(r.1).font(GridFont.small).foregroundStyle(theme.text).lineLimit(2).truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }
            }
        case .list(let items):
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in ListRow(item: item, perform: perform) }
            }
        case .tag(let s, let tone):
            Tag(s, color: tone == "default" ? nil : color(tone, fallback: theme.accent))
        case .button(let title, let action, let prominent):
            Button(title) { perform(action) }
                .buttonStyle(GridButtonStyle(prominent: prominent, compact: true))
                .help(WidgetNodeView.describe(action))
        case .divider:
            TerminatedRule()
        case .progress(let v):
            if let v { SegmentBar(value: v, warnAbove: 2) } else { IndeterminateLine() }
        case .empty(let title, let message):
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("◇").font(GridFont.small).foregroundStyle(theme.accent)
                    Text(title).font(GridFont.bodyStrong).foregroundStyle(theme.textDim)
                }
                if !message.isEmpty {
                    Text(message).font(GridFont.small).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 6)
            .overlay(alignment: .leading) { Rectangle().fill(theme.accent.opacity(0.6)).frame(width: 2) }
        case .code(let s, let lines):
            Text(s).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.textDim)
                .lineLimit(lines ?? 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6).background(theme.bg1)
                .overlay(Rectangle().stroke(theme.line, lineWidth: Metrics.hairline))
                .textSelection(.enabled)
        case .unsupported:
            EmptyView()
        }
    }

    private func font(_ style: String) -> Font {
        switch style {
        case "small": GridFont.small
        case "label": GridFont.label
        case "title": GridFont.title
        case "mono": .system(size: 11, design: .monospaced)
        default: GridFont.body
        }
    }

    private func color(_ tone: String, fallback: Color) -> Color {
        switch tone {
        case "dim": theme.textDim
        case "mute": theme.textMute
        case "accent": theme.accent
        case "ok": theme.ok
        case "warn": theme.warn
        case "danger": theme.danger
        default: fallback
        }
    }

    /// Tooltip naming exactly what a click will do (no surprises from a third-party script).
    static func describe(_ a: WidgetActionSpec) -> String {
        let v = a.value ?? ""
        switch a.kind {
        case "copy": return "Copies text to the clipboard"
        case "openURL": return "Opens \(v) in your browser"
        case "revealInFiles": return "Shows \(PathResolver.abbreviate(v)) in Files"
        case "openFile": return "Opens \(PathResolver.abbreviate(v))"
        case "insertPath":
            let n = a.paths?.count ?? 1
            return n > 1 ? "Inserts \(n) paths at the terminal prompt (nothing runs)" : "Inserts \(PathResolver.abbreviate(a.paths?.first ?? v)) at the terminal prompt (nothing runs)"
        default: return ""
        }
    }
}

private struct ListRow: View {
    @Environment(\.theme) private var theme
    let item: WidgetListItem
    let perform: (WidgetActionSpec) -> Void
    @State private var hover = false

    var body: some View {
        let row = HStack(spacing: 6) {
            icon
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(GridFont.small).foregroundStyle(tone(item.tone)).lineLimit(1).truncationMode(.middle)
                if let s = item.subtitle, !s.isEmpty {
                    Text(s).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(theme.textMute).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if let t = item.trailing { Text(t).font(GridFont.small).foregroundStyle(theme.textMute).lineLimit(1) }
        }
        .padding(.vertical, 2).padding(.horizontal, 3)
        .contentShape(Rectangle())
        .gridRowBackground(selected: false, hovered: hover && item.action != nil, theme: theme)

        if let a = item.action {
            Button { perform(a) } label: { row }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
                .help(WidgetNodeView.describe(a))
        } else {
            row
        }
    }

    @ViewBuilder private var icon: some View {
        if let i = item.icon, !i.isEmpty {
            if i.hasPrefix("/") {
                Image(nsImage: NSWorkspace.shared.icon(forFile: i)).resizable().frame(width: 14, height: 14)
            } else if NSImage(systemSymbolName: i, accessibilityDescription: nil) != nil {
                Image(systemName: i).font(.system(size: 10)).foregroundStyle(tone(item.tone == "default" ? "accent" : item.tone)).frame(width: 14)
            } else {
                Text(String(i.prefix(2))).font(GridFont.label).foregroundStyle(tone(item.tone == "default" ? "accent" : item.tone)).frame(width: 14)
            }
        }
    }

    private func tone(_ t: String) -> Color {
        switch t {
        case "dim": theme.textDim; case "mute": theme.textMute; case "accent": theme.accent
        case "ok": theme.ok; case "warn": theme.warn; case "danger": theme.danger
        default: theme.text
        }
    }
}

/// Indeterminate progress: a static striped bar. (A sliding segment would animate forever, and
/// every animation frame inside the deck costs a CPU re-render of the panel.)
private struct IndeterminateLine: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: size.height)), with: .color(theme.line))
            var x: CGFloat = 0
            while x < size.width {
                ctx.fill(Path(CGRect(x: x, y: 0, width: 6, height: size.height)), with: .color(theme.accent.opacity(0.7)))
                x += 12
            }
        }
        .frame(height: 2)
        .accessibilityLabel("In progress")
    }
}
