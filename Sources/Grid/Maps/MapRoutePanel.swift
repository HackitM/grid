import AppKit
import GridCore
import SwiftUI

enum RouteFormat {
    static var usesMiles: Bool { Locale.current.measurementSystem == .us }

    static func distance(_ m: Double) -> String {
        if usesMiles {
            let mi = m / 1609.344
            return mi < 0.1 ? String(format: "%.0f ft", m * 3.28084) : (mi < 10 ? String(format: "%.1f mi", mi) : String(format: "%.0f mi", mi))
        }
        return m < 1000 ? String(format: "%.0f m", m) : (m < 10_000 ? String(format: "%.1f km", m / 1000) : String(format: "%.0f km", m / 1000))
    }

    static func duration(_ s: Double) -> String {
        let min = Int((s / 60).rounded())
        return min < 60 ? "\(max(1, min)) min" : "\(min / 60) h \(min % 60) min"
    }

    static func symbol(_ k: RouteStep.Kind) -> String {
        switch k {
        case .depart: "location.north"
        case .arrive: "flag.checkered"
        case .straight: "arrow.up"
        case .slightLeft, .keepLeft: "arrow.up.left"
        case .slightRight, .keepRight: "arrow.up.right"
        case .left: "arrow.turn.up.left"
        case .right: "arrow.turn.up.right"
        case .sharpLeft: "arrow.turn.down.left"
        case .sharpRight: "arrow.turn.down.right"
        case .uTurn: "arrow.uturn.down"
        case .roundabout: "arrow.triangle.turn.up.right.circle"
        case .ramp(let left): left ? "arrow.up.left" : "arrow.up.right"
        case .merge: "arrow.merge"
        }
    }
}

/// ROUTE: the two ends, options, road data, the result and its steps.
struct MapRoutePanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme
    let model: MapModel

    var body: some View {
        let r = model.routing
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                SectionLabel("route", color: theme.accent); TerminatedRule()
                Button { r.open = false; r.clear() } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                    .buttonStyle(.plain).foregroundStyle(theme.textMute).accessibilityLabel("Close directions")
            }
            endRow("A", r.from, isFrom: true)
            endRow("B", r.to, isFrom: false)
            if r.from == nil || r.to == nil {
                Text("Right-click the map for Directions from / to Here, or search a place and use Directions in its card.")
                    .font(GridFont.small).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true)
            }
            toggle("Avoid mapped ALPR cameras", r.avoid) { r.avoid = $0 }
            toggle("Use camera facing (cones)", r.directional) { r.directional = $0 }
            HStack(spacing: 6) {
                Text("BUFFER").font(GridFont.label).tracking(1).foregroundStyle(theme.textMute)
                Text(RouteFormat.distance(r.buffer)).font(GridFont.small).foregroundStyle(theme.text).monospacedDigit()
                Spacer()
                Button("−") { r.buffer = max(25, r.buffer - 25) }.disabled(r.buffer <= 25)
                Button("+") { r.buffer = min(150, r.buffer + 25) }.disabled(r.buffer >= 150)
            }
            .buttonStyle(GridButtonStyle(compact: true))
            .help("How close a road must pass a camera to count as seen")
            DataStatus(model: model)
            switch r.state {
            case .idle, .needsData: EmptyView()
            case .working: Text("Working out the route on this Mac…").font(GridFont.small).foregroundStyle(theme.textDim)
            case .failed(let msg): Text("△ \(msg)").font(GridFont.small).foregroundStyle(theme.warn).fixedSize(horizontal: false, vertical: true)
            case .done: RouteResults(model: model)
            }
        }
        .padding(8)
        .background(theme.bg2.opacity(0.5))
        .overlay(Rectangle().stroke(theme.accent.opacity(0.4), lineWidth: Metrics.hairline))
    }

    private func endRow(_ letter: String, _ end: MapRouting.End?, isFrom: Bool) -> some View {
        let r = model.routing
        return HStack(spacing: 6) {
            Text(letter).font(GridFont.bodyStrong).foregroundStyle(theme.accent).frame(width: 12)
            Text(end?.name ?? (isFrom ? "Start not set" : "Destination not set"))
                .font(GridFont.small).foregroundStyle(end == nil ? theme.textMute : theme.text).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(end.map { String(format: "%@ · %.5f, %.5f", $0.name, $0.coordinate.lat, $0.coordinate.lon) } ?? "")
            GridMenuButton(help: isFrom ? "Set the start" : "Set the destination", size: 9, frame: CGSize(width: 16, height: 16)) {
                GridMenuItem.action("Use My Location") { r.useLocation(from: isFrom) }
                GridMenuItem.action("Use the Map Centre") {
                    let c = TileMath.unproject(model.camera.center)
                    r.setEnd(from: isFrom, .init(name: String(format: "%.4f, %.4f", c.lat, c.lon), coordinate: c))
                }
                GridMenuItem.action("Use the Chosen Place", enabled: model.place != nil) {
                    if let p = model.place { r.setEnd(from: isFrom, .init(name: p.name, coordinate: p.coordinate)) }
                }
                GridMenuItem.divider
                GridMenuItem.action("Swap Start and Destination", enabled: r.from != nil || r.to != nil) { r.swapEnds() }
                GridMenuItem.action("Clear", enabled: end != nil) { if isFrom { r.from = nil } else { r.to = nil } }
            }
        }
    }

    private func toggle(_ label: String, _ on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: set)) { Text(label).font(GridFont.small).foregroundStyle(theme.text) }
            .toggleStyle(GridToggleStyle())
    }
}

