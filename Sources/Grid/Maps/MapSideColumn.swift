import AppKit
import GridCore
import SwiftUI

/// The Map page's right column: LAYERS, REGIONS (downloaded camera regions + picker), INSPECT,
/// LEGEND and LIST (an accessible table of the cameras in view).
struct MapSideColumn: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let model: MapModel
    @Binding var showPicker: Bool

    var body: some View {
        Panel(index: "05.1", title: "Layers", suffix: "geo", clipped: false) {
            EmptyView()
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("layers") {
                        layerToggle("ALPR cameras", model.showCameras, count: model.alpr.index.cameras.count) { model.showCameras = $0 }
                        layerToggle("Region outlines", model.showRegions, count: model.alpr.regions.count) { model.showRegions = $0 }
                        layerToggle("3D buildings (when tilted)", model.showBuildings) { model.showBuildings = $0 }
                        layerToggle("Grid floor", model.showGrid) { model.showGrid = $0 }
                        layerToggle("Terrain (relief, contours, 3D)", model.showTerrain) { model.showTerrain = $0 }
                    }
                    if let cam = model.selectedCamera { CameraInspector(model: model, camera: cam) }
                    RegionsSection(model: model, showPicker: $showPicker)
                    LegendSection()
                    CameraList(model: model)
                    Text("ALPR cameras mapped by OpenStreetMap volunteers via DeFlock. Coverage is incomplete and may be out of date.")
                        .font(GridFont.small).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) { SectionLabel(title, color: theme.accent); TerminatedRule() }
            c()
        }
    }

    private func layerToggle(_ label: String, _ on: Bool, count: Int? = nil, _ set: @escaping (Bool) -> Void) -> some View {
        HStack {
            Toggle(isOn: Binding(get: { on }, set: set)) { Text(label).font(GridFont.small).foregroundStyle(theme.text) }
                .toggleStyle(GridToggleStyle())
            Spacer(minLength: 4)
            if let count { Text(count.formatted()).font(GridFont.small).foregroundStyle(theme.textDim).monospacedDigit() }
        }
    }
}

private struct CameraInspector: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let model: MapModel
    let camera: ALPRCamera

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) { SectionLabel("inspect", color: theme.accent); TerminatedRule() }
            HStack(spacing: 6) {
                Text("⌗").foregroundStyle(theme.accent)
                Text("ALPR").font(GridFont.label).tracking(1.2).foregroundStyle(theme.textDim)
                Spacer()
                Button { model.select(nil) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                    .buttonStyle(.plain).foregroundStyle(theme.textMute).accessibilityLabel("Close inspector")
            }
            Text(camera.vendor.label.uppercased()).font(GridFont.bodyStrong).foregroundStyle(theme.text)
            row("operator", camera.operatorName)
            row("facing", camera.directions.isEmpty ? "unknown" : camera.directions.map { "\($0)°" }.joined(separator: " "))
            row("mount", camera.mount)
            row("zone", camera.zone)
            row("edited", camera.lastEdited.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none) })
            row("osm", camera.id.description)
            HStack(spacing: 6) {
                Button("View on OSM ↗") { app.openURL(camera.id.webURL.absoluteString) }
                Button("Copy Coordinates") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(format: "%.6f, %.6f", camera.coordinate.lat, camera.coordinate.lon), forType: .string)
                    app.flash(.info, "Copied coordinates")
                }
            }
            .buttonStyle(GridButtonStyle(compact: true))
        }
        .padding(8)
        .background(theme.bg2.opacity(0.5))
        .overlay(Rectangle().stroke(theme.accent.opacity(0.4), lineWidth: Metrics.hairline))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label.uppercased()).font(GridFont.label).tracking(1).foregroundStyle(theme.textMute).frame(width: 64, alignment: .leading)
                Text(value).font(GridFont.small).foregroundStyle(theme.text).lineLimit(2).textSelection(.enabled)
            }
        }
    }
}

