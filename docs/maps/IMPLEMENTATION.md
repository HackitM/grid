# GRID Maps v1: authoritative implementation plan

Status: **active**. This file is the single source of truth for the Maps v1 build. The research
and options behind it are in `docs/MAPS-PLAN.md`; where the two differ, **this file wins**.
Owner: the lead (integrator). Changes to §3 contracts go through the lead only.

## 1. Scope

**In v1**
1. **Map page** `05 MAP` (Settings becomes `06 SYS`), ⌥⌘5, palette "Map". A custom Metal
   vector-tile renderer in GRID's Tron / Cyberpunk look:
   - **Base map:** dark land, bg3 water, a procedural grid floor, glowing roads by class, buildings
     extruded when pitched.
   - **Labels:** CoreText place and road labels.
   - **Theme:** colours follow the theme (Legacy, Ares, ENCOM). Glow and Motion follow Effects.
2. **Tiles:** OpenFreeMap tiles (OpenMapTiles schema, z0–14, overzoom to z18), after a one-time
   **ENABLE MAP DATA** consent. Kept in a flat-file disk cache (200 MB cap) with an attribution
   strip.
3. **ALPR cameras downloaded per region the user picks:**
   - **Choosing a region:** a US state or sub-state, a Canadian province, another country's region
     (from Geofabrik's catalogue), or a rectangle drawn on the map (⇧-drag in REGION mode).
   - **Storage:** cameras are stored offline per region.
   - **Display:** reticles with field-of-view wedges, clusters below z12, an inspector card, and
     counts.
4. **Locate** (⌖): CoreLocation "when in use", one fix per click. The position is kept in memory
   only.
5. **Camera-data freshness:** checked while the Map page is in use (at most daily). Shown in
   Settings › Updates (a "Map data" block) and Settings › Map, where you update per region.

**Non-goals (v1):** POI search and Nominatim, traffic, routing (including the on-device
FlockHopper pack), print/GPX export, FOLLOW location, the Perimeter widget, offline PMTiles base
maps, slicing the national GeoJSON, OSM editing, label glyph atlas, half-res bloom.

## 2. Architecture

```
GridCore/Maps (pure Swift, tested)                     Grid/Maps (app)
  MapContracts  TileMath/MapProjection   [lead]          MapRenderContract                 [lead]
  MVTDecoder Earcut LineTessellator                      MapRenderer MapShaders MapMetalView
  TileGeometryBuilder OpenMapTilesSchema                 MapLabelLayer                     [C]
  LabelPlacer TileSource                 [A]             MapNetwork TileCache TileStore    [lead]
  OSMSurveillance DeFlockTile DeFlockIndex               ALPRStore RegionDownloader
  DeFlockBuild GeoPolygon+ RegionCatalog                 OverpassClient LocationProvider
  OverpassQuery CameraIndex RegionPackage                MapUpdateSources (UpdateSource)    [lead]
  FetchPolicy ALPRSourcePlanner          [B]             MapModel MapPanel MapInspector
                                                         MapRegionsPanel MapSettingsSection [lead]
```

**Key decisions (from the joint review; see §9 for the reasons):**
- **Rendering:** a custom Metal renderer.
- **Glow:** analytic (the line shader expands by width + glow radius and falls off with
  smoothstep), so there is no blur pass.
- **Colours and widths:** uniform tables indexed by `RenderClass`, so zoom and theme changes
  never re-tessellate.
- **Zoom and pitch:**
  - Overzoom above z14.
  - The nearest loaded ancestor is drawn while children load.
  - Pitch is capped at 45°.
  - Cover is limited to 48 tiles.
- **Drawing:** the view stays paused and draws on demand only; it's paused when hidden or not key.
- **US/CA cameras:** DeFlock/FlockHopper's hourly **z11 MVT tiles**. Only the region's non-empty
  tiles are fetched, pruned with the 1.3 MB national **index** (`FHIX`), and the result is
  filtered to the region polygon.
- **Cameras elsewhere:** Overpass, chunked by z7 tile boxes. Requests are serial, with backoff
  and a budget.
- **Region catalogue:** Geofabrik `index-v1.json` (ODbL, fetched at runtime, cached, refreshed
  monthly). Only the chosen region's polygon is kept.
- **Storage:** `~/Library/Application Support/GRID[-QA]/Maps/` with `tiles/`, `alpr/<storageKey>/`
  and `regions/`. All writes are atomic and the folder is checked for symlinks.
- **No ODbL data in the repo:** tests use synthetic fixtures built by test-only encoders.

## 3. Contracts (frozen)

### 3.1 GridCore data types
`Sources/GridCore/Maps/MapContracts.swift` and `TileMath.swift` (with `MapProjection`). Read them;
don't change them. Notable invariants:
- `TileGeometry` positions are **tile-local 0…1**. World placement comes only from `TileID` via
  `MapProjection.tileMatrix`.
- `LineVertex` stride is 32 and `ExtrusionVertex` stride is 16 (`shade`/`flags` as UInt16 at
  offsets 12 and 14); they match the MSL structs byte for byte (tested in `MapsMathTests`).
- `MapFrame.tileGeneration` changes when the tile source changes; the renderer drops all GPU
  tiles then.
- `RenderClass.rawValue` indexes the per-frame colour and width tables (`RenderClass.allCases.count
  ≤ 24`).
- MVT geometry is in layer integer space, y down. Polygons are `[exterior, holes…]` and unclosed,
  with ≥ 3 points per ring.
- `RegionDescriptor.storageKey` is the only way a region becomes a path component.
- GridCore never imports AppKit, Metal or CoreLocation. Every decoder is total: it throws or skips
  and never traps on any input.

### 3.2 App render contract
`Sources/Grid/Maps/MapRenderContract.swift`: `MapPalette`, `MapFrame`, `CameraMarker`,
`ClusterMarker`, `LocationMarker`, `RegionOutline`, `MapGesture`, `MapKey`, `PlacedMapLabel`.

### 3.3 Function signatures each workstream must provide

**A — map geometry (GridCore/Maps)**
```swift
public enum MVTDecoder {
    public static func decode(_ data: Data, layers: Set<String>? = nil, limits: MVTLimits = .init()) throws -> MVTTile
}
public enum Earcut {
    /// rings[0] exterior, rest holes; returns triangle indices into the rings flattened in order.
    public static func triangulate(_ rings: [[SIMD2<Float>]]) -> [UInt32]
}
public enum LineTessellator {
    public static func append(_ pts: [SIMD2<Float>], closed: Bool, cls: RenderClass, flags: UInt16,
                              miterLimit: Float = 2, vertices: inout [LineVertex], indices: inout [UInt32])
}
public enum OpenMapTilesSchema {
    public static let layers: Set<String>   // the layers v1 decodes
    public static func fillClass(layer: String, tags: [String: MVTValue]) -> RenderClass?
    public static func lineClass(layer: String, tags: [String: MVTValue]) -> (RenderClass, UInt16)?   // class, flags
    public static func label(layer: String, tags: [String: MVTValue]) -> (text: String, kind: LabelKind, priority: Int, minZoom: Float)?
    public static func buildingHeight(_ tags: [String: MVTValue]) -> Float      // metres, 0…500, default 10
}
public enum TileGeometryBuilder {
    public static func build(_ tile: MVTTile, id: TileID) -> TileGeometry
}
public struct LabelCandidate: Sendable { public var text: String; public var kind: LabelKind; public var priority: Int
    public var center: SIMD2<Double>; public var size: SIMD2<Double>; public init(...) }
public enum LabelPlacer {
    /// Greedy collision in screen space; candidates in `keep` (last frame's texts) are placed first.
    public static func place(_ c: [LabelCandidate], viewport: SIMD2<Double>, keep: Set<String>, max: Int = 40, padding: Double = 4) -> [LabelCandidate]
}
public struct TileSource: Sendable, Equatable {
    public let tileJSONURL: URL; public let template: String; public let minZoom: Int; public let maxZoom: Int
    public let attribution: String; public let version: String?; public let host: String
    public static func parse(_ data: Data, from url: URL, maxBytes: Int = 1 << 20) throws -> TileSource
    public func url(for t: TileID) -> URL?
}
```

**B — ALPR core (GridCore/Maps)**
```swift
public enum OSMSurveillance {
    public static func isALPR(_ tags: [String: String]) -> Bool
    public static func directions(_ raw: String) -> [UInt16]
    public static func vendor(_ tags: [String: String]) -> ALPRVendor
    public static func vendor(brand: String?) -> ALPRVendor
    public static func camera(id: OSMElementID, at: LonLat, tags: [String: String], edited: Date?) -> ALPRCamera?
}
public struct DeFlockBuild: Sendable, Equatable {
    public let build: String; public let tileTemplate: String; public let indexURL: URL; public let bounds: BBox; public let maxZoom: Int
    public static func parse(_ data: Data, from url: URL, maxBytes: Int = 1 << 20) throws -> DeFlockBuild   // hosts: *.dontgetflocked.com, https only
    public func tileURL(_ t: TileID) -> URL?
}
public struct DeFlockIndex: Sendable {
    public init(_ data: Data) throws                       // "FHIX", v1, count, lat/lon int32e6, brand u8
    public var count: Int { get }
    public func count(in p: GeoPolygon) -> Int
    public func nonEmptyTiles(z: Int, in p: GeoPolygon) -> [TileID]
}
public enum DeFlockTile {
    public static func cameras(_ tile: MVTTile, id: TileID) -> [ALPRCamera]    // layer "cameras"
}
extension GeoPolygon {
    public var bbox: BBox { get }
    public func contains(_ p: LonLat) -> Bool              // even-odd, holes honoured
    public func tileCover(z: Int, limit: Int) -> [TileID]  // tiles whose bounds intersect the polygon
}
public struct RegionCatalog: Sendable {
    public static func parse(_ data: Data, maxBytes: Int = 16 << 20) throws -> RegionCatalog
    public var regions: [RegionDescriptor] { get }
    public func polygon(_ id: String) -> GeoPolygon?
    public func children(of id: String?) -> [RegionDescriptor]
}
public enum ALPRSourcePlanner {
    public static func sources(for r: RegionDescriptor?, polygon: GeoPolygon, us: BBox?, ca: BBox?) -> [ALPRSource]
}
public enum OverpassQuery {
    public static func alpr(_ box: BBox, timeout: Int = 90) -> String
    public static func chunks(_ p: GeoPolygon, z: Int = 7, limit: Int = 60) -> [BBox]
    public static func parse(_ data: Data, maxElements: Int = 200_000) throws -> (cameras: [ALPRCamera], osmBase: Date?, remark: String?)
}
public struct CameraIndex: Sendable {
    public init(_ cameras: [ALPRCamera])
    public var cameras: [ALPRCamera] { get }
    public func query(_ box: BBox) -> [Int]
    public func clusters(_ box: BBox, cellWorld: Double) -> [CameraCluster]   // Mercator-space grid cells
    public func nearest(to p: LonLat, maxWorldDistance: Double) -> Int?
}
public enum RegionPackage {
    public static func encode(_ cameras: [ALPRCamera]) -> Data
    public static func decode(_ data: Data, maxCount: Int = 2_000_000) throws -> [ALPRCamera]
}
public struct FetchPolicy: Codable, Sendable, Equatable {
    public init(base: TimeInterval = 30, max: TimeInterval = 600, dailyBudget: Int = 60)
    public mutating func failed(status: Int, now: Date)   // 429/406/504 → backoff doubles; others count once
    public mutating func succeeded(now: Date)
    public func canRequest(now: Date) -> Bool
    public var retryAt: Date? { get }
}
```

**C — renderer and view (Grid/Maps)**
```swift
@MainActor final class MapRenderer: NSObject, MTKViewDelegate {
    init?(view: MTKView)
    func setFrame(_ f: MapFrame)          // marks the view for display; uploads new tiles lazily
    var gpuTileCount: Int { get }         // QA readout
    var lastFrameGPUms: Double { get }    // QA readout
}
struct MapMetalView: NSViewRepresentable {
    var frame: MapFrame
    var onGesture: (MapGesture) -> Void
    var onViewport: (SIMD2<Double>) -> Void        // view size in points
    var interactive: Bool                          // false under consent/overlays
}
```
`MapMetalView` places labels itself (GridCore `LabelPlacer` + `MapProjection` + a CTLine width
cache) and draws them in the render pass from a string atlas (see the addendum at the end).

## 4. Tasks, ownership and order

| # | Task | Owner | Files (new unless noted) | Depends on | Parallel |
|---|---|---|---|---|---|
| 0 | Contracts, TileMath, plan | lead | done on `maps` | — | — |
| A | Map geometry core + tests | Sonnet worker A (worktree) | `GridCore/Maps/{MVTDecoder,Earcut,LineTessellator,OpenMapTilesSchema,TileGeometryBuilder,LabelPlacer,TileSource}.swift`, `Tests/GridCoreTests/Maps{MVT,Earcut,Line,Geometry,Label,TileSource}Tests.swift`, `Tests/GridCoreTests/Support/MVTTestEncoder.swift` | 0 | with B, C |
| B | ALPR core + tests | Sonnet worker B (worktree) | `GridCore/Maps/{OSMSurveillance,DeFlock,GeoPolygonMath,RegionCatalog,OverpassQuery,CameraIndex,RegionPackage,FetchPolicy}.swift`, `Tests/GridCoreTests/Maps{ALPR,DeFlock,Region,Overpass,CameraIndex,Package}Tests.swift` | 0 (uses only contract MVT types) | with A, C |
| C | Renderer, shaders, view, labels | Fable (worktree) | `Grid/Maps/{MapRenderer,MapShaders,MapMetalView,MapLabelLayer}.swift` | 0; visual tuning after A merges | with A, B |
| D | Network, tile cache/store, ALPR store, downloads, Overpass client, location, update sources | lead | `Grid/Maps/{MapNetwork,TileCache,TileStore,ALPRStore,RegionDownloader,OverpassClient,LocationProvider,MapUpdateSources,MapStorage}.swift`, `Grid/Updates/UpdateSource.swift` | A, B signatures (code), merges to build | lead, on `maps` |
| E | UI and integration | lead | `Grid/Maps/{MapModel,MapPanel,MapInspector,MapRegionsPanel,MapSettingsSection,MapReadouts}.swift`; edits to `AppState`, `RootView`, `GridApp`, `Shortcuts`, `CommandPalette`, `SettingsPanel`, `UpdateSettingsSection`, `DebugHooks`, `Info.plist`, `Grid.entitlements`, docs | C, D | last |
| F | Review + fixes | Fable reviews; lead fixes or assigns | — | A–E | — |

**Rules:**
- Workers edit only their own files. No edits to contracts, `Package.swift`, other targets or
  docs.
- Workers commit on their worktree branch. The lead merges into `maps` and reviews every diff.
- A contract change stops dependent work: the lead updates this file and re-sends the briefs.

## 5. Security and privacy requirements (all workstreams)

- **Remote input is untrusted:** MVT, TileJSON, the DeFlock index and tiles, Geofabrik JSON,
  Overpass JSON and the region packages on disk.
  - Caps are enforced **during transfer** (not after decompression) and again in the decoders.
  - Decoders never trap.
  - Counts are checked against byte lengths.
  - Strings are capped.
  - Coordinates are range-checked.
- **URLs:**
  - https only; no userinfo or ports.
  - Hosts are pinned per source: `tiles.openfreemap.org` (or a user tile URL after re-consent),
    `*.dontgetflocked.com`, `download.geofabrik.de`, `elevation-tiles-prod.s3.amazonaws.com`
    (terrain, only while the Terrain layer is on), and the user-chosen Overpass endpoint.
  - Tile URLs come only from validated templates with `{z}/{x}/{y}` substitution.
  - Redirects are followed only within the same host.
  - Inspector links are built from numeric OSM ids only.
- **Paths:**
  - Only `storageKey`, integer tile coordinates and the tile cache's **source key** (a SHA-256
    prefix of the tile host + template, never a remote string) become path components.
  - Before writing, the Maps folder must not be a symlink and must resolve inside Application
    Support.
  - Writes are atomic.
  - `EACCES` / `ENOSPC` produce a `StateBlock` error, never a crash.
  - Clear Map Data never follows symlinks.
