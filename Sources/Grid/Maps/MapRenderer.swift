import AppKit
import GridCore
import Metal
import MetalKit
import simd

// The GridMap renderer (docs/maps/IMPLEMENTATION.md Brief C). Draws one `MapFrame`: the grid
// floor, fills, glowing lines, extruded buildings and the overlay instances, on demand only.
// Tiles are uploaded once into one MTLBuffer each (LRU of 160) and placed per frame with the
// contract projection (`MapProjection.tileMatrix`); colours and widths are per-frame uniform
// tables indexed by `RenderClass.rawValue`, so theme and zoom changes never touch tile buffers.
//
// A frame is drawn in two steps: `prepare` works out everything on the CPU (uniforms, visible
// tiles, overlay instances, labels), then `encode` issues the GPU commands through
// `MapFramePass`. Work that arrives in bursts stays off the frame: tiles are copied to the GPU
// on a background queue, and new label strings are rasterised a few per frame.

/// Everything compiled once per process (shared by every map view on the same device).
private struct MapPipelines {
    let device: MTLDevice
    let floor, lattice, fill, stencil, line, extrusion, overlay, label: MTLRenderPipelineState
    /// Lines over a light (paper) palette: source-over, since max blending can't darken white.
    let lineOver: MTLRenderPipelineState
    let terrainGround, terrainShade, terrainMask: MTLRenderPipelineState
    // Stencil bit planes: 0x01 fill-phase level mask, 0x02 water, 0x04 line-phase level mask.
    let dsNone, dsFill, dsFillWrite, dsWater, dsLattice, dsLine, dsLineWrite, dsExtrusion: MTLDepthStencilState
    /// Contours and relief stay off water (bits 0x02 and the level mask).
    let dsContour, dsShade: MTLDepthStencilState
    /// 3D terrain: the ground writes depth; everything draped on it is tested against it.
    let dsGround3D, dsFill3D, dsWater3D, dsShade3D, dsLine3D, dsContour3D: MTLDepthStencilState
    /// Overlays: tested against the depth of the drawn ground and buildings (instances carry their
    /// depth; 0 = always shown), never written.
    let dsOverlay: MTLDepthStencilState
    let unitQuad: MTLBuffer
    /// The terrain mesh: 65×65 grid plus edge skirts (float4: u, v, skirt, 0), UInt16 indices;
    /// the first `terrainGridIndexCount` indices are the grid alone.
    let terrainMesh: MTLBuffer
    let terrainIndices: MTLBuffer
    let terrainGridIndexCount: Int
    let terrainIndexCount: Int
    /// 1×1 zero elevation for tiles without a grid.
    let zeroDEM: MTLTexture

    static let colorFormat = MTLPixelFormat.bgra8Unorm
    static let depthFormat = MTLPixelFormat.depth32Float_stencil8
    /// 4× multisampling: smooth building, polygon and line edges (cheap on Apple GPUs).
    static let sampleCount = 4

    init?(device: MTLDevice) {
        self.device = device
        #if DEBUG
        MapUniformLayout.checkLayouts()
        #endif
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: mapShaderSource, options: nil) } catch {
            #if DEBUG
            try? FileManager.default.createDirectory(atPath: "/tmp/grid-qa", withIntermediateDirectories: true)
            try? "\(error)".write(toFile: "/tmp/grid-qa/map-shader-error.txt", atomically: true, encoding: .utf8)
            #endif
            return nil
        }
        func pso(_ v: String, _ f: String, blend: Bool, maxBlend: Bool = false, colorWrite: Bool = true) -> MTLRenderPipelineState? {
            guard let vf = lib.makeFunction(name: v), let ff = lib.makeFunction(name: f) else { return nil }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vf
            d.fragmentFunction = ff
            d.colorAttachments[0].pixelFormat = Self.colorFormat
            d.rasterSampleCount = Self.sampleCount
            d.depthAttachmentPixelFormat = Self.depthFormat
            d.stencilAttachmentPixelFormat = Self.depthFormat
            if blend {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                // Premultiplied source-over; the line pass uses max so the tessellator's overlapping
                // bevel quads (and glow halos of neighbouring segments) never double up.
                c.rgbBlendOperation = maxBlend ? .max : .add; c.alphaBlendOperation = maxBlend ? .max : .add
                c.sourceRGBBlendFactor = .one; c.sourceAlphaBlendFactor = .one
                c.destinationRGBBlendFactor = maxBlend ? .one : .oneMinusSourceAlpha
                c.destinationAlphaBlendFactor = maxBlend ? .one : .oneMinusSourceAlpha
            }
            if !colorWrite { d.colorAttachments[0].writeMask = [] }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let floor = pso("floor_vertex", "floor_fragment", blend: false),
              let lattice = pso("floor_vertex", "floor_fragment", blend: true),
              let fill = pso("fill_vertex", "fill_fragment", blend: true),
              let stencil = pso("fill_vertex", "stencil_fragment", blend: false, colorWrite: false),
              let line = pso("line_vertex", "line_fragment", blend: true, maxBlend: true),
              let lineOver = pso("line_vertex", "line_fragment", blend: true),
              let extrusion = pso("ext_vertex", "ext_fragment", blend: false),
              let overlay = pso("overlay_vertex", "overlay_fragment", blend: true),
              let label = pso("label_vertex", "label_fragment", blend: true),
              let terrainGround = pso("terrain_vertex", "terrain_ground_fragment", blend: false),
              let terrainShade = pso("terrain_vertex", "terrain_shade_fragment", blend: true),
              let terrainMask = pso("terrain_vertex", "terrain_mask_fragment", blend: false, colorWrite: false) else { return nil }
        self.floor = floor; self.lattice = lattice; self.fill = fill; self.stencil = stencil; self.line = line; self.extrusion = extrusion; self.overlay = overlay; self.label = label
        self.lineOver = lineOver
        self.terrainGround = terrainGround; self.terrainShade = terrainShade; self.terrainMask = terrainMask

        func ds(depth: Bool, test: Bool = false, stencil: MTLStencilDescriptor?) -> MTLDepthStencilState? {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = depth ? .less : test ? .lessEqual : .always
            d.isDepthWriteEnabled = depth
            d.frontFaceStencil = stencil; d.backFaceStencil = stencil
            return device.makeDepthStencilState(descriptor: d)
        }
        // Geometry of a level is drawn only where no deeper tile has written its bit; after a level
        // its tile quads set the bit. Water sets its own bit so the lattice stays off it.
        func st(read: UInt32, write: UInt32) -> MTLStencilDescriptor {
            let d = MTLStencilDescriptor()
            d.stencilCompareFunction = read == 0 ? .always : .equal
            d.readMask = read; d.writeMask = write
            d.depthStencilPassOperation = write == 0 ? .keep : .replace
            return d
        }
        guard let dsNone = ds(depth: false, stencil: nil),
              let dsFill = ds(depth: false, stencil: st(read: 0x01, write: 0)),
              let dsFillWrite = ds(depth: false, stencil: st(read: 0, write: 0x01)),
              let dsWater = ds(depth: false, stencil: st(read: 0x01, write: 0x02)),
              let dsLattice = ds(depth: false, stencil: st(read: 0x02, write: 0)),
              let dsLine = ds(depth: false, stencil: st(read: 0x04, write: 0)),
              let dsLineWrite = ds(depth: false, stencil: st(read: 0, write: 0x04)),
              let dsExtrusion = ds(depth: true, stencil: st(read: 0x04, write: 0)),
              let dsContour = ds(depth: false, stencil: st(read: 0x06, write: 0)),
              let dsShade = ds(depth: false, stencil: st(read: 0x03, write: 0)),
              let dsGround3D = ds(depth: true, stencil: st(read: 0x01, write: 0)),
              let dsFill3D = ds(depth: false, test: true, stencil: st(read: 0x01, write: 0)),
              let dsWater3D = ds(depth: false, test: true, stencil: st(read: 0x01, write: 0x02)),
              let dsShade3D = ds(depth: false, test: true, stencil: st(read: 0x03, write: 0)),
              let dsLine3D = ds(depth: false, test: true, stencil: st(read: 0x04, write: 0)),
              let dsContour3D = ds(depth: false, test: true, stencil: st(read: 0x06, write: 0)),
              let dsOverlay = ds(depth: false, test: true, stencil: nil) else { return nil }
        self.dsOverlay = dsOverlay
        self.dsNone = dsNone; self.dsFill = dsFill; self.dsFillWrite = dsFillWrite; self.dsWater = dsWater
        self.dsLattice = dsLattice; self.dsLine = dsLine; self.dsLineWrite = dsLineWrite; self.dsExtrusion = dsExtrusion
        self.dsContour = dsContour; self.dsShade = dsShade
        self.dsGround3D = dsGround3D; self.dsFill3D = dsFill3D; self.dsWater3D = dsWater3D; self.dsShade3D = dsShade3D
        self.dsLine3D = dsLine3D; self.dsContour3D = dsContour3D

        let quad: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)]
        guard let q = device.makeBuffer(bytes: quad, length: quad.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared) else { return nil }
        unitQuad = q

        // Terrain mesh.
        let n = TerrainGrid.size, last = Float(n - 1)
        var verts: [SIMD4<Float>] = []
        verts.reserveCapacity(n * n + 4 * n)
        for j in 0..<n { for i in 0..<n { verts.append(SIMD4(Float(i) / last, Float(j) / last, 0, 0)) } }
        var idx: [UInt16] = []
        for j in 0..<(n - 1) {
            for i in 0..<(n - 1) {
                let a = UInt16(j * n + i), b = a + 1, c = a + UInt16(n), d = c + 1
                idx += [a, b, c, b, d, c]
            }
        }
        let gridCount = idx.count
        // Skirts: each edge's vertices again, flagged to hang below the edge.
        let edges: [[Int]] = [(0..<n).map { $0 }, (0..<n).map { (n - 1) * n + $0 },
                              (0..<n).map { $0 * n }, (0..<n).map { $0 * n + n - 1 }]
        for e in edges {
            let base = UInt16(verts.count)
            for k in e { var v = verts[k]; v.z = 1; verts.append(v) }
            for k in 0..<(n - 1) {
                let a = UInt16(e[k]), b = UInt16(e[k + 1]), a2 = base + UInt16(k), b2 = a2 + 1
                idx += [a, b, b2, a, b2, a2]
            }
        }
        guard let mesh = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared),
              let mi = device.makeBuffer(bytes: idx, length: idx.count * 2, options: .storageModeShared) else { return nil }
        terrainMesh = mesh; terrainIndices = mi
        terrainGridIndexCount = gridCount; terrainIndexCount = idx.count
        let zd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        zd.usage = [.shaderRead]; zd.storageMode = .shared
        guard let zt = device.makeTexture(descriptor: zd) else { return nil }
        var zero: Float = 0
        zt.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
        zeroDEM = zt
    }
}

// MARK: - GPU tiles

/// One tile's geometry on the GPU: a single buffer holding every batch at 256-byte offsets.
/// Built on the upload queue (it only reads its arguments), then owned by the main thread.
private final class GPUTile: @unchecked Sendable {
    struct Batch { let cls: UInt16; let vertexOffset: Int; let indexOffset: Int; let indexCount: Int }
    let id: TileID
    let buffer: MTLBuffer
    let fills: [Batch]
    let lines: [Batch]
    let extrusion: Batch?
    let bytes: Int
    let revision: Int
    var lastUsed: UInt64 = 0
    /// This frame's elevation texture (or nil: drawn at sea level).
    var dem: MTLTexture?
    /// Cached per-frame uniforms (rewritten every frame, read by the draw loops).
    var uniforms = MapTileUniforms(mvp: matrix_identity_float4x4, worldUnitsPerMeter: 0, tilePx: 0)

