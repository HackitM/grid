import Foundation
import GridCore
import simd

// Metal shader source and the uniform layouts shared with it (docs/maps/IMPLEMENTATION.md Brief C).
// Everything the shaders need per frame sits in one ≤ 4 KB blob passed with setBytes: three tables
// indexed by `RenderClass.rawValue` (fill colour, line style, line colour) followed by scalars.
// Theme and zoom changes only rewrite this blob; tile buffers never change after upload.

/// Number of entries in each per-class table (RenderClass.allCases.count ≤ 24, see §3.1).
let mapClassTableCount = 24

/// Scalars after the three class tables. Field order and types match `FrameU` in the MSL below
/// (C++ layout: every field is naturally aligned, no implicit padding).
struct MapFrameScalars {
    /// Clip space → centred ground space (points, y down, origin at the camera centre).
    var invCenteredVP: simd_float4x4 = matrix_identity_float4x4
    var bg0: SIMD4<Float> = .zero
    var bg3: SIMD4<Float> = .zero
    var accent: SIMD4<Float> = .zero
    var glow: SIMD4<Float> = .zero
    var text: SIMD4<Float> = .zero
    var line: SIMD4<Float> = .zero
    var roof: SIMD4<Float> = .zero
    var wall: SIMD4<Float> = .zero
    var viewportPx: SIMD2<Float> = .zero
    var scale: Float = 2
    var pitch: Float = 0
    var zoom: Float = 0
    /// Pixels: fragments below this row are not drawn (scan-sweep reveal). ≥ height = off.
    var revealY: Float = 1e9
    var gridMinorPx: Float = 0      // 0 = no grid floor
    var gridMajorPx: Float = 0
    var phaseMinor: SIMD2<Float> = .zero
    var phaseMajor: SIMD2<Float> = .zero
    var gridFadeStart: Float = 1
    var gridFadeEnd: Float = 2
    /// 1 = draw building roofs at ground level (footprints), walls collapse to nothing.
    var flat: Float = 1
    var glowOn: Float = 1
}

/// Per-tile uniforms (`TileU`): tile-local 0…1 → clip, plus the height scale and tile size.
struct MapTileUniforms {
    var mvp: simd_float4x4
    /// World units per metre at the tile centre (heights → world z).
    var worldUnitsPerMeter: Float
    /// Screen pixels per tile (dash lengths from `along`).
    var tilePx: Float
    var pad: SIMD2<Float> = .zero
}

/// One instanced overlay quad (`OverlayInst`). Pixels, top-left origin.
struct MapOverlayInstance {
    var center: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
    var p: SIMD4<Float>
    var kind: UInt32
    // Three scalar pads (a SIMD3 would align to 16 and break the 64-byte stride).
    var pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0
}

enum MapOverlayKind: UInt32 {
    case reticle = 0      // p.x tick length px, p.y selected (0/1)
    case wedge = 1        // p.x centre angle (rad, clockwise from up), p.y half angle; radius = size.x/2
    case cluster = 2      // ▣ block
    case locationDot = 3
    case ring = 4         // p.x thickness px
    case segment = 5      // p.x angle (rad), p.y half length px, p.z dash px (0 solid), p.w phase px
}

/// Byte layout of the frame uniform blob.
enum MapUniformLayout {
    /// The Swift structs must match the MSL structs byte for byte (checked once in DEBUG).
    static func checkLayouts() {
        assert(MemoryLayout<MapFrameScalars>.size == 256 && MemoryLayout<MapFrameScalars>.stride == 256, "FrameU scalars")
        assert(MemoryLayout<MapTileUniforms>.stride == 80, "TileU")
        assert(MemoryLayout<MapOverlayInstance>.stride == 64, "OverlayInst")
        assert(MemoryLayout<LineVertex>.stride == 32 && MemoryLayout<ExtrusionVertex>.stride == 16, "vertex structs")
    }
    static let tableBytes = mapClassTableCount * MemoryLayout<SIMD4<Float>>.stride
    static let fillColorOffset = 0
    static let lineStyleOffset = tableBytes
    static let lineColorOffset = tableBytes * 2
    static let scalarsOffset = tableBytes * 3
    static let totalBytes = tableBytes * 3 + MemoryLayout<MapFrameScalars>.stride
}

