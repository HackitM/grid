import Foundation
import simd

/// Decoded MVT tile → render geometry (tile-local 0…1 positions, ready for GPU upload).
public enum TileGeometryBuilder {
    static let maxLabelsPerTile = 2000
    /// Light direction in tile space (y down) used to shade building walls: from the upper left.
    private static let light = simd_normalize(SIMD2<Float>(-0.5, -0.8))

    public static func build(_ tile: MVTTile, id: TileID) -> TileGeometry {
        let maxVerts = MVTLimits().maxVerticesPerFeature
        var fillPos = [[SIMD2<Float>]](repeating: [], count: RenderClass.allCases.count)
        var fillIdx = [[UInt32]](repeating: [], count: RenderClass.allCases.count)
        var lineVerts = [[LineVertex]](repeating: [], count: RenderClass.allCases.count)
        var lineIdx = [[UInt32]](repeating: [], count: RenderClass.allCases.count)
        var extVerts: [ExtrusionVertex] = []
        var extIdx: [UInt32] = []
        var labels: [LabelAnchor] = []

        for layer in tile.layers where OpenMapTilesSchema.layers.contains(layer.name) {
            guard layer.extent > 0 else { continue }
            let inv = 1 / Float(layer.extent)
            @inline(__always) func norm(_ p: SIMD2<Int32>) -> SIMD2<Float> { SIMD2(Float(p.x) * inv, Float(p.y) * inv) }

            for f in layer.features {
                switch f.geometry {
                case .polygons(let polys):
                    guard let cls = OpenMapTilesSchema.fillClass(layer: layer.name, tags: f.tags) else { continue }
                    let isBuilding = cls == .building
                    let height = isBuilding ? OpenMapTilesSchema.buildingHeight(f.tags) : 0
                    let minH = isBuilding ? min(height, OpenMapTilesSchema.buildingMinHeight(f.tags)) : 0
                    for poly in polys {
                        guard poly.count > 0 else { continue }
                        if poly.reduce(0, { $0 + $1.count }) > maxVerts { continue }
                        let rings = poly.map { $0.map(norm) }
                        let tris = Earcut.triangulate(rings)
                        guard !tris.isEmpty else { continue }
                        if isBuilding {
                            appendBuilding(rings, tris, height: height, minHeight: minH, vertices: &extVerts, indices: &extIdx)
                        } else {
                            let c = Int(cls.rawValue)
                            let base = UInt32(fillPos[c].count)
                            for r in rings { fillPos[c].append(contentsOf: r) }
                            fillIdx[c].reserveCapacity(fillIdx[c].count + tris.count)
                            for t in tris { fillIdx[c].append(base + t) }
                        }
                    }
                case .lines(let lines):
                    if let (cls, flags) = OpenMapTilesSchema.lineClass(layer: layer.name, tags: f.tags) {
                        let c = Int(cls.rawValue)
                        for l in lines where l.count >= 2 && l.count <= maxVerts {
                            LineTessellator.append(l.map(norm), closed: false, cls: cls, flags: flags,
                                                   vertices: &lineVerts[c], indices: &lineIdx[c])
                        }
                    }
                    if layer.name == "transportation_name", labels.count < maxLabelsPerTile,
                       let info = OpenMapTilesSchema.label(layer: layer.name, tags: f.tags),
                       let mid = longestSegmentMidpoint(lines) {
                        let pos = norm(mid)
                        if inTile(pos) {
                            labels.append(LabelAnchor(text: info.text, kind: info.kind, priority: info.priority, pos: pos, minZoom: info.minZoom))
                        }
                    }
                case .points(let pts):
                    guard layer.name == "place" || layer.name == "water_name", labels.count < maxLabelsPerTile,
                          let info = OpenMapTilesSchema.label(layer: layer.name, tags: f.tags) else { continue }
                    for p in pts {
                        let pos = norm(p)
                        guard inTile(pos), labels.count < maxLabelsPerTile else { continue }
                        labels.append(LabelAnchor(text: info.text, kind: info.kind, priority: info.priority, pos: pos, minZoom: info.minZoom))
                    }
                }
            }
        }

        var fills: [FillBatch] = []
        var lines: [LineBatch] = []
        var bytes = 0
        for cls in RenderClass.allCases {
            let c = Int(cls.rawValue)
            if !fillIdx[c].isEmpty {
                fills.append(FillBatch(cls: cls, positions: fillPos[c], indices: fillIdx[c]))
                bytes += fillPos[c].count * MemoryLayout<SIMD2<Float>>.stride + fillIdx[c].count * 4
            }
            if !lineIdx[c].isEmpty {
                lines.append(LineBatch(cls: cls, vertices: lineVerts[c], indices: lineIdx[c]))
                bytes += lineVerts[c].count * MemoryLayout<LineVertex>.stride + lineIdx[c].count * 4
            }
        }
        var extrusion: ExtrusionBatch?
        if !extIdx.isEmpty {
            extrusion = ExtrusionBatch(vertices: extVerts, indices: extIdx)
            bytes += extVerts.count * MemoryLayout<ExtrusionVertex>.stride + extIdx.count * 4
        }
        bytes += labels.count * MemoryLayout<LabelAnchor>.stride
        return TileGeometry(id: id, fills: fills, lines: lines, extrusion: extrusion, labels: labels, byteCount: bytes)
    }