    /// Where one batch's vertices and indices go in the buffer, and which source batch they come from.
    private struct Placement { let cls: UInt16; let vertexOffset: Int; let indexOffset: Int; let source: Int; let indexCount: Int }

    init?(_ g: TileGeometry, device: MTLDevice) {
        // Layout pass: every array lands at a 256-byte aligned offset; batches with bad indices are
        // skipped (the shaders fetch vertices by index, unchecked).
        func aligned(_ n: Int) -> Int { (n + 255) & ~255 }
        func valid(_ indices: [UInt32], vertexCount: Int) -> Bool {
            guard !indices.isEmpty, indices.count % 3 == 0, vertexCount > 0 else { return false }
            return indices.allSatisfy { Int($0) < vertexCount }
        }
        var total = 0
        func place(cls: UInt16, source: Int, vertexBytes: Int, indexCount: Int) -> Placement {
            let v = total; total = aligned(total + vertexBytes)
            let ix = total; total = aligned(total + indexCount * MemoryLayout<UInt32>.stride)
            return Placement(cls: cls, vertexOffset: v, indexOffset: ix, source: source, indexCount: indexCount)
        }
        var fillPlan: [Placement] = [], linePlan: [Placement] = []
        var extrusionPlan: Placement?
        for (i, f) in g.fills.enumerated() where valid(f.indices, vertexCount: f.positions.count) {
            fillPlan.append(place(cls: f.cls.rawValue, source: i, vertexBytes: f.positions.count * MemoryLayout<SIMD2<Float>>.stride, indexCount: f.indices.count))
        }
        for (i, l) in g.lines.enumerated() where valid(l.indices, vertexCount: l.vertices.count) {
            linePlan.append(place(cls: l.cls.rawValue, source: i, vertexBytes: l.vertices.count * MemoryLayout<LineVertex>.stride, indexCount: l.indices.count))
        }
        if let e = g.extrusion, valid(e.indices, vertexCount: e.vertices.count) {
            extrusionPlan = place(cls: RenderClass.building.rawValue, source: 0, vertexBytes: e.vertices.count * MemoryLayout<ExtrusionVertex>.stride, indexCount: e.indices.count)
        }
        // A tile with nothing drawable (labels only) still gets a small buffer: it masks ancestors
        // through the stencil.
        let length = max(256, total)
        guard length < 256 << 20, let buf = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
        let base = buf.contents()
        func copy<T>(_ a: [T], to offset: Int) {
            a.withUnsafeBytes { src in if let p = src.baseAddress { base.advanced(by: offset).copyMemory(from: p, byteCount: src.count) } }
        }
        func batch(_ p: Placement) -> Batch { Batch(cls: p.cls, vertexOffset: p.vertexOffset, indexOffset: p.indexOffset, indexCount: p.indexCount) }
        for p in fillPlan { copy(g.fills[p.source].positions, to: p.vertexOffset); copy(g.fills[p.source].indices, to: p.indexOffset) }
        for p in linePlan { copy(g.lines[p.source].vertices, to: p.vertexOffset); copy(g.lines[p.source].indices, to: p.indexOffset) }
        if let p = extrusionPlan, let e = g.extrusion { copy(e.vertices, to: p.vertexOffset); copy(e.indices, to: p.indexOffset) }
        id = g.id
        revision = g.revision
        buffer = buf
        fills = fillPlan.map(batch)
        lines = linePlan.map(batch)
        extrusion = extrusionPlan.map(batch)
        bytes = length
    }
}

/// True when `a` is an ancestor of `b` in the tile pyramid (covers its ground).
private func isAncestor(_ a: TileID, of b: TileID) -> Bool {
    guard a.z < b.z else { return false }
    let shift = UInt32(b.z - a.z)
    guard shift < 32 else { return false }
    return b.x >> shift == a.x && b.y >> shift == a.y
}

// MARK: - Per-frame GPU buffers

/// Frames the GPU may still be reading while the next one is written.
private let maxFramesInFlight = 3

/// A buffer per frame in flight, used in turn: what the CPU writes for frame N is never what the
/// GPU still reads for frames N−1 and N−2 (the renderer's semaphore keeps it to three).
private struct BufferRing {
    private var buffers = [MTLBuffer?](repeating: nil, count: maxFramesInFlight)
    private var index = 0

    /// The next buffer in turn, at least `length` bytes. Grows in steps (never below `floor`) so
    /// steady-state frames don't allocate.
    mutating func next(length: Int, floor: Int, device: MTLDevice) -> MTLBuffer? {
        index = (index + 1) % buffers.count
        if let b = buffers[index], b.length >= length { return b }
        let b = device.makeBuffer(length: max(floor, length + length / 2), options: .storageModeShared)
        buffers[index] = b
        return b
    }
}

/// GPU time of the last completed frame, written from the command buffer's completion handler.
private final class FrameStats: @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Double = 0
    var gpuMs: Double { lock.withLock { ms } }
    func set(_ v: Double) { lock.withLock { ms = v } }
}

// MARK: - Polylines cut into runs

/// A long polyline (a route, a region outline) cut into runs of consecutive points with their
/// bounds, so a frame projects only the runs that can reach the view: the cost of a route follows
/// what is on screen, not its length. Rebuilt when a frame arrives.
private struct PolylineRuns {
    struct Run {
        /// First and last point (inclusive); a run starts on the previous run's last point.
        var first, last: Int
        var lo, hi: SIMD2<Double>
        /// Length in world units (keeps a dash pattern in step when the run is skipped).
        var worldLength: Double
    }
    static let pointsPerRun = 64

    private(set) var runs: [Run] = []
    /// Raw elevation per point (metres; nan: none), filled run by run the first time a run is
    /// drawn on raised terrain.
    private var heights: [Double] = []
    private var hasHeights: [Bool] = []

    init(_ points: [Mercator]) {
        guard points.count >= 2 else { return }
        runs.reserveCapacity(points.count / Self.pointsPerRun + 1)
        var first = 0
        while first < points.count - 1 {
            let last = min(first + Self.pointsPerRun, points.count - 1)
            var lo = SIMD2(points[first].x, points[first].y), hi = lo
            var length = 0.0
            for i in (first + 1)...last {
                let p = SIMD2(points[i].x, points[i].y), q = SIMD2(points[i - 1].x, points[i - 1].y)
                lo = simd_min(lo, p); hi = simd_max(hi, p)
                length += simd_length(p - q)
            }
            runs.append(Run(first: first, last: last, lo: lo, hi: hi, worldLength: length.isFinite ? length : 0))
            first = last
        }
        hasHeights = [Bool](repeating: false, count: runs.count)
    }

    /// Looks up the elevations of a run's points once (they don't depend on the camera).
    mutating func prepareHeights(run k: Int, points: [Mercator], frame: MapFrame) {
        guard !hasHeights[k] else { return }
        if heights.isEmpty { heights = [Double](repeating: .nan, count: points.count) }
        for i in runs[k].first...runs[k].last { heights[i] = frame.rawElevation(at: points[i]) ?? .nan }
        hasHeights[k] = true
    }

    /// Metres drawn above the ground plane at point `i` (after `prepareHeights` for its run).
    func lift(at i: Int, _ lift: TerrainLift) -> Double {
        let h = heights[i]
        return h.isNaN ? 0 : lift.lift(h)
    }
}

// MARK: - Renderer

@MainActor
final class MapRenderer: NSObject, MTKViewDelegate {
    private let pipes: MapPipelines
    private let queue: MTLCommandQueue
    private weak var view: MTKView?
    private let stats = FrameStats()

    private var frame: MapFrame?
    /// The camera drawn: the latest of `frame.camera` and the view's in-progress gesture.
    private(set) var camera: MapCamera?

    // GPU tiles.
    private var tileGeneration = Int.min
    private var gpuTiles: [TileID: GPUTile] = [:]
    /// Tiles drawn for the current frame grouped by zoom, deepest level first (draw order).
    private var levels: [[GPUTile]] = []
    /// Tiles in `levels` that the frame no longer lists: they keep their ground covered until
    /// the tiles replacing them are on the GPU.
    private var standIns: Set<TileID> = []
    private var useClock: UInt64 = 0
    /// Tiles kept on the GPU: a tilted view alone draws up to ~55 (cover plus stand-ins), and the
    /// ones just scrolled out are the likeliest to come back.
    static let maxGPUTiles = 160
    static let maxGPUBytes = 320 << 20
    private var gpuBytes = 0

    /// One upload: a tile revision under a tile generation.
    private struct UploadKey: Hashable { let id: TileID; let revision: Int; let generation: Int }
    private var uploadsInFlight: Set<UploadKey> = []
    /// Uploads that failed (no memory, oversized): not tried again for the same geometry.
    private var failedUploads: Set<UploadKey> = []
    /// Serial, so tiles reach the GPU in the frame's order (the view first, then the ring around it).
    private static let uploadQueue = DispatchQueue(label: "grid.map.tile-upload", qos: .userInitiated)

    /// Elevation textures (R32Float 65×65) for the frame's grids, kept while in view (+ a few).
    private var demTextures: [TileID: MTLTexture] = [:]
    private var demOrder: [TileID] = []
    private static let maxDEMTextures = 160

    // Per-frame CPU data and the GPU buffers it is copied into.
    private var uniformBlob = [UInt8](repeating: 0, count: MapUniformLayout.totalBytes)
    private var uniformBuffers = BufferRing()
    private var overlayInstances: [MapOverlayInstance] = []
    private var overlayBuffers = BufferRing()
    private var labelInstances: [MapLabelInstance] = []
    private var labelBuffers = BufferRing()
    private let inflight = DispatchSemaphore(value: maxFramesInFlight)
    /// The last style tables built (they change with theme, zoom and glow, not with a pan).
    private var styleCache: (palette: MapPalette, zoom: Double, glow: Bool, scale: Float, style: MapStyle)?

    // Overlays.
    /// The frame's routes and region rings cut into runs (same order as in the frame).
    private var routeRuns: [PolylineRuns] = []
    private var regionRuns: [[PolylineRuns]] = []
    /// Cameras in view this frame (kept between frames for its capacity).
    private var projectedCameras: [ProjectedCamera] = []
    /// Count strings by count (formatting one per cluster per frame adds up).
    private var countTexts: [Int: String] = [:]
    /// Text drawn beside markers this frame (cluster counts, route ends, the pin's name): the
    /// text and the left end of its box in points. Placed before every other label.
    private var captions: [(text: String, left: SIMD2<Double>)] = []
    static let maxOverlayInstances = 60_000

    // Labels: placed for the projection of the frame being encoded and drawn in the same pass.
    private let planner = MapLabelPlanner()
    private let atlas: MapLabelAtlas
    private var plannerEpoch = -1
    /// Seconds a frame may spend rasterising label strings it hasn't drawn before, and as long
    /// again preparing the anchors of new tiles; the rest appear over the next frames (a zoom
    /// across a tile level brings dozens of new names at once).
    static let labelRasterBudget: CFTimeInterval = 0.0015
    /// This frame left label work for the next ones: strings still to rasterise, or tiles whose
    /// anchors the planner has yet to prepare.
    private var labelWorkPending = false
    private var followUpDrawScheduled = false

    /// Drawing is wanted (window key and visible). While false, frames are kept and drawn once on resume.
    var isActive = true { didSet { if isActive && dirty { requestDraw() } } }
    private var dirty = false

    /// `.infinity` uploads every tile inside `setFrame` (a renderer that draws one image:
    /// printing). Otherwise tiles are copied to the GPU off the main thread and drawn when ready.
    var uploadBudget: Double = 0.006
    private var uploadsSynchronously: Bool { uploadBudget == .infinity }

