import AppKit
import GridCore
import Metal
import MetalKit
import simd

// The GridMap renderer (docs/maps/IMPLEMENTATION.md Brief C). Draws one `MapFrame`: the grid
// floor, fills, glowing lines, extruded buildings and the overlay instances, on demand only.
// Tiles are uploaded once into one MTLBuffer each (LRU of 60) and placed per frame with the
// contract projection (`MapProjection.tileMatrix`); colours and widths are per-frame uniform
// tables indexed by `RenderClass.rawValue`, so theme and zoom changes never touch tile buffers.

/// Everything compiled once per process (shared by every map view on the same device).
private struct MapPipelines {
    let device: MTLDevice
    let floor, lattice, fill, stencil, line, extrusion, overlay: MTLRenderPipelineState
    // Stencil bit planes: 0x01 fill-phase level mask, 0x02 water, 0x04 line-phase level mask.
    let dsNone, dsFill, dsFillWrite, dsWater, dsLattice, dsLine, dsLineWrite, dsExtrusion: MTLDepthStencilState
    let unitQuad: MTLBuffer

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
              let extrusion = pso("ext_vertex", "ext_fragment", blend: false),
              let overlay = pso("overlay_vertex", "overlay_fragment", blend: true) else { return nil }
        self.floor = floor; self.lattice = lattice; self.fill = fill; self.stencil = stencil; self.line = line; self.extrusion = extrusion; self.overlay = overlay

        func ds(depth: Bool, stencil: MTLStencilDescriptor?) -> MTLDepthStencilState? {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = depth ? .less : .always
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
              let dsExtrusion = ds(depth: true, stencil: st(read: 0x04, write: 0)) else { return nil }
        self.dsNone = dsNone; self.dsFill = dsFill; self.dsFillWrite = dsFillWrite; self.dsWater = dsWater
        self.dsLattice = dsLattice; self.dsLine = dsLine; self.dsLineWrite = dsLineWrite; self.dsExtrusion = dsExtrusion

        let quad: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)]
        guard let q = device.makeBuffer(bytes: quad, length: quad.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared) else { return nil }
        unitQuad = q
    }
}

/// One tile's geometry on the GPU: a single buffer holding every batch at 256-byte offsets.
private final class GPUTile {
    struct Batch { let cls: UInt16; let vertexOffset: Int; let indexOffset: Int; let indexCount: Int }
    let id: TileID
    let buffer: MTLBuffer
    let fills: [Batch]
    let lines: [Batch]
    let extrusion: Batch?
    let labels: [LabelAnchor]
    let bytes: Int
    var lastUsed: UInt64 = 0
    /// Cached per-frame uniforms (rewritten every frame, read by the draw loops).
    var uniforms = MapTileUniforms(mvp: matrix_identity_float4x4, worldUnitsPerMeter: 0, tilePx: 0)