/// Road data: what's needed, the download / build in progress, or its error.
private struct DataStatus: View {
    @Environment(\.theme) private var theme
    let model: MapModel

    var body: some View {
        let r = model.routing, store = r.store
        switch store.job {
        case .sizing(let name):
            Text("Checking the size of \(name)'s road data…").font(GridFont.small).foregroundStyle(theme.textDim)
        case .downloading(let name, let done, let total):
            progress("Downloading \(name)", total > 0 ? Double(done) / Double(total) : nil,
                     detail: ByteCountFormatter.string(fromByteCount: done, countStyle: .file) + (total > 0 ? " of " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : ""))
        case .building(let name, let stage, let f):
            progress("Building \(name): \(stage.lowercased())", f, detail: "\(Int(f * 100))%")
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 4) {
                Text("△ \(msg)").font(GridFont.small).foregroundStyle(theme.warn).fixedSize(horizontal: false, vertical: true)
                Button("OK") { store.dismissError() }.buttonStyle(GridButtonStyle(compact: true))
            }
        case .none:
            if case .needsData(let region, let reason) = r.state {
                VStack(alignment: .leading, spacing: 4) {
                    Text(reason).font(GridFont.small).foregroundStyle(theme.textDim).fixedSize(horizontal: false, vertical: true)
                    if let region {
                        Button("Download Road Data for \(region.name)…") { r.requestData(region) }
                            .buttonStyle(GridButtonStyle(prominent: true, compact: true))
                            .disabled(!model.enabled)
                    }
                }
            }
        }
    }

    private func progress(_ title: String, _ f: Double?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(GridFont.small).foregroundStyle(theme.text).lineLimit(2)
                Spacer(minLength: 4)
                Button("Cancel") { model.routing.store.cancel() }.buttonStyle(GridButtonStyle(compact: true))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(theme.line)
                    Rectangle().fill(theme.accent).frame(width: g.size.width * CGFloat(min(1, max(0, f ?? 0.05))))
                }
            }
            .frame(height: 3)
            Text(detail).font(GridFont.small).foregroundStyle(theme.textMute).monospacedDigit()
        }
    }
}

private struct RouteResults: View {
    @Environment(\.theme) private var theme
    let model: MapModel

