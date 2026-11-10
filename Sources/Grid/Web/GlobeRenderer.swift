import AppKit
import GridCore
import Metal
import MetalKit
import QuartzCore
import SwiftUI

// GPU globe for the new tab page. A single fragment shader draws everything: the dot-matrix land
// (from WorldMask, looked up per pixel), the see-through far side, sparse ocean dots, the rim,
// the tick ring and sweep, and the city spikes. Per frame the CPU only updates a few uniforms and
// moves the city labels (Core Animation text layers), so a turning globe costs about as much as
// a blinking cursor. The shader is compiled at runtime by Metal: no build-time toolchain needed.

/// Uniforms shared with the shader (layout must match `struct U` in the source below).
private struct GlobeUniforms {
    var size: SIMD2<Float> = .zero          // drawable size, pixels
    var radius: Float = 0                   // globe radius, pixels
    var angle: Float = 0
    var tilt: Float = 0
    var sweep: Float = 0
    var spacing: Float = 0
    var oceanSpacing: Float = 0
    var dotPx: Float = 0                    // land dot radius, pixels
    var scale: Float = 1                    // backing scale
    var rows: Int32 = 0
    var oceanRows: Int32 = 0
    var cityCount: Int32 = 0
    var _pad: Int32 = 0
    var accent: SIMD4<Float> = .zero
    var text: SIMD4<Float> = .zero
    var line: SIMD4<Float> = .zero
    var spikes: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                 SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) =
        (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
}

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut globe_vertex(uint vid [[vertex_id]]) {
    float2 p[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    VOut o; o.pos = float4(p[vid], 0, 1); o.uv = p[vid] * float2(0.5, -0.5) + 0.5; return o;
}

struct U {
    float2 size; float radius; float angle; float tilt; float sweep; float spacing; float oceanSpacing;
    float dotPx; float scale; int rows; int oceanRows; int cityCount; int pad;
    float4 accent; float4 text; float4 line; float4 spikes[16];
};

constant float PI = 3.14159265;

// Which grid dot a sphere point falls in, and how far (degrees, along the surface) from its centre.
static float dotDistance(float lat, float lon, float spacing, int rows, constant int* rowN, texture2d<float> mask, thread bool &land) {
    int row = clamp(int(floor((lat + 90.0) / spacing)), 0, rows - 1);
    float latc = -90.0 + spacing * 0.5 + float(row) * spacing;
    int n = rowN[row];
    int k = clamp(int(floor((lon + 180.0) / 360.0 * float(n))), 0, n - 1);
    float lonc = -180.0 + (float(k) + 0.5) * 360.0 / float(n);
    land = mask.read(uint2(k, row)).r > 0.5;
    float dlon = lon - lonc;
    dlon -= 360.0 * round(dlon / 360.0);
    float dlat = lat - latc;
    return sqrt(dlat * dlat + dlon * dlon * cos(lat * PI / 180.0) * cos(lat * PI / 180.0));
}

static float3 toWorld(float3 v, float a, float b) {
    float y1 = v.y * cos(b) + v.z * sin(b);
    float z1 = -v.y * sin(b) + v.z * cos(b);
    float x = v.x * cos(a) - z1 * sin(a);
    float z = v.x * sin(a) + z1 * cos(a);
    return float3(x, y1, z);
}

static float segDist(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
    return length(pa - ba * h);
}

static float4 over(float4 dst, float3 rgb, float a) {   // premultiplied "source over"
    return float4(rgb * a + dst.rgb * (1 - a), a + dst.a * (1 - a));
}

fragment float4 globe_fragment(VOut in [[stage_in]], constant U& u [[buffer(0)]],
                               constant int* rowN [[buffer(1)]], constant int* oceanRowN [[buffer(2)]],
                               texture2d<float> land [[texture(0)]], texture2d<float> ocean [[texture(1)]]) {
    float2 p = in.uv * u.size;
    float2 c = u.size * 0.5;
    float2 d = (p - c) / u.radius; d.y = -d.y;
    float dist = length(d);
    float px = 1.0 / u.radius;               // one pixel, in globe radii
    float4 col = float4(0);

    // Tick ring and sweep (outside the globe).
    float ringR = 1.16;
    float ang = atan2(-d.y, d.x);             // screen angle, clockwise from +x
    float a01 = fract(ang / (2 * PI) + 1.0);
    float t = a01 * 120.0;
    float tickIndex = round(t);
    float along = abs(t - tickIndex) / 120.0 * 2 * PI * dist;   // distance along the ring, radii
    bool longTick = fmod(tickIndex, 10.0) < 0.5;
    float inner = ringR - (longTick ? 7.0 : 3.0) * u.scale * px;
    if (dist > inner && dist < ringR && along < 0.6 * u.scale * px) col = over(col, u.line.rgb, u.line.a * 0.45);
    float s0 = u.sweep, s1 = u.sweep + 0.9;
    float sa = fract((ang - s0) / (2 * PI) + 1.0) * 2 * PI;
    if (sa < (s1 - s0) && abs(dist - (ringR + 4.0 * u.scale * px)) < 0.8 * u.scale * px) col = over(col, u.accent.rgb, 0.8);

    // Rim.
    float rim = 1.0 - smoothstep(0.0, 0.8 * u.scale * px, abs(dist - 1.0));
    col = over(col, u.line.rgb, u.line.a * 0.35 * rim);

    if (dist < 1.0) {
        float zf = sqrt(1.0 - dist * dist);
        float dotR = u.dotPx * px * 180.0 / PI;                         // dot radius in degrees at the centre
        // Far side, seen through the globe.
        if (zf > 0.25) {
            float3 w = toWorld(float3(d.x, d.y, -zf), u.angle, u.tilt);
            bool isLand;
            float dd = dotDistance(asin(w.y) * 180 / PI, atan2(w.x, w.z) * 180 / PI, u.spacing, u.rows, rowN, land, isLand);
            float aa = max(fwidth(dd), 1e-3);
            if (isLand) col = over(col, u.accent.rgb, 0.10 * (1 - smoothstep(dotR - aa, dotR + aa, dd)));
        }
        float3 w = toWorld(float3(d.x, d.y, zf), u.angle, u.tilt);
        float lat = asin(w.y) * 180 / PI, lon = atan2(w.x, w.z) * 180 / PI;
        bool isOcean;
        float od = dotDistance(lat, lon, u.oceanSpacing, u.oceanRows, oceanRowN, ocean, isOcean);
        float oaa = max(fwidth(od), 1e-3);
        if (isOcean) col = over(col, u.line.rgb, u.line.a * 0.35 * (1 - smoothstep(dotR * 0.66 - oaa, dotR * 0.66 + oaa, od)));
        bool isLand;
        float dd = dotDistance(lat, lon, u.spacing, u.rows, rowN, land, isLand);
        float aa = max(fwidth(dd), 1e-3);
        if (isLand) {
            float depth = zf < 0.3 ? 0.40 : (zf < 0.65 ? 0.72 : 1.0);
            col = over(col, u.accent.rgb, depth * (1 - smoothstep(dotR - aa, dotR + aa, dd)));
        }
    }

    // City spikes: xy = base, zw = tip (pixels); visible ones only.
    for (int i = 0; i < u.cityCount; i++) {
        float4 s = u.spikes[i];
        if (s.x < -1e4) continue;
        float l = segDist(p, s.xy, s.zw);
        col = over(col, u.text.rgb, 0.55 * (1 - smoothstep(0.3 * u.scale, 0.9 * u.scale, l)));
        float ring = abs(length(p - s.zw) - 2.0 * u.scale);
        col = over(col, u.text.rgb, 0.9 * (1 - smoothstep(0.4 * u.scale, 1.0 * u.scale, ring)));
    }
    return col;
}
"""

@MainActor
final class GlobeRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var landTex: MTLTexture?, oceanTex: MTLTexture?
    private var rowN: MTLBuffer?, oceanRowN: MTLBuffer?
    private var rows: Int32 = 0, oceanRows: Int32 = 0
    private let spacing: Double = 2.2, oceanSpacing: Double = 6.5
    private let start = Date()
    var colors = (accent: SIMD4<Float>(0, 1, 1, 1), text: SIMD4<Float>(1, 1, 1, 1), line: SIMD4<Float>(0, 1, 1, 1))
    weak var labelHost: GlobeLabelLayer?

    private static let compiled: (MTLDevice, MTLRenderPipelineState)? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: shaderSource, options: nil) } catch {
            #if DEBUG
            try? "\(error)".write(toFile: "/tmp/grid-qa/globe-shader-error.txt", atomically: true, encoding: .utf8)
            #endif
            return nil
        }
        guard let v = lib.makeFunction(name: "globe_vertex"), let f = lib.makeFunction(name: "globe_fragment") else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = v
        d.fragmentFunction = f
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        return (device, p)
    }()

    init?(_ unused: Void = ()) {
        guard let (device, pipeline) = Self.compiled, let queue = device.makeCommandQueue() else { return nil }
        self.device = device; self.pipeline = pipeline; self.queue = queue
        super.init()
        let (land, landRows, landN) = Self.mask(spacing: spacing, land: true)
        let (ocean, oRows, oN) = Self.mask(spacing: oceanSpacing, land: false)
        landTex = texture(land, width: landN.max() ?? 1, height: landRows)
        oceanTex = texture(ocean, width: oN.max() ?? 1, height: oRows)
        rowN = device.makeBuffer(bytes: landN.map(Int32.init), length: landN.count * 4)
        oceanRowN = device.makeBuffer(bytes: oN.map(Int32.init), length: oN.count * 4)
        rows = Int32(landRows); oceanRows = Int32(oRows)
    }

    /// Flags per grid dot laid out as rows (cached per spacing; built once per process).
    private static var maskCache: [Double: ([UInt8], Int, [Int])] = [:]
    private static func mask(spacing: Double, land: Bool) -> ([UInt8], Int, [Int]) {
        let key = land ? spacing : -spacing
        if let c = maskCache[key] { return c }
        var perRow: [[Bool]] = []
        var lat = -90 + spacing / 2
        let dots = WorldMask.dots(spacing: spacing)
        var i = 0
        while lat < 90 {
            let n = max(1, Int((360 * cos(lat * .pi / 180) / spacing).rounded()))
            perRow.append(dots[i..<i + n].map { $0.land == land })
            i += n
            lat += spacing
        }
        let width = perRow.map(\.count).max() ?? 1
        var bytes = [UInt8](repeating: 0, count: width * perRow.count)
        for (r, row) in perRow.enumerated() { for (k, on) in row.enumerated() where on { bytes[r * width + k] = 255 } }
        let out = (bytes, perRow.count, perRow.map(\.count))
        maskCache[key] = out
        return out
    }

    private func texture(_ bytes: [UInt8], width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        bytes.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width) }
        return t
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    #if DEBUG
    nonisolated(unsafe) static var debugFrames = 0
    nonisolated(unsafe) static var debugNoLabels = false
    #endif

    func draw(in view: MTKView) {
        #if DEBUG
        Self.debugFrames += 1
        #endif
        let size = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))
        // Nothing to draw into yet (and the shader divides by the radius).
        guard size.x >= 1, size.y >= 1 else { return }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let scale = Float(view.window?.backingScaleFactor ?? 2)
        let radius = min(size.x, size.y) * 0.40
        let angle = GlobeView.angle(at: Date(), since: start)
        var u = GlobeUniforms()
        u.size = size; u.radius = radius; u.angle = angle; u.tilt = GlobeView.tilt
        u.sweep = -angle * 3; u.spacing = Float(spacing); u.oceanSpacing = Float(oceanSpacing)
        u.dotPx = 0.9 * scale; u.scale = scale; u.rows = rows; u.oceanRows = oceanRows
        u.accent = colors.accent; u.text = colors.text; u.line = colors.line
        let labels = placeCities(in: &u, size: size, radius: radius, angle: angle, scale: scale)

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<GlobeUniforms>.stride, index: 0)
        enc.setFragmentBuffer(rowN, offset: 0, index: 1)
        enc.setFragmentBuffer(oceanRowN, offset: 0, index: 2)
        enc.setFragmentTexture(landTex, index: 0)
        enc.setFragmentTexture(oceanTex, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        #if DEBUG
        if Self.debugNoLabels { return }
        #endif
        labelHost?.place(labels)
    }

    /// The most cities the shader's spike table holds (`spikes[16]`).
    private static let maxSpikes = 16
    /// A table entry the shader skips (a city on the far side).
    private static let hiddenSpike = SIMD4<Float>(repeating: -1e5)

    /// Projects the cities on the CPU (a handful of points): writes the spikes of the visible
    /// ones into the uniforms and returns the labels to show (name, tip in points, opacity).
    private func placeCities(in u: inout GlobeUniforms, size: SIMD2<Float>, radius: Float, angle: Float, scale: Float) -> [(String, CGPoint, Float)] {
        var labels: [(String, CGPoint, Float)] = []
        let (sa, ca, st, ct) = (sin(angle), cos(angle), sin(GlobeView.tilt), cos(GlobeView.tilt))
        /// Unit-sphere point → pixel position and depth (z > 0 faces the viewer).
        func project(_ p: SIMD3<Float>) -> (x: Float, y: Float, z: Float) {
            let x = p.x * ca + p.z * sa
            let z1 = -p.x * sa + p.z * ca
            let y = p.y * ct - z1 * st
            let z = p.y * st + z1 * ct
            return (size.x / 2 + radius * x, size.y / 2 - radius * y, z)
        }
        let cities = GlobeView.cities.prefix(Self.maxSpikes)
        withUnsafeMutableBytes(of: &u.spikes) { table in
            for i in 0..<Self.maxSpikes {
                var spike = Self.hiddenSpike
                if i < cities.count {
                    let city = cities[i]
                    let la = city.lat * .pi / 180, lo = city.lon * .pi / 180
                    let base = SIMD3<Float>(cos(la) * sin(lo), sin(la), cos(la) * cos(lo))
                    let foot = project(base)
                    if foot.z > 0.08 {
                        let tip = project(base * (1 + city.height))
                        spike = SIMD4(foot.x, foot.y, tip.x, tip.y)
                        // Labels only well onto the facing side, fading in from the limb.
                        if city.label && foot.z > 0.35 {
                            labels.append((city.name, CGPoint(x: CGFloat(tip.x / scale), y: CGFloat(tip.y / scale)), min(1, foot.z * 1.4)))
                        }
                    }
                }
                table.storeBytes(of: spike, toByteOffset: i * MemoryLayout<SIMD4<Float>>.stride, as: SIMD4<Float>.self)
            }
        }
        u.cityCount = Int32(cities.count)
        return labels
    }
}

/// City labels as Core Animation text layers, moved each frame without implicit animations.
final class GlobeLabelLayer: NSView {
    private var layers: [String: CATextLayer] = [:]
    var color: NSColor = .white { didSet { layers.values.forEach { $0.foregroundColor = color.cgColor } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for city in GlobeView.cities where city.label {
            let t = CATextLayer()
            t.string = city.name
            t.font = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .medium)
            t.fontSize = 8.5
            t.foregroundColor = color.cgColor
            t.contentsScale = 2
            t.isHidden = true
            t.anchorPoint = CGPoint(x: 0, y: 0.5)
            t.bounds = CGRect(x: 0, y: 0, width: 110, height: 12)
            layer?.addSublayer(t)
            layers[city.name] = t
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeBackingProperties() {
        let s = window?.backingScaleFactor ?? 2
        layers.values.forEach { $0.contentsScale = s }
    }

    func place(_ items: [(String, CGPoint, Float)]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (name, l) in layers where !items.contains(where: { $0.0 == name }) { l.isHidden = true }
        for (name, p, alpha) in items {
            guard let l = layers[name] else { continue }
            l.isHidden = false
            l.opacity = alpha
            // Layer coordinates are bottom-up unless flipped; this view is flipped.
            l.position = CGPoint(x: p.x + 6, y: p.y + 1)
        }
        CATransaction.commit()
    }
}

/// Hosts the Metal view and the label layer; pauses whenever animation isn't wanted.
final class GlobeMetalContainer: NSView {
    let mtk: MTKView
    let labels = GlobeLabelLayer(frame: .zero)
    let renderer: GlobeRenderer
    var animate = false { didSet { updatePaused() } }
    private var observers: [NSObjectProtocol] = []

    init?(_ unused: Void = ()) {
        guard let r = GlobeRenderer() , let device = MTLCreateSystemDefaultDevice() else { return nil }
        renderer = r
        mtk = MTKView(frame: .zero, device: device)
        super.init(frame: .zero)
        mtk.delegate = r
        mtk.colorPixelFormat = .bgra8Unorm
        mtk.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtk.layer?.isOpaque = false
        mtk.framebufferOnly = true
        mtk.preferredFramesPerSecond = 15   // one turn per two minutes: under a pixel per frame
        mtk.autoresizingMask = [.width, .height]
        labels.autoresizingMask = [.width, .height]
        addSubview(mtk)
        addSubview(labels)
        r.labelHost = labels
        updatePaused()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        mtk.frame = bounds
        labels.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let w = window {
            for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                      NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updatePaused() }
                })
            }
        }
        updatePaused()
    }

    override func viewDidHide() { super.viewDidHide(); updatePaused() }
    override func viewDidUnhide() { super.viewDidUnhide(); updatePaused() }

    /// Animates only while wanted, the window is key and actually visible; otherwise draws once.
    private func updatePaused() {
        var visible = window.map { $0.isKeyWindow && $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? false
        if isHiddenOrHasHiddenAncestor { visible = false }
        #if DEBUG
        if GlobeView.debugForceActive { visible = window != nil }
        #endif
        let run = animate && visible
        mtk.enableSetNeedsDisplay = !run
        mtk.isPaused = !run
        if !run { mtk.needsDisplay = true }
    }

    func redraw() { if mtk.isPaused { mtk.needsDisplay = true } }
}

struct GlobeMetalView: NSViewRepresentable {
    let theme: Theme
    let animate: Bool

    func makeNSView(context: Context) -> NSView {
        GlobeMetalContainer() ?? NSView()
    }

    func updateNSView(_ v: NSView, context: Context) {
        guard let g = v as? GlobeMetalContainer else { return }
        func c(_ color: Color, _ alpha: Float = 1) -> SIMD4<Float> {
            let n = NSColor(color).usingColorSpace(.sRGB) ?? .white
            return SIMD4(Float(n.redComponent), Float(n.greenComponent), Float(n.blueComponent), Float(n.alphaComponent) * alpha)
        }
        g.renderer.colors = (c(theme.accent), c(theme.text), c(theme.lineStrong))
        g.labels.color = NSColor(theme.text)
        g.animate = animate
        g.redraw()
    }

    static var isSupported: Bool { GlobeMetalContainer.supported }
}

extension GlobeMetalContainer {
    @MainActor static let supported: Bool = GlobeRenderer() != nil
}
