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
/// Optional window-like chrome for a top-level panel: a drag grip on the title bar (to re-dock it)
/// and a close button. Supplied by the container through the environment.
struct PanelChrome {
    var drag: DragPayload?
    var onClose: (() -> Void)?
    var closeHelp = "Close"
}

private struct PanelChromeKey: EnvironmentKey { static let defaultValue = PanelChrome() }
extension EnvironmentValues {
    var panelChrome: PanelChrome {
        get { self[PanelChromeKey.self] }
        set { self[PanelChromeKey.self] = newValue }
    }
}

/// Header layout, widest first: the full title with suffix and all trailing controls; the title
/// without its suffix; then the title alone with the trailing controls folded into an overflow
/// menu (when the panel provides one). The title itself is never dropped.
///
/// Sizing: header controls are 22-24 pt each, so a six-button toolbar plus × needs ≈ 190 pt
/// before the title gets any room; the cascade keeps "01 TERMINAL" readable down to ≈ 150 pt.
struct Panel<Content: View, Trailing: View, Overflow: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.effects) private var effects
    @Environment(\.panelChrome) private var chrome
    @State private var gripHover = false
    let index: String
    let title: String
    let suffix: String
    var focused: Bool
    var clipped: Bool
    /// Whether `overflow` has menu items for the collapsed header.
    let hasOverflow: Bool
    @ViewBuilder var trailing: () -> Trailing
    /// Menu items standing in for `trailing` when the header is too narrow to show the buttons.
    @ViewBuilder var overflow: () -> Overflow
    @ViewBuilder var content: () -> Content

    init(index: String, title: String, suffix: String = "", focused: Bool = false, clipped: Bool = true,
         @ViewBuilder trailing: @escaping () -> Trailing,
         @ViewBuilder overflow: @escaping () -> Overflow,
         @ViewBuilder content: @escaping () -> Content) {
        self.index = index; self.title = title; self.suffix = suffix; self.focused = focused
        self.clipped = clipped; self.trailing = trailing; self.overflow = overflow; self.content = content
        self.hasOverflow = Overflow.self != EmptyView.self
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                header(showSuffix: true, compact: false)
                header(showSuffix: false, compact: false)
                header(showSuffix: false, compact: true)
            }
            .padding(.horizontal, 10)
            .frame(height: Metrics.headerHeight)
            .background(theme.bg2.opacity(0.6))
            Rectangle().fill(focused ? theme.lineStrong.opacity(0.6) : theme.line).frame(height: Metrics.hairline)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.panelChrome, PanelChrome())   // nested panels don't inherit chrome
        }
        .background {
            ZStack {
                theme.bg1
                if effects.gridBackdrop { GridBackdrop() }
            }
        }
        .clipShape(ClippedRect(topRight: clipped))
        .overlay(
            ClippedRect(topRight: clipped)
                .stroke(focused ? theme.lineStrong : theme.line, lineWidth: Metrics.hairline)
                .shadow(color: (focused && effects.glow) ? theme.glow.opacity(0.55) : .clear, radius: 5)
        )
        .overlay(
            // Focus selector: brackets snap in from just outside the frame.
            CornerBrackets()
                .stroke(theme.accent, lineWidth: 2)
                .padding(-2)
                .scaleEffect(focused ? 1 : 1.035)
                .opacity(focused ? 1 : 0)
        )
        .animation(effects.motion ? .easeOut(duration: 0.14) : nil, value: focused)
        // Legacy build-on whenever a panel appears (panel switch, reopen, re-dock).
        .buildOn(topRight: clipped)
    }

    /// One header variant. In the compact one the trailing controls give way to the overflow
    /// menu (or disappear when the panel has none) so the title keeps its room; it is the last
    /// resort, so its title may still truncate on an extremely narrow panel.
    private func header(showSuffix: Bool, compact: Bool) -> some View {
        HStack(spacing: 8) {
            // Title area: the drag handle when the panel is dockable.
            HStack(spacing: 8) {
                if chrome.drag != nil {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(gripHover ? theme.accent : theme.textMute)
                }
                Text(index)
                    .font(GridFont.label)
                    .foregroundStyle(focused ? theme.accent : theme.textMute)
                HStack(spacing: 0) {
                    Text(title.uppercased()).foregroundStyle(focused ? theme.text : theme.textDim)
                    if showSuffix && !suffix.isEmpty {
                        Text(" ." + suffix.uppercased()).foregroundStyle(theme.textMute)
                    }
                }
                .font(GridFont.label).tracking(1.4).lineLimit(1)
                .layoutPriority(compact ? 1 : 0)
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .modifier(PanelDragSource(payload: chrome.drag, title: title, hover: $gripHover))
            if compact {
                if hasOverflow {
                    Menu { overflow() } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(theme.textDim).frame(width: 22, height: 20)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("More actions")
                    .accessibilityLabel("More actions")
                }
            } else {
                trailing()
            }
            if let close = chrome.onClose {
                IconButton(symbol: "xmark", label: chrome.closeHelp, action: close)
            }
        }
    }
}