    @inline(__always) private static func inTile(_ p: SIMD2<Float>) -> Bool { p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1 }

    private static func longestSegmentMidpoint(_ lines: [[SIMD2<Int32>]]) -> SIMD2<Int32>? {
        var best: Int64 = -1
        var mid: SIMD2<Int32>?
        for l in lines where l.count >= 2 {
            for i in 0..<(l.count - 1) {
                let dx = Int64(l[i + 1].x) - Int64(l[i].x), dy = Int64(l[i + 1].y) - Int64(l[i].y)
                let d = dx * dx + dy * dy
                if d > best {
                    best = d
                    mid = SIMD2((l[i].x + l[i + 1].x) / 2, (l[i].y + l[i + 1].y) / 2)
                }
            }
        }
        return mid
    }

    /// Roof (earcut at `height`) plus two triangles per ring edge for the walls. Wall-top vertices
    /// carry `ExtrusionVertex.wallTop`; roof vertices `ExtrusionVertex.roof`. Hole rings get walls
    /// too (they face the courtyard).
    private static func appendBuilding(_ rings: [[SIMD2<Float>]], _ tris: [UInt32], height: Float, minHeight: Float,
                                       vertices: inout [ExtrusionVertex], indices: inout [UInt32]) {
        let base = UInt32(vertices.count)
        for r in rings {
            for p in r { vertices.append(ExtrusionVertex(pos: p, height: height, shade: 65535, flags: ExtrusionVertex.roof)) }
        }
        for t in tris { indices.append(base + t) }
        for r in rings where r.count >= 3 {
            for i in 0..<r.count {
                let a = r[i], b = r[(i + 1) % r.count]
                let e = b - a
                let len = simd_length(e)
                guard len > 1e-9 else { continue }
                // Rings are wound so that (dy, -dx) points away from the building's solid part.
                let nrm = SIMD2<Float>(e.y, -e.x) / len
                let lit = max(-1, min(1, simd_dot(nrm, light)))
                let shade = UInt16(max(0, min(65535, (0.25 + 0.65 * (0.5 + 0.5 * lit)) * 65535)))
                let v = UInt32(vertices.count)
                vertices.append(ExtrusionVertex(pos: a, height: minHeight, shade: shade, flags: 0))
                vertices.append(ExtrusionVertex(pos: b, height: minHeight, shade: shade, flags: 0))
                vertices.append(ExtrusionVertex(pos: a, height: height, shade: shade, flags: ExtrusionVertex.wallTop))
                vertices.append(ExtrusionVertex(pos: b, height: height, shade: shade, flags: ExtrusionVertex.wallTop))
                indices.append(contentsOf: [v, v + 1, v + 2, v + 1, v + 3, v + 2])
            }
        }
    }
}