- **Network only after consent:**
  - A **user-chosen Overpass endpoint or tile URL** is validated (https, no userinfo or port) and
    needs re-consent when it changes.
  - Nothing is requested before **ENABLE MAP DATA** (tiles and catalogue).
  - Each region download is confirmed with its host, request count and estimated size.
  - User-Agent: `GRID/<version> (+https://github.com/max-pasho/grid)`.
  - Ephemeral session, no cookies, `urlCache = nil`.
- **Location:**
  - Requested only on ⌖ click.
  - Held in memory and never written, logged or put in a URL.
  - Info.plist gets `NSLocationWhenInUseUsageDescription` and `NSLocationUsageDescription`.
  - `Grid.entitlements` gets `com.apple.security.personal-information.location`.
- **Fair use:**
  - DeFlock: ≤ 4 parallel requests, immutable tiles cached by build, TileJSON at most hourly.
  - Overpass: serial, `FetchPolicy` backoff (30 s → 10 min), ≤ 60 chunk requests a day, user
    endpoint.
  - Geofabrik: at most monthly.
- **No ODbL data is bundled, including in tests.**

## 6. Validation

- **A/B:** unit tests with synthetic fixtures, plus mutation fuzzing (truncate, flip bytes,
  inflate counts) that must never trap. Performance tests are `measure` blocks that report and
  don't gate.