    // QA readouts (§3.3 C).
    var gpuTileCount: Int { gpuTiles.count }
    var lastFrameGPUms: Double { stats.gpuMs }
    private(set) var frameCount = 0

    #if DEBUG
    /// Called after each frame is encoded with the projection it used (QA measurements).
    var debugOnFrameDrawn: ((any MapScreenProjection) -> Void)?
    /// Main-thread time of the last frame's label pass (placement and instances) and its label count.
    private(set) var debugLastLabelMs: Double = 0
    private(set) var debugLastLabelCount = 0
    /// Main-thread time spent on the last frame (uniforms, tile matrices, overlays, labels, commands).
    private(set) var debugLastEncodeCPUms: Double = 0
    private var debugPrepareMs: Double = 0
    /// Frames drawn, and the zoom of the last one.
    private(set) var debugDrawCount = 0
    private(set) var debugDrawnZoom = 0.0
    var debugFrameTiles: Set<TileID> { Set(frame?.tiles.map(\.id) ?? []) }
    /// GPU uploads so far (count, milliseconds of copying; off the main thread unless printing).
    private(set) var debugUploads = 0
    private(set) var debugUploadMs = 0.0
    /// QA: draw even though the test window is never key (on by default for `--qa` launches).
    nonisolated(unsafe) static var debugForceActive = ProcessInfo.processInfo.arguments.contains("--qa")
    #endif

    private static var compiledByDevice: [ObjectIdentifier: MapPipelines] = [:]
    private static func pipelines(for device: MTLDevice) -> MapPipelines? {
        let key = ObjectIdentifier(device)
        if let p = compiledByDevice[key] { return p }
        guard let p = MapPipelines(device: device) else { return nil }
        compiledByDevice[key] = p
        return p
    }

