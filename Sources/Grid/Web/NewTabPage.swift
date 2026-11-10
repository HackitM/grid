import AppKit
import GridCore
import SwiftUI

// The browser's new tab page: a slowly turning dot-matrix globe with a few network "nodes",
// flanked by recent pages and a status readout. Inspired by the boardroom displays in Tron:
// Legacy, drawn from GRID's own theme tokens. No location or network data is used: the globe
// starts facing the longitude of the Mac's time zone, and the nodes are fixed cities.

struct NewTabPage: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 880
            let globeSize = min(geo.size.height - 120, wide ? geo.size.width - 560 : geo.size.width - 48, 560)
            ZStack {
                theme.bg1
                if wide {
                    HStack(alignment: .center, spacing: 28) {
                        RecentColumn().frame(width: 250)
                        center(globeSize: max(globeSize, 200))
                        StatusColumn().frame(width: 230)
                    }
                    .padding(.horizontal, 24)
                } else {
                    ScrollView {
                        VStack(spacing: 18) {
                            center(globeSize: max(globeSize, 220))
                            RecentColumn().frame(maxWidth: 520)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func center(globeSize: CGFloat) -> some View {
        VStack(spacing: 14) {
            GlobeView().frame(width: globeSize, height: globeSize)
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    SectionLabel("grid // web", color: theme.accent)
                    Text("·").foregroundStyle(theme.textMute)
                    Text("\(GlobeView.cities.count) NODES").font(GridFont.label).tracking(1.2).foregroundStyle(theme.textMute)
                }
                Text("Type an address or a search in the bar above  ·  ⌘L")
                    .font(GridFont.small).foregroundStyle(theme.textDim)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Side columns

private struct RecentColumn: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let browser = app.browser
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SectionLabel("recent", color: theme.accent)
                TerminatedRule()
            }
            .padding(.bottom, 6)
            if browser.history.isEmpty {
                Text("Pages you visit appear here. History stays on this Mac.")
                    .font(GridFont.small).foregroundStyle(theme.textMute)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(browser.history.prefix(12).enumerated()), id: \.element.id) { i, h in
                    RecentRow(index: i + 1, item: h) {
                        if let u = URL(string: h.url) { browser.open(u, newTab: browser.active == nil) }
                    }
                }
            }
        }
    }
}

private struct RecentRow: View {
    @Environment(\.theme) private var theme
    let index: Int
    let item: BrowserModel.HistoryItem
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Text(String(format: "%02d", index)).font(GridFont.label).foregroundStyle(hover ? theme.accent : theme.textMute)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title.isEmpty ? item.url : item.title).font(GridFont.small).foregroundStyle(theme.text).lineLimit(1)
                Text(URL(string: item.url)?.host ?? "").font(.system(size: 9, design: .monospaced)).foregroundStyle(theme.textMute).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .gridRowBackground(selected: false, hovered: hover, theme: theme)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct StatusColumn: View {
    @Environment(AppState.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let b = app.browser
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                SectionLabel("status", color: theme.accent)
                TerminatedRule()
            }
            // Ticks once a second; plain text, no animation.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .leading, spacing: 10) {
                    readout("local", ctx.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second()))
                    readout("utc", Self.utc.string(from: ctx.date))
                }
            }
            readout("tabs", "\(b.tabs.count)")
            readout("shield", shield(b.adBlocker))
            readout("themes", "\(b.themes.entries.filter { b.themes.isEnabled($0.id) }.count) of \(b.themes.entries.count) sites")
            readout("search", b.settings.searchEngine.label)
            Text("Pages can't reach your terminal, files or apps.")
                .font(GridFont.small).foregroundStyle(theme.textMute)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func shield(_ a: AdBlocker) -> String {
        guard a.enabled else { return "OFF" }
        if case .ready(let n) = a.status { return "ON · \(n.formatted()) rules" }
        return "ON · loading lists"
    }

    private func readout(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(GridFont.label).tracking(1.2).foregroundStyle(theme.textMute)
            Text(value).font(GridFont.mono(13, .medium)).foregroundStyle(theme.text).monospacedDigit().lineLimit(1)
        }
    }
}

// MARK: - Globe

/// The land/ocean dots, built once off the main thread.
@MainActor
final class GlobeData {
    static let shared = GlobeData()
    private(set) var land: [SIMD3<Float>] = []
    private(set) var ocean: [SIMD3<Float>] = []
    private var loading: Task<Void, Never>?