- **Live fixtures (optional, never committed):** `scripts/qa/maps-fixtures.sh` downloads into the
  gitignored `Tests/Fixtures/live/`, and tests skip when it's absent.
- **C:** builds; draws synthetic geometry in the QA app; paused when hidden; theme switch recolours
  without a rebuild; no per-frame GPU buffer allocation in steady state; ≤ 2 ms main-thread per
  frame while panning (40 labels).
- **Integration (lead, QA app with `--qa` hooks):**
  - consent gating;
  - tiles load and render at z3 / z10 / z14 / z17 and at pitch 45;
  - Rhode Island region download (request count asserted);
  - cameras displayed, clustered and selectable;
  - freshness rows;
  - Clear Map Data;
  - rail and shortcut renumbering;
  - CPU idle ≈ 0% (< 1%) with the page visible; GPU and memory measured.
  - The MTKView is `accessibilityHidden`, and LAYERS ▸ LIST gives an accessible table of the
    cameras.
- **Regression:** the full `swift test` suite; QA app smoke tests of Terminal, Files, Web,
  Settings, the startup build-on, menus and the deck.

## 7. Migration and rollback

- No data migrations: new UserDefaults keys are under `map.*`, and new files go under `Maps/`.
- **Rollback:** remove the rail item; the Maps folder is inert. Settings › Map › Clear Map Data
  deletes everything.
