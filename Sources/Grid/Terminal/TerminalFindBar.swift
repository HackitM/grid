import AppKit
import SwiftTerm
import SwiftUI

/// Per-pane find state (searches the pane's scrollback + screen via SwiftTerm's search API).
@Observable
@MainActor
final class TerminalFind {
    var visible = false
    var query = ""
    var caseSensitive = false
    var regex = false
    var wholeWord = false
    private(set) var index = 0
    private(set) var total = 0
    private(set) var invalidPattern = false
    /// Bumped to ask the bar's field to take focus.
    var focusToken = 0

    var options: SearchOptions { SearchOptions(caseSensitive: caseSensitive, regex: regex, wholeWord: wholeWord) }

    func open() {
        visible = true
        focusToken += 1
    }

    func close(_ view: TerminalView) {
        visible = false
        view.clearSearch()
        index = 0; total = 0
        view.window?.makeFirstResponder(view)
    }

    /// Re-runs the search after the query or options change, jumping to the first match.
    func update(_ view: TerminalView) {
        invalidPattern = false
        guard !query.isEmpty else { view.clearSearch(); index = 0; total = 0; return }
        if regex, (try? NSRegularExpression(pattern: query)) == nil {
            invalidPattern = true; view.clearSearch(); index = 0; total = 0; return
        }
        _ = view.findNext(query, options: options)
        refreshCount(view)
    }

    func next(_ view: TerminalView) {
        guard !query.isEmpty, !invalidPattern else { return }
        _ = view.findNext(query, options: options)
        refreshCount(view)
    }

    func previous(_ view: TerminalView) {
        guard !query.isEmpty, !invalidPattern else { return }
        _ = view.findPrevious(query, options: options)
        refreshCount(view)
    }

    private func refreshCount(_ view: TerminalView) {
        let s = view.searchMatchSummary(query, options: options, limit: 1000)
        index = s.index; total = s.total
    }
}

/// Themed find bar shown at the top-right of a pane.
struct TerminalFindBar: View {
    @Environment(\.theme) private var theme
    let session: TerminalSession
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var find = session.find
        HStack(spacing: 6) {
            Text("FIND").font(GridFont.label).tracking(1.2).foregroundStyle(theme.accent)
            TextField("", text: $find.query, prompt: Text("search scrollback").foregroundStyle(theme.textMute))
                .textFieldStyle(.plain)
                .font(GridFont.body)
                .foregroundStyle(theme.text)
                .frame(width: 170)
                .focused($focused)
                .onSubmit {
                    if NSEvent.modifierFlags.contains(.shift) { find.previous(session.view) } else { find.next(session.view) }
                    focused = true
                }
                .onExitCommand { find.close(session.view) }
                .onChange(of: find.query) { _, _ in find.update(session.view) }
            optionToggle("Aa", "Match case", $find.caseSensitive)
            optionToggle(".*", "Regular expression", $find.regex)
            optionToggle("W", "Whole word", $find.wholeWord)
            Group {
                if find.invalidPattern {
                    Text("✕ bad pattern").foregroundStyle(theme.danger)
                } else if find.query.isEmpty {
                    Text("—").foregroundStyle(theme.textMute)
                } else if find.total == 0 {
                    Text("no matches").foregroundStyle(theme.warn)
                } else {
                    Text("\(find.index)/\(find.total >= 1000 ? "999+" : String(find.total))").foregroundStyle(theme.textDim)
                }
            }
            .font(GridFont.small)
            .frame(minWidth: 62, alignment: .trailing)
            IconButton(symbol: "chevron.up", label: "Previous match (⇧⌘G / ⇧⏎)", disabled: find.total == 0) { find.previous(session.view) }
            IconButton(symbol: "chevron.down", label: "Next match (⌘G / ⏎)", disabled: find.total == 0) { find.next(session.view) }
            IconButton(symbol: "xmark", label: "Close (Esc)") { find.close(session.view) }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(theme.bg2)
        .clipShape(ClippedRect(cut: 6, topRight: false, bottomLeft: true))
        .overlay(ClippedRect(cut: 6, topRight: false, bottomLeft: true).stroke(theme.lineStrong, lineWidth: Metrics.hairline))
        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
        .onAppear { focused = true }
        .onChange(of: session.find.focusToken) { _, _ in focused = true }
        .onChange(of: find.caseSensitive) { _, _ in find.update(session.view) }
        .onChange(of: find.regex) { _, _ in find.update(session.view) }
        .onChange(of: find.wholeWord) { _, _ in find.update(session.view) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in terminal")
    }

    private func optionToggle(_ text: String, _ help: String, _ value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 22, height: 18)
                .foregroundStyle(value.wrappedValue ? theme.textOnAccent : theme.textDim)
                .background(value.wrappedValue ? theme.accent : theme.bg3)
                .overlay(Rectangle().stroke(theme.line, lineWidth: Metrics.hairline))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(value.wrappedValue ? "on" : "off")
    }
}