    /// Fails when there is no Metal device or the shaders don't compile: the caller shows a StateBlock.
    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let pipes = Self.pipelines(for: device),
              let queue = device.makeCommandQueue() else { return nil }
        self.pipes = pipes
        self.queue = queue
        self.view = view
        atlas = MapLabelAtlas(device: device)
        super.init()
        view.device = device
        view.colorPixelFormat = MapPipelines.colorFormat
        // The view only supplies the drawable: the multisampled colour and depth/stencil targets
        // are ours (see `renderPass`), memoryless on Apple GPUs, so 4× MSAA costs no memory.
        view.depthStencilPixelFormat = .invalid
        view.sampleCount = 1
        view.framebufferOnly = true
        // Draw on demand only: an idle map costs nothing.
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = self
    }

    // MARK: Frame input

    /// Takes a new frame: tiles the GPU doesn't hold yet are uploaded (once per tile revision)
    /// and the view is marked for display.
    func setFrame(_ f: MapFrame) {
        if f.tileGeneration != tileGeneration {
            // A new tile source: the same TileID now means different geometry.
            gpuTiles.removeAll()
            gpuBytes = 0
            levels = []
            standIns = []
            uploadsInFlight = []
            failedUploads = []
            tileGeneration = f.tileGeneration
        }
        frame = f
        camera = f.camera
        routeRuns = f.routes.map { PolylineRuns($0.points) }
        regionRuns = f.regions.map { $0.rings.map(PolylineRuns.init) }
        rebuildLevels()
    }

    /// The view's in-progress gesture camera (frame.camera is authoritative when the model echoes it).
    func setCamera(_ c: MapCamera) {
        camera = c
        requestDraw()
    }

    // MARK: GPU tiles

    /// Works out what to draw for the current frame from the tiles on the GPU, and asks for the
    /// ones that are missing. Runs when a frame arrives and again whenever an upload lands.
    private func rebuildLevels() {
        guard let f = frame else { return }
        useClock &+= 1
        var byZoom: [UInt8: [GPUTile]] = [:]
        var included = Set<TileID>()
        included.reserveCapacity(f.tiles.count)
        func include(_ t: GPUTile) {
            guard included.insert(t.id).inserted else { return }
            t.lastUsed = useClock
            byZoom[t.id.z, default: []].append(t)
        }
        var awaited: [TileID] = []
        for t in f.tiles {
            if let ready = currentTile(for: t) {
                include(ready)
            } else {
                awaited.append(t.id)
                // The copy already on the GPU (older contours) still draws meanwhile.
                if let stale = gpuTiles[t.id] { include(stale) }
            }
        }
        // Until an awaited tile is on the GPU, whatever covered its ground in the last frame
        // (the ancestor that stood in for it, or its children after a zoom out) stays, so
        // nothing blinks to the bare floor for a frame. The stencil keeps the two from overlapping.
        var kept = Set<TileID>()
        if !awaited.isEmpty {
            for old in levels.joined() where !included.contains(old.id) && gpuTiles[old.id] === old {
                guard awaited.contains(where: { isAncestor(old.id, of: $0) || isAncestor($0, of: old.id) }) else { continue }
                include(old)
                kept.insert(old.id)
            }
        }
        standIns = kept
        levels = byZoom.keys.sorted(by: >).map { byZoom[$0]! }
        updateDEMs(f)
        evict()
        requestDraw()
    }

    /// The GPU tile holding exactly this geometry, or nil while it is on its way.
    private func currentTile(for t: TileGeometry) -> GPUTile? {
        if let g = gpuTiles[t.id], g.revision == t.revision { return g }
        let key = UploadKey(id: t.id, revision: t.revision, generation: tileGeneration)
        guard !failedUploads.contains(key) else { return nil }
        if uploadsSynchronously {
            #if DEBUG
            let t0 = CACurrentMediaTime()
            defer { debugUploads += 1; debugUploadMs += (CACurrentMediaTime() - t0) * 1000 }
            #endif
            guard let g = GPUTile(t, device: pipes.device) else { failedUploads.insert(key); return nil }
            install(g)
            return g
        }
        startUpload(t, key)
        return nil
    }

    /// Copies a tile into a GPU buffer on the upload queue. Checking its indices and copying a
    /// megabyte or two takes around half a millisecond a tile; a new zoom level brings dozens.
    private func startUpload(_ t: TileGeometry, _ key: UploadKey) {
        guard uploadsInFlight.insert(key).inserted else { return }
        let device = pipes.device
        Self.uploadQueue.async { [weak self] in
            let t0 = CACurrentMediaTime()
            let uploaded = GPUTile(t, device: device)
            let ms = (CACurrentMediaTime() - t0) * 1000
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishUpload(key, uploaded, ms: ms) }
            }
        }
    }

    private func finishUpload(_ key: UploadKey, _ uploaded: GPUTile?, ms: Double) {
        uploadsInFlight.remove(key)
        guard key.generation == tileGeneration else { return }
        guard let uploaded else { failedUploads.insert(key); return }
        #if DEBUG
        debugUploads += 1; debugUploadMs += ms
        #endif
        // Only what the frame still asks for (the view may have moved on meanwhile).
        guard let f = frame, f.tiles.contains(where: { $0.id == key.id && $0.revision == key.revision }) else { return }
        install(uploaded)
        rebuildLevels()
    }

    private func install(_ g: GPUTile) {
        gpuBytes += g.bytes - (gpuTiles[g.id]?.bytes ?? 0)
        gpuTiles[g.id] = g
    }

    private func evict() {
        guard gpuTiles.count > Self.maxGPUTiles || gpuBytes > Self.maxGPUBytes else { return }
        // Least recently drawn first; never a tile of the current frame.
        for v in gpuTiles.values.sorted(by: { $0.lastUsed < $1.lastUsed }) {
            guard gpuTiles.count > Self.maxGPUTiles || gpuBytes > Self.maxGPUBytes, v.lastUsed != useClock else { break }
            gpuTiles[v.id] = nil
            gpuBytes -= v.bytes
        }
    }

    private func updateDEMs(_ f: MapFrame) {
        let n = TerrainGrid.size
        var wanted: [TileID: MTLTexture] = [:]
        for g in f.terrain where g.heights.count == n * n {
            if let t = demTextures[g.id] { wanted[g.id] = t; continue }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: n, height: n, mipmapped: false)
            d.usage = [.shaderRead]; d.storageMode = .shared
            guard let t = pipes.device.makeTexture(descriptor: d) else { continue }
            g.heights.withUnsafeBytes { raw in
                guard let p = raw.baseAddress else { return }
                t.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: p, bytesPerRow: n * MemoryLayout<Float>.stride)
            }
            demTextures[g.id] = t
            demOrder.append(g.id)
            wanted[g.id] = t
        }
        for t in levels.joined() {
            // A stand-in keeps the elevation it was last drawn with.
            t.dem = wanted[t.id] ?? (standIns.contains(t.id) ? demTextures[t.id] : nil)
        }
        if demTextures.count > Self.maxDEMTextures {
            demOrder.removeAll { id in
                guard demTextures.count > Self.maxDEMTextures, wanted[id] == nil else { return false }
                demTextures[id] = nil
                return true
            }
        }
    }

    // MARK: Drawing on demand

    /// Marks the view for display. Nothing draws unless something asked: a frame, a camera, an
    /// upload that landed, labels still to rasterise.
    private func requestDraw() {
        dirty = true
        var active = isActive
        #if DEBUG
        if Self.debugForceActive { active = true }
        #endif
        guard active, let view else { return }
        view.needsDisplay = true
    }

    /// One more frame on the next turn of the run loop (asking from inside `draw` would be lost).
    private func scheduleFollowUpDraw() {
        guard !followUpDrawScheduled else { return }
        followUpDrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.followUpDrawScheduled = false
                self.requestDraw()
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { dirty = true }

    func draw(in view: MTKView) {
        guard let frame, let camera else { return }
        let size = view.drawableSize
        guard size.width >= 1, size.height >= 1 else { return }
        #if DEBUG
        let d0 = CACurrentMediaTime()
        defer { MapDebugTimes.add("draw", since: d0) }
        #endif
        let scale = Double(view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        // Everything the CPU works out comes first, so the drawable is held as briefly as possible.
        let prepared = prepare(frame: frame, camera: camera, drawableSize: size, scale: scale, labelRasterBudget: Self.labelRasterBudget)
        guard let drawable = view.currentDrawable,
              let pass = renderPass(resolvingInto: drawable.texture, clear: frame.palette.bg0),
              let cmd = encode(prepared, into: pass) else { return }
        cmd.present(drawable)
        cmd.commit()
        dirty = false
        #if DEBUG
        debugDrawCount += 1; debugDrawnZoom = camera.zoom
        #endif
        if labelWorkPending { scheduleFollowUpDraw() }
    }

    // MARK: Multisampled targets

    private var msaaColor: MTLTexture?
    private var msaaDepth: MTLTexture?
    private let onScreenPass = MTLRenderPassDescriptor()

    /// Memoryless (tile-memory only) where the GPU supports it, so the 4× targets take no RAM.
    private var targetStorage: MTLStorageMode {
        pipes.device.supportsFamily(.apple1) ? .memoryless : .private
    }

    private func makeMultisampleTarget(_ format: MTLPixelFormat, width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.textureType = .type2DMultisample
        d.sampleCount = MapPipelines.sampleCount
        d.usage = [.renderTarget]
        d.storageMode = targetStorage
        return pipes.device.makeTexture(descriptor: d)
    }

    /// Points `pass` at multisampled targets that resolve into `texture`; nothing but the
    /// resolved colour is kept.
    private func configure(_ pass: MTLRenderPassDescriptor, color: MTLTexture, depth: MTLTexture, resolvingInto texture: MTLTexture, clear bg: SIMD4<Float>) {
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].resolveTexture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: 1)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        pass.stencilAttachment.texture = depth
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.clearStencil = 0
        pass.stencilAttachment.storeAction = .dontCare
    }

    /// The on-screen pass: draws into the view's multisampled targets (remade when the drawable
    /// changes size) and resolves into `texture` (the drawable).
    private func renderPass(resolvingInto texture: MTLTexture, clear bg: SIMD4<Float>) -> MTLRenderPassDescriptor? {
        let w = texture.width, h = texture.height
        if msaaColor?.width != w || msaaColor?.height != h {
            msaaColor = makeMultisampleTarget(MapPipelines.colorFormat, width: w, height: h)
            msaaDepth = makeMultisampleTarget(MapPipelines.depthFormat, width: w, height: h)
        }
        guard let color = msaaColor, let depth = msaaDepth else { return nil }
        configure(onScreenPass, color: color, depth: depth, resolvingInto: texture, clear: bg)
        return onScreenPass
    }

    // MARK: Preparing a frame (CPU)

    /// What `prepare` hands to `encode`; the instance arrays and the uniform blob stay on the renderer.
    private struct PreparedFrame {
        let projection: any MapScreenProjection
        let mode: MapFramePass.Mode
        /// The frame's levels without the tiles that are wholly off screen.
        let levels: [[GPUTile]]
    }

    /// Works out everything one frame needs before any GPU command: uniforms, which tiles show
    /// and their matrices, overlay instances and labels.
    private func prepare(frame: MapFrame, camera: MapCamera, drawableSize: CGSize, scale: Double, labelRasterBudget: CFTimeInterval) -> PreparedFrame {
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { debugPrepareMs = (CACurrentMediaTime() - t0) * 1000 }
        #endif
        let viewportPt = SIMD2<Double>(drawableSize.width / scale, drawableSize.height / scale)
        let proj = mapProjection(camera: camera, viewport: viewportPt)
        // The terrain lift follows the camera being drawn (not the one the frame was built for).
        var frame = frame
        frame.lift = frame.lift(for: camera, viewport: viewportPt)
        let globe = proj is GlobeProjection            // fully a globe (no fills, no masks)
        let shade = !globe && frame.hillshade && proj is MapProjection
        let mode = MapFramePass.Mode(globe: globe,
                                     pitched: !globe && frame.buildings && camera.pitch > 5,
                                     shade: shade,
                                     terrain3D: shade && !frame.lift.isFlat,
                                     lattice: frame.gridFloor && !shade,
                                     lightBackground: frame.palette.bg0.x > 0.5)
        let viewportPx = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        fillUniforms(frame: frame, proj: proj, viewportPx: viewportPx, scale: Float(scale), mode: mode)
        let visible = visibleLevels(proj)
        for t in visible.joined() { t.uniforms = tileUniforms(t, proj: proj) }
        buildOverlays(frame: frame, proj: proj, scale: scale)
        buildLabels(frame: frame, proj: proj, scale: scale, rasterBudget: labelRasterBudget)
        return PreparedFrame(projection: proj, mode: mode, levels: visible)
    }

    /// The frame's levels without the tiles that are wholly off screen. The frame carries the ring
    /// around the view (so ground is ready before it scrolls in); those cost nothing until they show.
    private func visibleLevels(_ proj: any MapScreenProjection) -> [[GPUTile]] {
        guard let flat = proj as? MapProjection else { return levels }
        let vp = flat.viewport, m = flat.viewProjection
        // Room for what stands above the ground plane (raised terrain, buildings, glow).
        let margin = 0.3 * max(vp.x, vp.y) + 200
        func visible(_ t: GPUTile) -> Bool {
            let (nw, se) = TileMath.bounds(t.id)
            var lo = SIMD2<Double>(repeating: .infinity), hi = -lo
            for corner in 0..<4 {
                let c = m * SIMD4(corner & 1 == 0 ? nw.x : se.x, corner & 2 == 0 ? nw.y : se.y, 0, 1)
                guard c.w > 1e-9 else { return true }      // reaches behind the camera: keep
                let s = SIMD2((c.x / c.w + 1) / 2 * vp.x, (1 - c.y / c.w) / 2 * vp.y)
                lo = simd_min(lo, s); hi = simd_max(hi, s)
            }
            return hi.x > -margin && hi.y > -margin && lo.x < vp.x + margin && lo.y < vp.y + margin
        }
        var out: [[GPUTile]] = []
        out.reserveCapacity(levels.count)
        for level in levels {
            let kept = level.filter(visible)
            if !kept.isEmpty { out.append(kept) }
        }
        return out
    }

    private func tileUniforms(_ t: GPUTile, proj: any MapScreenProjection) -> MapTileUniforms {
        let id = t.id
        let (nw, se) = TileMath.bounds(id)
        let wupm = MapProjection.worldUnitsPerMeter(y: (nw.y + se.y) / 2)
        let tilePx = Float(proj.worldScale * (se.x - nw.x))
        let flat = (proj as? MapProjection) ?? (proj as? BlendedProjection)?.flat
        let mvp = flat?.tileMatrix(id) ?? matrix_identity_float4x4
        let c = proj.camera.center
        let rel = SIMD2(Float((nw.x - c.x) * proj.worldScale), Float((nw.y - c.y) * proj.worldScale))
        return MapTileUniforms(mvp: mvp, worldUnitsPerMeter: Float(wupm), tilePx: tilePx,
                               merc: SIMD4(Float(nw.x), Float(nw.y), Float(se.x - nw.x), Float(se.y - nw.y)),
                               terr: SIMD4(t.dem == nil ? 0 : 1, 0, rel.x, rel.y))
    }

    // MARK: Encoding a frame (GPU commands)

    /// Encodes a prepared frame into `pass`. Returns the command buffer (not committed).
    private func encode(_ prepared: PreparedFrame, into pass: MTLRenderPassDescriptor) -> MTLCommandBuffer? {
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer {
            let ms = (CACurrentMediaTime() - t0) * 1000
            debugLastEncodeCPUms = debugPrepareMs + ms
            MapDebugTimes.add("encode", ms: debugPrepareMs + ms)
        }
        #endif
        // At most three frames on their way to the GPU: the per-frame buffers below are reused
        // in turn, and the one taken now must no longer be read by an earlier frame.
        inflight.wait()
        guard let cmd = queue.makeCommandBuffer() else { inflight.signal(); return nil }
        let stats = self.stats, inflight = self.inflight
        cmd.addCompletedHandler { cb in
            stats.set(max(0, cb.gpuEndTime - cb.gpuStartTime) * 1000)
            inflight.signal()
        }
        // From here the completion handler returns the semaphore, so a failure still commits.
        guard let uniforms = uniformBuffers.next(length: uniformBlob.count, floor: uniformBlob.count, device: pipes.device),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { cmd.commit(); return nil }
        frameCount += 1
        uniformBlob.withUnsafeBytes { src in
            if let p = src.baseAddress { uniforms.contents().copyMemory(from: p, byteCount: src.count) }
        }
        // The frame uniforms sit at the same indices in every shader, so they are bound once
        // (bindings outlive pipeline changes).
        enc.setVertexBuffer(uniforms, offset: 0, index: MapFramePass.frameUniformsVertexIndex)
        enc.setFragmentBuffer(uniforms, offset: 0, index: MapFramePass.frameUniformsFragmentIndex)

        let draw = MapFramePass(encoder: enc, pipes: pipes, mode: prepared.mode)
        draw.backdrop()
        if prepared.mode.globe {
            draw.globe(prepared.levels)
        } else {
            for level in prepared.levels { draw.ground(level) }
            draw.lattice()
            for level in prepared.levels { draw.linesAndBuildings(level) }
        }
        if !overlayInstances.isEmpty,
           let buffer = instanceBuffer(&overlayBuffers, holding: overlayInstances, floor: 256) {
            draw.overlays(buffer, count: overlayInstances.count)
        }
        if !labelInstances.isEmpty, let texture = atlas.texture,
           let buffer = instanceBuffer(&labelBuffers, holding: labelInstances, floor: 128) {
            draw.labels(buffer, count: labelInstances.count, atlas: texture)
        }
        enc.endEncoding()
        #if DEBUG
        debugOnFrameDrawn?(prepared.projection)
        #endif
        return cmd
    }

    /// This frame's buffer from `ring` with `instances` copied in (`floor`: the smallest buffer, in instances).
    private func instanceBuffer<T>(_ ring: inout BufferRing, holding instances: [T], floor: Int) -> MTLBuffer? {
        let stride = MemoryLayout<T>.stride
        guard let buffer = ring.next(length: instances.count * stride, floor: floor * stride, device: pipes.device) else { return nil }
        instances.withUnsafeBytes { src in
            if let p = src.baseAddress { buffer.contents().copyMemory(from: p, byteCount: src.count) }
        }
        return buffer
    }

    // MARK: Labels

    private static func labelColor(_ v: SIMD4<Float>, _ alpha: Float = 1) -> SIMD4<Float> { SIMD4(v.x, v.y, v.z, v.w * alpha) }

    /// How much rasterising a frame may still do: the first new string always goes through (so
    /// labels keep arriving), the rest only until the deadline.
    private struct RasterAllowance {
        let deadline: CFTimeInterval
        private var used = false
        init(budget: CFTimeInterval) { deadline = budget.isFinite ? CACurrentMediaTime() + budget : .infinity }
        mutating func take() -> Bool {
            if !used { used = true; return true }
            return deadline == .infinity || CACurrentMediaTime() < deadline
        }
    }

    private enum SlotLookup {
        case ready(MapLabelAtlas.Slot?)
        /// Not rasterised yet and this frame's time for it is spent.
        case later
        /// The atlas has no room left.
        case full
    }

    /// Places the frame's labels and turns them into instances. Strings met for the first time
    /// are rasterised into the atlas within `rasterBudget`; labels that have to wait are left
    /// out of this frame and drawn in one of the next (see `labelWorkPending`).
    private func buildLabels(frame: MapFrame, proj: any MapScreenProjection, scale: Double, rasterBudget: CFTimeInterval) {
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { debugLastLabelMs = (CACurrentMediaTime() - t0) * 1000; debugLastLabelCount = labelInstances.count; MapDebugTimes.add("labels", since: t0) }
        #endif
        labelInstances.removeAll(keepingCapacity: true)
        // The same budget bounds preparing the anchors of tiles the planner hasn't seen.
        let placed = planner.place(frame: frame, projection: proj, counts: captions, prepareBudget: rasterBudget)
        labelWorkPending = planner.hasUnpreparedTiles
        guard !placed.isEmpty else { return }
        var budget = rasterBudget
        if atlas.texture == nil || atlas.scale != CGFloat(scale) || plannerEpoch != planner.epoch {
            // The atlas starts over under labels that are on screen (new backing scale, new
            // string table): they are rasterised in one go rather than blinking back in over
            // several frames. The very first atlas has nothing on screen to blink.
            if atlas.texture != nil { budget = .infinity }
            atlas.reset(scale: CGFloat(scale))
            plannerEpoch = planner.epoch
        }
        var allowance = RasterAllowance(budget: budget)
        if appendLabelInstances(placed, palette: frame.palette, scale: scale, allowance: &allowance) { return }
        // Full: start the atlas over and rasterise what this frame shows in one go (about once
        // per thousand new strings; spreading it would blank the labels on screen meanwhile).
        atlas.reset(scale: CGFloat(scale))
        labelInstances.removeAll(keepingCapacity: true)
        labelWorkPending = planner.hasUnpreparedTiles
        var unlimited = RasterAllowance(budget: .infinity)
        _ = appendLabelInstances(placed, palette: frame.palette, scale: scale, allowance: &unlimited)
    }

    /// Appends the instances of `placed`. False when the atlas ran out of room part-way.
    private func appendLabelInstances(_ placed: [MapLabelPlanner.Placed], palette p: MapPalette, scale: Double,
                                      allowance: inout RasterAllowance) -> Bool {
        let place = Self.labelColor(p.text), road = Self.labelColor(p.textDim), water = Self.labelColor(p.accent, 0.8)
        let poi = Self.labelColor(p.textDim, 0.95), glyph = Self.labelColor(p.accent)
        let atlasSize = SIMD2(Float(MapLabelAtlas.width), Float(MapLabelAtlas.height))
        func uv(_ s: MapLabelAtlas.Slot) -> SIMD4<Float> {
            SIMD4(Float(s.x) / atlasSize.x, Float(s.y) / atlasSize.y, Float(s.x + s.w) / atlasSize.x, Float(s.y + s.h) / atlasSize.y)
        }
        for l in placed {
            // A label shows once its text and its glyph are both in the atlas.
            let text: MapLabelAtlas.Slot, icon: MapLabelAtlas.Slot?
            switch textSlot(l, &allowance) {
            case .ready(let s?): text = s
            case .ready(nil): continue
            case .later: labelWorkPending = true; continue
            case .full: return false
            }
            switch iconSlot(l, &allowance) {
            case .ready(let s): icon = s
            case .later: labelWorkPending = true; continue
            case .full: return false
            }
            if let icon {
                let half = SIMD2(Float(icon.w), Float(icon.h)) / 2
                let c = (SIMD2(Float(l.iconCenter.x * scale), Float(l.iconCenter.y * scale)) - half).rounded(.toNearestOrAwayFromZero) + half
                labelInstances.append(MapLabelInstance(center: c, half: half, uv: uv(icon), color: glyph, rot: SIMD2(1, 0)))
            }
            let half = SIMD2(Float(text.w), Float(text.h)) / 2
            var c = SIMD2(Float(l.center.x * scale), Float(l.center.y * scale))
            var rot = SIMD2<Float>(1, 0)
            if l.angle == 0 {
                // Level text sits on whole pixels (texels map 1:1, so it stays sharp).
                c = (c - half).rounded(.toNearestOrAwayFromZero) + half
            } else {
                rot = SIMD2(Float(cos(l.angle)), Float(sin(l.angle)))
            }
            let color: SIMD4<Float>
            switch l.style { case .place, .count: color = place; case .road: color = road; case .water: color = water; case .poi: color = poi }
            labelInstances.append(MapLabelInstance(center: c, half: half, uv: uv(text), color: color, rot: rot))
        }
        return true
    }

    private func textSlot(_ l: MapLabelPlanner.Placed, _ allowance: inout RasterAllowance) -> SlotLookup {
        if let s = atlas.cachedSlot(l.id) { return .ready(s) }
        guard allowance.take() else { return .later }
        guard let s = atlas.slot(l.id, text: planner.text(of: l.id), bold: l.style == .count, width: planner.width(of: l.id)) else { return .full }
        return .ready(s)
    }

    /// The glyph of a point of interest (`.ready(nil)`: the label has none).
    private func iconSlot(_ l: MapLabelPlanner.Placed, _ allowance: inout RasterAllowance) -> SlotLookup {
        guard l.icon != 0, let category = POICategory(rawValue: l.icon) else { return .ready(nil) }
        if let s = atlas.cachedIconSlot(category) { return .ready(s) }
        guard allowance.take() else { return .later }
        guard let s = atlas.iconSlot(category) else { return .full }
        return .ready(s)
    }

    // MARK: Uniforms and style

    private func style(palette: MapPalette, zoom: Double, glow: Bool, scale: Float) -> MapStyle {
        if let c = styleCache, c.zoom == zoom, c.glow == glow, c.scale == scale, c.palette == palette { return c.style }
        let style = MapStyle(palette: palette, zoom: zoom, glow: glow, scale: scale)
        styleCache = (palette, zoom, glow, scale, style)
        return style
    }

    /// Writes the frame's uniform blob: the three class tables and the scalars.
    private func fillUniforms(frame: MapFrame, proj: any MapScreenProjection, viewportPx: SIMD2<Float>, scale: Float, mode: MapFramePass.Mode) {
        let p = frame.palette
        let cam = proj.camera
        let flat = !mode.pitched
        var s = MapFrameScalars()
        let blended = proj as? BlendedProjection
        if let flatProj = (proj as? MapProjection) ?? blended?.flat { s.invCenteredVP = Self.centeredInverse(flatProj) }
        if let g = (proj as? GlobeProjection) ?? blended?.globe {
            func f(_ m: simd_double4x4) -> simd_float4x4 {
                simd_float4x4(columns: (SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1), SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3)))
            }
            s.globeVP = f(g.shaderMatrix)
            s.invGlobeVP = f(g.inverse)
            s.invRot = f(GlobeProjection.embed(g.inverseRotation))
            s.globe = SIMD4(1, Float(g.lon0), Float(g.horizonZ), Float(blended?.t ?? 0))
            let r = g.rotation
            s.rotZRow = SIMD4(Float(r[0][2]), Float(r[1][2]), Float(r[2][2]), 0)
        }
        s.bg0 = p.bg0; s.bg3 = p.bg3; s.accent = p.accent; s.glow = p.glow; s.text = p.text; s.line = p.line
        s.roof = flat ? mapMix(p.bg1, p.accent, 0.06) : mapMix(p.bg1, p.accent, 0.13)
        s.wall = mapMix(p.bg1, p.accent, 0.05)
        s.viewportPx = viewportPx
        s.scale = scale
        s.pitch = Float(cam.pitch)
        s.zoom = Float(cam.zoom)
        s.revealY = frame.reveal >= 1 ? 1e9 : max(0, frame.reveal) * viewportPx.y
        s.flat = flat ? 1 : 0
        s.glowOn = frame.glow ? 1 : 0
        if mode.shade {
            let l = mode.terrain3D ? frame.lift : .flat
            s.terrain = SIMD4(l.scale, l.base, l.ceiling, 1)
            // Relief reads at every zoom: steeper exaggeration for the shading as you zoom out.
            let shadeExaggeration = Float(min(2, max(1.2, 1.2 + (13 - cam.zoom) * 0.2)))
            s.depthK = SIMD4(Float(Self.depthFactor(cam: cam, viewport: proj.viewport)), 0.006, shadeExaggeration, frame.gridFloor ? 1 : 0)
            s.tint = SIMD4(frame.terrainFloor, 2600, 0.15, 0)
        }
        if frame.gridFloor && !(proj is GlobeProjection) {
            // A power-of-two Mercator lattice: minor cells 1/8 tile at floor(zoom) (32…64 pt), majors every 4.
            let zi = cam.zoom.rounded(.down)
            let minorPt = 256 * pow(2, cam.zoom - zi) / 8
            let majorPt = minorPt * 4
            s.gridMinorPx = Float(minorPt) * scale
            s.gridMajorPx = Float(majorPt) * scale
            let cx = cam.center.x * proj.worldScale * Double(scale), cy = cam.center.y * proj.worldScale * Double(scale)
            let mnPx = Double(s.gridMinorPx), mjPx = Double(s.gridMajorPx)
            s.phaseMinor = SIMD2(Float(cx.truncatingRemainder(dividingBy: mnPx)), Float(cy.truncatingRemainder(dividingBy: mnPx)))
            s.phaseMajor = SIMD2(Float(cx.truncatingRemainder(dividingBy: mjPx)), Float(cy.truncatingRemainder(dividingBy: mjPx)))
            let t = Float(min(1, max(0, cam.pitch / MapCamera.maxPitch)))
            s.gridFadeStart = 1.0 + (0.45 - 1.0) * t
            s.gridFadeEnd = 1.4 + (1.15 - 1.4) * t
        }
        let style = style(palette: p, zoom: cam.zoom, glow: frame.glow, scale: scale)
        uniformBlob.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            func write(_ table: [SIMD4<Float>], at offset: Int) {
                table.withUnsafeBytes { src in
                    if let p = src.baseAddress { base.advanced(by: offset).copyMemory(from: p, byteCount: min(src.count, MapUniformLayout.tableBytes)) }
                }
            }
            write(style.fill, at: MapUniformLayout.fillColorOffset)
            write(style.lineStyle, at: MapUniformLayout.lineStyleOffset)
            write(style.lineColor, at: MapUniformLayout.lineColorOffset)
            base.advanced(by: MapUniformLayout.scalarsOffset).storeBytes(of: s, as: MapFrameScalars.self)
        }
    }

    /// far/(near − far) of the flat projection (MapProjection's perspective), for the ground's depth push.
    private static func depthFactor(cam: MapCamera, viewport: SIMD2<Double>) -> Double {
        let pitch = max(0, min(MapCamera.maxPitch, cam.pitch)) * .pi / 180
        let dist = 0.5 * viewport.y / tan(MapProjection.fovY / 2)
        let near = max(1, dist * 0.05)
        let far = dist / max(0.1, cos(pitch + MapProjection.fovY / 2 + 0.01)) * 1.5 + dist
        return far / (near - far)
    }

    /// Inverse of the projection without the world translation and scale: clip → points around the camera centre.
    private static func centeredInverse(_ proj: MapProjection) -> simd_float4x4 {
        let cam = proj.camera
        let w = proj.viewport.x, h = proj.viewport.y
        let pitch = max(0, min(MapCamera.maxPitch, cam.pitch)) * .pi / 180
        let bearing = cam.bearing * .pi / 180
        let dist = 0.5 * h / tan(MapProjection.fovY / 2)
        let near = max(1, dist * 0.05)
        let far = dist / max(0.1, cos(pitch + MapProjection.fovY / 2 + 0.01)) * 1.5 + dist
        let y = 1 / tan(MapProjection.fovY / 2), x = y / (w / h), z = far / (near - far)
        let p = simd_double4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
        var m = matrix_identity_double4x4
        let (cb, sb) = (cos(-bearing), sin(-bearing))
        m = simd_double4x4(columns: (SIMD4(cb, sb, 0, 0), SIMD4(-sb, cb, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))) * m
        let (cp, sp) = (cos(pitch), sin(pitch))
        m = simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, cp, sp, 0), SIMD4(0, -sp, cp, 0), SIMD4(0, 0, 0, 1))) * m
        var t = matrix_identity_double4x4; t.columns.3 = SIMD4(0, 0, -dist, 1)
        m = t * m
        m = simd_double4x4(diagonal: SIMD4(1, -1, 1, 1)) * m
        let inv = (p * m).inverse
        return simd_float4x4(columns: (SIMD4<Float>(inv.columns.0), SIMD4<Float>(inv.columns.1), SIMD4<Float>(inv.columns.2), SIMD4<Float>(inv.columns.3)))
    }

    // MARK: Overlays

    /// What the overlay builders share for one frame: the projection, the view, and the terms
    /// that place a marker in depth when the view is tilted.
    private struct OverlayContext {
        let frame: MapFrame
        let proj: any MapScreenProjection
        /// World → clip of the flat map (nil on the globe and mid-morph): the fast path for points.
        let flatMatrix: simd_double4x4?
        let viewport: SIMD2<Double>
        /// Pixels per point, as Double and Float.
        let scale: Double
        let s: Float
        /// Terrain is raised: points sit at their elevation.
        let lifted: Bool
        /// Tilted flat map: markers carry a depth and shrink with distance.
        let tilted: Bool
        /// Clip w at the centre of the view (a marker's nearness is relative to it).
        let centreW: Double
        let metersPerPoint: Double
        /// Unit vector on the ground towards the viewer, in world axes (y south).
        let toViewer: SIMD2<Double>
        let tiltCos: Double

        init(frame: MapFrame, proj: any MapScreenProjection, scale: Double) {
            self.frame = frame
            self.proj = proj
            self.scale = scale
            s = Float(scale)
            viewport = proj.viewport
            lifted = !frame.lift.isFlat
            let flat = proj as? MapProjection
            flatMatrix = flat?.viewProjection
            let cam = proj.camera
            tilted = flat != nil && cam.pitch > 2
            if tilted, let m = flatMatrix { centreW = (m * SIMD4(cam.center.x, cam.center.y, 0, 1)).w } else { centreW = 1 }
            metersPerPoint = TileMath.metersPerPoint(lat: TileMath.unproject(cam.center).lat, zoom: cam.zoom)
            let bearing = cam.bearing * .pi / 180
            toViewer = SIMD2(-sin(bearing), cos(bearing))
            tiltCos = max(0.3, cos(cam.pitch * .pi / 180))
        }

        /// Within 80 points of the view (markers and their halos reach that far at most).
        func onScreen(_ q: SIMD2<Double>) -> Bool {
            let margin = 80.0
            return q.x > -margin && q.y > -margin && q.x < viewport.x + margin && q.y < viewport.y + margin
        }

        func pixels(_ q: SIMD2<Double>) -> SIMD2<Float> { SIMD2(Float(q.x * scale), Float(q.y * scale)) }

        /// Screen point of a world point `height` metres above the ground plane. The same maths
        /// as `MapProjection.screen`, without the protocol call or the latitude term at height 0.
        func project(_ w: Mercator, height: Double) -> SIMD2<Double>? {
            guard let m = flatMatrix else { return proj.screen(w, heightMeters: height) }
            let z = height == 0 ? 0 : height * MapProjection.worldUnitsPerMeter(y: w.y)
            let c = m * SIMD4(w.x, w.y, z, 1)
            guard c.w > 1e-9 else { return nil }
            return SIMD2((c.x / c.w + 1) / 2 * viewport.x, (1 - c.y / c.w) / 2 * viewport.y)
        }

        /// Screen point of a world point on the terrain (the same lift the GPU applies).
        func screen(_ w: Mercator) -> SIMD2<Double>? { project(w, height: frame.elevation(at: w)) }

        /// Whether anything inside a world box can come within `margin` points of the view.
        /// Always true where the projection isn't a plain matrix, or the box reaches behind the camera.
        func mayShow(lo: SIMD2<Double>, hi: SIMD2<Double>, margin: Double) -> Bool {
            guard let m = flatMatrix else { return true }
            // Raised terrain: the box spans every height its points can be drawn at.
            let low = lifted ? frame.lift.lift(0) : 0, high = lifted ? frame.lift.lift(9000) : 0
            var slo = SIMD2<Double>(repeating: .infinity), shi = -slo
            for corner in 0..<4 {
                let x = corner & 1 == 0 ? lo.x : hi.x, y = corner & 2 == 0 ? lo.y : hi.y
                let wupm = lifted ? MapProjection.worldUnitsPerMeter(y: y) : 0
                for level in 0..<(lifted ? 2 : 1) {
                    let c = m * SIMD4(x, y, (level == 0 ? low : high) * wupm, 1)
                    guard c.w > 1e-9 else { return true }
                    let q = SIMD2((c.x / c.w + 1) / 2 * viewport.x, (1 - c.y / c.w) / 2 * viewport.y)
                    slo = simd_min(slo, q); shi = simd_max(shi, q)
                }
            }
            return shi.x > -margin && shi.y > -margin && slo.x < viewport.x + margin && slo.y < viewport.y + margin
        }

        /// A ground marker's depth (so hills and buildings in front hide it; 0 = always shown)
        /// and how near it is relative to the centre of the view (1 there, smaller further away).
        /// `reachPts` is the marker's half size on screen: the depth is taken that far towards
        /// the viewer (and a little above the ground), because the quad's lower half covers
        /// ground nearer than the marker, which must not cut it; a ridge or building in front
        /// still hides it.
        func depthAndNearness(_ w: Mercator, _ h: Double, reachPts: Double = 12) -> (depth: Float, nearness: Double) {
            guard tilted, let m = flatMatrix else { return (0, 1) }
            let wpm = MapProjection.worldUnitsPerMeter(y: w.y)
            let c0 = m * SIMD4(w.x, w.y, h * wpm, 1)
            guard c0.w > 1e-9 else { return (0, 1) }
            let near = centreW / c0.w
            let meters = (reachPts + 4) * metersPerPoint / max(0.05, near) / tiltCos
            let d = toViewer * meters * wpm
            let c = m * SIMD4(w.x + d.x, w.y + d.y, (h + 30) * wpm, 1)
            guard c.w > 1e-9 else { return (0, near) }
            return (Float(min(1, max(0, c.z / c.w))), near)
        }
    }

    /// One camera in view: where it is on screen and in depth.
    private struct ProjectedCamera {
        /// Index into `frame.cameras`.
        var index: Int
        var point: SIMD2<Double>
        var height: Double
        var depth: Float
        var nearness: Double
    }

    /// Builds this frame's overlay instances (CPU-projected SDF quads), back to front: region
    /// outlines, routes, cameras, clusters, the user's position, route ends, the chosen place.
    private func buildOverlays(frame: MapFrame, proj: any MapScreenProjection, scale: Double) {
        overlayInstances.removeAll(keepingCapacity: true)
        captions.removeAll(keepingCapacity: true)
        let ctx = OverlayContext(frame: frame, proj: proj, scale: scale)
        addRegionOutlines(ctx)
        addRoutes(ctx)
        addCameras(ctx)
        addClusters(ctx)
        addLocation(ctx)
        addRouteMarks(ctx)
        addPin(ctx)
    }

    private func addOverlay(_ kind: MapOverlayKind, at c: SIMD2<Float>, size: SIMD2<Float>, color: SIMD4<Float>, p: SIMD4<Float> = .zero,
                            q: SIMD2<Float> = .zero, depth: Float = 0) {
        guard overlayInstances.count < Self.maxOverlayInstances else { return }
        overlayInstances.append(MapOverlayInstance(center: c, size: size, color: color, p: p, kind: kind.rawValue, q0: q.x, q1: q.y, q2: depth))
    }

    /// Region outlines: accent segments between projected ring points (dashed unless highlighted).
    private func addRegionOutlines(_ ctx: OverlayContext) {
        let s = ctx.s
        for (r, region) in ctx.frame.regions.enumerated() {
            var color = ctx.frame.palette.accent
            color.w *= region.highlighted ? 0.95 : 0.55
            let dash: Float = region.highlighted ? 0 : 4 * s
            func segment(_ a: SIMD2<Double>?, _ b: SIMD2<Double>?) {
                guard let a, let b else { return }
                let d = b - a
                let length = simd_length(d)
                // Only the part in view is drawn: an edge that crosses the view with both ends far
                // outside still shows, and the quad stays small however long the edge is.
                guard length > 0.01, length.isFinite, let (t0, t1) = Self.clip(a, b, to: ctx.viewport, margin: 80) else { return }
                let shown = length * (t1 - t0)
                guard shown > 0.01 else { return }
                // The dashes keep their place along the whole edge.
                let phase = dash > 0 ? Float((length * t0 * ctx.scale).truncatingRemainder(dividingBy: Double(2 * dash))) : 0
                addOverlay(.segment, at: ctx.pixels(a + d * ((t0 + t1) / 2)), size: SIMD2(Float(shown * ctx.scale) + 4 * s, 4 * s), color: color,
                           p: SIMD4(Float(atan2(d.y, d.x)), Float(shown * ctx.scale / 2), dash, phase))
            }
            for (k, ring) in region.rings.enumerated() where ring.count >= 2 {
                guard regionRuns.indices.contains(r), regionRuns[r].indices.contains(k) else { continue }
                var previous: SIMD2<Double>?
                for run in regionRuns[r][k].runs.indices {
                    let bounds = regionRuns[r][k].runs[run]
                    guard ctx.mayShow(lo: bounds.lo, hi: bounds.hi, margin: 80) else { previous = nil; continue }
                    if ctx.lifted { regionRuns[r][k].prepareHeights(run: run, points: ring, frame: ctx.frame) }
                    // A run starts on the last point of the one before it.
                    for i in (previous == nil ? bounds.first : bounds.first + 1)...bounds.last {
                        let q = ctx.project(ring[i], height: ctx.lifted ? regionRuns[r][k].lift(at: i, ctx.frame.lift) : 0)
                        segment(previous, q)
                        previous = q
                    }
                }
                // The closing edge (two points make one segment, not two).
                if ring.count > 2 { segment(ctx.screen(ring[ring.count - 1]), ctx.screen(ring[0])) }
            }
        }
    }

    /// The part of the segment a→b inside the view grown by `margin`, as parameters 0…1 along
    /// it (Liang–Barsky); nil when it misses the view.
    private static func clip(_ a: SIMD2<Double>, _ b: SIMD2<Double>, to viewport: SIMD2<Double>, margin: Double) -> (Double, Double)? {
        var t0 = 0.0, t1 = 1.0
        let d = b - a
        for axis in 0..<2 {
            let fromLow = a[axis] + margin, toHigh = viewport[axis] + margin - a[axis]
            if d[axis] == 0 {
                if fromLow < 0 || toHigh < 0 { return nil }
                continue
            }
            let atLow = -fromLow / d[axis], atHigh = toHigh / d[axis]
            t0 = max(t0, min(atLow, atHigh))
            t1 = min(t1, max(atLow, atHigh))
            if !(t0 <= t1) { return nil }
        }
        return (t0, t1)
    }

    /// Routes: the alternative dim and dashed, the chosen one bright with a glow (on the terrain).
    private func addRoutes(_ ctx: OverlayContext) {
        let p = ctx.frame.palette, s = ctx.s, vp = ctx.viewport
        for (r, route) in ctx.frame.routes.enumerated() where route.points.count >= 2 && routeRuns.indices.contains(r) {
            var color = route.primary ? (p.route ?? p.accent) : p.textMute
            color.w = route.primary ? 1 : 0.75
            let half: Float = (route.primary ? 2.0 : 1.3) * s
            let glow: Float = route.primary && ctx.frame.glow ? 4 * s : 0
            let dash: Float = route.primary ? 0 : 5 * s
            /// How far the band and its glow reach from the centre line, in points.
            let reach = Double(half + glow) / ctx.scale + 2
            var previous: SIMD2<Double>?
            /// Pixels along the route so far (the dash phase).
            var along: Float = 0
            for run in routeRuns[r].runs.indices {
                let bounds = routeRuns[r].runs[run]
                guard ctx.mayShow(lo: bounds.lo, hi: bounds.hi, margin: reach) else {
                    // Out of view: none of its points are projected; the dashes move on by its length.
                    along += Float(bounds.worldLength * ctx.proj.worldScale * ctx.scale)
                    previous = nil
                    continue
                }
                if ctx.lifted { routeRuns[r].prepareHeights(run: run, points: route.points, frame: ctx.frame) }
                // A run starts on the last point of the one before it.
                for i in (previous == nil ? bounds.first : bounds.first + 1)...bounds.last {
                    let height = ctx.lifted ? routeRuns[r].lift(at: i, ctx.frame.lift) : 0
                    guard let q = ctx.project(route.points[i], height: height) else { previous = nil; continue }
                    guard let a = previous else { previous = q; continue }
                    let d = q - a
                    let length = simd_length(d)
                    if length < 1.5 { continue }          // sub-pixel steps: merge into the next segment
                    previous = q
                    let lengthPx = Float(length * ctx.scale)
                    defer { along += lengthPx }
                    let lo = simd_min(a, q) - reach, hi = simd_max(a, q) + reach
                    guard hi.x > 0, hi.y > 0, lo.x < vp.x, lo.y < vp.y, length < 50_000 else { continue }
                    let halfLength = lengthPx / 2
                    addOverlay(.route, at: ctx.pixels((a + q) / 2),
                               size: SIMD2(2 * halfLength + 2 * (half + glow) + 2 * s, 2 * (half + glow) + 2 * s), color: color,
                               p: SIMD4(Float(atan2(d.y, d.x)), halfLength, half, dash), q: SIMD2(along, glow))
                }
            }
        }
    }

    /// ALPR cameras: FOV wedges lying on the ground (foreshortened when tilted) under the reticles.
    private func addCameras(_ ctx: OverlayContext) {
        let frame = ctx.frame
        guard !frame.cameras.isEmpty else { return }
        let p = frame.palette, s = ctx.s, scale = ctx.scale
        projectedCameras.removeAll(keepingCapacity: true)
        for (i, c) in frame.cameras.enumerated() {
            let h = frame.elevation(at: c.world)
            guard let q = ctx.project(c.world, height: h), ctx.onScreen(q) else { continue }
            let (depth, nearness) = ctx.depthAndNearness(c.world, h)
            projectedCameras.append(ProjectedCamera(index: i, point: q, height: h, depth: depth, nearness: nearness))
        }
        // Radius: 14…48 pt at the centre of the view, as a ground distance.
        let radiusM = min(48, max(14, 40 / max(0.01, ctx.metersPerPoint))) * ctx.metersPerPoint
        let wedge = p.accent   // fill 28% and arc 85% are applied in the shader
        for pc in projectedCameras {
            let c = frame.cameras[pc.index]
            // Far wedges (towards the horizon when tilted) are a few pixels of noise: skip them.
            guard !c.directions.isEmpty, pc.nearness >= 0.35 else { continue }
            // Screen images of the radius pointing east and north (a local linear map).
            let radius = MapProjection.worldUnitsPerMeter(y: c.world.y) * radiusM
            guard let e = ctx.project(Mercator(x: c.world.x + radius, y: c.world.y), height: pc.height),
                  let n = ctx.project(Mercator(x: c.world.x, y: c.world.y - radius), height: pc.height) else { continue }
            let ev = (e - pc.point) * scale, nv = (n - pc.point) * scale
            guard ev.x.isFinite, nv.x.isFinite else { continue }
            let half = SIMD2(abs(ev.x) + abs(nv.x), abs(ev.y) + abs(nv.y))
            let size = SIMD2(Float(min(400, half.x)) * 2 + 4 * s, Float(min(400, half.y)) * 2 + 4 * s)
            // The wedge lies on the ground and reaches its radius towards the viewer.
            let wedgeDepth = pc.depth == 0 ? 0 : ctx.depthAndNearness(c.world, pc.height, reachPts: min(400, half.y) / scale).depth
            for d in c.directions {
                addOverlay(.wedge, at: ctx.pixels(pc.point), size: size, color: wedge, p: SIMD4(Float(ev.x), Float(ev.y), Float(nv.x), Float(nv.y)),
                           q: SIMD2(Float(d) * .pi / 180, .pi / 6), depth: wedgeDepth)
            }
        }
        // Nearest drawn last (on top). Further away they shrink (to 45%) and fade, so the horizon
        // of a tilted view doesn't fill with full-size reticles. Untilted, all are equally near.
        if ctx.tilted { projectedCameras.sort { $0.nearness < $1.nearness } }
        for pc in projectedCameras {
            let c = frame.cameras[pc.index]
            let k = Float(min(1, max(0.45, pc.nearness)))
            var color = c.onRoute ? p.warn : p.accent
            color.w = (c.isFlock ? 1.0 : 0.7) * (c.selected ? 1 : Float(min(1, max(0.25, (pc.nearness - 0.15) / 0.6))))
            let side: Float = 13 * s * (c.selected ? 1 : k)
            addOverlay(.reticle, at: ctx.pixels(pc.point), size: SIMD2(repeating: side + 4 * s + (c.selected ? 8 * s : 0)), color: color,
                       p: SIMD4(0, c.selected ? 1 : 0, 0, 0), depth: c.selected ? 0 : pc.depth)
        }
    }

    /// Clusters: ▣ blocks, each with its count as a label beside it.
    private func addClusters(_ ctx: OverlayContext) {
        let s = ctx.s, vp = ctx.viewport
        for c in ctx.frame.clusters {
            let h = ctx.frame.elevation(at: c.world)
            guard let q = ctx.project(c.world, height: h), ctx.onScreen(q) else { continue }
            let side = Self.clusterSide(c.count)
            let depth = ctx.depthAndNearness(c.world, h, reachPts: side / 2 + 2).depth
            addOverlay(.cluster, at: ctx.pixels(q), size: SIMD2(repeating: Float(side) * s + 2 * s), color: ctx.frame.palette.accent, depth: depth)
            if c.count > 0, q.x > -40, q.y > -20, q.x < vp.x + 40, q.y < vp.y + 20 {
                captions.append((cachedCountText(c.count), SIMD2(q.x + side / 2 + 3, q.y)))
            }
        }
    }

    /// You: accuracy ring and dot.
    private func addLocation(_ ctx: OverlayContext) {
        guard let l = ctx.frame.location, let q = ctx.screen(l.world), ctx.onScreen(q) else { return }
        let s = ctx.s, accent = ctx.frame.palette.accent
        let r = Float(max(6, l.accuracyMeters / max(0.01, ctx.metersPerPoint))) * s
        var ring = accent; ring.w = 0.5
        addOverlay(.ring, at: ctx.pixels(q), size: SIMD2(repeating: r * 2 + 4 * s), color: ring, p: SIMD4(1 * s, 0, 0, 0))
        addOverlay(.locationDot, at: ctx.pixels(q), size: SIMD2(repeating: 22 * s), color: accent)
    }

    /// Route ends (A, B) and the step under the pointer.
    private func addRouteMarks(_ ctx: OverlayContext) {
        let s = ctx.s, p = ctx.frame.palette
        for m in ctx.frame.routeMarks {
            guard let q = ctx.screen(m.world), ctx.onScreen(q) else { continue }
            addOverlay(.pin, at: ctx.pixels(q), size: SIMD2(repeating: 20 * s), color: p.accent)
            captions.append((m.label, SIMD2(q.x + 12, q.y)))
        }
        if let w = ctx.frame.stepMark, let q = ctx.screen(w), ctx.onScreen(q) {
            var ring = p.text; ring.w = 0.9
            addOverlay(.ring, at: ctx.pixels(q), size: SIMD2(repeating: 26 * s), color: ring, p: SIMD4(1.6 * s, 0, 0, 0))
        }
    }

    /// The chosen place: a diamond pin, its name beside it (placed before every other label).
    private func addPin(_ ctx: OverlayContext) {
        guard let pin = ctx.frame.pin, let q = ctx.screen(pin.world), ctx.onScreen(q) else { return }
        addOverlay(.pin, at: ctx.pixels(q), size: SIMD2(repeating: 24 * ctx.s), color: ctx.frame.palette.accent)
        captions.append((MapLabelPlanner.display(pin.title, kind: .place), SIMD2(q.x + 14, q.y)))
    }

    private func cachedCountText(_ n: Int) -> String {
        if let t = countTexts[n] { return t }
        if countTexts.count > 4096 { countTexts.removeAll(keepingCapacity: true) }
        let t = Self.countText(n)
        countTexts[n] = t
        return t
    }

    /// A cluster's count as drawn: 1…999 as is, then "1.2K", then "12K".
    static func countText(_ n: Int) -> String {
        if n >= 10_000 { return "\(n / 1000)K" }
        if n >= 1000 { return String(format: "%.1fK", Double(n) / 1000) }
        return "\(n)"
    }

    /// Side of a cluster block in points for a count (grows slowly with log2).
    static func clusterSide(_ count: Int) -> Double {
        10 + min(8, log2(Double(max(1, count)))) * 1.5
    }

    // MARK: Offscreen

    /// Renders the current frame into an offscreen texture and returns it as an image (printing,
    /// and QA). Blocks until the GPU finishes.
    func renderImage(size: CGSize, scale: Double = 2) -> CGImage? {
        guard let frame, let camera else { return nil }
        let width = size.width * scale, height = size.height * scale
        // Up to 16384 pixels a side (the largest texture every Mac GPU takes).
        guard width.isFinite, height.isFinite, width >= 1, height >= 1, width <= 16384, height <= 16384 else { return nil }
        let w = Int(width), h = Int(height)
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MapPipelines.colorFormat, width: w, height: h, mipmapped: false)
        cd.usage = [.renderTarget]; cd.storageMode = .shared
        // Multisampled targets (the pipelines draw at MapPipelines.sampleCount), resolved into `color`.
        guard let color = pipes.device.makeTexture(descriptor: cd),
              let msaa = makeMultisampleTarget(MapPipelines.colorFormat, width: w, height: h),
              let depth = makeMultisampleTarget(MapPipelines.depthFormat, width: w, height: h) else { return nil }
        let pass = MTLRenderPassDescriptor()
        configure(pass, color: msaa, depth: depth, resolvingInto: color, clear: frame.palette.bg0)
        // One image: every label is rasterised now.
        let prepared = prepare(frame: frame, camera: camera, drawableSize: CGSize(width: w, height: h), scale: scale, labelRasterBudget: .infinity)
        guard let cmd = encode(prepared, into: pass) else { return nil }
        cmd.commit()
        cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let p = raw.baseAddress else { return }
            color.getBytes(p, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: - Render pass

/// The GPU commands of one frame, pass by pass. Tiles are drawn deepest level first; each level
/// then writes a stencil mask so the ancestors standing in around it don't draw over it.
@MainActor
private final class MapFramePass {
    /// What this frame draws, decided once from the camera and the frame's switches.
    struct Mode {
        /// Fully a globe: the sphere, oceans and lines only (no land fills, masks or buildings).
        var globe: Bool
        /// Buildings stand up (tilted view), tested against each other in depth.
        var pitched: Bool
        /// Shaded relief (and the lattice draped over it) is drawn.
        var shade: Bool
        /// The ground is raised: everything on it is tested against its depth.
        var terrain3D: Bool
        /// The flat grid lattice is drawn (with relief on, it is draped in the relief pass instead).
        var lattice: Bool
        /// A light (paper) palette: lines blend source-over, since max blending can't darken white.
        var lightBackground: Bool
    }

    /// Where every shader finds the frame uniforms (`FrameU`).
    static let frameUniformsVertexIndex = 2, frameUniformsFragmentIndex = 0
    /// Fragment buffer 1: the class being filled or the floor's mode (`DrawU`), or the tile (`TileU`) in the relief pass.
    private static let drawUniformsIndex = 1
    private static let tileUniformsIndex = 1

    /// Fill order: tints first, water over them, footprints last.
    private static let fillOrder: [RenderClass] = [.landuse, .park, .aeroway, .water, .waterway, .building]
    /// Line order: shoreline and rivers under the road hierarchy; boundaries on top.
    private static let lineOrder: [RenderClass] = [.contour, .contourIndex, .water, .waterway, .path, .rail, .service, .minor, .tertiary, .secondary, .primary, .trunk, .motorway, .aeroway, .boundary]

    private let enc: MTLRenderCommandEncoder
    private let pipes: MapPipelines
    private let mode: Mode
    /// The elevation texture bound for the vertex stage (most draws in a row share one).
    private var boundDEM: MTLTexture?

    init(encoder: MTLRenderCommandEncoder, pipes: MapPipelines, mode: Mode) {
        enc = encoder
        self.pipes = pipes
        self.mode = mode
        bindDEM(pipes.zeroDEM)
    }

    private func bindDEM(_ texture: MTLTexture) {
        guard boundDEM !== texture else { return }
        enc.setVertexTexture(texture, index: 0)
        boundDEM = texture
    }

    private func setDrawUniform(_ value: UInt32) {
        var v = value
        enc.setFragmentBytes(&v, length: MemoryLayout<UInt32>.stride, index: Self.drawUniformsIndex)
    }

    private func bindTileUniforms(_ t: GPUTile) {
        enc.setVertexBytes(&t.uniforms, length: MemoryLayout<MapTileUniforms>.stride, index: Self.tileUniformsIndex)
    }

    private func drawBatch(_ t: GPUTile, _ b: GPUTile.Batch) {
        bindDEM(t.dem ?? pipes.zeroDEM)
        enc.setVertexBuffer(t.buffer, offset: b.vertexOffset, index: 0)
        bindTileUniforms(t)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: b.indexCount, indexType: .uint32, indexBuffer: t.buffer, indexBufferOffset: b.indexOffset)
    }

    private func drawFullScreenTriangle() {
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private var linePipeline: MTLRenderPipelineState { mode.lightBackground ? pipes.lineOver : pipes.line }

    // MARK: Passes

    /// The void behind the map with the reveal band (and, on the globe, the sphere's body).
    func backdrop() {
        enc.setDepthStencilState(pipes.dsNone)
        enc.setRenderPipelineState(pipes.floor)
        setDrawUniform(0)
        drawFullScreenTriangle()
    }

    /// The globe: oceans over the land-coloured sphere, then lines on the facing side. No land
    /// fills (large low-zoom triangles would cut through the sphere), no ancestor masks, no buildings.
    func globe(_ levels: [[GPUTile]]) {
        enc.setDepthStencilState(pipes.dsNone)
        // Opaque, shallowest level first, so overlapping levels don't show.
        enc.setRenderPipelineState(pipes.fill)
        for level in levels.reversed() {
            for cls in [RenderClass.water, .waterway] {
                setDrawUniform(UInt32(cls.rawValue))
                for t in level { for b in t.fills where b.cls == cls.rawValue { drawBatch(t, b) } }
            }
        }
        enc.setRenderPipelineState(linePipeline)
        for level in levels.reversed() {
            for cls in Self.lineOrder {
                for t in level { for b in t.lines where b.cls == cls.rawValue { drawBatch(t, b) } }
            }
        }
    }

    /// One level's ground: the raised terrain (3D), the fills, the relief, then the level's mask
    /// (stencil bit 0) so shallower levels stay out of its tiles. Water marks bit 1.
    func ground(_ level: [GPUTile]) {
        enc.setStencilReferenceValue(0)
        if mode.terrain3D {
            enc.setDepthStencilState(pipes.dsGround3D)
            drawTerrain(level, pipes.terrainGround, skirts: true)
        }
        enc.setRenderPipelineState(pipes.fill)
        for cls in Self.fillOrder {
            let water = cls == .water || cls == .waterway
            var bound = false
            for t in level {
                for b in t.fills where b.cls == cls.rawValue {
                    if !bound {
                        setDrawUniform(UInt32(cls.rawValue))
                        enc.setDepthStencilState(mode.terrain3D ? (water ? pipes.dsWater3D : pipes.dsFill3D) : (water ? pipes.dsWater : pipes.dsFill))
                        enc.setStencilReferenceValue(water ? 2 : 0)
                        bound = true
                    }
                    drawBatch(t, b)
                }
            }
        }
        enc.setStencilReferenceValue(0)
        if mode.shade {
            // Relief and the draped lattice above this level's fills (off water, under deeper levels).
            enc.setDepthStencilState(mode.terrain3D ? pipes.dsShade3D : pipes.dsShade)
            drawTerrain(level, pipes.terrainShade, skirts: false)
        }
        writeLevelMask(level, pipes.dsFillWrite)
    }

    /// The grid lattice above the land tints, kept off water by the stencil.
    func lattice() {
        guard mode.lattice else { return }
        enc.setDepthStencilState(pipes.dsLattice)
        enc.setRenderPipelineState(pipes.lattice)
        setDrawUniform(1)
        drawFullScreenTriangle()
    }

    /// One level's lines and buildings, then its mask (stencil bit 2).
    func linesAndBuildings(_ level: [GPUTile]) {
        enc.setRenderPipelineState(linePipeline)
        let contourState = mode.terrain3D ? pipes.dsContour3D : pipes.dsContour
        let lineState = mode.terrain3D ? pipes.dsLine3D : pipes.dsLine
        var current: MTLDepthStencilState?
        for cls in Self.lineOrder {
            // Contours also stay off water.
            let wanted = cls == .contour || cls == .contourIndex ? contourState : lineState
            for t in level {
                for b in t.lines where b.cls == cls.rawValue {
                    if current !== wanted { enc.setDepthStencilState(wanted); current = wanted }
                    drawBatch(t, b)
                }
            }
        }
        if level.contains(where: { $0.extrusion != nil }) {
            enc.setDepthStencilState(mode.pitched ? pipes.dsExtrusion : pipes.dsLine)
            enc.setRenderPipelineState(pipes.extrusion)
            for t in level {
                if let b = t.extrusion { drawBatch(t, b) }
            }
        }
        writeLevelMask(level, pipes.dsLineWrite)
    }

    /// Overlays: instanced SDF quads, tested against the depth of the ground and buildings.
    func overlays(_ instances: MTLBuffer, count: Int) {
        enc.setDepthStencilState(pipes.dsOverlay)
        enc.setRenderPipelineState(pipes.overlay)
        enc.setVertexBuffer(instances, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
    }

    /// Labels: instanced quads from the atlas, over everything.
    func labels(_ instances: MTLBuffer, count: Int, atlas: MTLTexture) {
        enc.setDepthStencilState(pipes.dsNone)
        enc.setRenderPipelineState(pipes.label)
        enc.setVertexBuffer(instances, offset: 0, index: 0)
        enc.setFragmentTexture(atlas, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
    }

    // MARK: Pieces

    /// One terrain mesh per tile of a level (grid only, or with skirts for the 3D ground).
    private func drawTerrain(_ level: [GPUTile], _ pipeline: MTLRenderPipelineState, skirts: Bool) {
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(pipes.terrainMesh, offset: 0, index: 0)
        let indexCount = skirts ? pipes.terrainIndexCount : pipes.terrainGridIndexCount
        for t in level {
            let dem = t.dem ?? pipes.zeroDEM
            bindDEM(dem)
            enc.setFragmentTexture(dem, index: 0)
            bindTileUniforms(t)
            enc.setFragmentBytes(&t.uniforms, length: MemoryLayout<MapTileUniforms>.stride, index: Self.tileUniformsIndex)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint16, indexBuffer: pipes.terrainIndices, indexBufferOffset: 0)
        }
    }

    /// Sets a stencil bit (chosen by `state`) over every tile of a level.
    private func writeLevelMask(_ level: [GPUTile], _ state: MTLDepthStencilState) {
        enc.setDepthStencilState(state)
        enc.setStencilReferenceValue(0xFF)
        defer { enc.setStencilReferenceValue(0) }
        if mode.terrain3D {
            // The displaced footprint, so ancestors are masked where the tile actually draws.
            drawTerrain(level, pipes.terrainMask, skirts: false)
            return
        }
        enc.setRenderPipelineState(pipes.stencil)
        enc.setVertexBuffer(pipes.unitQuad, offset: 0, index: 0)
        bindDEM(pipes.zeroDEM)
        for t in level {
            bindTileUniforms(t)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }
}

/// Per-class colour and width tables for one frame (theme + zoom + glow), in pixels.
struct MapStyle {
    var fill: [SIMD4<Float>]
    var lineStyle: [SIMD4<Float>]   // x half width px, y glow px, z glow strength, w dash px
    var lineColor: [SIMD4<Float>]

    init(palette p: MapPalette, zoom: Double, glow: Bool, scale: Float) {
        var fill = [SIMD4<Float>](repeating: .zero, count: mapClassTableCount)
        var style = [SIMD4<Float>](repeating: .zero, count: mapClassTableCount)
        var color = [SIMD4<Float>](repeating: .zero, count: mapClassTableCount)
        // Width factor: roads grow with zoom, slower than the map itself. Hairline threads at low zoom.
        let wf = Float(min(2.2, max(0.5, pow(2, (zoom - 14) * 0.42))))
        func setFill(_ c: RenderClass, _ col: SIMD4<Float>, _ a: Float) { var v = col; v.w = a; fill[Int(c.rawValue)] = v }
        func setLine(_ c: RenderClass, hw: Float, _ col: SIMD4<Float>, alpha: Float, glow g: Float, dash: Float = 0) {
            let half = max(0.4, hw * wf) * scale
            let glowPx: Float = glow && g > 0 ? (1.5 + hw * wf * 1.6) * scale : 0
            style[Int(c.rawValue)] = SIMD4(half, glowPx, g, dash * scale)
            var v = col; v.w = alpha; color[Int(c.rawValue)] = v
        }
        let water = mapMix(p.bg3, p.bg0, 0.5)   // the darkest surface: land tints sit above it
        setFill(.water, water, 1)
        setFill(.waterway, water, 1)
        setFill(.landuse, mapMix(p.bg1, p.accent, 0.05), 0.75)
        setFill(.park, mapMix(p.bg1, p.ok, 0.07), 0.75)
        setFill(.building, p.bg2, 0.9)
        setFill(.aeroway, mapMix(p.bg2, p.textMute, 0.1), 0.8)

        // Thin bright cores with a soft halo for the top three classes only; everything below is
        // pure accent at falling alpha, no glow, so a city at z13 reads as a graded lattice.
        // On the globe the coastline is what shows the land, so it is a brighter, glowing thread.
        // (blended across the globe → flat morph so nothing pops).
        let flatness = Float(MapCamera(center: Mercator(x: 0.5, y: 0.5), zoom: zoom).flatness)
        setLine(.water, hw: 0.5 - 0.05 * flatness, p.accent, alpha: 0.85 - 0.5 * flatness, glow: 0.5 * (1 - flatness))
        setLine(.waterway, hw: 0.6, mapMix(p.accent, p.bg3, 0.45), alpha: 0.6, glow: 0)
        setLine(.path, hw: 0.25, p.textMute, alpha: 0.35, glow: 0, dash: 3)
        setLine(.rail, hw: 0.35, p.textMute, alpha: 0.45, glow: 0, dash: 6)
        setLine(.service, hw: 0.3, p.accent, alpha: 0.3, glow: 0)
        setLine(.minor, hw: 0.4, p.accent, alpha: 0.38, glow: 0)
        setLine(.tertiary, hw: 0.45, p.accent, alpha: 0.55, glow: 0)
        setLine(.secondary, hw: 0.55, p.accent, alpha: 0.7, glow: 0)
        setLine(.primary, hw: 0.65, p.accent, alpha: 0.95, glow: 0.45)
        setLine(.trunk, hw: 0.75, mapMix(p.accent, p.text, 0.15), alpha: 1, glow: 0.6)
        setLine(.motorway, hw: 0.85, mapMix(p.accent, p.text, 0.35), alpha: 1, glow: 0.7)
        setLine(.boundary, hw: 0.5, p.accent, alpha: 0.45, glow: 0, dash: 5)
        setLine(.aeroway, hw: 0.7, p.textDim, alpha: 0.6, glow: 0)
        // Contours: thin accent threads under the roads; every fifth (index) line brighter with a faint glow.
        setLine(.contour, hw: 0.3, p.accent, alpha: 0.2, glow: 0)
        setLine(.contourIndex, hw: 0.45, p.accent, alpha: 0.42, glow: 0.25)
        self.fill = fill; lineStyle = style; lineColor = color
    }
}

@inline(__always) func mapMix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> { a + (b - a) * t }