- **Shortcut migration:** if the user had bound ⌥⌘5 to another command, that binding wins and
  `showMap` stays unassigned.

## 8. Assumptions to verify (and how)

| Assumption | Check |
|---|---|
| z11 DeFlock tiles hold every camera with full attributes | Compare index count vs tile features on one dense TX tile (lead, during D) |
| `cameras-ca-hourly.json` mirrors the US layout | ✓ exists (1.3 KB). Check index/manifest keys in D |
| Decode + build of a dense z14 tile < 15 ms | A's `measure` test on a synthetic 13k-vertex polygon + the live fixture when present |
| Analytic glow looks right | C's QA screenshots at z12/z14/z16, three themes |
| CATextLayer labels hold up while panning | C measures main-thread time while dragging with 40 labels |
| Location prompt on ad-hoc builds | Lead: click Locate in the QA build. A hardened-runtime build is not available here (no Developer ID), so it's documented as untested |
| URLSession size caps cancel `br` streams | D: cap the 39 MB file at 1 MB in a QA hook and confirm the cancel |

## 9. Decisions and reasons (incl. disagreements)

- **The per-region source is DeFlock tiles, not Overpass, for the US and Canada.** Fable's probe of
  an Overpass area query for Rhode Island took 48 s. DeFlock tiles are complete at z11, immutable,
  and about 60 B per camera. They reveal the region to the FlockHopper host; the confirmation says
  so.
- **No national-file slicing in v1.** It's the most private option, but the owner asked for region
  selectivity and smaller downloads. It's recorded for later.
- **Analytic glow instead of a blur pass:** one pass, no offscreen targets, and trivial to turn
  off.
- **The lead owns TileMath/MapProjection,** so the renderer, hit testing and labels share one
  tested projection.
- **`LineVertex` is 32 bytes, not the 24 Fable first proposed:** `float2` alignment makes 28 round
  up to 32. This is tested.
- **No FOLLOW mode in v1.** It keeps location to explicit clicks only.
- **Fable implements the renderer (C),** the most specialised piece. The lead reviews it and
  verifies it visually; Fable's review of its own code doesn't count as independent.

- **Fable's review of this plan (round 2):** all three blocking items were accepted and applied:
  `ExtrusionVertex` flags, `MapFrame.tileGeneration`, and the hashed tile-cache source key. Its
  non-blocking items were folded into the briefs. One is deferred: `TileMath.cover` picks
  pitched-view tiles by bbox and distance to the centre, which can drop far-edge tiles at 45°. It's
  acceptable for v1 with a 48-tile cap, and revisited if holes show in QA.

---

## Briefs

### Brief A — Map geometry core (Sonnet worker A)
1. **Objective:** pure-Swift decoding and tessellation of OpenMapTiles MVT into `TileGeometry`,
   plus label placement and TileJSON parsing. Nothing user-visible on its own; it feeds the
   renderer.
2. **Context:** read §2, §3 and §5 of this file, `GridCore/Maps/MapContracts.swift`,
   `TileMath.swift` and `docs/MAPS-PLAN.md` §1.3–1.4. The OpenMapTiles schema:
   - `transportation`: `class` motorway/trunk/primary/secondary/tertiary/minor/service/track/path/
     rail/transit/ferry…; `brunnel` tunnel/bridge.
   - `water`, `waterway` (river/canal/stream).
   - `landuse` (residential/industrial/commercial/retail…).
   - `landcover` (grass/wood/farmland…), `park`.
   - `building` (`render_height`, `render_min_height`).
   - `place` (`class` city/town/village/suburb…, `name`, `rank`).
   - `transportation_name` (`name`, `class`).
   - `water_name`.
3. **Own:** the files in §4 row A. **Don't touch:** the contracts, `Package.swift`, anything under
   `Sources/Grid`, other tests, docs.
4. **Contracts:** the signatures in §3.3 A, exactly. If one is unworkable, stop and escalate; don't
   change it.
5. **Sequence:** MVTTestEncoder (test helper) → MVTDecoder + tests + fuzz → Earcut + tests →
   LineTessellator + tests → schema → TileGeometryBuilder + tests + `measure` → LabelPlacer →
   TileSource.
6. **Security and edge cases:**
   - MVT:
     - Truncated varints (> 10 bytes); lengths overrunning the buffer; unknown wire types (skip by
       type: 0 varint, 1 64-bit, 2 length, 5 32-bit; others throw).
     - `extent` 0 or > 1<<16 (skip the layer); a command count over the remaining ints; tag index
       out of range or an odd tag count (drop the feature); invalid UTF-8.
     - All value types (string, float, double, int, uint, sint, bool).
     - Rings < 3 distinct points (drop); duplicate consecutive points (dedupe).
     - Winding: positive shoelace area in y-down = exterior, negative = hole of the current
       exterior. A hole before any exterior is dropped.
     - Coordinates outside the extent: keep within ±2×extent, clamp beyond.
     - Skip unwanted layers without parsing their features. Enforce every `MVTLimits` field.
   - Earcut: a faithful port of mapbox/earcut (ISC; credit it in a file header), including the
     z-order hash for > 80 vertices, hole elimination and the fallback passes. It must not hang
     on degenerate input; cap iterations.
   - Lines: zero-length segments give no NaN; miter limit 2, beyond it a bevel. Closed rings join
     the end to the start. Output is in tile-local 0…1 (divide by extent). Tunnel flag from
     `brunnel=tunnel`.
   - Builder: positions normalised by extent; drop features > `maxVerticesPerFeature`. Roads draw
     only at classes the schema maps. Buildings produce an extrusion: earcut roof at the height
     (flags `roof`), walls as 2 triangles per exterior edge with the top two vertices flagged
     `wallTop`, shade (UInt16) from edge orientation. Labels: `place` points,
     `water_name` points, and road names at the midpoint of the longest segment (minZoom 15).
     `byteCount` = the sum of the array byte sizes.
   - TileSource: TileJSON 2/3; `tiles[0]` https, no userinfo or port, and the host equal to the
     TileJSON host. The template must contain `{z}`, `{x}`, `{y}` (`{s}` is not supported → throw).
     minzoom/maxzoom clamped to 0…22. Attribution is stripped of HTML tags. `version` = the path
     segment immediately before `{z}` (OpenFreeMap: `20261101_080013_pt`).
   - Schema decisions (settled):
     - `place` label minZoom by class: country 2, state 5, city 4, town 8, village 11,
       suburb/neighbourhood 13; others skipped.
     - `transportation` **polygons are dropped** (lines only).
     - `boundary`: lines with `admin_level` ≤ 4 → `.boundary`, and `maritime=1` is skipped.
     - `aeroway`: runway/taxiway lines → `.aeroway` lines; runway polygons → `.aeroway` fills.
     - `transit`/`ferry` → skipped in v1.