private struct RegionsSection: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let model: MapModel
    @Binding var showPicker: Bool

    var body: some View {
        let alpr = model.alpr
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) { SectionLabel("regions", color: theme.accent); TerminatedRule() }
            if alpr.regions.isEmpty {
                Text("No camera regions yet. Download a state, province or country region, or draw an area.")
                    .font(GridFont.small).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(alpr.regions) { r in RegionRow(model: model, region: r) }
            HStack(spacing: 6) {
                Button(showPicker ? "Close List" : "Add Region…") { showPicker.toggle(); if showPicker { Task { await alpr.loadCatalog() } } }
                Button("Draw Area") { model.drawingRegion = true }
            }
            .buttonStyle(GridButtonStyle(compact: true))
            .disabled(alpr.busy)
            if showPicker { RegionPicker(model: model, done: { showPicker = false }) }
        }
    }
}

private struct RegionRow: View {
    @Environment(\.theme) private var theme
    let model: MapModel
    let region: ALPRStore.Region

    var body: some View {
        let m = region.meta
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button { fly() } label: {
                    Text(m.descriptor.name.uppercased()).font(GridFont.label).tracking(1).foregroundStyle(theme.text).lineLimit(1)
                }
                .buttonStyle(.plain).help("Show on the map")
                Spacer(minLength: 2)
                status
            }
            HStack(spacing: 6) {
                Text("\(m.cameraCount.formatted()) cameras · \(age(m.fetchedAt))").font(GridFont.small).foregroundStyle(theme.textDim)
                Spacer(minLength: 2)
                GridMenuButton(help: "Region actions", size: 9, frame: CGSize(width: 16, height: 16)) {
                    if case .downloading = region.status {
                        GridMenuItem.action("Cancel Download") { model.alpr.cancel() }
                        GridMenuItem.divider
                    }
                    GridMenuItem.action("Show on Map") { fly() }
                    GridMenuItem.action("Update Now", enabled: !model.alpr.busy) {
                        model.requestDownload(m.descriptor, polygon: m.polygon, isRectangle: m.isRectangle)
                    }
                    GridMenuItem.divider
                    GridMenuItem.action("Remove Region", destructive: true) { model.alpr.remove(region.id); model.refresh() }
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var status: some View {
        switch region.status {
        case .downloading(let done, let total):
            Text("\(done)/\(total)").font(GridFont.small).foregroundStyle(theme.accent).monospacedDigit()
        case .checking: Text("…").font(GridFont.small).foregroundStyle(theme.textMute)
        case .current: Tag("current", color: theme.ok)
        case .outdated: Tag("update", color: theme.warn)
        case .failed(let msg): Tag("error", color: theme.danger).help(msg)
        case .idle: EmptyView()
        }
    }

    private func fly() {
        let b = boundsOf(region.meta.polygon)
        let span = max(b.east - b.west, b.north - b.south)
        model.flyTo(LonLat(lon: (b.west + b.east) / 2, lat: (b.south + b.north) / 2), zoom: max(4, min(14, log2(360 / max(span, 0.01)) + 0.5)))
    }

    private func boundsOf(_ p: GeoPolygon) -> BBox { p.bbox }

    private func age(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 3600 { return "just now" }
        if s < 86400 { return "\(Int(s / 3600)) h old" }
        return "\(Int(s / 86400)) d old"
    }
}

/// Region catalogue: United States, Canada, then the rest of the world by continent and country.
private struct RegionPicker: View {
    @Environment(\.theme) private var theme
    let model: MapModel
    let done: () -> Void
    @State private var query = ""
    @State private var path: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        let alpr = model.alpr
        VStack(alignment: .leading, spacing: 6) {
            if let s = alpr.catalogState { Text(s).font(GridFont.small).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true) }
            if let cat = alpr.catalog {
                GridField(placeholder: "search regions", text: $query, prompt: "⌕", focus: $focused)
                if !path.isEmpty {
                    Button("‹ Back") { path.removeLast() }.buttonStyle(.plain).font(GridFont.small).foregroundStyle(theme.accent)
                }
                let items = entries(cat)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items, id: \.id) { r in
                            HStack(spacing: 4) {
                                Button { download(r, cat) } label: {
                                    Text(r.name).font(GridFont.small).foregroundStyle(cat.polygon(r.id) == nil ? theme.textMute : theme.text)
                                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(cat.polygon(r.id) == nil)
                                .help(cat.polygon(r.id) == nil ? "No boundary available" : "Download cameras for \(r.name)")
                                if !children(cat, r.id).isEmpty && query.isEmpty {
                                    Button { path.append(r.id) } label: { Text("▸").font(GridFont.small).foregroundStyle(theme.accent).frame(width: 18) }
                                        .buttonStyle(.plain).help("Show regions inside \(r.name)")
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(6)
        .background(theme.bg3)
        .overlay(Rectangle().stroke(theme.line, lineWidth: Metrics.hairline))
    }

    private func entries(_ cat: RegionCatalog) -> [RegionDescriptor] {
        if !query.isEmpty {
            let q = query.lowercased()
            return cat.regions.filter { $0.name.lowercased().contains(q) }.sorted { $0.name < $1.name }.prefix(80).map { $0 }
        }
        if let id = path.last { return children(cat, id) }
        // Top level: the US states and Canadian provinces first, then continents.
        var top: [RegionDescriptor] = []
        if let us = cat.regions.first(where: { $0.id == "us" }) { top.append(us) }
        if let ca = cat.regions.first(where: { $0.id == "canada" }) { top.append(ca) }
        top += cat.children(of: nil).sorted { $0.name < $1.name }
        return top
    }

    /// Geofabrik lists US states under "north-america" (ids "us/…"), not under "us".
    private func children(_ cat: RegionCatalog, _ id: String) -> [RegionDescriptor] {
        var out = cat.children(of: id)
        if id == "us" { out += cat.regions.filter { $0.id.hasPrefix("us/") && $0.parent == "north-america" } }
        if id == "north-america" { out.removeAll { $0.id.hasPrefix("us/") } }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }.sorted { $0.name < $1.name }
    }

    private func download(_ r: RegionDescriptor, _ cat: RegionCatalog) {
        guard let poly = cat.polygon(r.id) else { return }
        done()
        model.requestDownload(r, polygon: poly, isRectangle: false)
    }
}

private struct LegendSection: View {
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) { SectionLabel("legend", color: theme.accent); TerminatedRule() }
            item("━", "motorway / trunk")
            item("─", "street")
            item("⌗", "ALPR camera + field of view")
            item("▣", "camera cluster (zoom out)")
            item("◉", "you (after Locate)")
            item("┅", "downloaded region")
        }
    }
    private func item(_ glyph: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(glyph).font(GridFont.bodyStrong).foregroundStyle(theme.accent).frame(width: 16)
            Text(text).font(GridFont.small).foregroundStyle(theme.textDim)
        }
    }
}

