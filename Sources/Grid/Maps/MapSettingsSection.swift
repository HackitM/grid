import AppKit
import GridCore
import SwiftUI

/// Settings › Map.
struct MapSettingsSection: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    @State private var endpoint = UserDefaults.standard.string(forKey: "map.overpass.endpoint") ?? ALPRStore.defaultOverpass
    @State private var endpointError: String?
    @State private var searchEndpoint = UserDefaults.standard.string(forKey: MapSearch.endpointKey) ?? Nominatim.defaultEndpoint
    @State private var searchEndpointError: String?
    @State private var onlineSearch = UserDefaults.standard.object(forKey: MapSearch.onlineKey) as? Bool
    @State private var cacheSize: Int64?
    @FocusState private var focused: Bool

    var body: some View {
        let m = app.maps
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                toggle("Map data (tiles, region list, camera downloads)", m.enabled) { m.enabled = $0 }
                Text("Off means the Map page makes no network requests at all. Hosts: tiles.openfreemap.org, elevation-tiles-prod.s3.amazonaws.com (terrain, while the Terrain layer is on), download.geofabrik.de, deflock.dontgetflocked.com, and your Overpass server (only for regions outside the US and Canada). Online place search and road data for directions are separate (below).")
                    .font(GridFont.small).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true)
                toggle("Remember the last map view", m.rememberView) { m.rememberView = $0 }
                toggle("3D buildings when the map is tilted", m.showBuildings) { m.showBuildings = $0 }
                toggle("Terrain: shaded relief, contour lines, and 3D ground when tilted", m.showTerrain) { m.showTerrain = $0 }
            }
            HStack(spacing: 12) {
                Text("Terrain height").font(GridFont.body).foregroundStyle(theme.textDim).frame(width: 150, alignment: .leading)
                ForEach([1.0, 1.5, 2.0, 3.0], id: \.self) { x in
                    Button(String(format: "%g×", x)) { m.terrainExaggeration = x }
                        .buttonStyle(GridButtonStyle(prominent: m.terrainExaggeration == x, compact: true))
                }
            }
            .disabled(!m.showTerrain)
            Text("Elevation comes from the public AWS Terrain Tiles dataset (about 30 m detail in most places) and is cached on this Mac, up to 150 MB. Contours are in \(Locale.current.measurementSystem == .us ? "feet" : "metres"), following your region settings.")
                .font(GridFont.small).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Text("Overpass server").font(GridFont.body).foregroundStyle(theme.textDim).frame(width: 150, alignment: .leading)
                GridField(placeholder: ALPRStore.defaultOverpass, text: $endpoint, focus: $focused) { saveEndpoint() }
                    .frame(maxWidth: 360)
                Button("Apply") { saveEndpoint() }.buttonStyle(GridButtonStyle(compact: true))
            }
            if let e = endpointError { Text("✕ \(e)").font(GridFont.small).foregroundStyle(theme.danger) }
            Text("Used only for camera regions outside the US and Canada. Requests go one at a time, wait after errors, and stop after 60 a day. Public servers ask apps to keep usage light.")
                .font(GridFont.small).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                toggle("Online place search (only when you press Return or choose Search Online)", onlineSearch ?? false) { on in
                    onlineSearch = on
                    m.search.onlineAllowed = on
                    if !on { m.search.forgetOnline() }
                }
                HStack(spacing: 12) {
                    Text("Search server").font(GridFont.body).foregroundStyle(theme.textDim).frame(width: 150, alignment: .leading)
                    GridField(placeholder: Nominatim.defaultEndpoint, text: $searchEndpoint, focus: $focused) { saveSearchEndpoint() }
                        .frame(maxWidth: 360)
                    Button("Apply") { saveSearchEndpoint() }.buttonStyle(GridButtonStyle(compact: true))
                }
                if let e = searchEndpointError { Text("✕ \(e)").font(GridFont.small).foregroundStyle(theme.danger) }
                Text("Typing in the map's search box only searches names in the map already on this Mac. Online search sends your search and the visible area to \(MapSearch.host) (Nominatim, run by the OpenStreetMap Foundation): at most once a second, never while you type. Answers are kept in memory for up to a day; searches are never saved. \(onlineSearch == nil ? "GRID asks the first time you search online." : "")")
                    .font(GridFont.small).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Road data for directions").font(GridFont.body).foregroundStyle(theme.textDim)
                if m.routing.store.installed.isEmpty {
                    Text("None yet. The first route in an area offers to download its road data.")
                        .font(GridFont.small).foregroundStyle(theme.textMute)
                }
                ForEach(m.routing.store.installed) { g in
                    HStack(spacing: 10) {
                        Text(g.name).font(GridFont.small).foregroundStyle(theme.text).frame(width: 150, alignment: .leading)
                        Text("\(ByteCountFormatter.string(fromByteCount: g.graphBytes, countStyle: .file)) · \(g.edges.formatted()) roads · built \(g.builtAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(GridFont.small).foregroundStyle(theme.textDim)
                        Button("Remove") { m.routing.store.remove(g.id) }.buttonStyle(GridButtonStyle(compact: true))
                    }
                }
                Text("Routes are worked out on this Mac from OpenStreetMap road data downloaded per region from download.geofabrik.de; your start, destination and routes are never sent anywhere.")
                    .font(GridFont.small).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Text("Stored").font(GridFont.body).foregroundStyle(theme.textDim).frame(width: 150, alignment: .leading)
                Text(cacheSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                    .font(GridFont.small).foregroundStyle(theme.text)
                Text("· \(m.alpr.regions.count) camera region\(m.alpr.regions.count == 1 ? "" : "s")").font(GridFont.small).foregroundStyle(theme.textDim)
                Button("Clear Map Data…") {
                    _ = app.present(Confirmation(code: "MAP-CLEAR", title: "Clear all map data?",
                                                 message: "Deletes cached map tiles, the region list and every downloaded camera region from this Mac.",
                                                 confirmLabel: "Clear", destructive: true, onConfirm: { m.clearAllData(); refreshSize() }))
                }
                .buttonStyle(GridButtonStyle(compact: true))
            }
            Text("Stored in ~/Library/Application Support/\(MapStorage.root.deletingLastPathComponent().lastPathComponent)/Maps. Map tiles are capped at 200 MB.")
                .font(GridFont.small).foregroundStyle(theme.textMute)
        }
        .onAppear { refreshSize() }
    }

    private func saveEndpoint() {
        let raw = endpoint.trimmingCharacters(in: .whitespaces)
        guard let u = URL(string: raw), u.scheme == "https", u.host != nil, u.user == nil, u.port == nil, u.query == nil else {
            endpointError = "Use an https address without a port, user name or query (for example \(ALPRStore.defaultOverpass))."
            return
        }
        let old = UserDefaults.standard.string(forKey: "map.overpass.endpoint") ?? ALPRStore.defaultOverpass
        guard raw != old else { endpointError = nil; return }
        _ = app.present(Confirmation(code: "MAP-NET", title: "Use \(u.host!) for camera downloads?",
                                     message: "Regions outside the US and Canada will be downloaded from \(u.host!). That server learns which areas you download.",
                                     confirmLabel: "Use It", destructive: false,
                                     onConfirm: { UserDefaults.standard.set(raw, forKey: "map.overpass.endpoint"); endpointError = nil }))
    }

    private func saveSearchEndpoint() {
        guard let u = Nominatim.endpoint(searchEndpoint) else {
            searchEndpointError = "Use an https address without a port, user name or query (for example \(Nominatim.defaultEndpoint))."
            return
        }
        let raw = u.absoluteString
        guard raw != MapSearch.endpoint.absoluteString else { searchEndpointError = nil; return }
        _ = app.present(Confirmation(code: "SEARCH-NET", title: "Use \(u.host ?? raw) for online search?",
                                     message: "Online place searches will go to \(u.host ?? raw). That server learns what you search for and roughly where you're looking.",
                                     confirmLabel: "Use It", destructive: false,
                                     onConfirm: {
                                         UserDefaults.standard.set(raw, forKey: MapSearch.endpointKey)
                                         searchEndpoint = raw; searchEndpointError = nil
                                         app.maps.search.forgetOnline()
                                     }))
    }

    private func refreshSize() {
        Task.detached(priority: .utility) {
            let s = MapStorage.size(of: MapStorage.root)
            await MainActor.run { cacheSize = s }
        }
    }

    private func toggle(_ label: String, _ value: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { value }, set: set)) { Text(label).font(GridFont.body).foregroundStyle(theme.text) }
            .toggleStyle(GridToggleStyle())
    }
}

