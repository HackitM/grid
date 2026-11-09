import AppKit
import GridCore
import SwiftUI

/// Page 05: the map. A consent block until map data is enabled; then the GridMap view with its
/// readouts and attribution, and a right column with LAYERS, REGIONS, INSPECT and LEGEND.
struct MapPanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    @State private var columnVisible = true
    @State private var showPicker = false

    var body: some View {
        let m = app.maps
        GeometryReader { geo in
            let compact = geo.size.width < 1000
            HStack(spacing: Metrics.gutter) {
                Panel(index: "05", title: "Map", suffix: "geo") {
                    HStack(spacing: 2) {
                        IconButton(symbol: "location", label: "Locate (shows where you are; asks macOS once)", disabled: !m.enabled) { m.locate() }
                        IconButton(symbol: m.camera.pitch > 1 ? "view.2d" : "view.3d", label: m.camera.pitch > 1 ? "Flat view" : "Tilted 3D view", disabled: !m.enabled) {
                            m.camera.pitch = m.camera.pitch > 1 ? 0 : 40; m.refresh()
                        }
                        IconButton(symbol: "location.north.line", label: "Reset north", disabled: !m.enabled) { m.handle(.key(.resetNorth)) }
                        IconButton(symbol: "rectangle.dashed", label: "Draw an area to download cameras (⇧-drag on the map)", active: m.drawingRegion, disabled: !m.enabled) {
                            m.drawingRegion.toggle()
                        }
                        IconButton(symbol: "sidebar.right", label: "Layers, regions and inspector (⌘I)", active: columnVisible) { columnVisible.toggle() }
                    }
                } overflow: {
                    GridMenuItem.action("Download Cameras for a Region…", enabled: m.enabled) { columnVisible = true; showPicker = true }
                    GridMenuItem.action("Check Camera Data for Updates", enabled: m.enabled && !m.alpr.regions.isEmpty) { Task { await m.alpr.checkFreshness(manual: true) } }
                    GridMenuItem.divider
                    GridMenuItem.action("Map Settings…") { app.settingsSection = "map"; app.show(.settings) }
                    GridMenuItem.action("Clear Map Data…", destructive: true) { confirmClear(m) }
                } content: {
                    ZStack {
                        if m.enabled {
                            MapCanvas(model: m)
                        } else {
                            ConsentBlock(model: m)
                        }
                    }
                }
                if columnVisible && m.enabled && !compact {
                    MapSideColumn(model: m, showPicker: $showPicker)
                        .frame(width: 236)
                }
            }
            .popover(isPresented: Binding(get: { compact && columnVisible && m.enabled && showPicker }, set: { showPicker = $0 })) {
                MapSideColumn(model: m, showPicker: $showPicker).frame(width: 260, height: 520).padding(8)
            }
        }
        .onAppear { m.app = app; m.appeared() }
        .onDisappear { m.disappeared() }
        .onKeyPress(characters: CharacterSet(charactersIn: "i"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            columnVisible.toggle(); return .handled
        }
    }

    private func confirmClear(_ m: MapModel) {
        _ = app.present(Confirmation(code: "MAP-CLEAR", title: "Clear all map data?",
                                     message: "Deletes cached map tiles, the region list and every downloaded camera region from this Mac. You can download them again later.",
                                     confirmLabel: "Clear", destructive: true, onConfirm: { m.clearAllData() }))
    }
}

/// The map and its overlays (readouts, attribution, notices, location explanation).
private struct MapCanvas: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let model: MapModel

    var body: some View {
        let fx = app.settings.effects
        let frame = model.frame(palette: MapPalette.make(theme), glow: fx.glow)
        ZStack(alignment: .bottomLeading) {
            MapMetalView(frame: frame, onGesture: { model.handle($0) }, onViewport: { model.setViewport($0) },
                         interactive: app.confirmation == nil)
            VStack(alignment: .leading, spacing: 4) {
                Spacer()
                if let n = model.notice ?? model.alpr.lastError ?? model.tiles.sourceError {
                    Text("△ \(n)").font(GridFont.small).foregroundStyle(theme.warn)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(theme.bg0.opacity(0.85))
                }
                MapReadout(model: model)
            }
            .padding(8)
            .allowsHitTesting(false)
            VStack { Spacer(); HStack { Spacer(); MapAttribution() } }
                .padding(6)
            if model.drawingRegion {
                VStack {
                    Text("⇧-DRAG TO MARK AN AREA · ESC TO CANCEL").font(GridFont.label).tracking(1.2).foregroundStyle(theme.accent)
                        .padding(.horizontal, 10).padding(.vertical, 4).background(theme.bg0.opacity(0.85))
                        .overlay(Rectangle().stroke(theme.accent.opacity(0.5), lineWidth: Metrics.hairline))
                    Spacer()
                }
                .padding(.top, 10).frame(maxWidth: .infinity)
                .allowsHitTesting(false)
            }
            LocationOverlay(location: model.location)
        }
        .onExitCommand { if model.drawingRegion { model.drawingRegion = false } else { model.select(nil) } }
    }
}