/// LAYERS ▸ LIST: the cameras in view as an accessible, keyboard-navigable list.
private struct CameraList: View {
    @Environment(\.theme) private var theme
    let model: MapModel
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Text(open ? "▾" : "▸").foregroundStyle(theme.accent)
                    SectionLabel("list", color: theme.accent)
                    TerminatedRule()
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(open ? "Hide camera list" : "Show camera list")
            if open {
                let rows = model.camerasInView(limit: 60)
                if rows.isEmpty { Text("No cameras in view.").font(GridFont.small).foregroundStyle(theme.textMute) }
                ForEach(rows, id: \.0) { i, cam, dist in
                    Button {
                        model.select(i)
                        model.flyTo(cam.coordinate)
                    } label: {
                        HStack(spacing: 6) {
                            Text(cam.vendor == .flock ? "FLOCK" : cam.vendor.label.uppercased()).font(GridFont.label).foregroundStyle(theme.text).lineLimit(1)
                            Spacer(minLength: 2)
                            Text(dist < 1000 ? "\(Int(dist)) m" : String(format: "%.1f km", dist / 1000)).font(GridFont.small).foregroundStyle(theme.textDim)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(cam.vendor.label) camera, \(Int(dist)) metres from the map centre")
                }
            }
        }
    }
}