    var body: some View {
        let r = model.routing
        if let o = r.outcome {
            VStack(alignment: .leading, spacing: 6) {
                if let av = o.avoiding {
                    option("AVOID", av, selected: r.shown == .avoiding) { r.show(.avoiding) }
                    option("FASTEST", o.fastest, selected: r.shown == .fastest) { r.show(.fastest) }
                    let dd = av.path.distance - o.fastest.path.distance, dt = av.path.duration - o.fastest.path.duration
                    Text("Avoiding: \(dd >= 0 ? "+" : "−")\(RouteFormat.distance(abs(dd))) · \(dt >= 0 ? "+" : "−")\(RouteFormat.duration(abs(dt))), \(o.fastest.hits.count - av.hits.count) fewer mapped camera\(o.fastest.hits.count - av.hits.count == 1 ? "" : "s")")
                        .font(GridFont.small).foregroundStyle(theme.textDim).fixedSize(horizontal: false, vertical: true)
                } else {
                    option(o.fastest.hits.isEmpty ? "ROUTE" : "FASTEST", o.fastest, selected: true) {}
                    if r.avoid && !o.fastest.hits.isEmpty {
                        Text("No route avoids more of these cameras.").font(GridFont.small).foregroundStyle(theme.textDim)
                    } else if o.fastest.hits.isEmpty {
                        Text("Passes no mapped cameras.").font(GridFont.small).foregroundStyle(theme.ok)
                    }
                }
                HStack(spacing: 6) {
                    Button("Print…") { MapRouteExport.printRoute(model) }.help("Print the map and the turn list")
                    Button("GPX…") { MapRouteExport.saveGPX(model) }.help("Save for a GPS unit or an offline navigator")
                    Button("Copy") { MapRouteExport.copyText(model) }.help("Copy the directions as text")
                }
                .buttonStyle(GridButtonStyle(compact: true))
                if let leg = r.shownLeg { StepList(model: model, leg: leg) }
                Text("Only cameras mapped in OpenStreetMap and downloaded to GRID count. Coverage is incomplete; GRID can't promise a route is unseen.")
                    .font(GridFont.small).foregroundStyle(theme.textMute).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func option(_ title: String, _ leg: RouteService.Leg, selected: Bool, pick: @escaping () -> Void) -> some View {
        let n = leg.hits.count
        let level = ExposureLevel(count: n)
        return Button(action: pick) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(selected ? "▸" : " ").foregroundStyle(theme.accent)
                    Text(title).font(GridFont.label).tracking(1.1).foregroundStyle(selected ? theme.text : theme.textDim)
                    Spacer(minLength: 4)
                    Text("\(RouteFormat.distance(leg.path.distance)) · \(RouteFormat.duration(leg.path.duration))")
                        .font(GridFont.small).foregroundStyle(theme.text).monospacedDigit()
                }
                HStack(spacing: 6) {
                    Text(" ").frame(width: 8)
                    Text("⌗ \(n) mapped camera\(n == 1 ? "" : "s")").font(GridFont.small).foregroundStyle(n == 0 ? theme.ok : theme.warn)
                    Spacer(minLength: 4)
                    Tag(level.rawValue, color: n == 0 ? theme.ok : (level == .medium ? theme.warn : theme.danger))
                }
            }
            .padding(4)
            .background(selected ? theme.accent.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title.lowercased()) route, \(RouteFormat.distance(leg.path.distance)), \(RouteFormat.duration(leg.path.duration)), \(n) mapped cameras")
    }
}

private struct StepList: View {
    @Environment(\.theme) private var theme
    let model: MapModel
    let leg: RouteService.Leg

    var body: some View {
        let steps = leg.path.steps
        let cams = model.alpr.index.cameras
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) { SectionLabel("steps", color: theme.accent); TerminatedRule() }.padding(.bottom, 3)
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                let next = i + 1 < steps.count ? steps[i + 1].along : .infinity
                let here = leg.hits.filter { $0.along >= s.along && $0.along < next }
                Button { model.flyTo(s.location, zoom: max(model.camera.zoom, 16)) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .top, spacing: 6) {
                            Text(String(format: "%02d", i + 1)).font(GridFont.small).foregroundStyle(theme.textMute).monospacedDigit()
                            Image(systemName: RouteFormat.symbol(s.kind)).font(.system(size: 10)).foregroundStyle(theme.accent).frame(width: 14)
                            Text(s.text).font(GridFont.small).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            if s.distance > 0 { Text(RouteFormat.distance(s.distance)).font(GridFont.small).foregroundStyle(theme.textDim).monospacedDigit() }
                        }
                        ForEach(here, id: \.camera) { h in
                            let c = cams.indices.contains(h.camera) ? cams[h.camera] : nil
                            Text("   ⌗ camera \(RouteFormat.distance(h.distance)) from the road" + (c.map { $0.directions.isEmpty ? ", facing unknown" : ", facing " + $0.directions.map { "\($0)°" }.joined(separator: " ") } ?? ""))
                                .font(GridFont.small).foregroundStyle(theme.warn)
                        }
                    }
                    .padding(.vertical, 3)
                    .background(model.routing.hoveredStep == i ? theme.accent.opacity(0.12) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { model.routing.hoveredStep = i } else if model.routing.hoveredStep == i { model.routing.hoveredStep = nil }
                    model.routeChanged()
                }
            }
        }
    }
}
