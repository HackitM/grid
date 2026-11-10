import AppKit
import GridCore
import SwiftUI

extension Notification.Name {
    /// ⌘F while the Map page is showing.
    static let gridFocusMapSearch = Notification.Name("GridFocusMapSearch")
}

/// The search box over the map's top-left corner and its results. Typing searches the loaded
/// map only; online search needs ⏎ (when nothing matched), ⌘⏎ or the "Search online" row.
struct MapSearchBar: View {
    @Environment(\.theme) private var theme
    let model: MapModel
    @FocusState private var focused: Bool

    var body: some View {
        let search = model.search
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("⌕").font(GridFont.bodyStrong).foregroundStyle(theme.accent)
                TextField("", text: Binding(get: { search.query }, set: { search.query = $0 }),
                          prompt: Text("Search places").foregroundStyle(theme.textMute))
                    .textFieldStyle(.plain)
                    .font(GridFont.body)
                    .foregroundStyle(theme.text)
                    .focused($focused)
                    .onSubmit { if search.submit() { focused = false } else { search.listOpen = true } }
                    .onKeyPress(.downArrow) { search.moveHighlight(1); return .handled }
                    .onKeyPress(.upArrow) { search.moveHighlight(-1); return .handled }
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        search.submit(forceOnline: true); search.listOpen = true
                        return .handled
                    }
                    .onExitCommand {
                        if search.listOpen { search.listOpen = false } else if search.isEmptyQuery { focused = false } else { search.clear() }
                    }
                    .accessibilityLabel("Search places")
                if !search.isEmptyQuery {
                    Button { search.clear() } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                        .buttonStyle(.plain).foregroundStyle(theme.textMute).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(theme.bg0)
            .overlay(Rectangle().stroke(focused ? theme.lineStrong : theme.line, lineWidth: Metrics.hairline))
            if search.listOpen && !search.isEmptyQuery {
                MapSearchResults(model: model) { focused = false }
            }
        }
        .frame(width: 300)
        .onReceive(NotificationCenter.default.publisher(for: .gridFocusMapSearch)) { _ in focused = true }
        .onChange(of: focused) { _, f in if f, !search.isEmptyQuery { search.listOpen = true } }
    }
}

private struct MapSearchResults: View {
    @Environment(\.theme) private var theme
    let model: MapModel
    let picked: () -> Void

    var body: some View {
        let search = model.search
        let local = search.local, online = search.online
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header("in loaded map", note: local.isEmpty ? "no match" : nil)
                        ForEach(Array(local.enumerated()), id: \.element.id) { i, r in row(r, index: i).id(i) }
                        switch search.onlineState {
                        case .idle:
                            onlineRow
                        case .searching:
                            header("online · \(MapSearch.host)", note: "searching…")
                        case .done:
                            header("online · \(MapSearch.host)", note: online.isEmpty ? "no match" : nil)
                            ForEach(Array(online.enumerated()), id: \.element.id) { i, r in row(r, index: local.count + i).id(local.count + i) }
                        case .failed(let msg):
                            header("online", note: nil)
                            Text("△ \(msg)").font(GridFont.small).foregroundStyle(theme.warn)
                                .padding(.horizontal, 8).padding(.vertical, 4).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxHeight: 330)
                .onChange(of: search.highlight) { _, h in withAnimation(nil) { proxy.scrollTo(h) } }
            }
        }
        .background(theme.bg1.opacity(0.97))
        .overlay(Rectangle().stroke(theme.line, lineWidth: Metrics.hairline))
    }

    private func header(_ title: String, note: String?) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(GridFont.label).tracking(1.1).foregroundStyle(theme.accent)
            Spacer(minLength: 4)
            if let note { Text(note).font(GridFont.small).foregroundStyle(theme.textMute) }
        }
        .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 3)
    }

    /// The only way to send a search: shown until it has been used for this query.
    private var onlineRow: some View {
        let off = model.search.onlineAllowed == false
        return Button { model.search.searchOnline() } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe").font(.system(size: 10)).foregroundStyle(theme.accent).frame(width: 14)
                Text(off ? "Online search is off (Settings › Map)" : "Search online for “\(LocalSearch.clean(model.search.query))”")
                    .font(GridFont.small).foregroundStyle(off ? theme.textMute : theme.text).lineLimit(1)
                Spacer(minLength: 4)
                if !off { Text(model.search.local.isEmpty ? "⏎" : "⌘⏎").font(GridFont.small).foregroundStyle(theme.textMute) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(off)
        .help(off ? "Turn on online search in Settings › Map" : "Sends this search and the visible area to \(MapSearch.host)")
        .padding(.top, 2)
    }

    private func row(_ r: PlaceResult, index: Int) -> some View {
        let lit = model.search.highlight == index
        return Button { model.search.choose(r); picked() } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: Self.symbol(r)).font(.system(size: 10)).foregroundStyle(theme.accent).frame(width: 14).padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.name).font(GridFont.small).foregroundStyle(theme.text).lineLimit(1)
                    Text(Self.subtitle(r)).font(GridFont.small).foregroundStyle(theme.textDim).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let d = r.distance { Text(Self.distance(d)).font(GridFont.small).foregroundStyle(theme.textMute).monospacedDigit() }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(lit ? theme.accent.opacity(0.14) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { model.search.highlight = index } }
        .accessibilityLabel("\(r.name), \(Self.subtitle(r))")
    }

    static func symbol(_ r: PlaceResult) -> String {
        if let c = r.category { return c.symbol }
        switch r.kind {
        case .place: return "building.2.crop.circle"
        case .road: return "road.lanes"
        case .water: return "drop"
        case .poi, .address: return "mappin"
        }
    }

    static func subtitle(_ r: PlaceResult) -> String {
        if let a = r.address, !a.isEmpty {
            // The address minus its first part (the name itself).
            let rest = a.split(separator: ",").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.prefix(3).joined(separator: ", ")
            return rest.isEmpty ? r.detail : "\(r.detail) · \(rest)"
        }
        return r.detail
    }

    static func distance(_ m: Double) -> String {
        let us = Locale.current.measurementSystem == .us
        if us {
            let mi = m / 1609.344
            return mi < 0.1 ? String(format: "%.0f ft", m * 3.28084) : (mi < 10 ? String(format: "%.1f mi", mi) : String(format: "%.0f mi", mi))
        }
        return m < 1000 ? String(format: "%.0f m", m) : (m < 10_000 ? String(format: "%.1f km", m / 1000) : String(format: "%.0f km", m / 1000))
    }
}
