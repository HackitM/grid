import SwiftUI

// MARK: - Geometry

/// Rectangle with a diagonal cut on chosen corners (the Legacy "clipped plate").
struct ClippedRect: Shape {
    var cut: CGFloat = Metrics.cornerCut
    var topRight = true
    var bottomLeft = false

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        if topRight {
            p.addLine(to: CGPoint(x: r.maxX - cut, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + cut))
        } else {
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        if bottomLeft {
            p.addLine(to: CGPoint(x: r.minX + cut, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY - cut))
        } else {
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        }
        p.closeSubpath()
        return p
    }
}

/// Four L-shaped corner marks. Shown on the focused panel so focus is signalled by shape,
/// not only by color.
struct CornerBrackets: Shape {
    var length: CGFloat = 10
    func path(in r: CGRect) -> Path {
        var p = Path()
        let l = min(length, r.width / 4, r.height / 4)
        // top-left
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        // bottom-right
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        // bottom-left
        p.move(to: CGPoint(x: r.minX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.maxY))
        return p
    }
}

/// Horizontal rule with small square terminators, as on the Ares command bars.
struct TerminatedRule: View {
    @Environment(\.theme) private var theme
    var strong = false
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().frame(width: 3, height: 3)
            Rectangle().frame(height: Metrics.hairline)
            Rectangle().frame(width: 3, height: 3)
        }
        .foregroundStyle(strong ? theme.lineStrong : theme.line)
    }
}

// MARK: - Text

struct SectionLabel: View {
    @Environment(\.theme) private var theme
    let text: String
    var color: Color?
    init(_ text: String, color: Color? = nil) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased())
            .font(GridFont.label)
            .tracking(1.4)
            .foregroundStyle(color ?? theme.textMute)
            .lineLimit(1)
    }
}

/// Small bordered shortcut hint, e.g. ⌘T.
struct KeyCap: View {
    @Environment(\.theme) private var theme
    let keys: String
    init(_ keys: String) { self.keys = keys }
    var body: some View {
        Text(keys)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(theme.textDim)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(Rectangle().stroke(theme.line, lineWidth: Metrics.hairline))
    }
}

/// Inverted label block (Legacy "ENCOM CORP" highlight): solid accent with dark text.
struct Tag: View {
    @Environment(\.theme) private var theme
    let text: String
    var color: Color?
    init(_ text: String, color: Color? = nil) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(theme.textOnAccent)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(color ?? theme.accent)
    }
}

// MARK: - Panel

/// The standard panel: hairline plate with an indexed header strip.
///
///   ┌ 01 TERMINAL .SESSION ─────────────── trailing ┐
///   │ content                                        │
struct Panel<Content: View, Trailing: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.effects) private var effects
    let index: String
    let title: String
    let suffix: String
    var focused: Bool
    var clipped: Bool
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(index: String, title: String, suffix: String = "", focused: Bool = false, clipped: Bool = true,
         @ViewBuilder trailing: @escaping () -> Trailing,
         @ViewBuilder content: @escaping () -> Content) {
        self.index = index; self.title = title; self.suffix = suffix; self.focused = focused
        self.clipped = clipped; self.trailing = trailing; self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(index)
                    .font(GridFont.label)
                    .foregroundStyle(focused ? theme.accent : theme.textMute)
                HStack(spacing: 0) {
                    Text(title.uppercased()).foregroundStyle(focused ? theme.text : theme.textDim)
                    if !suffix.isEmpty {
                        Text(" ." + suffix.uppercased()).foregroundStyle(theme.textMute)
                    }
                }
                .font(GridFont.label).tracking(1.4).lineLimit(1)
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 10)
            .frame(height: Metrics.headerHeight)
            .background(theme.bg2.opacity(0.6))
            Rectangle().fill(focused ? theme.lineStrong.opacity(0.6) : theme.line).frame(height: Metrics.hairline)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.bg1)
        .clipShape(ClippedRect(topRight: clipped))
        .overlay(
            ClippedRect(topRight: clipped)
                .stroke(focused ? theme.lineStrong : theme.line, lineWidth: Metrics.hairline)
                .shadow(color: (focused && effects.glow) ? theme.glow.opacity(0.55) : .clear, radius: 5)
        )
        .overlay(
            CornerBrackets()
                .stroke(theme.accent, lineWidth: 2)
                .padding(-2)
                .opacity(focused ? 1 : 0)
        )
        .animation(effects.motion ? .easeOut(duration: 0.14) : nil, value: focused)
    }
}