    var isReady: Bool { !land.isEmpty }

    func load() async {
        if isReady { return }
        if let loading { await loading.value; return }
        let task = Task.detached(priority: .userInitiated) { () -> ([SIMD3<Float>], [SIMD3<Float>]) in
            let land = WorldMask.dots(spacing: 2.2).filter(\.land).map { SIMD3(Float($0.x), Float($0.y), Float($0.z)) }
            let ocean = WorldMask.dots(spacing: 6.5).filter { !$0.land }.map { SIMD3(Float($0.x), Float($0.y), Float($0.z)) }
            return (land, ocean)
        }
        loading = Task { @MainActor in
            let (l, o) = await task.value
            self.land = l; self.ocean = o
        }
        await loading?.value
    }
}

struct GlobeView: View {
    @Environment(\.theme) private var theme
    @Environment(\.effects) private var effects
    @State private var land: [SIMD3<Float>] = GlobeData.shared.land
    @State private var ocean: [SIMD3<Float>] = GlobeData.shared.ocean
    @State private var start = Date()
    private var ready: Bool { !land.isEmpty }

    struct City { let name: String; let lat: Float; let lon: Float; let height: Float; let label: Bool }
    static let cities: [City] = [
        City(name: "VANCOUVER", lat: 49.3, lon: -123.1, height: 0.16, label: true),
        City(name: "NEW YORK", lat: 40.7, lon: -74.0, height: 0.22, label: true),
        City(name: "MEXICO CITY", lat: 19.4, lon: -99.1, height: 0.10, label: false),
        City(name: "SÃO PAULO", lat: -23.5, lon: -46.6, height: 0.15, label: true),
        City(name: "REYKJAVÍK", lat: 64.1, lon: -21.9, height: 0.08, label: false),
        City(name: "LONDON", lat: 51.5, lon: -0.1, height: 0.20, label: true),
        City(name: "LAGOS", lat: 6.5, lon: 3.4, height: 0.11, label: false),
        City(name: "CAIRO", lat: 30.0, lon: 31.2, height: 0.12, label: false),
        City(name: "DUBAI", lat: 25.2, lon: 55.3, height: 0.14, label: true),
        City(name: "MUMBAI", lat: 19.1, lon: 72.9, height: 0.13, label: false),
        City(name: "SINGAPORE", lat: 1.35, lon: 103.8, height: 0.17, label: true),
        City(name: "TOKYO", lat: 35.7, lon: 139.7, height: 0.21, label: true),
        City(name: "SYDNEY", lat: -33.9, lon: 151.2, height: 0.14, label: true),
        City(name: "JOHANNESBURG", lat: -26.2, lon: 28.0, height: 0.09, label: false),
    ]

    /// One turn every 120 seconds; the globe starts facing the time zone's longitude.
    static let period: Double = 120
    static let tilt: Float = 0.33   // radians, shows the northern hemisphere a little more
    static let startLongitude = Double(TimeZone.current.secondsFromGMT()) / 3600 * 15
    #if DEBUG
    /// QA: animate even though the background test window is never key.
    nonisolated(unsafe) static var debugForceActive = false
    #endif

    static func angle(at date: Date, since start: Date) -> Float {
        let turns = date.timeIntervalSince(start) / period
        return Float(-startLongitude * .pi / 180 - turns * 2 * .pi)
    }

    var body: some View {
        Group {
            if GlobeMetalView.isSupported {
                // Drawn by the GPU; animates only while the window is key and visible.
                GlobeMetalView(theme: theme, animate: effects.motion)
            } else {
                // Fallback without Metal: a still frame drawn on the CPU.
                canvas(angle: Self.angle(at: start, since: start))
                    .task {
                        await GlobeData.shared.load()
                        land = GlobeData.shared.land
                        ocean = GlobeData.shared.ocean
                    }
            }
        }
        .accessibilityHidden(true)
    }