7. **Acceptance:**
   - Every test passes, including a fuzz test of ≥ 5,000 mutations that never traps.
   - Earcut triangle area matches the polygon area within 0.1% (square with a hole, concave
     comb, 13k-vertex synthetic city block with holes).
   - The builder on a synthetic dense tile is reported by a `measure` block.
   - LabelPlacer: no overlaps, `keep` honoured, max honoured.
   - TileSource: rejects http, userinfo, a foreign host, a missing `{z}`, `{s}`, and oversize
     input; accepts the OpenFreeMap shape (write it as a literal string in the test).
   - `swift build` and `swift test` are green.
8. **Dependencies:** none beyond §3.
9. **You decide:** internal helpers and private types, test structure, performance tricks.
10. **Escalate:** any contract change, needing a new dependency, ambiguity in the schema mapping
    that affects the look (e.g. which classes to draw), a performance target missed by > 2×.
11. **Handoff:** files changed, test count and results (paste the summary line), measured timings,
    assumptions, open concerns, and the worktree branch name with its final commit.

### Brief B — ALPR core (Sonnet worker B)
1. **Objective:** pure-Swift parsing and indexing for the camera layer: OSM tags → `ALPRCamera`;
   DeFlock build, index and tiles; region catalogue and polygons; the Overpass query and parser;
   the spatial index and clustering; the on-disk region package; fetch backoff. It feeds the
   camera downloads and the map overlay.
2. **Context:** read §2, §3 and §5 of this file, `MapContracts.swift`, `TileMath.swift` and
   `docs/MAPS-PLAN.md` §4.
   - **DeFlock TileJSON** (US): `{"tiles":["https://deflock.dontgetflocked.com/cameras-us-hourly-<build>/{z}/{x}/{y}.mvt"],
     "build":"7b4993d5a0e3","bounds":[-159.69,17.68,-64.59,61.61],"maxzoom":14,"index_bin":"https://deflock.dontgetflocked.com/cameras-us-hourly-index-<build>.bin", …}`.
     The CA build is at `cameras-ca-hourly.json` with the same shape.
   - **Index:** ASCII `"FHIX"`, then u32 LE version = 1 and u32 LE count. Then three columns:
     `lat` int32 LE ×1e-6 (count), `lon` int32 LE ×1e-6 (count), `brandId` u8 (count). The total
     length must be exactly 12 + 9·count.
   - **Camera tiles:** layer `cameras`, points. Properties: `osmId` (number), `osmType` ("node" or
     "way"), `brand`, `direction` (number), `directions` (string like "45;225"),
     `directionCardinal`, `mountType`, `operator`, `surveillanceZone`, `osmTimestamp` (ISO8601),
     `osmVersion`, `ref`, `startDate`. z11 holds every camera with all attributes.
   - **Geofabrik `index-v1.json`:** a FeatureCollection. Each feature has `properties` `id`,
     `parent`, `name`, `iso3166-1:alpha2` [..], `iso3166-2` [..], `urls`, and a `geometry` that is a
     MultiPolygon or Polygon in lon/lat. US states have parent `north-america` and `iso3166-2`
     `US-xx`. Canadian provinces have parent `canada`.
   - **Overpass JSON:** `{"osm3s":{"timestamp_osm_base":"…"},"remark":"…"?,"elements":[{"type":"node","id":1,"lat":..,"lon":..,"tags":{..},"timestamp"?},{"type":"way","id":2,"center":{"lat":..,"lon":..},"tags":{..}}]}`.
3. **Own:** the files in §4 row B (`DeFlock.swift` may hold DeFlockBuild, DeFlockIndex and
   DeFlockTile). **Don't touch:** the contracts, `Package.swift`, `Sources/Grid`, A's files, docs.
4. **Contracts:** the signatures in §3.3 B, exactly. `DeFlockTile` takes an already decoded
   `MVTTile` (build test tiles in memory; no decoder needed).
5. **Sequence:** OSMSurveillance → GeoPolygon math → RegionCatalog → DeFlockBuild/Index/Tile →
   ALPRSourcePlanner → OverpassQuery → CameraIndex → RegionPackage → FetchPolicy.