    init?(_ g: TileGeometry, device: MTLDevice) {
        // Layout pass: every array lands at a 256-byte aligned offset; batches with bad indices are skipped.
        struct Pending { let cls: UInt16; let vBytes: UnsafeRawBufferPointer; let iBytes: UnsafeRawBufferPointer; let indexCount: Int }
        func align(_ n: Int) -> Int { (n + 255) & ~255 }
        func valid(_ indices: [UInt32], vertexCount: Int) -> Bool {
            guard !indices.isEmpty, indices.count % 3 == 0, vertexCount > 0 else { return false }
            return indices.allSatisfy { Int($0) < vertexCount }
        }
        var total = 0
        var fillPlan: [(UInt16, Int, Int, Int, Int)] = []   // cls, vOff, iOff, fillIndex, indexCount
        var linePlan: [(UInt16, Int, Int, Int, Int)] = []
        var extPlan: (Int, Int, Int)? = nil
        for (i, f) in g.fills.enumerated() where valid(f.indices, vertexCount: f.positions.count) {
            let v = total; total = align(total + f.positions.count * MemoryLayout<SIMD2<Float>>.stride)
            let ix = total; total = align(total + f.indices.count * 4)
            fillPlan.append((f.cls.rawValue, v, ix, i, f.indices.count))
        }
        for (i, l) in g.lines.enumerated() where valid(l.indices, vertexCount: l.vertices.count) {
            let v = total; total = align(total + l.vertices.count * MemoryLayout<LineVertex>.stride)
            let ix = total; total = align(total + l.indices.count * 4)
            linePlan.append((l.cls.rawValue, v, ix, i, l.indices.count))
        }
        if let e = g.extrusion, valid(e.indices, vertexCount: e.vertices.count) {
            let v = total; total = align(total + e.vertices.count * MemoryLayout<ExtrusionVertex>.stride)
            let ix = total; total = align(total + e.indices.count * 4)
            extPlan = (v, ix, e.indices.count)
        }
        id = g.id
        labels = g.labels
        // A tile with nothing drawable (labels only) still gets a small buffer: it masks ancestors
        // through the stencil and contributes its labels.
        let length = max(256, total)
        guard length < 256 << 20, let buf = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
        let base = buf.contents()
        func copy<T>(_ a: [T], to offset: Int) {
            a.withUnsafeBytes { src in if let p = src.baseAddress { base.advanced(by: offset).copyMemory(from: p, byteCount: src.count) } }
        }
        var fb: [Batch] = [], lb: [Batch] = []
        for (cls, v, ix, i, n) in fillPlan { copy(g.fills[i].positions, to: v); copy(g.fills[i].indices, to: ix); fb.append(Batch(cls: cls, vertexOffset: v, indexOffset: ix, indexCount: n)) }
        for (cls, v, ix, i, n) in linePlan { copy(g.lines[i].vertices, to: v); copy(g.lines[i].indices, to: ix); lb.append(Batch(cls: cls, vertexOffset: v, indexOffset: ix, indexCount: n)) }
        if let (v, ix, n) = extPlan, let e = g.extrusion {
            copy(e.vertices, to: v); copy(e.indices, to: ix)
            extrusion = Batch(cls: RenderClass.building.rawValue, vertexOffset: v, indexOffset: ix, indexCount: n)
        } else { extrusion = nil }
        buffer = buf; fills = fb; lines = lb; bytes = length
    }
}

/// GPU time of the last completed frame, written from the command buffer's completion handler.
private final class FrameStats: @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Double = 0
    var gpuMs: Double { lock.withLock { ms } }
    func set(_ v: Double) { lock.withLock { ms = v } }
}

@MainActor
final class MapRenderer: NSObject, MTKViewDelegate {
    private let pipes: MapPipelines
    private let queue: MTLCommandQueue
    private weak var view: MTKView?
    private let stats = FrameStats()

    private var frame: MapFrame?
    /// The camera drawn: the latest of `frame.camera` and the view's in-progress gesture.
    private(set) var camera: MapCamera?
    private var tileGeneration = Int.min
    private var gpuTiles: [TileID: GPUTile] = [:]
    /// Tiles of the current frame grouped by zoom, deepest level first (draw order).
    private var levels: [[GPUTile]] = []
    private var useClock: UInt64 = 0
    static let maxGPUTiles = 60

    private var uniformBlob = [UInt8](repeating: 0, count: MapUniformLayout.totalBytes)
    private var overlayInstances: [MapOverlayInstance] = []
    private var overlayBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var overlayBufferIndex = 0
    private var inflight = DispatchSemaphore(value: 3)

    /// Drawing is wanted (window key and visible). While false, frames are kept and drawn once on resume.
    var isActive = true { didSet { if isActive && dirty { requestDraw() } } }
    private var dirty = false
    /// True while a drag is in progress (the view sets it); the label pass thins itself out.
    var dragging = false
    /// Called after each frame is encoded with the projection it used, for label placement.
    var onFrameDrawn: ((any MapScreenProjection, MapFrame) -> Void)?

    // QA readouts (§3.3 C).
    var gpuTileCount: Int { gpuTiles.count }
    var lastFrameGPUms: Double { stats.gpuMs }
    private(set) var frameCount = 0
    #if DEBUG
    /// Main-thread time spent encoding the last frame (uniforms, tile matrices, overlays, commands).
    private(set) var debugLastEncodeCPUms: Double = 0
    #endif

