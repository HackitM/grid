import AppKit
import GridCore
import SwiftUI

/// Milestone 1 web capability: hand web addresses to the user's default browser.
/// Reader mode and embedded browsing are Milestone 3 (see docs/ARCHITECTURE.md §Web).
struct WebPanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    @State private var address = ""
    @State private var error: String?
    @FocusState private var focused: Bool
    @AppStorage("web.history") private var historyData = Data()

    private var history: [String] { (try? JSONDecoder().decode([String].self, from: historyData)) ?? [] }

    var body: some View {
        Panel(index: "04", title: "Web", suffix: "external", focused: focused) {
            Tag("default browser")
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                GridField(placeholder: "example.com  or  https://…", text: $address, prompt: "URL ▸", focus: $focused) { submit() }
                if let error {
                    HStack(spacing: 6) {
                        Text("✕").foregroundStyle(theme.danger)
                        Text(error).foregroundStyle(theme.textDim)
                    }.font(GridFont.small)
                }

                StateBlock(code: "MODE.EXTERNAL", title: "Pages open in your default browser",
                           message: "GRID does not render web pages yet. A text/reader view and an isolated embedded browser are planned for Milestone 3. Only http(s) addresses are accepted here; javascript:, file: and other schemes are refused.")

                if !history.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            SectionLabel("Recent", color: theme.accent)
                            Rectangle().fill(theme.line).frame(height: Metrics.hairline)
                            Button("Clear") { historyData = Data() }.buttonStyle(GridButtonStyle(compact: true))
                        }
                        .padding(.bottom, 4)
                        ForEach(history, id: \.self) { h in
                            HistoryRow(text: h) { open(h) }
                        }
                    }
                }
                Spacer()
            }
            .padding(14)
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func submit() {
        guard let url = WebAddress.normalize(address) else {
            error = address.isEmpty ? nil : "Not an http(s) web address."
            return
        }
        error = nil
        open(url.absoluteString)
        address = ""
    }

    private func open(_ s: String) {
        app.openURL(s)
        var h = history.filter { $0 != s }
        h.insert(s, at: 0)
        historyData = (try? JSONEncoder().encode(Array(h.prefix(15)))) ?? Data()
    }
}

private struct HistoryRow: View {
    @Environment(\.theme) private var theme
    let text: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        HStack {
            Text("↗").foregroundStyle(theme.accent)
            Text(text).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .font(GridFont.body)
        .padding(.horizontal, 8).frame(height: Metrics.rowHeight)
        .gridRowBackground(selected: false, hovered: hover, theme: theme)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
    }
}