    private func canvas(angle: Float) -> some View {
        let land = land, ocean = ocean
        let accent = theme.accent, text = theme.text, line = theme.lineStrong
        return Canvas(rendersAsynchronously: false) { ctx, size in
            let r = Float(min(size.width, size.height)) * 0.40
            let cx = Float(size.width) / 2, cy = Float(size.height) / 2
            let (sa, ca) = (sin(angle), cos(angle))
            let (st, ct) = (sin(Self.tilt), cos(Self.tilt))
            func project(_ p: SIMD3<Float>) -> (Float, Float, Float) {
                let x = p.x * ca + p.z * sa
                let z1 = -p.x * sa + p.z * ca
                let y = p.y * ct - z1 * st
                let z = p.y * st + z1 * ct
                return (cx + r * x, cy - r * y, z)
            }

            // Outer ring with ticks (static) and the sphere's rim.
            let ringR = CGFloat(r * 1.16)
            let c = CGPoint(x: CGFloat(cx), y: CGFloat(cy))
            var ticks = Path()
            for i in 0..<120 {
                let a = Double(i) / 120 * 2 * .pi
                let long = i % 10 == 0
                let r0 = ringR - (long ? 7 : 3)
                ticks.move(to: CGPoint(x: c.x + r0 * cos(a), y: c.y + r0 * sin(a)))
                ticks.addLine(to: CGPoint(x: c.x + ringR * cos(a), y: c.y + ringR * sin(a)))
            }
            ctx.stroke(ticks, with: .color(line.opacity(0.45)), lineWidth: 1)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - CGFloat(r), y: c.y - CGFloat(r), width: CGFloat(2 * r), height: CGFloat(2 * r))),
                       with: .color(line.opacity(0.35)), lineWidth: 1)
            // A slow sweep around the ring.
            var sweep = Path()
            sweep.addArc(center: c, radius: ringR + 4, startAngle: .radians(Double(-angle) * 3), endAngle: .radians(Double(-angle) * 3 + 0.9), clockwise: false)
            ctx.stroke(sweep, with: .color(accent.opacity(0.8)), lineWidth: 1.5)

            // Dots: far side faintly (the globe is see-through), near side by depth.
            var back = Path(), oceanP = Path(), dim = Path(), mid = Path(), bright = Path()
            for p in ocean {
                let (x, y, z) = project(p)
                if z > 0 { oceanP.addRect(CGRect(x: CGFloat(x) - 0.6, y: CGFloat(y) - 0.6, width: 1.2, height: 1.2)) }
            }
            for p in land {
                let (x, y, z) = project(p)
                let rect = CGRect(x: CGFloat(x) - 0.9, y: CGFloat(y) - 0.9, width: 1.8, height: 1.8)
                if z < 0 { if z < -0.25 { back.addRect(rect) } }
                else if z < 0.3 { dim.addRect(rect) }
                else if z < 0.65 { mid.addRect(rect) }
                else { bright.addRect(rect) }
            }
            ctx.fill(back, with: .color(accent.opacity(0.10)))
            ctx.fill(oceanP, with: .color(line.opacity(0.35)))
            ctx.fill(dim, with: .color(accent.opacity(0.40)))
            ctx.fill(mid, with: .color(accent.opacity(0.72)))
            ctx.fill(bright, with: .color(accent))

            // Network nodes: spikes off the surface, a node at the tip, a few labels.
            var spikes = Path(), nodes = Path()
            for city in Self.cities {
                let la = city.lat * .pi / 180, lo = city.lon * .pi / 180
                let p = SIMD3<Float>(cos(la) * sin(lo), sin(la), cos(la) * cos(lo))
                let (x0, y0, z) = project(p)
                guard z > 0.08 else { continue }
                let (x1, y1, _) = project(p * (1 + city.height))
                spikes.move(to: CGPoint(x: CGFloat(x0), y: CGFloat(y0)))
                spikes.addLine(to: CGPoint(x: CGFloat(x1), y: CGFloat(y1)))
                nodes.addEllipse(in: CGRect(x: CGFloat(x1) - 2, y: CGFloat(y1) - 2, width: 4, height: 4))
                if city.label && z > 0.35, let label = ctx.resolveSymbol(id: city.name) {
                    var c = ctx
                    c.opacity = Double(min(1, z * 1.4))
                    c.draw(label, at: CGPoint(x: CGFloat(x1) + 6, y: CGFloat(y1)), anchor: .leading)
                }
            }
            ctx.stroke(spikes, with: .color(text.opacity(0.55)), lineWidth: 0.8)
            ctx.stroke(nodes, with: .color(text.opacity(0.9)), lineWidth: 1)
        } symbols: {
            // City labels are laid out once, not on every frame.
            ForEach(Self.cities.filter(\.label), id: \.name) { city in
                Text(city.name).font(.system(size: 8.5, weight: .medium, design: .monospaced)).foregroundStyle(text).tag(city.name)
            }
        }
        // Rendered by the GPU (Metal) rather than rasterized on the CPU each frame.
        .drawingGroup()
    }
}