    #if DEBUG
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
        super.init()
        view.device = device
        view.colorPixelFormat = MapPipelines.colorFormat
        // The view only supplies the drawable: the multisampled colour and depth/stencil targets
        // are ours (see `targets`), memoryless on Apple GPUs, so 4× MSAA costs no memory.
        view.depthStencilPixelFormat = .invalid
        view.sampleCount = 1
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.clearDepth = 1
        view.clearStencil = 0
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = self
    }

    // MARK: Frame input

    /// Marks the view for display; uploads new tiles lazily (here, once per new TileID).
    func setFrame(_ f: MapFrame) {
        if f.tileGeneration != tileGeneration {
            gpuTiles.removeAll()
            tileGeneration = f.tileGeneration
        }
        frame = f
        camera = f.camera
        useClock &+= 1
        var byZoom: [UInt8: [GPUTile]] = [:]
        for t in f.tiles {
            let gpu: GPUTile
            if let g = gpuTiles[t.id] { gpu = g } else {
                guard let g = GPUTile(t, device: pipes.device) else { continue }
                gpuTiles[t.id] = g
                gpu = g
            }
            gpu.lastUsed = useClock
            byZoom[t.id.z, default: []].append(gpu)
        }
        levels = byZoom.keys.sorted(by: >).map { byZoom[$0]! }
        evict()
        requestDraw()
    }

    /// The view's in-progress gesture camera (frame.camera is authoritative when the model echoes it).
    func setCamera(_ c: MapCamera) {
        camera = c
        requestDraw()
    }

    private func evict() {
        guard gpuTiles.count > Self.maxGPUTiles else { return }
        let victims = gpuTiles.values.sorted { $0.lastUsed < $1.lastUsed }.prefix(gpuTiles.count - Self.maxGPUTiles)
        for v in victims where v.lastUsed != useClock { gpuTiles[v.id] = nil }
    }

    private func requestDraw() {
        dirty = true
        var active = isActive
        #if DEBUG
        if Self.debugForceActive { active = true }
        #endif
        guard active, let view else { return }
        view.needsDisplay = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { dirty = true }

    func draw(in view: MTKView) {
        guard let frame, let camera else { return }
        guard view.drawableSize.width >= 1, view.drawableSize.height >= 1 else { return }
        // The clear colour is read when the pass descriptor is made.
        let bg = frame.palette.bg0
        view.clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: 1)
        guard let drawable = view.currentDrawable, let pass = renderPass(resolvingInto: drawable.texture, clear: bg) else { return }
        let scale = Double(view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        dirty = false
        guard let cmd = encode(frame: frame, camera: camera, pass: pass, drawableSize: view.drawableSize, scale: scale) else { return }
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: Multisampled targets

    private var msaaColor: MTLTexture?
    private var msaaDepth: MTLTexture?

    /// Memoryless (tile-memory only) where the GPU supports it, so the 4× targets take no RAM.
    private var targetStorage: MTLStorageMode {
        pipes.device.supportsFamily(.apple1) ? .memoryless : .private
    }

    /// A pass that draws into multisampled targets and resolves into `texture` (the drawable).
    private func renderPass(resolvingInto texture: MTLTexture, clear bg: SIMD4<Float>) -> MTLRenderPassDescriptor? {
        let w = texture.width, h = texture.height
        if msaaColor?.width != w || msaaColor?.height != h {
            func make(_ format: MTLPixelFormat) -> MTLTexture? {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
                d.textureType = .type2DMultisample
                d.sampleCount = MapPipelines.sampleCount
                d.usage = [.renderTarget]
                d.storageMode = targetStorage
                return pipes.device.makeTexture(descriptor: d)
            }
            msaaColor = make(MapPipelines.colorFormat)
            msaaDepth = make(MapPipelines.depthFormat)
        }
        guard let color = msaaColor, let depth = msaaDepth else { return nil }
        let pass = MTLRenderPassDescriptor()
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
        return pass
    }

    // MARK: Encoding

    /// Encodes one frame into `pass`. Returns the command buffer (not committed).
    private func encode(frame: MapFrame, camera: MapCamera, pass: MTLRenderPassDescriptor, drawableSize: CGSize, scale: Double) -> MTLCommandBuffer? {
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { debugLastEncodeCPUms = (CACurrentMediaTime() - t0) * 1000 }
        #endif
        let viewportPt = SIMD2<Double>(drawableSize.width / scale, drawableSize.height / scale)
        let proj = mapProjection(camera: camera, viewport: viewportPt)
        let globe = proj as? GlobeProjection          // fully a globe (no fills, no masks)
        let px = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        let pitched = globe == nil && frame.buildings && camera.pitch > 5
        fillUniforms(frame: frame, proj: proj, viewportPx: px, scale: Float(scale), flat: !pitched)
        for level in levels { for t in level { t.uniforms = tileUniforms(t.id, proj: proj) } }
        buildOverlays(frame: frame, proj: proj, scale: scale)

        inflight.wait()
        guard let cmd = queue.makeCommandBuffer() else { inflight.signal(); return nil }
        let stats = self.stats, sem = inflight
        cmd.addCompletedHandler { cb in
            stats.set(max(0, cb.gpuEndTime - cb.gpuStartTime) * 1000)
            sem.signal()
        }
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { cmd.commit(); return nil }
        frameCount += 1

        let blobLen = uniformBlob.count
        func bindFrame(_ enc: MTLRenderCommandEncoder, vertex: Int?, fragment: Int?) {
            uniformBlob.withUnsafeBytes { raw in
                if let v = vertex { enc.setVertexBytes(raw.baseAddress!, length: blobLen, index: v) }
                if let f = fragment { enc.setFragmentBytes(raw.baseAddress!, length: blobLen, index: f) }
            }
        }

        func drawTile(_ enc: MTLRenderCommandEncoder, _ t: GPUTile, _ b: GPUTile.Batch) {
            enc.setVertexBuffer(t.buffer, offset: b.vertexOffset, index: 0)
            enc.setVertexBytes(&t.uniforms, length: MemoryLayout<MapTileUniforms>.stride, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: b.indexCount, indexType: .uint32, indexBuffer: t.buffer, indexBufferOffset: b.indexOffset)
        }
        func writeLevelMask(_ enc: MTLRenderCommandEncoder, _ level: [GPUTile], _ ds: MTLDepthStencilState) {
            enc.setDepthStencilState(ds)
            enc.setStencilReferenceValue(0xFF)
            enc.setRenderPipelineState(pipes.stencil)
            enc.setVertexBuffer(pipes.unitQuad, offset: 0, index: 0)
            for t in level {
                enc.setVertexBytes(&t.uniforms, length: MemoryLayout<MapTileUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            enc.setStencilReferenceValue(0)
        }
        var mode0: UInt32 = 0, mode1: UInt32 = 1

        // 1. Void + reveal band.
        enc.setDepthStencilState(pipes.dsNone)
        enc.setRenderPipelineState(pipes.floor)
        bindFrame(enc, vertex: nil, fragment: 0)
        enc.setFragmentBytes(&mode0, length: 4, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Globe: the sphere body (drawn by the floor pass above), then lines on the facing side and
        // the overlays. No fills (large low-zoom triangles would cut through the sphere), no
        // ancestor masks, no buildings.
        if globe != nil {
            enc.setDepthStencilState(pipes.dsNone)
            enc.setRenderPipelineState(pipes.line)
            bindFrame(enc, vertex: 2, fragment: 0)
            for level in levels.reversed() {
                for cls in Self.lineOrder {
                    for t in level { for b in t.lines where b.cls == cls.rawValue { drawTile(enc, t, b) } }
                }
            }
            encodeOverlays(enc, bindFrame)
            enc.endEncoding()
            onFrameDrawn?(proj, frame)
            return cmd
        }

        // 2. Fills, deepest level first; each level masks the ones above it (bit 0). Water marks bit 1.
        enc.setStencilReferenceValue(0)
        for level in levels {
            enc.setRenderPipelineState(pipes.fill)
            bindFrame(enc, vertex: 2, fragment: 0)
            for cls in Self.fillOrder {
                let water = cls == .water || cls == .waterway
                var d = UInt32(cls.rawValue)
                var bound = false
                for t in level {
                    for b in t.fills where b.cls == cls.rawValue {
                        if !bound {
                            enc.setFragmentBytes(&d, length: 4, index: 1)
                            enc.setDepthStencilState(water ? pipes.dsWater : pipes.dsFill)
                            enc.setStencilReferenceValue(water ? 2 : 0)
                            bound = true
                        }
                        drawTile(enc, t, b)
                    }
                }
            }
            enc.setStencilReferenceValue(0)
            writeLevelMask(enc, level, pipes.dsFillWrite)
        }

        // 3. The grid lattice above the land tints, kept off water by the stencil.
        if frame.gridFloor {
            enc.setDepthStencilState(pipes.dsLattice)
            enc.setRenderPipelineState(pipes.lattice)
            bindFrame(enc, vertex: nil, fragment: 0)
            enc.setFragmentBytes(&mode1, length: 4, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        // 4. Lines and buildings, deepest level first (bit 2 masks ancestors).
        for level in levels {
            enc.setDepthStencilState(pipes.dsLine)
            enc.setRenderPipelineState(pipes.line)
            bindFrame(enc, vertex: 2, fragment: 0)
            for cls in Self.lineOrder {
                for t in level {
                    for b in t.lines where b.cls == cls.rawValue { drawTile(enc, t, b) }
                }
            }
            if level.contains(where: { $0.extrusion != nil }) {
                enc.setDepthStencilState(pitched ? pipes.dsExtrusion : pipes.dsLine)
                enc.setRenderPipelineState(pipes.extrusion)
                bindFrame(enc, vertex: 2, fragment: 0)
                for t in level {
                    guard let b = t.extrusion else { continue }
                    drawTile(enc, t, b)
                }
            }
            writeLevelMask(enc, level, pipes.dsLineWrite)
        }

        // 5. Overlays (CPU-projected, instanced SDF quads).
        encodeOverlays(enc, bindFrame)
        enc.endEncoding()
        onFrameDrawn?(proj, frame)
        return cmd
    }

    private func encodeOverlays(_ enc: MTLRenderCommandEncoder, _ bindFrame: (MTLRenderCommandEncoder, Int?, Int?) -> Void) {
        guard !overlayInstances.isEmpty, let buf = overlayBuffer(for: overlayInstances.count) else { return }
        overlayInstances.withUnsafeBytes { src in buf.contents().copyMemory(from: src.baseAddress!, byteCount: src.count) }
        enc.setDepthStencilState(pipes.dsNone)
        enc.setRenderPipelineState(pipes.overlay)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        bindFrame(enc, 2, 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: overlayInstances.count)
    }

    /// Fill order: tints first, water over them, footprints last.
    private static let fillOrder: [RenderClass] = [.landuse, .park, .aeroway, .water, .waterway, .building]
    /// Line order: shoreline and rivers under the road hierarchy; boundaries on top.
    private static let lineOrder: [RenderClass] = [.water, .waterway, .path, .rail, .service, .minor, .tertiary, .secondary, .primary, .trunk, .motorway, .aeroway, .boundary]

    private func tileUniforms(_ id: TileID, proj: any MapScreenProjection) -> MapTileUniforms {
        let (nw, se) = TileMath.bounds(id)
        let wupm = MapProjection.worldUnitsPerMeter(y: (nw.y + se.y) / 2)
        let tilePx = Float(proj.worldScale * (se.x - nw.x))
        let flat = (proj as? MapProjection) ?? (proj as? BlendedProjection)?.flat
        let mvp = flat?.tileMatrix(id) ?? matrix_identity_float4x4
        return MapTileUniforms(mvp: mvp, worldUnitsPerMeter: Float(wupm), tilePx: tilePx,
                               merc: SIMD4(Float(nw.x), Float(nw.y), Float(se.x - nw.x), Float(se.y - nw.y)))
    }

    private func overlayBuffer(for count: Int) -> MTLBuffer? {
        overlayBufferIndex = (overlayBufferIndex + 1) % overlayBuffers.count
        let need = count * MemoryLayout<MapOverlayInstance>.stride
        if let b = overlayBuffers[overlayBufferIndex], b.length >= need { return b }
        // Grow in steps so steady-state frames never allocate.
        let len = max(need, 256 * MemoryLayout<MapOverlayInstance>.stride) * 3 / 2
        let b = pipes.device.makeBuffer(length: len, options: .storageModeShared)
        overlayBuffers[overlayBufferIndex] = b
        return b
    }

    // MARK: Uniforms and style

    private func fillUniforms(frame: MapFrame, proj: any MapScreenProjection, viewportPx: SIMD2<Float>, scale: Float, flat: Bool) {
        let p = frame.palette
        let cam = proj.camera
        let style = MapStyle(palette: p, zoom: cam.zoom, glow: frame.glow, scale: scale)
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
        uniformBlob.withUnsafeMutableBytes { raw in
            style.fill.withUnsafeBytes { raw.baseAddress!.advanced(by: MapUniformLayout.fillColorOffset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            style.lineStyle.withUnsafeBytes { raw.baseAddress!.advanced(by: MapUniformLayout.lineStyleOffset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            style.lineColor.withUnsafeBytes { raw.baseAddress!.advanced(by: MapUniformLayout.lineColorOffset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            raw.baseAddress!.advanced(by: MapUniformLayout.scalarsOffset).storeBytes(of: s, as: MapFrameScalars.self)
        }
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

    private func buildOverlays(frame: MapFrame, proj: any MapScreenProjection, scale: Double) {
        overlayInstances.removeAll(keepingCapacity: true)
        let p = frame.palette
        let s = Float(scale)
        let vp = proj.viewport
        let margin = 80.0
        func onScreen(_ q: SIMD2<Double>) -> Bool { q.x > -margin && q.y > -margin && q.x < vp.x + margin && q.y < vp.y + margin }
        func px(_ q: SIMD2<Double>) -> SIMD2<Float> { SIMD2(Float(q.x * scale), Float(q.y * scale)) }
        func add(_ kind: MapOverlayKind, at c: SIMD2<Float>, size: SIMD2<Float>, color: SIMD4<Float>, p: SIMD4<Float> = .zero) {
            guard overlayInstances.count < 60_000 else { return }
            overlayInstances.append(MapOverlayInstance(center: c, size: size, color: color, p: p, kind: kind.rawValue))
        }
        let lat = TileMath.unproject(proj.camera.center).lat
        let metersPerPoint = TileMath.metersPerPoint(lat: lat, zoom: proj.camera.zoom)
        let bearingRad = Float(proj.camera.bearing * .pi / 180)

        // Region outlines: dashed accent segments between projected ring points.
        for r in frame.regions {
            let alpha: Float = r.highlighted ? 0.95 : 0.55
            var color = p.accent; color.w *= alpha
            for ring in r.rings where ring.count >= 2 {
                var pts: [SIMD2<Double>?] = []
                pts.reserveCapacity(ring.count)
                for w in ring { pts.append(proj.screen(w)) }
                let n = ring.count
                for i in 0..<n {
                    let j = (i + 1) % n
                    if j == 0 && n == 2 { break }
                    guard let a = pts[i], let b = pts[j] else { continue }
                    if !onScreen(a) && !onScreen(b) { continue }
                    let d = b - a
                    let len = (d.x * d.x + d.y * d.y).squareRoot()
                    guard len > 0.01, len < 20_000 else { continue }
                    let mid = (a + b) / 2
                    let ang = atan2(d.y, d.x)
                    add(.segment, at: px(mid), size: SIMD2(Float(len * scale) + 4 * s, 4 * s), color: color,
                        p: SIMD4(Float(ang), Float(len * scale / 2), r.highlighted ? 0 : 4 * s, 0))
                }
            }
        }

        // ALPR cameras: FOV wedges under the reticles.
        if !frame.cameras.isEmpty {
            let wedgeR = Float(min(48, max(14, 40 / max(0.01, metersPerPoint)))) * s
            let wedge = p.accent   // fill 28% and arc 85% are applied in the shader
            var projected: [(SIMD2<Float>, CameraMarker)] = []
            projected.reserveCapacity(frame.cameras.count)
            for c in frame.cameras {
                guard let q = proj.screen(c.world), onScreen(q) else { continue }
                projected.append((px(q), c))
            }
            for (q, c) in projected {
                for d in c.directions {
                    let ang = Float(d) * .pi / 180 - bearingRad
                    add(.wedge, at: q, size: SIMD2(repeating: wedgeR * 2 + 2 * s), color: wedge, p: SIMD4(ang, .pi / 6, 0, 0))
                }
            }
            for (q, c) in projected {
                var color = p.accent
                color.w = c.isFlock ? 1.0 : 0.7
                let side: Float = 13 * s
                add(.reticle, at: q, size: SIMD2(repeating: side + 4 * s + (c.selected ? 8 * s : 0)), color: color, p: SIMD4(0, c.selected ? 1 : 0, 0, 0))
            }
        }

        // Clusters: ▣ blocks (the count is drawn as a label by the view).
        for c in frame.clusters {
            guard let q = proj.screen(c.world), onScreen(q) else { continue }
            let side = Float(Self.clusterSide(c.count)) * s
            add(.cluster, at: px(q), size: SIMD2(repeating: side + 2 * s), color: p.accent)
        }

        // You: accuracy ring and dot.
        if let l = frame.location, let q = proj.screen(l.world), onScreen(q) {
            let r = Float(max(6, l.accuracyMeters / max(0.01, metersPerPoint))) * s
            var ring = p.accent; ring.w = 0.5
            add(.ring, at: px(q), size: SIMD2(repeating: r * 2 + 4 * s), color: ring, p: SIMD4(1 * s, 0, 0, 0))
            add(.locationDot, at: px(q), size: SIMD2(repeating: 22 * s), color: p.accent)
        }
    }

    /// Side of a cluster block in points for a count (grows slowly with log2).
    static func clusterSide(_ count: Int) -> Double {
        10 + min(8, log2(Double(max(1, count)))) * 1.5
    }

    // MARK: DEBUG harness

    #if DEBUG
    /// Renders the current frame into an offscreen texture and returns it as an image (QA, tests
    /// in the scratch harness). Blocks until the GPU finishes.
    func debugRenderOffscreen(size: CGSize, scale: Double = 2) -> CGImage? {
        guard let frame, let camera else { return nil }
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0 else { return nil }
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MapPipelines.colorFormat, width: w, height: h, mipmapped: false)
        cd.usage = [.renderTarget]; cd.storageMode = .shared
        // Multisampled targets (the pipelines draw at MapPipelines.sampleCount), resolved into `color`.
        let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MapPipelines.colorFormat, width: w, height: h, mipmapped: false)
        md.textureType = .type2DMultisample; md.sampleCount = MapPipelines.sampleCount; md.usage = [.renderTarget]; md.storageMode = .private
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MapPipelines.depthFormat, width: w, height: h, mipmapped: false)
        dd.textureType = .type2DMultisample; dd.sampleCount = MapPipelines.sampleCount
        dd.usage = [.renderTarget]; dd.storageMode = .private
        guard let color = pipes.device.makeTexture(descriptor: cd), let msaa = pipes.device.makeTexture(descriptor: md),
              let depth = pipes.device.makeTexture(descriptor: dd) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa
        pass.colorAttachments[0].resolveTexture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        let bg = frame.palette.bg0
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: 1)
        pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.clearDepth = 1; pass.depthAttachment.storeAction = .dontCare
        pass.stencilAttachment.texture = depth; pass.stencilAttachment.loadAction = .clear; pass.stencilAttachment.clearStencil = 0; pass.stencilAttachment.storeAction = .dontCare
        guard let cmd = encode(frame: frame, camera: camera, pass: pass, drawableSize: CGSize(width: w, height: h), scale: scale) else { return nil }
        cmd.commit()
        cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { color.getBytes($0.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: cs, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    #endif
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
        self.fill = fill; lineStyle = style; lineColor = color
    }
}

@inline(__always) func mapMix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> { a + (b - a) * t }