// MARK: - Controls

struct GridButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    var prominent = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? GridFont.small : GridFont.body)
            .textCase(nil)
            .padding(.horizontal, compact ? 6 : 10)
            .frame(minHeight: compact ? 20 : 24)
            .foregroundStyle(prominent ? theme.textOnAccent : (enabled ? theme.text : theme.textMute))
            .background(prominent ? theme.accent.opacity(configuration.isPressed ? 0.75 : 1)
                                  : (configuration.isPressed ? theme.accentSoft : theme.bg2))
            .overlay(Rectangle().stroke(prominent ? Color.clear : theme.line, lineWidth: Metrics.hairline))
            .contentShape(Rectangle())
    }
}

/// Square icon button for toolbars. Always has a tooltip/accessibility label.
struct IconButton: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let label: String
    var active = false
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .foregroundStyle(disabled ? theme.textMute.opacity(0.5) : (active ? theme.accent : (hover ? theme.text : theme.textDim)))
                .background(active ? theme.accentSoft : (hover && !disabled ? theme.bg2 : .clear))
                .overlay(Rectangle().stroke(active ? theme.lineStrong.opacity(0.5) : .clear, lineWidth: Metrics.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Inset text field with hairline border that lights when focused.
struct GridField: View {
    @Environment(\.theme) private var theme
    let placeholder: String
    @Binding var text: String
    var prompt: String? = nil
    var focus: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            if let prompt {
                Text(prompt).font(GridFont.bodyStrong).foregroundStyle(theme.accent)
            }
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(theme.textMute))
                .textFieldStyle(.plain)
                .font(GridFont.body)
                .foregroundStyle(theme.text)
                .focused(focus)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(theme.bg3)
        .overlay(Rectangle().stroke(focus.wrappedValue ? theme.lineStrong : theme.line, lineWidth: Metrics.hairline))
    }
}

// MARK: - States

/// Shared empty / error / permission state block. Uses a glyph + words, never color alone.
struct StateBlock<Actions: View>: View {
    @Environment(\.theme) private var theme
    enum Tone { case neutral, warning, error }
    let tone: Tone
    let code: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    init(tone: Tone = .neutral, code: String, title: String, message: String,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.tone = tone; self.code = code; self.title = title; self.message = message; self.actions = actions
    }

    var color: Color {
        switch tone { case .neutral: theme.accent; case .warning: theme.warn; case .error: theme.danger }
    }
    var glyph: String {
        switch tone { case .neutral: "◇"; case .warning: "△"; case .error: "✕" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(glyph).font(GridFont.bodyStrong).foregroundStyle(color)
                SectionLabel(code, color: color)
            }
            Text(title).font(GridFont.title).foregroundStyle(theme.text)
            Text(message).font(GridFont.body).foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { actions() }
                .buttonStyle(GridButtonStyle())
        }
        .padding(16)
        .frame(maxWidth: 460, alignment: .leading)
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 2) }
        .background(theme.bg2.opacity(0.5))
    }
}

/// Optional faint grid backdrop (off by default). Static: no animation.
struct GridBackdrop: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 32
            var p = Path()
            var x: CGFloat = 0
            while x <= size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y: CGFloat = 0
            while y <= size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            ctx.stroke(p, with: .color(theme.accent.opacity(0.035)), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Row highlight: accent fill + left bar for the selected row (shape + color).
    func gridRowBackground(selected: Bool, hovered: Bool, theme: Theme) -> some View {
        self.background(
            ZStack(alignment: .leading) {
                if selected { theme.accentSoft } else if hovered { theme.bg2 }
                if selected { Rectangle().fill(theme.accent).frame(width: 2) }
            }
        )
    }
}

extension StateBlock where Actions == EmptyView {
    init(tone: Tone = .neutral, code: String, title: String, message: String) {
        self.init(tone: tone, code: code, title: title, message: message, actions: { EmptyView() })
    }
}

extension Panel where Trailing == EmptyView {
    init(index: String, title: String, suffix: String = "", focused: Bool = false, clipped: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(index: index, title: title, suffix: suffix, focused: focused, clipped: clipped,
                  trailing: { EmptyView() }, content: content)
    }
}