6. **Security and edge cases:**
   - **Directions:** `"0"`→[0]; `"360"`→[0]; `"-45"`→[315]; `"12.5"`→[13]; `"NE;SW"`→[45,225];
     `"north"`→[0] (16-point compass words, case-insensitive); `"45;225"`; `"45-90"` (a range:
     midpoint); garbage dropped; at most 8 directions; deduplicated.
   - **ALPR match:** `man_made=surveillance` and `surveillance:type` contains `alpr` as a
     `;`-separated token, case-insensitive.
   - **Vendor:**
     - Flock if `manufacturer:wikidata=Q108485435`, or `manufacturer`/`brand` contains "flock"
       (case-insensitive).
     - Motorola Q634815, Genetec Q30295174, Leonardo Q910379, Axis Q2347731; name matches for
       Rekor, Axon and Neology.
     - Otherwise `other(trimmed ≤ 60 chars)` or `.unknown`.
   - **Strings:** operator, mount and zone trimmed and ≤ 120 chars.
   - **Settled:** a `directions` string wins over the numeric `direction` when both exist.
     `osmTimestamp` → `lastEdited`. `nonEmptyTiles` counts only cameras where
     `polygon.contains(point)` (not just the bbox). Geofabrik geometry may be `Polygon` or
     `MultiPolygon`.
   - **Coordinates:** reject NaN or out-of-range values.
   - **Polygons:** even-odd containment with holes; tolerate unclosed and closed rings and drop
     degenerate rings. `tileCover` uses a bbox prefilter, then tile-bounds/polygon intersection
     (any vertex inside, any tile corner inside, or an edge crossing); capped by `limit`.
   - **Catalogue:** cap 16 MB; skip features with bad geometry (keep them in the list without a
     polygon); `children(of: nil)` = top-level continents.
   - **DeFlockBuild:** https; host `deflock.dontgetflocked.com` or `tiles.dontgetflocked.com`; the
     template contains `{z}/{x}/{y}`; the index URL on the same host; the build is `[a-z0-9]{6,40}`.
   - **Index:** exact length check; coordinates valid.
   - **Overpass parse:** `remark` with a runtime error → throw; elements without coordinates
     skipped; non-ALPR elements skipped; cap elements.
   - **RegionPackage** (little-endian):
     - magic `GALP`, u32 version 1, u32 count;
     - per camera: lat/lon int32 ×1e-7, osm type u8, osm id i64, vendor u8 (+ string index for
       `.other`), direction count u8 + up to 8 u16, string indices u32 (operator, mount, zone,
       vendor-other; 0xFFFFFFFF = nil), `lastEdited` i64 seconds (Int64.min = nil);
     - a string table at the end (u32 count, then u32 length + UTF-8 bytes).
     - Decoding bounds-checks every offset and index, and rejects trailing garbage.
   - **CameraIndex:** cameras bucketed by z12 tile key; `query` walks the box's tiles; `clusters`
     uses Mercator grid cells; `nearest` uses Mercator distance. 150k cameras must build in < 1 s.
   - **FetchPolicy:** 429/406/504 → `retryAt = now + backoff`, backoff doubles from `base` up to
     `max`; success resets it. The budget is counted per UTC day.
7. **Acceptance:**
   - The direction table and vendor table tests pass.
   - Polygon tests: square, square with a hole, a multipolygon, a concave L.
   - `tileCover` of a small rectangle matches TileMath tiles.
   - The catalogue parses a synthetic Geofabrik-shaped JSON (US-CO, norcal under us/california,
     CA-ON) and rejects oversize input.
   - The index rejects a wrong magic or length and counts per polygon.
   - `DeFlockTile` maps a synthetic tile to cameras at the right lon/lat (±1e-6) with attributes.
   - Overpass parses node and way(center) entries and a remark error.
   - The package round-trips 10k random cameras and rejects every single-byte truncation and
     corrupted offsets.
   - `CameraIndex` query and nearest give correct results against brute force on 20k random
     points; `measure` 150k builds.
   - Fuzz: ≥ 2,000 mutations each for the package and the index never trap.
   - `swift build` and `swift test` are green.
8. **Dependencies:** §3 types only.
9. **You decide:** internals, the compass table, test layout.
10. **Escalate:** contract changes; ambiguity about vendor naming visible to users; anything
    needing network access in tests (not allowed).
11. **Handoff:** as Brief A.

### Brief C — Renderer, shaders, view and labels (Fable)
1. **Objective:** the GridMap renderer.
   - **Draws:** a `MapFrame` in GRID's Tron / Cyberpunk look: a void bg0, a procedural grid floor
     (minor and major lines in world space, fading with pitch distance), bg3 water with a faint
     accent shoreline, a subtle landuse/park tint, and roads as glowing accent lines graded by
     class (motorway brightest).
   - **Buildings:** extruded when pitched, with dark faces and accent roof edges.
   - **Overlays:** ALPR reticles (an open square with corner ticks) with 60° FOV wedges, cluster
     blocks `▣ n` with the count drawn as a label, the you marker with an accuracy ring, and region
     outlines (dashed accent).
   - **Interaction:** gestures (pan, zoom, rotate/pitch, click, ⇧-drag rectangle, keys) are
     reported through `MapGesture`.
   - **Labels:** placed and drawn in an overlay.
2. **Context:** read §2, §3 and §5 of this file and `MapRenderContract.swift`;
   `Web/GlobeRenderer.swift` for the patterns (runtime `makeLibrary(source:)`, a static compiled
   cache, pausing on key/occlusion, `CATextLayer` labels with transactions disabled, DEBUG
   switches); `Theme/Theme.swift` for tokens; `docs/DESIGN.md` for motion and performance rules.
3. **Own:** `Sources/Grid/Maps/{MapRenderer,MapShaders,MapMetalView,MapLabelLayer}.swift` only.
   **Don't touch:** the contracts, GridCore, other app files, docs, Package.swift.
4. **Contracts:** §3.2 and §3.3 C. Use `MapProjection(camera:viewport:)` and `tileMatrix(_:)` for
   all placement; heights through `MapProjection.worldUnitsPerMeter(y:)`. Colours and widths come
   from uniform tables indexed by `RenderClass.rawValue`, computed per frame from `MapPalette` and
   zoom.
5. **Sequence:**
   1. Shader source and pipelines: floor, fill, extrusion (depth), line (analytic glow), overlay
      (instanced SDF quads).
   2. Per-tile GPU buffers with an LRU of 60.
   3. On-demand drawing (`isPaused`, `enableSetNeedsDisplay`) and pausing when hidden or not key,
      like `GlobeMetalContainer`.
   4. Input handling in an MTKView subclass (scrollWheel with precise deltas → pan or zoom
      (⌘-scroll or pinch zooms; a plain trackpad scroll pans), magnify, rotate, drag, ⌥-drag
      rotate/pitch, click vs drag threshold 4 pt, ⇧-drag rectangle, keyDown).
   5. Labels: project anchors, measure with cached CTLine widths, `LabelPlacer` with last frame's
      texts kept, ≤ 40, pooled CATextLayers, SF Mono 9.5 medium, uppercase places, re-placed at
      most every other frame while dragging.
   6. A DEBUG-only synthetic-geometry harness so it can be checked before A lands.