/// The "MAP DATA" block in Settings › Updates: freshness of each downloaded camera region.
struct MapDataUpdatesBlock: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        if let m = app.mapsIfLoaded ?? (UserDefaults.standard.bool(forKey: "map.enabled") ? app.maps : nil) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) { SectionLabel("map data", color: theme.accent); TerminatedRule() }
                if m.alpr.regions.isEmpty {
                    Text("No camera regions downloaded.").font(GridFont.small).foregroundStyle(theme.textMute)
                }
                ForEach(m.alpr.regions) { r in
                    HStack(spacing: 10) {
                        Text("ALPR \(r.meta.descriptor.name.uppercased())").font(GridFont.label).tracking(1).foregroundStyle(theme.text)
                            .frame(width: 220, alignment: .leading).lineLimit(1)
                        Text("\(r.meta.cameraCount.formatted()) cameras · \(Self.age(r.meta.fetchedAt))").font(GridFont.small).foregroundStyle(theme.textDim)
                        Spacer()
                        switch r.status {
                        case .outdated:
                            Button("Update") { m.requestDownload(r.meta.descriptor, polygon: r.meta.polygon, isRectangle: r.meta.isRectangle) }
                                .buttonStyle(GridButtonStyle(compact: true)).disabled(m.alpr.busy)
                        case .current: Tag("current", color: theme.ok)
                        case .downloading(let a, let b): Text("\(a)/\(b)").font(GridFont.small).foregroundStyle(theme.accent)
                        case .failed(let e): Tag("error", color: theme.danger).help(e)
                        case .checking: Text("checking…").font(GridFont.small).foregroundStyle(theme.textMute)
                        case .idle: EmptyView()
                        }
                    }
                }
                if !m.alpr.regions.isEmpty {
                    HStack(spacing: 10) {
                        Button("Check Camera Data") { Task { await m.alpr.checkFreshness(manual: true) } }
                            .buttonStyle(GridButtonStyle(compact: true)).disabled(!m.enabled)
                        Text(m.alpr.lastCheck.map { "checked \(Self.age($0))" } ?? "not checked yet · checked at most daily while you use the Map")
                            .font(GridFont.small).foregroundStyle(theme.textMute)
                    }
                }
            }
        }
    }

    static func age(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 3600 { return "just now" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86400)) d ago"
    }
}