let mapShaderSource = """
#include <metal_stdlib>
using namespace metal;

#define CLASSES 24

struct FrameU {
    float4 fillColor[CLASSES];
    float4 lineStyle[CLASSES];     // x half width px, y glow px, z glow strength, w dash px (0 solid)
    float4 lineColor[CLASSES];
    float4x4 invVP;
    float4 bg0, bg3, accent, glow, text, line, roof, wall;
    float2 viewportPx; float scale; float pitch;
    float zoom; float revealY; float gridMinorPx; float gridMajorPx;
    float2 phaseMinor; float2 phaseMajor;
    float gridFadeStart; float gridFadeEnd; float flat; float glowOn;
};

struct TileU { float4x4 mvp; float wupm; float tilePx; float2 pad; };
struct DrawU { uint cls; };

struct LineVertex { float2 pos; float2 normal; float side; float along; ushort cls; ushort flags; };
struct ExtrusionVertex { float2 pos; float height; ushort shade; ushort flags; };
struct OverlayInst { float2 center; float2 size; float4 color; float4 p; uint kind; uint pad0; uint pad1; uint pad2; };

static float4 premul(float4 c, float a) { float k = c.a * a; return float4(c.rgb * k, k); }
static float4 over(float4 dst, float4 src) { return src + dst * (1.0 - src.a); }

// ---------------------------------------------------------------- floor

struct FloorOut { float4 pos [[position]]; float2 ndc; };

vertex FloorOut floor_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2)) * 2.0 - 1.0;   // one triangle covering clip space
    FloorOut o; o.pos = float4(p, 0, 1); o.ndc = p; return o;
}

// Anti-aliased lattice line coverage at `coord` (pixels) with the given spacing.
static float gridLine(float coord, float spacing, float widthPx) {
    float d = abs(fract(coord / spacing + 0.5) - 0.5) * spacing;
    float fw = max(fwidth(coord), 1e-4);
    float a = 1.0 - smoothstep(widthPx * 0.5, widthPx * 0.5 + fw, d);
    return a * clamp(1.0 - fw / spacing * 5.0, 0.0, 1.0);   // fade before the lattice aliases
}

// Mode 0: the void and the reveal band (opaque, drawn first). Mode 1: the grid lattice, drawn
// above the fills (blended, stencil keeps it off water) so it stays visible over land tints.
fragment float4 floor_fragment(FloorOut in [[stage_in]], constant FrameU& u [[buffer(0)]], constant DrawU& d [[buffer(1)]]) {
    bool revealed = in.pos.y <= u.revealY;
    if (d.cls == 1u) {
        float4 col = float4(0.0);
        if (revealed && u.gridMinorPx > 0.0) {
            float4 a = u.invVP * float4(in.ndc, 0.0, 1.0);
            float4 b = u.invVP * float4(in.ndc, 1.0, 1.0);
            if (abs(a.w) > 1e-12 && abs(b.w) > 1e-12) {
                float3 p0 = a.xyz / a.w, p1 = b.xyz / b.w;
                float dz = p1.z - p0.z;
                if (abs(dz) > 1e-12) {
                    float t = -p0.z / dz;
                    if (t >= 0.0) {
                        float3 g = p0 + (p1 - p0) * t;                 // points, centred on the camera
                        float2 gp = g.xy * u.scale;                   // pixels
                        float dist = length(g.xy) / max(1.0, u.viewportPx.y / u.scale);
                        float fade = 1.0 - smoothstep(u.gridFadeStart, u.gridFadeEnd, dist);
                        float minor = max(gridLine(gp.x + u.phaseMinor.x, u.gridMinorPx, u.scale * 0.5),
                                          gridLine(gp.y + u.phaseMinor.y, u.gridMinorPx, u.scale * 0.5));
                        float major = max(gridLine(gp.x + u.phaseMajor.x, u.gridMajorPx, u.scale * 0.5),
                                          gridLine(gp.y + u.phaseMajor.y, u.gridMajorPx, u.scale * 0.5));
                        col = premul(u.line, 0.45 * minor * fade);
                        col = over(col, premul(u.line, 0.9 * major * fade));
                    }
                }
            }
        }
        return col;
    }
    float4 col = float4(u.bg0.rgb, 1.0);
    if (u.revealY < u.viewportPx.y) {
        float dd = abs(in.pos.y - u.revealY);
        col = over(col, premul(u.accent, 0.85 * (1.0 - smoothstep(0.0, 2.0 * u.scale, dd))));
        col = over(col, premul(u.glow, 0.25 * (1.0 - smoothstep(0.0, 14.0 * u.scale, in.pos.y > u.revealY ? dd : 1e9))));
    }
    return col;
}

// ---------------------------------------------------------------- fills and stencil mask

struct FillOut { float4 pos [[position]]; };

vertex FillOut fill_vertex(uint vid [[vertex_id]], const device float2* v [[buffer(0)]], constant TileU& t [[buffer(1)]]) {
    FillOut o; o.pos = t.mvp * float4(v[vid], 0.0, 1.0); return o;
}

fragment float4 fill_fragment(FillOut in [[stage_in]], constant FrameU& u [[buffer(0)]], constant DrawU& d [[buffer(1)]]) {
    if (in.pos.y > u.revealY) discard_fragment();
    float4 c = u.fillColor[min(d.cls, uint(CLASSES - 1))];
    return float4(c.rgb * c.a, c.a);
}

fragment float4 stencil_fragment(FillOut in [[stage_in]]) { return float4(0.0); }

// ---------------------------------------------------------------- lines (analytic glow)

struct LineOut {
    float4 pos [[position]];
    float d;                 // signed distance from the centre line, px (± (half width + glow))
    float along;             // px along the line
    uint cls [[flat]];
    uint flags [[flat]];
};

vertex LineOut line_vertex(uint vid [[vertex_id]], const device LineVertex* v [[buffer(0)]],
                           constant TileU& t [[buffer(1)]], constant FrameU& u [[buffer(2)]]) {
    LineVertex a = v[vid];
    uint cls = min(uint(a.cls), uint(CLASSES - 1));
    float4 style = u.lineStyle[cls];
    float4 c0 = t.mvp * float4(a.pos, 0.0, 1.0);
    float ext = style.x + style.y;
    LineOut o;
    if (c0.w > 1e-4 && ext > 0.0) {
        float4 c1 = t.mvp * float4(a.pos + a.normal * 1e-3, 0.0, 1.0);
        if (c1.w > 1e-4) {
            float2 dir = (c1.xy / c1.w - c0.xy / c0.w) * u.viewportPx * 0.5;   // px
            float len = length(dir);
            dir = len > 1e-6 ? dir / len : float2(0.0, 1.0);
            float miter = clamp(length(a.normal), 1.0, 2.5);
            float2 off = dir * (a.side * ext * miter);
            c0.xy += off * (2.0 / u.viewportPx) * c0.w;
        }
    }
    o.pos = c0;
    o.d = a.side * ext;
    o.along = a.along * t.tilePx;
    o.cls = cls;
    o.flags = uint(a.flags);
    return o;
}

fragment float4 line_fragment(LineOut in [[stage_in]], constant FrameU& u [[buffer(0)]]) {
    if (in.pos.y > u.revealY) discard_fragment();
    float4 st = u.lineStyle[in.cls];
    float4 col = u.lineColor[in.cls];
    float hw = st.x, gl = st.y;
    float d = abs(in.d);
    float aa = 0.75;
    float core = 1.0 - smoothstep(hw - aa, hw + aa, d);
    float glow = 0.0;
    if (gl > 0.0) { float g = 1.0 - smoothstep(hw * 0.5, hw + gl, d); glow = g * g * st.z; }
    float dash = 1.0;
    if (st.w > 0.0) {
        float period = st.w * 2.0;
        float f = fract(in.along / period);
        float e = 0.75 / period;
        dash = smoothstep(0.0, e, f) * (1.0 - smoothstep(0.5 - e, 0.5, f));
    }
    float dim = (in.flags & 1u) ? 0.35 : 1.0;   // tunnel
    float k = dash * dim;
    float4 c = float4(col.rgb * col.a, col.a) * (core * k);
    float4 g = float4(u.glow.rgb, 1.0) * (glow * k);
    return c + g * (1.0 - c.a);
}

// ---------------------------------------------------------------- buildings

struct ExtOut {
    float4 pos [[position]];
    float shade; float top;
    float roof [[flat]];
    float2 tilePos;                 // interpolated tile-local position
    float2 corner [[flat]];         // the triangle's first vertex: the wall corner it contains
};

vertex ExtOut ext_vertex(uint vid [[vertex_id]], const device ExtrusionVertex* v [[buffer(0)]],
                         constant TileU& t [[buffer(1)]], constant FrameU& u [[buffer(2)]]) {
    ExtrusionVertex a = v[vid];
    float z = u.flat > 0.5 ? 0.0 : max(0.0, a.height) * t.wupm;
    ExtOut o;
    o.pos = t.mvp * float4(a.pos, z, 1.0);
    o.shade = float(a.shade) / 65535.0;
    o.top = (a.flags & 2) ? 1.0 : 0.0;
    o.roof = (a.flags & 1) ? 1.0 : 0.0;
    o.tilePos = a.pos;
    o.corner = a.pos;
    return o;
}

fragment float4 ext_fragment(ExtOut in [[stage_in]], constant FrameU& u [[buffer(0)]]) {
    if (in.pos.y > u.revealY) discard_fragment();
    if (in.roof > 0.5) return float4(u.roof.rgb, 1.0);
    // Dark faces, luminous edges: the roof line from the wallTop flag, the vertical corner edge
    // from the distance to the triangle's provoking corner (each wall triangle holds one corner).
    float3 wall = mix(u.wall.rgb * 0.6, u.wall.rgb, in.shade);
    float fwT = max(fwidth(in.top), 1e-4);
    float top = smoothstep(1.0 - 1.8 * fwT, 1.0 - 0.4 * fwT, in.top);
    float dc = length(in.tilePos - in.corner);
    float fwC = max(fwidth(dc), 1e-7);
    float vert = 1.0 - smoothstep(0.5 * fwC, 1.5 * fwC, dc);
    float edge = max(top, vert * 0.7);
    float3 c = mix(wall, u.accent.rgb, edge * 0.9);
    return float4(c, 1.0);
}

// ---------------------------------------------------------------- overlays (instanced SDF quads)

struct OverlayOut {
    float4 pos [[position]];
    float2 local;                 // px from the instance centre, unrotated frame
    float4 color [[flat]];
    float4 p [[flat]];
    float2 size [[flat]];
    uint kind [[flat]];
};

vertex OverlayOut overlay_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device OverlayInst* inst [[buffer(0)]], constant FrameU& u [[buffer(2)]]) {
    OverlayInst i = inst[iid];
    float2 corner = float2(float(vid & 1), float((vid >> 1) & 1)) - 0.5;      // strip: (-.5,-.5) (.5,-.5) (-.5,.5) (.5,.5)
    float2 local = corner * i.size;
    float2 px = local;
    if (i.kind == 5) { float c = cos(i.p.x), s = sin(i.p.x); px = float2(local.x * c - local.y * s, local.x * s + local.y * c); }
    float2 screen = i.center + px;
    float2 ndc = screen / u.viewportPx * 2.0 - 1.0;
    OverlayOut o;
    o.pos = float4(ndc.x, -ndc.y, 0.0, 1.0);
    o.local = local;
    o.color = i.color; o.p = i.p; o.size = i.size; o.kind = i.kind;
    return o;
}

static float segDist(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
    return length(pa - ba * h);
}
static float stroke(float d, float w) { return 1.0 - smoothstep(w * 0.5, w * 0.5 + 0.8, abs(d)); }

fragment float4 overlay_fragment(OverlayOut in [[stage_in]], constant FrameU& u [[buffer(0)]]) {
    float2 q = in.local;
    float2 aq = abs(q);
    float s = u.scale;
    float a = 0.0;
    float3 rgb = in.color.rgb;
    switch (in.kind) {
    case 0: {   // reticle: open square with heavier corner brackets and a centre dot
        float hs = in.size.x * 0.5 - 2.0 * s;
        float edge = max(aq.x, aq.y) - hs;
        float other = min(aq.x, aq.y);
        float outline = stroke(edge, 1.0 * s) * 0.5;
        float bracket = stroke(edge, 1.6 * s) * step(hs * 0.45, other);
        float dot = 1.0 - smoothstep(0.9 * s, 1.7 * s, length(q));
        a = max(max(outline, bracket), dot);
        if (in.p.y > 0.5) {   // selected: a second, dimmer square outside
            float e2 = max(aq.x, aq.y) - (hs - 1.0 * s) - 3.5 * s;
            a = max(a, stroke(e2, 1.0 * s) * 0.6);
        }
        break; }
    case 1: {   // FOV wedge: sector of radius size.x/2 around p.x with half angle p.y, brighter arc
        float R = in.size.x * 0.5 - 1.0 * s;
        float r = length(q);
        float ang = atan2(q.x, -q.y);                     // clockwise from up
        float da = ang - in.p.x;
        da = da - 6.28318530718 * round(da / 6.28318530718);
        float sector = 1.0 - smoothstep(in.p.y - 0.02, in.p.y + 0.02, abs(da));
        float inside = (1.0 - smoothstep(R - 1.5 * s, R, r)) * sector;
        float radial = mix(1.0, 0.45, clamp(r / max(R, 1.0), 0.0, 1.0));
        float arc = stroke(r - R + 0.7 * s, 1.0 * s) * sector;
        a = min(1.0, 0.28 * inside * radial + 0.85 * arc);
        break; }
    case 2: {   // cluster block ▣
        float hs = in.size.x * 0.5 - 1.0 * s;
        float outline = stroke(max(aq.x, aq.y) - hs, 1.0 * s);
        float inner = 1.0 - smoothstep(hs * 0.48, hs * 0.48 + 0.8, max(aq.x, aq.y));
        a = max(outline, inner * 0.85);
        break; }
    case 3: {   // you: filled dot with a dark rim and short ticks (quad = dot radius + 6 px of ticks)
        float R = in.size.x * 0.5 - 6.0 * s;
        float r = length(q);
        float dotA = 1.0 - smoothstep(R - 0.8, R + 0.4, r);
        float rim = stroke(r - (R + 1.0 * s), 1.2 * s);
        float ticks = max(stroke(aq.x, 1.0 * s) * step(R + 2.0 * s, aq.y) * step(aq.y, R + 5.0 * s),
                          stroke(aq.y, 1.0 * s) * step(R + 2.0 * s, aq.x) * step(aq.x, R + 5.0 * s));
        float4 col = float4(rgb * dotA, dotA);
        col = over(col, float4(u.bg0.rgb * rim * 0.9, rim * 0.9) * (1.0 - dotA));
        col = over(col, float4(rgb, 1.0) * ticks);
        return col * in.color.a;
        }
    case 4: {   // ring
        float R = in.size.x * 0.5 - in.p.x;
        a = stroke(length(q) - R, in.p.x);
        break; }
    case 5: {   // dashed segment
        float L = in.p.y;
        float line = stroke(q.y, 1.0 * s) * (1.0 - smoothstep(L, L + 0.8, aq.x));
        if (in.p.z > 0.0) {
            float period = in.p.z * 2.0;
            float f = fract((q.x + L + in.p.w) / period);
            float e = 0.8 / period;
            line *= smoothstep(0.0, e, f) * (1.0 - smoothstep(0.5 - e, 0.5, f));
        }
        a = line;
        break; }
    default: break;
    }
    a *= in.color.a;
    return float4(rgb * a, a);
}
"""