private struct MapReadout: View {
    @Environment(\.theme) private var theme
    let model: MapModel

    var body: some View {
        let c = TileMath.unproject(model.camera.center)
        let inView = model.showCameras && !model.alpr.regions.isEmpty ? model.camerasInViewCount() : nil
        HStack(spacing: 10) {
            Text(String(format: "%.4f %@ · %.4f %@", abs(c.lat), c.lat >= 0 ? "N" : "S", abs(c.lon), c.lon >= 0 ? "E" : "W"))
            Text(String(format: "Z%.1f", model.camera.zoom))
            if model.camera.bearing != 0 || model.camera.pitch != 0 {
                Text(String(format: "⊾%.0f° ↻%.0f°", model.camera.pitch, model.camera.bearing))
            }
            Text("TILES \(model.tiles.loadedCount)/\(model.tiles.wantedCount)")
            if let n = inView { Text("ALPR \(n) IN VIEW") }
            if case .fix(_, let acc, _) = model.location.state { Text(String(format: "◉ ±%.0f M", acc)) }
        }
        .font(.system(size: 9.5, weight: .medium, design: .monospaced)).tracking(0.6)
        .foregroundStyle(theme.textDim)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(theme.bg0.opacity(0.85))
        .overlay(Rectangle().stroke(theme.line, lineWidth: Metrics.hairline))
        .accessibilityElement(children: .combine)
    }
}

/// Required attribution, always visible without interacting (ODbL / OpenMapTiles / OpenFreeMap).
struct MapAttribution: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            link("© OpenStreetMap contributors", "https://www.openstreetmap.org/copyright")
            Text("·")
            link("© OpenMapTiles", "https://www.openmaptiles.org/")
            Text("·")
            link("OpenFreeMap", "https://openfreemap.org/")
            Text("·")
            link("ALPR: DeFlock/OSM", "https://deflock.org/")
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(theme.textMute)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(theme.bg0.opacity(0.8))
    }

    private func link(_ label: String, _ url: String) -> some View {
        Button(label) { app.openURL(url) }.buttonStyle(.plain).help(url)
    }
}

/// GRID's explanation before macOS's location prompt, and location errors.
private struct LocationOverlay: View {
    @Environment(\.theme) private var theme
    let location: LocationProvider

    var body: some View {
        switch location.state {
        case .explaining:
            card(StateBlock(code: "LOC-00", title: "Show where you are?",
                            message: "GRID will ask macOS for your location to centre the map. It stays on this Mac: GRID keeps it in memory only and never stores or sends it. The map tiles around you are then downloaded from OpenFreeMap.") {
                Button("Continue") { location.confirmAndAsk() }
                Button("Not now") { location.cancel() }
            })
        case .denied, .restricted:
            card(StateBlock(tone: .warning, code: "LOC-DENIED", title: "Location is off for GRID",
                            message: "Allow it in System Settings › Privacy & Security › Location Services, then click Locate again.") {
                Button("Open Privacy Settings") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") { NSWorkspace.shared.open(u) }
                    location.cancel()
                }
                Button("Close") { location.clear(); location.cancel() }
            })
        case .servicesOff:
            card(StateBlock(tone: .warning, code: "LOC-OFF", title: "Location Services are off",
                            message: "Turn on Location Services in System Settings › Privacy & Security to use Locate.") {
                Button("Close") { location.cancel() }
            })
        default:
            EmptyView()
        }
    }

    private func card<V: View>(_ v: V) -> some View {
        VStack { Spacer(); v.frame(maxWidth: 420).padding(14).background(theme.bg1)
            .overlay(Rectangle().stroke(theme.lineStrong, lineWidth: Metrics.hairline)); Spacer() }
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.35))
    }
}

/// MAP-NET: nothing is fetched until the user enables map data.
private struct ConsentBlock: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var app
    let model: MapModel

    var body: some View {
        ZStack {
            // The grid floor is drawn locally, so the page isn't blank.
            ConsentGrid()
            VStack {
                Spacer()
                StateBlock(code: "MAP-NET", title: "Enable map data?",
                           message: "The map downloads data only after you enable it:\n· Map tiles for the area you view, from tiles.openfreemap.org (it learns roughly where you're looking).\n· The region list, from download.geofabrik.de, when you open Regions.\n· ALPR camera locations for regions you choose, from deflock.dontgetflocked.com in the US and Canada, or your Overpass server elsewhere (they learn which region). Each download asks first.\nYour location is only read when you click Locate, and is never stored or sent by GRID.") {
                    Button("Enable Map Data") { model.enabled = true; model.appeared() }
                    Button("Settings…") { app.settingsSection = "map"; app.show(.settings) }
                }
                .frame(maxWidth: 560)
                Spacer()
            }
            .padding(20)
        }
    }
}

private struct ConsentGrid: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 32
            var p = Path()
            var x: CGFloat = 0
            while x < size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y: CGFloat = 0
            while y < size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            ctx.stroke(p, with: .color(theme.line.opacity(0.5)), lineWidth: 0.5)
        }
        .background(theme.bg0)
        .accessibilityHidden(true)
    }
}