6. **Security and edge cases:**
   - Never trust counts: buffer sizes come from array counts, and empty batches are skipped.
   - Handle device loss or no Metal device (fall back to a static `StateBlock`-like message drawn
     by the caller: return nil from init).
   - Drawable size churn during the build-on: debounce `onViewport`.
   - Glow off → `glowPx` 0. Motion off → `reveal` is always 1.
   - No idle animation: draw only when the frame changes or an animation is running.
   - Clamp pitch to `MapCamera.maxPitch`.
   - Labels must not crash on empty strings or huge counts.
   - **Settled:**
     - **Latency:** apply pan, zoom and rotate to a view-local camera immediately and report
       through `onGesture`. Treat `frame.camera` as authoritative when it arrives (the model
       echoes it), so a model update never fights an in-progress gesture.
     - **Overdraw:** draw descendants first, write the stencil, then draw ancestors
       stencil-tested.
     - **Overlays:** project cameras, outlines and location on the CPU in double precision.
       Per-tile `worldUnitsPerMeter` comes from the tile centre.
     - **QA:** expose a DEBUG `debugForceActive` switch so unkeyed QA windows draw.
     - **Accessibility:** the MTKView is `accessibilityHidden`.
     - **Stale tiles:** drop all GPU tiles when `tileGeneration` changes.
     - **Roof edges:** wall-top vertices carry the `wallTop` flag; draw the accent roof edge
       from it.
7. **Acceptance:**
   - `swift build` is green.
   - A synthetic frame draws in the QA app (the lead wires the page). Pausing and resuming works.
   - A theme switch recolours without re-uploading tiles.
   - With 48 synthetic tiles the frame GPU time is reported via `lastFrameGPUms`.
   - Panning feels direct: no per-frame GPU buffer allocation in steady state, and ≤ 2 ms
     main-thread time per frame while panning with 40 labels.
8. **Dependencies:** §3. Visual tuning with real tiles after A merges (the lead will ping you).
9. **You decide:** shader internals, uniform layout, buffer strategy, gesture mapping details, and
   the exact look within the design language.
10. **Escalate:** any contract change (e.g. `MapFrame` fields), needing a new framework, or a
    performance target unreachable.
11. **Handoff:** as Brief A, plus screenshots or notes on the look and measured GPU times.

## Addendum — terrain (0.8)

- **Source:** AWS Terrain Tiles, Terrarium PNGs (`(R·256 + G + B/256) − 32768` m), 256 px, z0–12.
  A map tile reads the elevation tile two levels up (its 64 px are exactly what the 65×65 grid
  samples, so one download serves 16 map tiles), capped at z12. Until it arrives the tile borrows
  a coarser elevation tile already in memory (no contours), and with none it draws at the
  camera's ground level. Fetched by `TerrainStore` only while map data is
  enabled and the Terrain layer is on, cached under `Maps/terrain/z/x/y.png` (written only after
  a successful decode; trimmed to 150 MB). ImageIO decodes; the raw pixel bytes are read without
  colour management, because the channels are data.
- **Per tile:** `Terrarium.grid` resamples to a 65×65 `TerrainGrid` (shared edges); `Contours`
  traces marching squares (saddles by centre value) into stitched polylines with zoom-based
  intervals in feet or metres (from the locale), index lines every fifth level, and up to 24
  elevation labels. Contours join the tile's geometry (`TileGeometry.revision` 1 → re-upload).
- **Drawing:** `TerrainLift` (GridCore) is the single height rule shared by the GPU and CPU:
  sea-level clamp (Terrarium holds ocean depths), heights relative to the ground under the
  camera centre, and a soft ceiling at 92% of the camera's height. Its scale eases in from 4° to
  20° of tilt, so the top-down map stays planimetric. The renderer uploads each grid as an
  R32Float texture and displaces fills, lines, buildings and a 65×65 skirted terrain mesh in the
  vertex shaders. The mesh writes depth pushed back by 0.6% of the view distance, so draped
  geometry never fights it but ridges still hide what's behind. Shaded relief (light from the
  north-west) and the draped lattice are a blended pass per level, kept off water by the stencil;
  contours also stay off water. Markers and labels use `MapFrame.elevation(at:)`; clicks refine
  the ground hit by the lift's screen offset.

## Addendum: gestures, labels and tile loading (supersedes the label and LRU notes above)

- **Camera.** The map view draws gestures from its own camera at display rate. `MapModel.camera`
  takes every gesture at once but is not what SwiftUI observes per event: views that read it are
  told about ten times a second, and `MapModel.frame` is rebuilt only when what it draws changes
  (the tile set, a loaded tile, markers, layers), not for every camera step. The frame carries
  the model's camera from build time; the view treats one that matches its recent cameras as an
  echo. The terrain lift is worked out by the renderer for the camera it draws
  (`MapFrame.lift(for:viewport:)`), not stored per frame.
- **Labels** are drawn by the renderer in the map's own render pass (`MapLabels.swift`):
  `MapLabelPlanner` places them every frame for the projection being drawn (interned strings,
  per-tile prepared anchors, `LabelPlacer.place(boxes:)`), and `MapLabelAtlas` holds each string
  rasterised once with CoreText in an R8 texture. There is no label view and no throttle, so a
  label cannot trail the map. Look unchanged: SF Mono 9.5, places uppercase, rotated line labels.
- **Tile plan** (`MapModel.plan`, ≤ 30 Hz during gestures plus one pass after they stop):
  the cover; a *backdrop* of its ancestors two and four levels up (loaded first, so ground that
  scrolls or zooms in is never empty); a *ring* around the view at rest, or the covers 0.3 s and
  0.6 s ahead of the gesture while moving. Ring tiles at the cover's level or coarser are part
  of the frame (the renderer skips tiles that are off screen), deeper ones are only loaded.
- **Loading.** `TileStore` runs up to 10 loads for tiles still asked for (20 in all; loads the
  view moved away from finish without blocking the queue), reads the disk cache without queueing
  behind writes or trims, and evicts least-recently-drawn tiles that nobody asks for first.
  The renderer keeps up to 160 tiles / 320 MB on the GPU and spreads uploads over frames.
- **QA.** `{"cmd":"map","op":"gesture",…}` drives pan/zoom/rotate through the view's gesture
  path at display rate and writes frame times, label lag and tile coverage (DebugHooks.swift).

## Addendum: places and search