/// Makes a title bar draggable (re-docking) with an open-hand cursor and a labelled drag preview.
private struct PanelDragSource: ViewModifier {
    @Environment(\.theme) private var theme
    let payload: DragPayload?
    let title: String
    @Binding var hover: Bool

    func body(content: Content) -> some View {
        if let payload {
            content
                .hoverCursor(.openHand) { hover = $0 }
                .dockDragSource(payload, label: title)
                .help("Drag the title bar to move this panel")
        } else {
            content
        }
    }
}

/// Shows `cursor` while hovering. Tracks whether it pushed, so it never pops what it didn't push
/// and restores the cursor if the view disappears mid-hover (e.g. a panel re-docked while hovered).
struct HoverCursor: ViewModifier {
    let cursor: NSCursor
    var onChange: ((Bool) -> Void)? = nil
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                onChange?(inside)
                if inside && !pushed { cursor.push(); pushed = true }
                else if !inside && pushed { NSCursor.pop(); pushed = false }
            }
            .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
    }
}

extension View {
    func hoverCursor(_ cursor: NSCursor, onChange: ((Bool) -> Void)? = nil) -> some View {
        modifier(HoverCursor(cursor: cursor, onChange: onChange))
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
    @Environment(\.effects) private var effects
    @State private var barShown = true
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
            TypeOnText(text: title, font: GridFont.title, color: theme.text, duration: 0.3)
            Text(message).font(GridFont.body).foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { actions() }
                .buttonStyle(GridButtonStyle())
        }
        .padding(16)
        .frame(maxWidth: 460, alignment: .leading)
        .overlay(alignment: .leading) {
            // The status bar draws itself top to bottom.
            Rectangle().fill(color).frame(width: 2)
                .scaleEffect(y: barShown ? 1 : 0, anchor: .top)
        }
        .background(theme.bg2.opacity(0.5))
        .onAppear {
            guard effects.motion else { barShown = true; return }
            barShown = false
            withAnimation(GridMotion.build) { barShown = true }
        }
    }
}

/// Optional grid backdrop (off by default): minor cells with a stronger major line every 4th.
/// Static (no animation); drawn behind panel content, so text contrast is unaffected.
struct GridBackdrop: View {
    @Environment(\.theme) private var theme
    var step: CGFloat = 24
    var body: some View {
        Canvas { ctx, size in
            var minor = Path(), major = Path()
            var i = 0
            var x: CGFloat = 0
            while x <= size.width {
                var p = i % 4 == 0 ? major : minor
                p.move(to: CGPoint(x: x + 0.5, y: 0)); p.addLine(to: CGPoint(x: x + 0.5, y: size.height))
                if i % 4 == 0 { major = p } else { minor = p }
                x += step; i += 1
            }
            i = 0
            var y: CGFloat = 0
            while y <= size.height {
                var p = i % 4 == 0 ? major : minor
                p.move(to: CGPoint(x: 0, y: y + 0.5)); p.addLine(to: CGPoint(x: size.width, y: y + 0.5))
                if i % 4 == 0 { major = p } else { minor = p }
                y += step; i += 1
            }
            ctx.stroke(minor, with: .color(theme.accent.opacity(0.055)), lineWidth: 1)
            ctx.stroke(major, with: .color(theme.accent.opacity(0.11)), lineWidth: 1)
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

extension Panel where Trailing == EmptyView, Overflow == EmptyView {
    init(index: String, title: String, suffix: String = "", focused: Bool = false, clipped: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(index: index, title: title, suffix: suffix, focused: focused, clipped: clipped,
                  trailing: { EmptyView() }, overflow: { EmptyView() }, content: content)
    }
}

extension Panel where Overflow == EmptyView {
    /// A panel whose trailing controls simply hide when the header gets too narrow for them.
    init(index: String, title: String, suffix: String = "", focused: Bool = false, clipped: Bool = true,
         @ViewBuilder trailing: @escaping () -> Trailing,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(index: index, title: title, suffix: suffix, focused: focused, clipped: clipped,
                  trailing: trailing, overflow: { EmptyView() }, content: content)
    }
}