- **Points of interest** come from the OpenMapTiles `poi` layer already in the base tiles
  (z12–z14): `OpenMapTilesSchema.poi` keeps named points, `POICatalog` maps `class`/`subclass`
  to ten categories (food, shops, fuel, transit, health, lodging, parks, sights, services, other)
  and skips noise (entrances, toilets, benches…). They live in `TileGeometry.pois` and are drawn
  by the label planner as a glyph (an SF Symbol rasterised into the R8 atlas as a coverage mask)
  plus the name, at most 28 per frame on top of the 40 names, after road names in priority. The
  Places layer and per-category chips set `MapFrame.poiMask`. Clicks pick only glyphs drawn in
  the last frame.
- **Local search** (`LocalSearch` in GridCore) searches the place, water, street and POI names of
  every decoded tile in memory: accent-folded, whole-name and prefix matches first, then words and
  substrings (no scattered subsequences); more important places and nearer ones rank higher, and
  the same name and kind within a kind-specific radius collapses to one result. Entries are built
  per tile revision off the main thread. Nothing leaves the Mac.
- **Online search** (`Nominatim` in GridCore, `MapSearch` in the app) follows the public server's
  policy: only on an explicit action (Return with no local match, ⌘Return, or the row), never as
  autocomplete; one request a second (`RequestSpacer`); answers cached in memory for 24 h
  (`ExpiringCache`); GRID's identifying User-Agent; an Off switch and a custom https endpoint in
  Settings › Map. First use asks (SEARCH-NET). The visible area is sent as a bias (`viewbox`), not
  a limit. Responses are capped at 512 KB and 10 results and treated as untrusted. Queries are
  never written to disk or logged.
- **Chosen place**: `MapModel.place` draws a diamond pin (`MapOverlayKind.pin`) with its name
  placed before every other label, and the side column shows a PLACE inspector (address,
  coordinates, Apple Maps and OpenStreetMap links).

## Addendum: on-device routing (native Swift router)

Chosen over a remote engine (FlockHopper / Valhalla) and the Java routing pack: nothing about a
trip leaves the Mac, and there is no helper runtime.

- **Road data.** A region's OSM extract (`urls.pbf` from Geofabrik's index, https on
  download.geofabrik.de only) is streamed to a file under `Maps/routing/` with a 700 MB cap and
  progress, after a ROUTE-DATA confirmation showing its size (HEAD). It is deleted once built.
- **PBF reader** (`GridCore/Routing/PBFReader.swift`): blob header ≤ 64 KiB, blob ≤ 32 MiB, raw
  or zlib (Compression's raw DEFLATE after the 2-byte header; size must match), `OsmSchema-V0.6`
  and `DenseNodes` only. Decodes node positions, ways with a given key, and relations of given
  types. Bounds-checked through `PBReader`; fuzzed in tests.
- **Graph** (`RoadGraph`, `RoadGraphBuilder`): pass 1 reads drivable ways (`RoadProfile`: car
  access hierarchy motorcar › motor_vehicle › vehicle › access, oneway incl. implied motorway and
  roundabout, `maxspeed` with mph, class default speeds) and node-via turn restrictions; node ids
  are sorted once and a node used twice or at a way end is a junction; pass 2 reads only those
  nodes' positions. Edges run junction to junction with their shape; a node missing from the
  extract cuts the way. Stored as `GRDG` v1 (struct-of-arrays, little-endian); every index is
  range-checked on load. Alabama: 152 MB extract → 77 MB graph (946k junctions, 1.18M edges) in
  about 6 s, about 0.5 GB above the app's baseline while building.
- **Search** (`RouteEngine`): edge-based A* over directed edges (so turn restrictions and the
  U-turn ban are exact), travel time from speeds, junction and turn costs (lefts cost more), a
  straight-line / 130 km/h heuristic. Points snap to the nearest drivable road (≤ 1.5 km) through
  a 0.01° edge grid. About 0.4 s for a city trip including loading checks.
- **Cameras** (`CameraExposure`): a camera sees a road passing within the buffer (75 m default,
  25–150) inside one of its 70° cones (no direction = all round; 0° is north, a real direction);
  the whole in-buffer part of each segment is checked, not just the nearest point. The avoiding
  search adds 600–1500 s per edge a camera sees; every route shown is re-scored by GRID itself.
- **Steps**: depart, turns by angle (slight / normal / sharp, U-turn), keep left/right on
  highways, ramps and merges, roundabouts with the exit number, arrive; cameras listed under the
  step where they are passed.
- **Checked against Valhalla** (FOSSGIS public server, four Birmingham trips): the downtown →
  Galleria route matched step for step; distances within 0–10 %, times within 0–10 %.
- **Export** (`CueSheet`, `GPXWriter` in GridCore; `MapRouteExport`): Print renders the route's
  area offscreen with a renderer of its own in `MapPalette.paper` (all tiles uploaded at once, a
  level finer than the page's zoom, 3× resolution; lines use source-over blending on the light
  palette) and lays out title, summary, map, the turn list in 13 pt with camera notes, the
  disclaimer and attribution as text, so the print system paginates for any paper size. GPX 1.1
  has the ends and passed cameras as `wpt`, the steps as `rte`, the line as `trk`; text is XML
  escaped (characters XML forbids dropped) and coordinates always use a decimal point. Copy puts
  the same turn list on the clipboard.
- **Not yet**: routes that cross from one region's data into another's, way-via turn
  restrictions, traffic, time-dependent access.

## Addendum: review pass (structure and performance notes)

- **MapModel** is split by concern: `MapModel.swift` (state, lifecycle), `+TilePlan` (cover,
  backdrop, ring and prefetch; look-ahead constants in `MapModel.Prefetch`), `+Frame` (frame
  building with cached markers, route and outline projections), `+Gestures`, `+Picking`.
  `CamerasInView` counts and lists cameras in view off the main thread.
- **Renderer**: `encode` is `prepare` (CPU) plus `MapFramePass` (one method per pass); frame
  uniforms live in one triple-buffered buffer; tile uploads run on a serial background queue
  (printing uploads synchronously), with tiles from the previous frame covering the ground until
  they land; atlas rasterisation and new-tile label preparation each have a 1.5 ms per-frame
  budget; labels are interned and measured only when they come within reach of the view.
- **Routing core**: snaps within 1 m of an edge end are the junction; up to 6 roads within 30 m of
  the nearest are tried as start / end candidates (charged at walking pace), which removed the
  loops round a block before the destination; searches can be cancelled; the edge grid stores
  32-bit ids and clamps its cells.
