# GRID Maps — Design & Implementation Plan

Status: **proposal, no code yet.** Research checked on 2026-11-09. Items marked **(verify)** are
not confirmed by documentation and must be tested in Phase 0 before anything depends on them.

Goal: a **Map** page in GRID's design language. It shows your location, live traffic, points of
interest, and automated licence plate reader (ALPR) cameras as mapped by OpenStreetMap volunteers
through [DeFlock](https://deflock.org). It can also plan **driving routes that avoid mapped cameras**
and print them as a **cue sheet** so the laptop can stay home. It keeps GRID's constraints:
- no cloud backend, accounts, telemetry or AI;
- your data stays local by default;
- every network request is explained before it happens;
- no privileged bridge to web content;
- no workaround for macOS privacy;
- native code.

---

## 0. Summary of recommendations

| Area | Recommendation | Main tradeoff |
|---|---|---|
| Renderer | **A custom Metal vector-tile renderer ("GridMap")**, built the same way as the new-tab globe and scoped to the Tron look. MapLibre Native is the fallback if the Phase 0 spike fails. MapKit is rejected for the base map. | More work up front (about 6–10 weeks), but no C++ dependency, memory-safe parsing of network data, and full control of the look. |
| Base data | **OpenMapTiles-schema vector tiles from [OpenFreeMap](https://openfreemap.org)** (no key, free). The tile URL can be changed, and self-hosted **Protomaps PMTiles** come later. | OpenFreeMap is donation-run and "may be discontinued", so the source must be swappable. |
| Traffic | **Off by default. Bring your own TomTom key** (stored in the Keychain). Vector flow tiles are drawn in GRID's semantic colours. Taking Apple's traffic off a hidden Apple map and redrawing it is **not possible within Apple's licence** (§2.1). An **"Open in Apple Maps"** button hands off to the Maps app. | Needs the user's own account. |
| POIs | **POIs come from the base tiles we already download**, so they cost no extra request. Wider search goes to **Nominatim only when you press Enter**. Apple search results can't be shown on a non-Apple map (§2.1). | Tile POIs are only as complete as OSM. A wider search sends the query out. |
| ALPR | **A daily nationwide snapshot (US/Canada) of DeFlock's OSM-derived data**, cached locally, so it doesn't reveal which area you look at. **Overpass** is used on demand for other regions and for "refresh this area", with requests snapped to cells and cached. | It depends on a community-run host. Ask DeFlock's maintainers before shipping. |
| Location | **CoreLocation "when in use"**, requested only when you click **⌖ LOCATE**. Never "Always". The position is never stored or sent. | The tiles you load around you still show roughly where you are (see §5). |
| Placement | **A new rail page `05 MAP`** (Settings moves to `06`). A small **Perimeter** deck widget comes later. | One more rail item. |
| Routing | **Routes that avoid mapped ALPR cameras** through a **FlockHopper-compatible engine**: self-hosted (recommended) or the public FlockHopper API if its maintainers agree. A downloadable **on-device FlockHopper "routing pack"** (GraphHopper in a sandboxed helper, a state or custom area, no Docker) keeps start and end points on the Mac (§7.5). A Valhalla engine comes second. **GRID re-scores every route against its own camera data** (§7). | Start and end points go to the engine you choose. "Out of view" can only mean "away from *mapped* cameras". |
| Updates | **An opt-in daily GitHub release check** (open the release page, or download, verify and reveal; one-click install once notarized) **plus freshness checks for map data**: ALPR snapshot, routing areas, engine pins (§12). | One more opt-in network request; no automatic install until releases are notarized. |
| Export | **A printable PDF cue sheet** (vector overview map, large-type turn list, cameras you can't avoid, attribution and a safety line) plus **GPX 1.1** for a GPS unit or an offline phone navigator (§8). | Printed directions can't re-route around closures. |

---

## 1. Rendering

### 1.1 Options compared

| | MapKit (`MKMapView` / SwiftUI `Map`) | MapLibre Native (macOS) | Custom Metal ("GridMap") |
|---|---|---|---|
| Tron look (dark land, glowing accent roads, grid floor, extruded buildings) | **Not possible.** No style JSON, no road or land recolouring. Only `.standard(emphasis: .muted)`, dark appearance and a POI filter. The only fully custom route is `MKTileOverlay.canReplaceMapContent` with raster tiles we would have to render ourselves. | **Yes.** Full style spec: `line-blur` for glow, `fill-extrusion`, `background-pattern`, data-driven colours, runtime restyling. | **Yes, built for it.** A procedural grid floor, bloom pass and accent extrusion edges in our own shaders, just like `GlobeRenderer`. |
| Traffic | Built-in Apple traffic (`MKStandardMapConfiguration.showsTraffic`), drawn in Apple's colours. It can't be restyled, and is lost if the base map is replaced. | Draw TomTom or HERE vector flow data as a style layer. | Same MVT decoder as the base map; we draw it ourselves. |
| macOS packaging | System framework, 0 MB. | **No prebuilt macOS SwiftPM package.** `maplibre-gl-native-distribution` is iOS-only; the macOS release workflow (PR #4242) has never published a `macos-v6.x` release (issue #4088 is open). We would build an xcframework with Bazel (`//platform/macos:MapLibre.dynamic --//:renderer=metal`) and host it ourselves. | Swift in GridCore and Grid. No dependencies if we write a small MVT/protobuf reader (`Outdooractive/mvt-tools`, MIT, serves as a reference). |
| Maintenance risk | Low. | **High.** The docs call the macOS AppKit API "not actively maintained", and discussion #3414 considers removing it. The SwiftUI wrapper is iOS-only. | Ours to maintain. The feature set is deliberately small. |
| Binary size | 0 | Roughly 10–20 MB stripped **(verify)**. The 7.0 iOS zip is 164 MB with debug symbols; the core static library is about 66 MB unstripped. | Under 1 MB of code. |
| Safety of parsing network data | Apple's. | C++ protobuf, geometry and style parsing of remote data. | Memory-safe Swift, unit-tested and fuzzed in GridCore. |
| Labels | Apple's. | Excellent: SDF glyphs, collision, labels along lines. | **The hardest part.** v1 uses CoreText labels in an overlay layer (as `GlobeLabelLayer` does) with greedy collision, and road names only at z15+ and horizontal. |
| Effort | Days. | 1–2 weeks for the build pipeline and wrapper, then the style. | About 6–10 weeks for v1. |
| Licence | Apple terms; no published quota for native apps. Apple throttles heavy use (`MKError.loadingThrottled`). | BSD-2-Clause. | Ours. Data is ODbL and the tile schema is CC-BY. |

### 1.2 Recommendation

Build **GridMap**, a custom Metal renderer, but only after a **timeboxed Phase 0 spike** that proves
it. The reasons:
- MapKit can't produce the look.
- MapLibre on macOS would mean carrying a self-built, unmaintained C++ framework that parses
  untrusted network data, which runs against GRID's one-dependency, native-and-lightweight stance.
- The Tron look needs far less than a general map engine: dark land and water, glowing roads,
  extruded buildings, a few labels and our own markers. GRID already has the Metal, on-demand
  rendering and label-overlay patterns in `Sources/Grid/Web/GlobeRenderer.swift`.

**Fallback.** If the spike misses its criteria (§9, Phase 0), use **MapLibre Native**: a pinned,
self-built xcframework attached to a GRID GitHub release as a SwiftPM `binaryTarget` with a
checksum, wrapped in an `NSViewRepresentable`, with the style JSON generated from theme tokens.
Everything above the renderer (data clients, cache, UI, privacy) is the same either way.

`WorldMask` and the globe stay decorative. `WorldMask` says itself that it is "not for anything
geographic".

### 1.3 GridMap renderer design

```
URLSession (tile cache) ──▶ MVTDecoder (GridCore) ──▶ TileGeometry (GridCore)
                                   features              earcut triangles, line strips,
                                                         extrusion walls, label anchors
                                                                 │ (background queue)
                                                                 ▼
                         MapRenderer (MTKView, paused; draws on demand)
  pass 1  floor     procedural grid in world space (minor / major lines), bg0 → bg1
  pass 2  water     bg3 fill, 1 px accent @ 18% shoreline
  pass 3  landuse   parks / industrial at a few % accent (hidden below z12)
  pass 4  buildings fill-extrusion: dark faces, accent @ 40% roof edge, shown when pitched
  pass 5  roads     core line: width by class (motorway › primary › … › service)
                    glow: same strips into a half-res target → separable blur → added on top
                    (skipped entirely when Effects › Glow is off)
  pass 6  overlays  traffic, ALPR, POI and "you" markers as instanced SDF quads
  labels            CoreText in an overlay layer, greedy collision, ≤ 40 visible
```

- **Colours come from `Theme`.** Each theme is a set of uniforms, so switching theme re-colours the
  map on the next frame without rebuilding tiles. Legacy and ENCOM get accent roads and a cyan or
  amber glow. In Ares, roads are red, so traffic "jammed" uses white plus a ✕ cap, as `DESIGN.md`
  does for danger.
- **Camera.**
  - 2D by default: drag to pan, pinch or scroll to zoom.
  - ⌥-drag or two-finger rotate for rotation and pitch up to 60°. Buildings appear only when pitched.
  - Keyboard: arrow keys pan, `+`/`−` zoom, `0` resets north and pitch.
- **Performance rules** (from `DESIGN.md`):
  - The view is paused while hidden, like the globe.
  - It draws only when the camera moves, a tile arrives or a one-shot animation runs. There is no
    idle animation.
  - Tiles are decoded off the main thread.
  - At most about 60 tiles stay in GPU memory, in an LRU.
  - Targets: idle at 0% GPU, 120 fps panning on an M1 at z14 downtown, under 200 MB resident.
- **Tile math, the MVT decoder, polygon triangulation (earcut port), line extrusion and label
  collision are pure Swift in GridCore**, so they can be unit-tested and fuzzed with malformed
  tiles.

### 1.4 Tile sources and licensing

| Source | Schema | Key | Terms (short) | Attribution to show |
|---|---|---|---|---|
| **OpenFreeMap** (default) — TileJSON `https://tiles.openfreemap.org/planet` | OpenMapTiles | none | Free, commercial use OK, no view limits. Bulk offline download is capped (3,000 tiles / 50 MB, 4 parallel requests, unique User-Agent). "As is" and may be discontinued. | `OpenFreeMap © OpenMapTiles Data from OpenStreetMap` |
| **Protomaps PMTiles** (later) | Protomaps (Tilezen-derived) | none | Daily planet build is about 139 GB. Use `pmtiles extract` for a region and host it on any static host with HTTP Range, or keep a local file for **fully offline maps**. Code BSD-3, style CC0, data ODbL. | `© OpenStreetMap contributors` (+ Protomaps courtesy) |
| Custom TileJSON URL | OpenMapTiles | user's | user's | user-provided string + OSM |

- **Schema support.** v1 understands the OpenMapTiles layers `water`, `waterway`, `landuse`,
  `landcover`, `park`, `building`, `transportation`, `transportation_name`, `place` and `poi`.
  Protomaps needs a second, small layer-mapping table, which comes with the PMTiles phase.
- **ODbL and OSMF attribution rules.** "© OpenStreetMap contributors" must be visible **without
  interacting with the map**, in a corner, linked to `openstreetmap.org/copyright`. OpenMapTiles
  (CC-BY 4.0) requires visible `© OpenMapTiles`.
- **GRID's attribution strip.** GRID draws a permanent strip at the bottom right in SF Mono 9.5,
  textMute: `© OpenStreetMap contributors · © OpenMapTiles · OpenFreeMap · ALPR: DeFlock/OSM`.
  Each name links to its source and opens in GRID's browser.
- **Caching tiles locally is fine under ODbL.** Shipping a bundled dataset would make GRID a
  distributor of an ODbL database, so **GRID bundles no map or ALPR data**; it is all fetched.
- **`LICENSES.md`** gains a "Map data (fetched at runtime, not bundled)" section, like the
  ad-blocking lists.

---

## 2. Traffic

| Source | How | What leaves the Mac | Restylable | Verdict |
|---|---|---|---|---|
| **Apple (MapKit)** | `showsTraffic` on an Apple base map | Visible map bounds, time, device model and OS, tied to identifiers that rotate several times an hour, not your Apple Account (Apple Maps privacy page) | **No.** Apple's colours, and only on Apple's base map | Not usable on our map, and it can't be extracted (§2.1). Offer **"Open in Apple Maps"** (`maps://?ll=…&z=…`) for live traffic and directions. |
| **TomTom** Vector Flow Tiles | `api.tomtom.com/traffic/map/4/tile/flow/relative/{z}/{x}/{y}.pbf?key=…` → layer "Traffic flow" with `traffic_level` (0–1), `road_type`, `road_closure` | z/x/y of the viewed area, **your API key** (links requests to your TomTom account), IP | **Yes.** We draw it from MVT ourselves (whether the terms allow restyling is not stated; **verify**). | **Recommended optional provider.** Free tier is 200k tile requests a month without a card. |
| **HERE** Traffic API v7 | `data.traffic.hereapi.com/v7/flow?in=bbox:…&locationReferencing=shape&apiKey=…` → JSON `speed`, `freeFlow`, `jamFactor`, shape polylines | bbox, key, IP | Yes. We draw the polylines. | Second provider. Free tier about 5k transactions a month after the April 2026 pricing change (**verify**). One bbox request per refresh, not per tile. |
| Mapbox `mapbox-traffic-v1` | Vector tiles, needs a token | z/x/y, token | Technically yes | **Rejected.** The product terms forbid caching beyond 30 days and proxying, and limit "Traffic Data" without an order. |
| Google Map Tiles `layerTraffic` | Raster tiles | — | — | **Rejected.** Google's terms (§3.2.3(e)) ban use with a non-Google map. |

### 2.1 Can GRID read Apple's traffic and draw it on its own map?

**No.** It's technically possible and fragile, but Apple's licence forbids it outright.

**Technically:**
- MapKit has **no API that returns traffic data**: no per-road speeds or congestion.
- The only route would be to render a hidden map or an `MKMapSnapshotter` image with
  `MKStandardMapConfiguration.showsTraffic` and read its pixels. A test on macOS 27.3 confirmed
  that snapshots do draw traffic.
- But that pixel approach falls apart:
  - only yellow and red congestion lines are drawn (free flow is not), so it can't be recovered;
  - labels and shields cover the lines;
  - colours change between light and dark;
  - Apple's road geometry doesn't line up with OSM, so the pixels would have to be matched back
    to roads;
  - snapshots are throttled (`loadingThrottled`);
  - any change to Apple's style silently breaks it.

**Legally,** the Apple Developer Program License Agreement, Attachment 6 (Apple Maps Service),
rules it out:
- "Map Data" explicitly includes **traffic data**, as well as POIs and coordinates.
- §2.4 requires Map Data to be shown "only on an Apple map", and says you "may not surface Map Data
  … without displaying the corresponding Apple map".
- §2.2 forbids attempts to "extract, scrape or reutilize" Map Data.
- §2.3 forbids derivative works.
- §2.5 allows caching only "on a temporary and limited basis".
- Apple can review an app's use and revoke access (§4).

The same rules mean **`MKDirections` routes and ETAs, and `MKLocalSearch` results, can't be drawn
or printed on GRID's map either.** That's why §3 and §7 don't use them.

**What is allowed:**
1. A **licensed traffic feed** drawn in GRID's colours, which is the TomTom/HERE plan above.
2. **"Open in Apple Maps"** (`maps://?ll=…&z=…` or `?saddr=…&daddr=…`), which hands off to Apple's
   app.
3. A MapKit map with GRID's own data (ALPR, routes) on top, which Apple's terms anticipate. That
   *shows* Apple's map, which the owner doesn't want, so it isn't planned. It is kept here only as
   a permitted fallback.

### 2.2 Rules for traffic in GRID

- Traffic is off until you turn it on in **Settings › Map › Traffic** and paste a key.
  - The key goes in the Keychain, the same as widget secrets.
  - The setting says plainly: *"Traffic tiles for the area you're viewing are requested from
    TomTom with your key, every 3 minutes while the Map is visible."*
- Requests happen only at z ≥ 10, only while the Map page is visible, and are refreshed every 3 min
  (TomTom updates about every minute; 3 min keeps a day of use well inside the free tier).
- Traffic is held in memory only and never written to disk, because the caching terms are
  unverified. The 2019 TomTom EULA had a 24 h storage limit.
- **Drawing in GRID's colours, shape before colour:**

  | `traffic_level` | Line | Colour token |
  |---|---|---|
  | ≥ 0.75 free flow | 1 px solid, offset to the driving side | `ok` @ 70% |
  | 0.4–0.75 slow | 2 px, dashed 6/4 | `warn` |
  | < 0.4 jammed | 3 px solid with a ✕ tick every 80 px | `danger` (white in Ares) |
  | `road_closure` | 2 px, 2/2 dot pattern + ⊘ glyph at the midpoint | `danger` |

  The traffic overlay never glows, so it stays readable over glowing roads. The legend in §6 shows
  all four.

---

## 3. Points of interest

| Source | Network | Privacy | Quality |
|---|---|---|---|
| **OpenMapTiles `poi` layer** (already in the base tiles, z14+) | **None extra** | Nothing beyond the tile request | As complete as OSM locally; names, `class`, `subclass` |
| ~~Apple `MKLocalSearch` / `MKLocalPointsOfInterestRequest`~~ | A request to Apple per search | Query text + region go to Apple | Good, but **not usable**: Apple's licence forbids showing results on a non-Apple map (§2.1) |
| **Nominatim** (OSMF) | One request per search | Query + IP to OSMF. Policy: **1 request/s at most, no autocomplete, an identifying User-Agent required, results cached, and apps must be able to switch it off without an update**. | OK for addresses and places |
| Overpass | One request per category per area | bbox + IP | Raw tags; heavy for broad categories. Use it only for ALPR. |

**Recommendation:**
1. **Default: local only.** POI glyphs and the filter chips (Food, Fuel, Transit, Health, Shops,
   Lodging) read the `poi` layer of tiles already loaded. The search box first matches POI and place
   names in loaded tiles, which needs **no network**.
2. **Search wider** happens only when you press ⏎ on a query with no local match, or on a visible
   `SEARCH OSM ⏎` row. It uses **Nominatim**: rate-limited in code to 1/s, no autocomplete (so
   keystrokes are never sent), cached for 24 h, with a custom endpoint allowed and an **Off**
   switch, as Nominatim's policy requires.
3. A result's `⋯` menu offers **Open in Apple Maps** as a hand-off, so Apple's richer business data
   is still one click away, in Apple's app.
4. Category mapping from OpenMapTiles `class` to GRID glyphs lives in GridCore (tested). Nominatim
   results are converted to the same `MapPOI` model so they look identical.

---

## 4. ALPR cameras (DeFlock)

### 4.1 How DeFlock gets its data (verified 2026-11-09)

- `deflock.me` now redirects to **deflock.org**. The current map is **maps.deflock.org**.
- **All of DeFlock's data is OpenStreetMap (ODbL).** Its terms say it "provides access to map data
  sourced from OpenStreetMap".
- **Identifying tag pair:** `man_made=surveillance` + `surveillance:type=ALPR`. DeFlock matches it
  exactly (case-sensitive) and **doesn't filter by vendor**.
- **Tags the DeFlock app writes** (`FoggedLens/deflock-app`, `lib/models/node_profile.dart`, AGPL-3.0):
  `man_made=surveillance`, `surveillance=public`, `surveillance:type=ALPR`,
  `surveillance:zone=traffic`, `camera:type=fixed`, `camera:mount=*`, `manufacturer=Flock Safety`,
  `manufacturer:wikidata=Q108485435`.
  - Other vendors use the same pattern with their Wikidata IDs: Motorola Solutions Q634815,
    Genetec Q30295174, Leonardo Q910379, Axis Q2347731, plus Neology and Rekor.
  - DeFlock's tag list (`deflock.org/taginfo.json`) also uses `direction`, `camera:direction`,
    `operator`, `surveillance:operator`, `brand` and `note`.
  - The OSM wiki prefers `direction=*` over `camera:direction`.
- **How the map gets data at runtime.** The map doesn't call Overpass from the browser:
  1. An hourly GitHub Action (`flockhopper3/deflock-data`, MIT) queries Overpass.
  2. It builds GeoJSON and per-country PMTiles.
  3. These are served as z/x/y MVT from `deflock.dontgetflocked.com` (backup
     `tiles.dontgetflocked.com`), with TileJSON `/cameras-us-hourly.json` and
     `/cameras-ca-hourly.json`, z0–14, and attributes at z11+.
  4. A bulk file `https://data.dontgetflocked.com/cameras.geojson.gz` (Canada: `cameras-ca.geojson.gz`)
     feeds the map's Download button.
  - The repo README says "Anyone can use the data. No API key, no rate limits beyond Cloudflare's
    defaults."
  - These hosts belong to FlockHopper, a DeFlock partner. No formal API or terms exist.
  - The older `cdn.deflock.me/regions/{lat}/{lon}.json` (20° cells) is deprecated and looks stale.
- **The DeFlock app** queries `overpass.deflock.org/api/interpreter`, which has no published usage
  policy, and falls back to `overpass-api.de`.
- **deflock.org's terms** forbid "scraping, harvesting, or systematically collecting data from
  DeFlock … in violation of their terms", and ask for proper attribution and OSM licence compliance
  in commercial use. GRID isn't commercial, but courtesy applies.
- **FlockHopper's router** (`api.dontgetflocked.com`, MIT source at `flockhopperdev/FlockHopper`)
  does camera-avoiding routing. Its health endpoint reports 146,410 cameras. §7 builds on it.
- **Contact for permission:** contact@deflock.org, the DeFlock Discord, or issues on
  `FoggedLens/deflock` and `flockhopperdev/FlockHopper`. Issues are disabled on
  `deflockhopper_maps`.
- **Scale:** about 145.8k ALPRs mapped in the USA (`cdn.deflock.me/alpr-counts.json`). About 158k
  OSM objects are tagged `surveillance:type=ALPR` worldwide (taginfo), and over 99.9% of them are
  nodes.

### 4.2 Source strategy

1. **Default: a nationwide snapshot (US + Canada).**
   - Download `cameras.geojson.gz` (and `-ca`) **at most once a day**, only while the ALPR layer is
     on and the Map is open.
   - Store it in `~/Library/Application Support/GRID/Maps/alpr/` with its ETag and date.
   - Index it into a GridCore spatial grid for instant viewport queries.
   - **Privacy win:** the request shows only that GRID fetched the national file, not where you are
     or what you look at.
   - The file is about **39 MB gzipped**. A Cloudflare Worker rebuilds it **daily at 09:00 UTC**
     from Overpass (`deflockhopper_maps/worker/wrangler.toml`). Fetches are conditional
     (`If-None-Match`). The default refresh is **when it's more than 7 days old, or before
     computing a route**, and never more than once a day. The UI shows its age.
   - If the file stops updating, use the hourly MVT tiles instead (option 3 below), which reveal only
     the tile area.
2. **Elsewhere, or "⟳ refresh this area":** Overpass, on demand, sent to the endpoint chosen in
   Settings. The default is `overpass-api.de`; alternatives are `overpass.private.coffee` and a
   custom URL.
   - The bbox snaps to a fixed **0.25° cell grid** (about 28 × 22 km at mid-latitudes). That
     reveals the cell, not the exact view, and makes cache hits likely.
   - Each cell is cached for 24 h on disk.
   - Only at z ≥ 10, so whole countries are never queried.
3. **Option b (fallback):** render DeFlock/FlockHopper's hourly MVT tiles directly with the same
   decoder.

**Before shipping**, ask DeFlock's maintainers whether GRID may use the FlockHopper files or tiles.
Open an issue on `FoggedLens/deflock` and agree on a User-Agent. GRID stays well under any sensible
limit: at most one 39 MB file a day per user, usually one a week.

### 4.3 Overpass query (cell or bbox)

```
[out:json][timeout:25][bbox:{south},{west},{north},{east}];
(
  node["man_made"="surveillance"]["surveillance:type"~"(^|;)alpr(;|$)",i];
  way ["man_made"="surveillance"]["surveillance:type"~"(^|;)alpr(;|$)",i];
);
out center qt;
```

- The case-insensitive, `;`-aware regex also catches `alpr` and mixed values such as `ALPR;camera`.
  DeFlock's exact match misses about 160 of these.
- `out center` gives one point per way without recursing into nodes. `qt` sorts by quadtile, which
  is faster.
- **Vendor.** Flock when `manufacturer:wikidata=Q108485435` **or** `manufacturer|brand ~ "flock",i`
  (that catches `Flock Group Inc.`, `Flock`, `Axon-Flock`…). Other vendors are matched by their
  Wikidata ID. Anything else is "unknown vendor".
- **Direction.** `direction`, otherwise `camera:direction`. Values are degrees or compass words
  (`NE`), often several separated by `;`. Each becomes a 60° field-of-view wedge.
- This was test-run on 2026-11-09: one small Atlanta bbox returned HTTP 200 with 305 elements.

### 4.4 Overpass fair use

Per the OSM wiki and the Overpass "commons" page:
- `overpass-api.de` asks for **under 10,000 queries and under 1 GB a day, divided by 100 for
  regular use**, counted across all of an app's users.
- **No parallel requests.** Pause 30 s on HTTP 429 or 406. 504 means overload.
- Send an **identifying User-Agent**.
- It warns against using public instances as the back end of an app for non-mappers, which is why
  Overpass is not GRID's default ALPR source.

**GRID's client:**
- Requests are serial (one in flight).
- A pan must rest for 800 ms before a fetch.
- Cells are cached for 24 h; requests stop at about 50 a day per user.
- On 429 or 406, back off 30 s, doubling up to 10 min.
- `[timeout:25]`.
- User-Agent `GRID/<version> (+https://github.com/HackitM/grid)`.
- The endpoint is user-switchable.

### 4.5 Model and display

```swift
struct ALPRCamera: Identifiable, Hashable, Sendable {   // GridCore
    let id: OSMElementID          // node/123 or way/456
    let coordinate: Coordinate
    let directions: [Double]      // degrees, parsed; [] = unknown
    let vendor: Vendor            // .flock, .motorola, .genetec, .leonardo, .axis, .other(String), .unknown
    let operatorName: String?     // operator / surveillance:operator
    let mount: String?            // camera:mount
    let zone: String?             // surveillance:zone
    let lastEdited: Date?         // when available
}
```

- **Marker.** A 9 pt square reticle (an open square with corner ticks, a shape not used elsewhere in
  GRID) plus translucent **FOV wedges** (accent @ 22%) for each direction. Below z12 the cameras
  cluster into a count block, `▣ 37`.
- **Clicking a camera** opens an inspector card in the right column. It shows the vendor, operator,
  directions, mount, the OSM id, and `VIEW ON OSM ↗` / `REPORT ON DEFLOCK ↗` (both open in GRID's
  browser on click).
  - GRID never edits OSM, which would need an OSM account (out of scope).
- **Wording stays neutral and factual:** *"ALPR cameras mapped by OpenStreetMap volunteers via
  DeFlock. Coverage is incomplete and may be out of date."*
- **Status-bar readout** (instrument, not prop): `ALPR 214 IN VIEW · SNAPSHOT 6 H OLD`.

---

## 5. Location and privacy

### 5.1 CoreLocation flow

1. The Map page never asks on appearance. The **⌖ LOCATE** button is the only trigger.
2. If `authorizationStatus == .notDetermined`, a GRID confirmation appears first (`StateBlock`,
   code `LOC-00`): *"GRID will ask macOS for your location to centre the map. It stays on this Mac.
   The map tiles around you are then downloaded from OpenFreeMap."* `[Continue] [Not now]`.
   Continue calls `requestWhenInUseAuthorization()`.
3. **Denied or restricted:** a `StateBlock` △ `LOC-DENIED` with an **Open Privacy Settings**
   button (`x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices`).
   **System-wide Location Services off:** △ `LOC-OFF`. GRID never retries on its own.
4. **One fix** uses `requestLocation()`. The **FOLLOW** toggle uses `startUpdatingLocation()` with
   `distanceFilter = 25 m`, only while the Map page is visible. It stops when the page is hidden or
   the window closes.
5. Accuracy is shown as measured (`± 35 m`), along with the source time. Macs locate by Wi-Fi, so
   accuracy is often tens of metres.
6. The position is **held in memory only**. It is never written to disk, logged or put in a URL.
   The last *camera* (centre and zoom) is saved in settings, like other layout state; turning on
   **Settings › Map › Remember last view** is required, and it's off by default.

**Bundle changes:**
- `Resources/Info.plist` gets `NSLocationWhenInUseUsageDescription`, plus `NSLocationUsageDescription`
  for older macOS code paths (**verify** which one macOS 15 shows):
  > *"GRID's Map shows where you are when you click Locate. Your location stays on this Mac."*
- **Hardened runtime:** Developer ID builds signed with `--options runtime` need the
  `com.apple.security.personal-information.location` entitlement, or location is silently denied
  (**verify** in Phase 0).
  - Add `Resources/GRID.entitlements` and pass `--entitlements` in `scripts/bundle.sh` for the
    `SIGN_ID` path. Ad-hoc builds have no hardened runtime.

### 5.2 What is sent where

Every request below happens only on the Map page, after the one-time **ENABLE MAP DATA** consent
(§6). With the Map page never opened, GRID makes no new network requests.

| Host | When | What it learns | Off switch |
|---|---|---|---|
| `tiles.openfreemap.org` (or your tile URL) | While the Map is visible | z/x/y of the tiles you view, so **roughly where you're looking** (a z14 tile is about 2.4 km × cos lat). IP, User-Agent. | Disable map data / self-host PMTiles / offline extract |
| `data.dontgetflocked.com` | ALPR layer on, at most once a day | That you downloaded the national file. **No area.** | ALPR layer off |
| Overpass endpoint (your choice) | "⟳ refresh area", or a region outside the US/CA snapshot | A **0.25° cell**, IP | ALPR source: Snapshot only |
| `api.tomtom.com` / HERE | Traffic on, every 3 min while visible | Viewed tiles or bbox **plus your API key**, so the vendor can tie it to your account | Traffic off (default) |
| `nominatim.openstreetmap.org` (or your endpoint) | You press ⏎ on SEARCH OSM | Query text, IP | Wider search: Off |
| Routing pack install / area download | You add the engine or an area | Adoptium + Maven Central: that you installed it. Geofabrik: **which region**. | Don't install; Remove deletes everything |
| Routing engine (your choice: self-hosted, FlockHopper, Valhalla) | You click ROUTE | **Start and end points**, buffer settings, IP. A Valhalla loop also sends the excluded camera points, which reveal the corridor. | Routing: Off (default) / self-hosted |
| `api.tomtom.com` (traffic ETA on a route) | Traffic on and a route computed | Flow tiles along the route corridor, plus your key | Traffic off |
| Apple Location Services (macOS) | ⌖ LOCATE / FOLLOW | macOS handles it per Apple's policy (Wi-Fi based). GRID sends nothing itself. | Don't press Locate; revoke in System Settings |

- **Tile cache:** `~/Library/Application Support/GRID/Maps/tiles` (a dedicated `URLCache`, 200 MB
  cap by default). **Settings › Map › Clear Map Data** empties tiles, ALPR snapshots and cells.
- **Offline mode** (Phase 5): point at a local `.pmtiles` extract, and the map makes **no** tile
  requests at all.

### 5.3 README "Privacy & security" addition (draft)

> - **Maps are opt-in.** The Map page downloads nothing until you click **Enable map data**.
>   After that, map tiles for the area you view come from OpenFreeMap (or a tile server you set),
>   and ALPR camera locations come as one nationwide file per day, so neither reveals your
>   position. **Your location** is only read when you click Locate, stays in memory, and is never
>   stored or sent by GRID.
> - **Traffic and wider place search are off by default.** Traffic uses your own TomTom key;
>   wider search sends your query to OpenStreetMap's Nominatim only when you press ⏎.
> - **Routing is off until you choose an engine.** Your start and end points go only to the engine
>   you pick, which can be one you run yourself. Routes aren't saved unless you save them, and
>   printouts and GPX files are written only where you choose.

The "Network requests GRID makes on its own" bullet stays true: none of these happen without you
opening the Map and enabling it.

---

## 6. UI

### 6.1 Where it lives

- **Rail page `05 MAP`** (`PanelID.map`, symbol `map`, ⌥⌘5). Settings becomes `06 SYS` (⌘, unchanged).
  It gets a whole page because the map needs space and its own layers, legend and inspector.
- **Not the browser's new tab page.** The globe stays decorative (as `WorldMask` says). The new tab
  page belongs to browsing, and putting live location there would surprise people.
- **Deck widget "Perimeter"** (later, `WidgetKind.perimeter`): no map tiles. It shows the count of
  mapped ALPRs within 1/5 km of the last LOCATE fix, the nearest one's bearing and distance, and the
  snapshot age. Click opens the Map.
  - It updates in place with no animation, per the widget rule.
  - It uses the local snapshot only, so it makes **no network requests**.
- **Command palette:** `map` (open), `map <query>` (search), `map here` (locate), `map alpr`
  (toggle layer).

### 6.2 Layout

```
┌ ● ● ●  GRID │ 05 MAP ──────────────────────────────────────────── COMMAND ⇧⌘P ┐
│ 01  │ ┌05 MAP .GEO ───────────────────────── ⌖ ◉FOLLOW 2D|3D ⇄ ⟳ ⋯ ┐┌LAYERS──────┐│
│TERM │ │⌕ search places, addresses…                       [LOCAL ▾]  ││[■] ROADS    ││
│ 02  │ │                         ┃                                   ││[■] POI      ││
│FILES│ │     ·  ·  ·  ·  ·  ·  · ┃ ·  ·  ·  ·  ·  ·  ·  ·  ·  ·      ││[■] ALPR  214││
│ 03  │ │  ━━━━━━━━━━━━━━━━━━━━━━━╋━━━━━━━━━━━━━━━━  MARKET ST         ││[ ] TRAFFIC ⓘ││
│APPS │ │     ·  ·  ·   ⌗◸     ·  ┃  ·  ·  ·  ·  ·  ·                 ││[ ] 3D BLDGS ││
│ 04  │ │  ───────────────────────╂───────┬───────── ◉ YOU ±35 m      │├LEGEND──────┤│
│WEB  │ │     ·  ·  ·  ·  ·  ·  · ┃  ·  · │ ·  ·  ·                   ││━ motorway   ││
│ 05  │ │  ──────────┬────────────╂───────┴──────  ▣ 12               ││─ street     ││
│MAP  │ │            │      ⌗◹    ┃                                   ││⌗ ALPR + FOV ││
│     │ │                                                             ││▣ cluster    ││
│     │ │ 37.7793 N 122.4193 W · Z15 · ⊾0° · TILES 48/48              ││━ ━ slow     ││
│     │ │              © OpenStreetMap contributors · © OpenMapTiles…  ││━✕━ jammed   ││
│ 06  │ └─────────────────────────────────────────────────────────────┘├INSPECT─────┤│
│SYS  │                                                                 │⌗ ALPR      ││
│     │                                                                 │FLOCK SAFETY││
│     │                                                                 │DIR 045° 225││
│     │                                                                 │node/1234567││
│     │                                                                 │VIEW ON OSM↗││
├─────┴─────────────────────────────────────────────────────────────────└────────────┘┤
│MAP │ OPENFREEMAP │ ALPR 214 IN VIEW · SNAPSHOT 6 H │ CACHE 41 MB │ LEGACY // CYAN    │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

- **Map panel.**
  - A `Panel` (ClippedRect, header `05 MAP .GEO`, trailing `IconButton`s).
  - The body is the Metal view with a `GridField` search on top.
  - The bottom overlay shows the readouts (centre, zoom, bearing, tiles loaded/needed: measured,
    not decorative) and the attribution strip.
- **Right column, 220 pt, collapsible with ⌘I like the Files inspector.**
  - LAYERS uses `GridToggleStyle` rows (`[■] ON`) with live counts.
  - LEGEND always pairs a shape with each colour.
  - INSPECT shows the selected POI or ALPR, using `SectionLabel` and `TerminatedRule`.
- **POI filter chips** sit under LAYERS ▸ POI as toggles: FOOD · FUEL · TRANSIT · HEALTH · SHOP ·
  LODGING. They are flat rects, not pills, per `DESIGN.md`.
- **First run.** Before consent the body shows a `StateBlock` (code `MAP-NET`) with a title, a short
  explanation and the list of hosts (tiles, ALPR snapshot), plus `[Enable map data]` `[Settings…]`.
  Nothing is fetched before the click. The grid floor still draws locally, so the page isn't blank.
- **Errors.**
  - △ `TILE-ERR n` in the readout.
  - △ `OVERPASS-429 · retry in 30 s` as a status notice.
  - ✕ `TRAFFIC-KEY` for a rejected key.
- **Compact window** (< 1000 pt wide): the right column becomes a popover from the `⋯` header
  button.
- **Accessibility.**
  - The Metal view is opaque to VoiceOver, so **LAYERS ▸ LIST** gives an accessible table of the
    visible POIs and ALPRs, sorted by distance from the centre and keyboard-navigable.
  - Selecting a row centres the map.
  - Every icon button has a label and tooltip, as the rules require.

### 6.3 Motion (from `Theme/Motion.swift` and `docs/DESIGN.md`)

| Event | Motion | Duration | Notes |
|---|---|---|---|
| Page appears | Existing **build-on** on the panel plate | 340 ms | `.buildOn()` as on other pages |
| First tiles of a new area arrive | **Scan sweep:** a single horizontal accent band sweeps top to bottom, with roads "drawn on" behind it (a shader uniform `reveal`, 0→1) | 450 ms, once | Not on every pan, only when more than half of the visible tiles were new. The band reuses the look of `ScanSweep`, the dock-target band. |
| ALPR / POI markers appear | **Pop** from 60% scale with a brief flash, like the DONE tags (`.popIn()`) | spring 260 ms, 8 ms stagger capped at 40 markers | Markers off-screen don't animate |
| ⌖ LOCATE succeeds | Camera flies over (ease, 600 ms max), then **one** ping ring | 600 + 400 ms | No continuous pulse ("no idle animation") |
| Layer toggled | Layer opacity eases | 160 ms (`GridMotion.quick`) | |
| Inspector opens | `TerminatedRule` extends + rows **cascade** | 14 ms stagger / 160 ms | Existing `.cascadeIn(_:)` |
| Status notice | Existing **Ares text band** | 240 + 450 ms | |

- With Motion off or Reduce Motion on, all of these become instant. Panning and zooming are always
  direct; inertia is user input, not decoration.
- Animations live in Metal uniforms or short SwiftUI transitions. No overlay is left in the view
  tree afterwards, per the performance rule.

### 6.4 Reuse

| Need | Existing code |
|---|---|
| Panel, header, buttons, fields, toggles, empty/error states | `Theme/Components.swift`: `Panel`, `IconButton`, `GridField`, `GridToggleStyle`, `StateBlock`, `SectionLabel`, `TerminatedRule`, `Tag` |
| Build-on, cascade, text band, pop, scan band | `Theme/Motion.swift` (`.buildOn()`, `.cascadeIn(_:)`, `.popIn()`, `ScanSweep`) |
| Menus (right-click on map: Copy coordinates, Open in Apple Maps, View on OSM) | `Theme/GridMenu.swift` |
| Metal view that pauses when hidden, label overlay layer | `Web/GlobeRenderer.swift` (`GlobeMetalContainer`, `GlobeLabelLayer`) |
| Opening links in GRID's browser | `BrowserModel` |
| API key storage | the Keychain secret helpers in `Widgets/Platform/WidgetLibrary.swift` (move them to a shared `KeychainStore` when Maps needs them) |
| Settings section | pattern from `BrowserSettingsSection` |
| Status-bar readouts | `RootView.StatusBar` |

---

## 7. Routing that avoids mapped ALPR cameras

### 7.1 What "out of view" can honestly mean

GRID can route around **cameras that are mapped in OSM**. It can't promise a driver is unseen:

- **Mapped cameras only.** The data is volunteer-mapped and incomplete. Mobile ALPRs (on patrol
  cars or trailers) and newly installed cameras are not in it.
- **Data age.** The snapshot is up to a day old, plus however long it takes for a camera to be
  mapped in OSM at all.
- **Unknown facing.** Many cameras have no `direction` tag. They are treated as seeing in every
  direction, which is safe but makes avoidance harder.
- **Assumed field of view.** Where `direction` is known, the field of view and range are
  assumptions, not measurements.
- **Some trips have no camera-free route.** A single bridge, an on-ramp or a dense downtown can
  leave no way around. GRID then **minimises** the count and lists each camera it can't avoid,
  with its location and the step where you pass it.

The UI says *"avoids all mapped cameras"* or *"passes 2 mapped cameras"*. It never says
"untracked" or "invisible". The legend and printouts carry the coverage disclaimer from §4.5.

### 7.2 Exposure model (GridCore, tested)

This is ported from FlockHopper's routing server (`flockhopperdev/FlockHopper`, MIT, files
`server/utils/geo.ts`, `server/services/routingConfig.ts`, `cameraAwareRouting.ts`). The MIT
notice goes in `LICENSES.md`. Using the same model as DeFlock's own router keeps the numbers
comparable.

- **Buffer D**, default 75 m, adjustable from 10 to 150 m.
- **A camera "sees" a route segment** when both hold:
  - the segment passes within D of the camera;
  - the camera has no known direction, **or** the bearing from the camera to the nearest route
    point is inside one of its view cones. Cones are 70° wide, centred on each `direction` value.
    A camera tagged `45;225` has two.
- **Avoidance zones** sent to engines that accept areas:
  - Block zone: a cone (or a circle if the direction is unknown) of radius D × 1.6, plus a 15 m
    buffer behind the camera.
  - Penalty zone: radius D × 2.5.
  - These multipliers are FlockHopper's.
- **Fix compared with upstream:** FlockHopper's `if (!camera.direction)` treats a north-facing
  camera (`direction=0`) as having no direction. GridCore parses directions as optional values,
  and a test covers the north-facing case.
- **Score.** Camera count plus FlockHopper's exposure scale (0 low, ≤ 2 medium, ≤ 5 high,
  6+ extreme). The composite used to choose between candidate routes is
  `distance + Σ (1 − d/150) · 800`.
- **GRID re-scores every route itself.** Whatever an engine returns is checked against GRID's own
  local camera snapshot, and the UI shows the cameras GRID found, not the engine's own count. The
  engine's camera list (if any) is only a cross-check, and a mismatch is shown as △.

### 7.3 Routing engines

All engines sit behind one `RouteProvider` protocol, and the user picks one in **Settings › Map ›
Routing**. Routing is **off until the user picks an engine**.

| Engine | Avoidance | What leaves the Mac | Setup | Verdict |
|---|---|---|---|---|
| **FlockHopper-compatible API**: `POST {base}/api/v1/route` with `{origin, destination, costing:"auto", cameraDistanceMeters, useDirectionalZones}` | Full. The server uses GraphHopper `custom_model` block and penalty `areas` over about 146k cameras, then detour waypoints. It returns `normalRoute` and `avoidanceRoute`, each with `maneuvers[]`, `camerasOnRoute[]` and a score. Trips are limited to 300 mi. | **Start and end points** plus IP, sent to the server's operator | None if public | **v1 default engine type.** The public `api.dontgetflocked.com` (v2.0.0, cameras at most 72 h old, no auth, CORS `*`) is offered as a preset **only if the FlockHopper/DeFlock maintainers agree**. It has no published terms or rate limits, and the deployed version differs from the public source. |
| **Self-hosted FlockHopper** (same API; GraphHopper + Express from the MIT repo) on your own Mac or server | Same | Nothing to third parties if it runs on your own machine | Docker + Java. GraphHopper RAM is roughly 8–16 GB for the whole US (estimate), much less for one state | **Recommended for privacy.** GRID only needs a base URL. Ship a recipe in `docs/MAPS-ROUTING-SELFHOST.md`. |
| **Valhalla-compatible endpoint** (self-hosted, or the FOSSGIS public server) | GRID loops: route, find cameras in a corridor around it, add them as `exclude_locations` / `exclude_polygons`, re-route, at most 4 rounds. `linear_cost_factors` gives soft penalties. Maneuvers come with narrative instructions. | Start/end + the excluded points (which reveal the corridor) | FOSSGIS public: **1 request/s, at most 50 exclude locations, polygons ≤ 10 km perimeter and 100 vertices, URL must not be hard-coded**, no guarantees. Self-hosted: limits are configurable | **Second engine.** The public server's limits make hard avoidance unreliable in dense cities; self-hosting removes them. |
| **On-device FlockHopper (routing pack, §7.5)** | Full: the same GraphHopper custom-model avoidance as FlockHopper, for a downloaded state or custom area | **Nothing** when routing. Geofabrik learns which region you downloaded. | A one-click add-on: ≈ 75–105 MB download, ≈ 170–200 MB on disk, plus about 0.3× the area's PBF for its graph. Building needs about 13× the PBF in RAM (Ohio: 4 GB) | **Recommended on-device option.** |
| **Native Swift router in GRID** | Full, with camera penalties applied per edge | **Nothing** | A drivable graph built from a Geofabrik state extract (California's PBF is 1.34 GB) into a compact file of about 100–300 MB (estimate). A* with penalties. Our own turn instructions, using the `osrm-text-instructions` phrase templates (BSD-2) | **Later research (Phase 8)**, not committed. It's the most private option but costs about 3–6 weeks (estimate) plus graph-building tools; turn restrictions and access tags are the hard parts. |
| Apple `MKDirections` | **None.** No waypoints and no avoid areas, only `tollPreference` / `highwayPreference` | — | — | **Rejected.** It can't avoid points, and Apple's licence forbids showing its routes on a non-Apple map (§2.1). |
| OSRM | Only profile-level `exclude` classes, nothing per request | — | — | **Rejected.** |

**Geocoding start and end points:**
- clicking the map (right-click › *Route from here* / *Route to here*);
- ⌖ current location;
- local search over loaded tiles;
- Nominatim when you press ⏎.

Apple search can't be used here (§3).

**ETA and traffic:**
- Engine ETAs are free-flow or typical speeds.
- If traffic is on (TomTom key), GRID samples flow tiles along the route corridor and shows an
  adjusted estimate, for example `+6 MIN TRAFFIC`.
  - This requests TomTom tiles along the route, which tells TomTom about the corridor. The setting
    says so.

**Privacy:**
- Before the first request to a remote engine, a one-time confirmation (`ROUTE-NET`) says:
  *"Your start and end points are sent to `<host>` to work out the route."*
- Routes stay in memory unless you click **Save route**. Saved routes go to
  `~/Library/Application Support/GRID/Maps/routes/`, and **Clear Map Data** removes them.
- Start and end points are never put in a URL query string. Every engine call is a POST body.

### 7.4 Route UI

Clicking **⇄ ROUTE** in the map header, or the palette command `route <from> to <to>`, switches the
right column to the route panel:

```
┌ROUTE────────────────────┐
│A ◉ 1 Market St          │
│B ◎ 2200 Mission St      │
│[■] AVOID MAPPED ALPR    │
│BUFFER  75 m      ◂ ▸    │
│[■] DIRECTIONAL CONES    │
│ENGINE  SELF-HOSTED  ▾   │
│[ ROUTE ⏎ ]              │
├RESULT───────────────────┤
│▸ AVOID   14.1 km  26 min│
│  ⌗ 0 mapped        LOW  │
│  NORMAL  12.4 km  21 min│
│  ⌗ 7 mapped        HIGH │
│  +1.7 km · +5 min       │
├STEPS────────────────────┤
│01 ↑  Market St    400 m │
│02 ↱  5th St       1.2 km│
│03 ↰  Mission St   3.4 km│
│   ⌗ camera 60 m, N-facing│
│…                        │
│[PRINT ⌘P]  [GPX ↓]  [⋯] │
└─────────────────────────┘
```

**On the map:**
- **Avoidance route.** A bright accent line with glow. It *draws on* from A to B in 600 ms, a
  light-cycle trail in the build-on vocabulary (instant when Motion is off).
- **Normal route.** Dim and dashed in textMute, for comparison.
- **Cameras the route passes.** Shown with their cones and a △, and listed in STEPS at the
  maneuver where you pass them.
- **Block zones.** Drawn faintly while ⌥ is held.

**Linked selection.** Hovering a step highlights its segment on the map. Clicking a camera scrolls
to the step where you pass it.

### 7.5 On-device FlockHopper: the routing pack (no Docker)

**Yes, this is feasible.** FlockHopper has two parts:
1. **GraphHopper**, an Apache-2.0 Java routing library. It does the actual pathfinding with
   per-request "custom models".
2. A thin Node/Express layer that turns cameras into avoidance zones and runs the
   normal → avoid → detour sequence.

GRID already ports part 2 to Swift (§7.2). So the only thing missing on the Mac is GraphHopper
itself. GRID can run it **as a helper process it manages**, the same way it runs `GridWidgetHost`.
That needs no Docker, no web server and no network access.

The whole feature is an **add-on you download and can remove**. It isn't part of `GRID.app`.

#### What gets installed, and where

Everything lives under `~/Library/Application Support/GRID/Addons/routing/`. Clicking Remove
deletes the folder.

| Piece | Download | On disk | Source and licence |
|---|---|---|---|
| Java runtime (Eclipse Temurin JRE 25, macOS arm64) | **56 MB** (measured, Adoptium API) | ≈ 130–150 MB unpacked (estimate) | Downloaded straight from Adoptium (GPLv2 + Classpath Exception). GRID doesn't redistribute it. |
| GraphHopper 11.1 | ≈ 15–25 MB core + dependency jars from Maven Central (estimate). The all-in-one `graphhopper-web-11.1.jar` is 47 MB (measured) and carries a web server we don't need. | same | Apache-2.0. Its NOTICE is kept. |
| `GridRouteHost.jar` | ships **inside GRID.app** (≈ 30 KB) | — | GRID's own code: about 300 lines of Java that use GraphHopper as a library |
| Engine total | **≈ 75–105 MB** | **≈ 170–200 MB** | |

Notes:
- GraphHopper 11.x needs Java 25. FlockHopper pins GraphHopper 9.1, which needs Java 17 (the JRE
  17 download is 43 MB).
- Using 11.1 gets current fixes. Phase 0 compares its routes with FlockHopper's on the same trips.
  The custom-model syntax is the same.
- **Integrity checks.** Every artifact's SHA-256 is pinned in GRID's source. Each download is checked
  before it's unpacked, and the JRE's code signature is verified with `codesign --verify`. The
  pinned versions change only with a GRID release.

#### Choosing the area

**Settings › Map › Routing › On-device** offers two ways to pick:

- **A region from Geofabrik's catalogue.** GRID reads `download.geofabrik.de/index-v1.json`
  (verified: each entry has an id, a parent, ISO codes, a `.osm.pbf` URL and a boundary polygon).
  The picker shows US states and sub-states, and other countries' regions too.
- **A custom area.** Drag a rectangle (or later a polygon) on the map:
  1. GRID downloads the Geofabrik extract(s) that cover it.
  2. It clips them to your area in Swift (`GridCore/Maps/PBFClip.swift`, which keeps whole ways
     that cross the edge).
  3. It deletes the full extract.

  A metro area builds far faster and uses much less RAM than a whole state.

**Extract sizes** (measured today, Geofabrik `Content-Length`):

| Region | Size |
|---|---|
| Rhode Island | 53 MB |
| Ohio | 327 MB |
| Colorado | 388 MB |
| Northern California | 656 MB |
| Southern California | 673 MB |
| Texas | 727 MB |
| California | 1.34 GB |

**Before anything downloads,** GRID shows a confirmation with:
- the download size;
- the expected disk use;
- the build time;
- the **peak RAM**.

**Peak RAM is the limiting factor.** FlockHopper's own README lists Ohio (about 300 MB of PBF) at
**4 GB of RAM and about 5 minutes** to build, and the full US at **28 GB of heap (32 GB of RAM) and
2–3 hours**.
- GRID estimates the heap as roughly 13× the PBF size (Ohio's ratio) and sets `-Xmx` from it.
- If the estimate is more than half of `ProcessInfo.physicalMemory`, GRID refuses and suggests a
  smaller area or a sub-state. On a 16 GB Mac, that rules out all of California at once; NorCal,
  SoCal or a custom area work instead.
- Several areas can be installed. Each is its own graph, and a route uses the one that contains
  both its start and its end.

#### Build, then route, all offline

```
Geofabrik .osm.pbf ──download──▶ (optional) PBFClip (Swift) ──▶ area.osm.pbf
        │ verified with Geofabrik's .md5                              │
        ▼                                                             ▼
GridRouteHost (JVM, sandbox: no network) ── import car profile ──▶ graph/<area>/  (≈ 0.3× PBF)
                                                                      │ PBF deleted after the build
ROUTE ⏎ ─▶ Swift FlockHopper port (CameraExposure, zones from the local ALPR snapshot,
           normal → avoid → detour tiers) ─▶ JSON over stdin ─▶ GraphHopper custom_model query
           ◀─ paths, instructions, distance, time ◀─ JSON over stdout
```

- **Graph size.** About **0.3× the PBF**: FlockHopper's US setup needs about 15 GB for an 11.6 GB
  PBF plus its graph. That makes Colorado about 120 MB and Texas about 220 MB (estimates).
- **Same engine settings as FlockHopper:**
  - a car profile with `car_access` and `car_average_speed`;
  - **contraction hierarchies and landmarks off**, so per-request custom models with camera
    `areas` work;
  - block zones ×0.0001 and penalty zones ×0.01;
  - cameras pre-filtered to the corridor around the normal route.
  - Flexible-mode queries over one state should take from a few hundred ms to a few seconds
    (**verify** in Phase 0).
- **Serving memory.** The graph opens memory-mapped (`MMAP`), so serving needs much less memory
  than building: roughly **0.5–1.5 GB while a route is being computed** (estimate).
  - The helper starts on the first ROUTE and **exits after 5 minutes idle**.
  - Starting it again (JVM plus a memory-mapped graph) takes a few seconds.
- **Camera data** comes from the local ALPR snapshot (§4.2), so nothing camera-related is
  downloaded per route. Outside the US and Canada, the area's cameras are fetched once from Overpass
  during the build, snapped to cells as in §4.4.
- **Updates.** Roads change slowly. The area shows its build date, and **Update** rebuilds it from a
  fresh extract, at most monthly. Camera data refreshes on its own schedule, so new cameras are
  avoided without rebuilding the graph.

#### Security model

The routing pack follows the widget host's pattern (ARCHITECTURE.md §5):
- **No network listener.** FlockHopper's `graphhopper-web` server on `localhost:8989` would be
  reachable by any local process and, through DNS rebinding, by web pages. `GridRouteHost` speaks
  JSON lines over stdin and stdout only.
- **Sandboxed.** It runs under `sandbox-exec` with a deny-default profile:
  - no network;
  - read-only access to the runtime and its area's input;
  - writes only to its own graph folder;
  - no home folder access beyond that.
- **Resource limits.** `-Xmx` comes from the estimate above, the process gets low priority
  (`QOS_CLASS_UTILITY`, niced), the build can be cancelled at any time, and partial builds are
  deleted.
- **Hardened runtime.** The JVM is a separate executable, signed and notarized by its publisher,
  with its own JIT entitlement. GRID's own entitlements don't change. Whether Gatekeeper prompts on
  the first run of a downloaded `java` is to be checked (**verify**).
- **Owner decision.** This adds a Java runtime as an optional download. It's "native" in the sense
  that matters (no Electron, no web UI, no server), but it is a second language in the repo. The
  pure-Swift router (Phase 8) is how to drop it later.

#### What leaves the Mac

| When | Host | What it learns |
|---|---|---|
| Installing the engine | Adoptium, Maven Central | That you installed the routing add-on |
| Adding an area | Geofabrik | **Which region you chose** (or, for a custom area, the regions covering it) |
| Routing | **Nobody** | Nothing. Start and end points never leave the Mac. |

#### Compared with the other ways to run routing on the Mac

| | Routing pack (GraphHopper helper) | Native Swift router (Phase 8) | Valhalla embedded (C++) |
|---|---|---|---|
| Matches FlockHopper's routes | **Yes**: same engine and model | Close, but its own engine | No: different engine. Its `exclude_polygons` work per segment. |
| Add-on size | ≈ 170–200 MB + graphs | **0 MB** + graphs (≈ 100–300 MB per state) | ≈ 20–40 MB library (estimate) + tiles |
| RAM to build one state | Ohio 4 GB (measured by FlockHopper) | ≈ 1–2 GB, streaming (estimate) | ≈ 2–4 GB (estimate) |
| RAM while routing | ≈ 0.5–1.5 GB | ≈ 100–300 MB | ≈ 0.3–1 GB |
| Turn restrictions, access rules, instructions | Mature, in many languages | **We build them**, the hard part | Mature |
| Effort | **≈ 3–4 weeks** | ≈ 6–10 weeks | ≈ 4–6 weeks (packaging C++ for macOS; `valhalla-mobile` is iOS-only) |
| Memory-safe parsing | JVM | **Swift** | C++ |

**Recommendation.** Ship the **routing pack** as the on-device option, because it reproduces
FlockHopper exactly and reuses a mature router. Remote engines stay in the list for anyone who
doesn't want a 200 MB add-on. Keep the native Swift router (Phase 8) as the long-term way to drop
the Java runtime and the multi-gigabyte build RAM. Its `PBFReader` and `PBFClip` are built in this
phase anyway.

---

## 8. Printable directions and GPX export

The goal is to drive without the laptop.

### 8.1 PDF cue sheet

**Print… (⌘P)** opens the standard macOS print panel through `NSPrintOperation`, which also offers
*Save as PDF*. The paper size comes from `NSPrintInfo` (Letter or A4).

**Page 1:**
- **Header:** "A → B", when it was generated, the engine, and the camera-data date.
- **Overview map.**
- **Summary:** distance, estimated time, mapped cameras on this route, and cameras avoided compared
  with the normal route.
- **Unavoidable cameras**, if any. For example: *"#2 at step 7: Mission St & 16th St, facing N,
  60 m from the route."*

**Following pages: the cue sheet.**
- Columns: `#` · turn glyph · instruction · onto street · step distance · running total · notes
  (⌗ camera within D).
- 14–16 pt type, high contrast, alternating row tints, readable at arm's length.
- **Optional strip maps:** a small map beside each complex maneuver (roundabouts, ramps, sharp
  turns), 3–4 per page.

**Every page footer:**
- `page n/m`
- `© OpenStreetMap contributors · routing: <engine> · ALPR data: DeFlock/OSM <date>`
- The safety line: *"Have a passenger read these directions or stop safely to check them. Roads
  and camera locations change; obey posted signs. Camera data is volunteer-mapped and
  incomplete."*

**Rendering:**
- The map is **vector**, drawn with CoreGraphics into the PDF context from the same `TileGeometry`
  the Metal renderer uses. It is not a screenshot: crisp at any print size, small files, and
  nothing new to fetch beyond tiles prefetched when the route is computed.
- **Two palettes:**
  - **Paper** (default): white background, dark grey roads, a black route with a thin accent
    stroke, and the accent darkened for print contrast.
  - **Screen**: GRID's dark look, for a PDF viewed on a phone or tablet.
- With the MapLibre fallback, the overview map would be a raster snapshot instead.
- Units follow the locale (mi or km), with an override.

### 8.2 GPX 1.1

**GPX…** writes a `.gpx` file that a standalone GPS unit (Garmin) or an offline phone navigator
(OsmAnd, Organic Maps) can import:
- `<rte>` with one `<rtept>` per maneuver (`name` = instruction, `desc` = street + distance);
- `<trk>` with the full geometry;
- `<wpt>` for each unavoidable camera (`name` "ALPR", `desc` vendor/facing).

This matches FlockHopper's `gpxService.ts` layout (MIT), so files work the same way in both tools.

The export dialog warns: *"Navigation apps may recalculate your route if you go off course, and the
new route can pass cameras. Turn off automatic recalculation, or follow the track."*

### 8.3 Other hand-offs
- **Copy as Text:** a plain cue sheet for Notes or Messages.
- **Share…** (`NSSharingServicePicker`): AirDrop the PDF or GPX to a phone.
- All exports are written only where you choose. Nothing is uploaded.

---

## 9. Phased implementation plan

Every phase ends with `swift test` green, the TESTING.md checklist updated, and a release-notes
entry. Nothing ships to users before Phase 2.

### Phase 0 — Spike and go/no-go (1–2 weeks, throwaway branch)
- `GridCore/Maps/MVTDecoder.swift` (minimal protobuf varint/zigzag reader) and
  `GridCore/Maps/TileMath.swift`. Decode one OpenFreeMap z14 tile, triangulate it, and draw roads
  and water with glow in a debug window.
- **Go criteria for GridMap:**
  - Decode + tessellate under 15 ms per z14 tile on an M1.
  - 120 fps pan at z14 downtown with glow.
  - Under 200 MB resident with 60 tiles.
  - 0% GPU idle.
  - Readable horizontal labels with collision.
- Otherwise, **no-go → MapLibre.** Build the Metal macOS xcframework with Bazel, measure its
  stripped size, and check `MLNMapView` in an `NSViewRepresentable`.
- **Also verify:**
  - Location entitlement under hardened runtime.
  - Which Info.plist key macOS 15 uses.
  - TomTom restyle and caching terms.
  - That the daily GeoJSON cron is actually running (`Last-Modified` over a week).
  - Self-hosting FlockHopper on an Apple-silicon Mac for one state: RAM, disk, import time.
  - Real numbers for §11: GridMap and MapLibre framework size, resident memory on the Map page
    (Instruments › Allocations + VM Tracker), and GRID's idle baseline.
- **Contact DeFlock and FlockHopper** about using the data files and the routing API, and agree on a
  User-Agent.

### Phase 1 — Map page and base map (3–5 weeks)
- `Sources/GridCore/Maps/`
  - `TileMath.swift`: Web Mercator, tile cover for a camera.
  - `MVTDecoder.swift`
  - `Earcut.swift`: polygon triangulation.
  - `LineTessellator.swift`
  - `TileGeometry.swift`: features → vertex arrays per pass.
  - `OpenMapTilesSchema.swift`: layer/class → GRID road class.
  - `LabelPlacer.swift`: greedy collision.
  - `TileSource.swift`: TileJSON parsing, URL templates.
- `Tests/GridCoreTests/Maps*Tests.swift`: fixtures, plus fuzzing of malformed tiles (truncated
  varints, huge counts, unclosed rings).
- `Sources/Grid/Maps/`
  - `MapPanel.swift`: page, header, consent StateBlock.
  - `MapModel.swift`: `@Observable` camera, layers, selection.
  - `MapRenderer.swift`: Metal passes and shaders.
  - `MapMetalView.swift`: pausing container, as the globe does.
  - `MapLabelLayer.swift`
  - `TileStore.swift`: URLSession, URLCache, LRU, User-Agent.
  - `MapAttribution.swift`
  - `MapReadouts.swift`
- `Shell/AppState.swift`: `PanelID.map`, re-index settings to 06. `Shell/RootView.swift`: rail item,
  command. `Settings/Shortcuts.swift`: `GridCommand.showMap` ⌥⌘5. `Palette/CommandPalette.swift`: `map …`.
- `Sources/Grid/Maps/MapSettingsSection.swift`: tile source, cache size, Clear Map Data.
- Docs: `DESIGN.md` (map tokens and passes), `ARCHITECTURE.md` (Maps section, security model:
  memory-safe decoding, no web content), `LICENSES.md` (fetched map data), README.

### Phase 2 — Location (1 week)
- `Sources/Grid/Maps/LocationProvider.swift`: CLLocationManager wrapper with the states from §5.1,
  one-shot and follow, stopping when hidden.
- `Resources/Info.plist` (usage strings), `Resources/GRID.entitlements`, `scripts/bundle.sh`
  (`--entitlements`).
- QA: allow, deny, Location Services off, revoke while following, sleep and wake.

### Phase 3 — ALPR layer (2 weeks)
- `Sources/GridCore/Maps/`
  - `OSMSurveillance.swift`: tags → `ALPRCamera`, vendor and direction parsing.
  - `OverpassQuery.swift`: query builder, cell snapping.
  - `SpatialIndex.swift`: grid bucket index for 160k points.
  - `GeoJSONReader.swift`: streaming, gz via `Compression`.
  - `FetchPolicy.swift`: TTLs, backoff, daily budget.
  - All tested, including real-world tag oddities: `NE;SW`, `45;225`, `ALPR;camera`, ways via `center`.
- `Sources/Grid/Maps/`
  - `ALPRStore.swift`: snapshot download (ETag), cell cache, Overpass client (serial, 429 backoff).
  - `ALPRLayer.swift`: markers, wedges, clusters.
  - `MapInspector.swift`
  - `MapList.swift`: accessible list.

### Phase 4 — POIs and search (1–2 weeks)
- `GridCore/Maps/POICatalog.swift`: OpenMapTiles class → category and glyph. `GridCore/Maps/LocalSearch.swift`:
  ranking over loaded tile names, reusing `GridCore/FuzzyMatch.swift`.
- `Sources/Grid/Maps/POILayer.swift`, `PlaceSearch.swift`: local first, then Nominatim on ⏎ with a
  1/s limiter and 24 h cache. "Open in Apple Maps" hand-off.

### Phase 5 — Traffic, offline and widget (2–3 weeks)
- `Sources/Grid/Maps/TrafficProvider.swift`: TomTom vector flow, then HERE v7. Key in the Keychain,
  3 min refresh while visible, memory only.
- `Sources/GridCore/Maps/PMTilesReader.swift`: header, directories, HTTP Range and local file. Add
  the Protomaps schema table.
- `Sources/Grid/Widgets/PerimeterWidget.swift` + `WidgetKind.perimeter`.
- "Open in Apple Maps" (`maps://`) in the header `⋯` and the right-click menu.

### Phase 6 — Camera-avoiding routing (3–4 weeks)
- `Sources/GridCore/Maps/`
  - `RouteModel.swift`: provider-neutral `Route`, `Maneuver`, `RouteComparison`.
  - `CameraExposure.swift`: cones and circles, the facing test, block and penalty zones, scoring.
    Ported from FlockHopper (MIT) with the north-facing fix.
  - `Polyline.swift`: encoded polyline, precision 5 and 6.
  - `FlockHopperAPI.swift` and `ValhallaAPI.swift`: Codable requests and responses, plus the corridor
    loop.
  - Tests: real tag cases, a camera at `direction=0`, a route with no camera-free option, and
    re-scoring that disagrees with the engine.
- `Sources/Grid/Maps/`
  - `RouteProvider.swift`: the protocol, a serial queue and the ROUTE-NET consent.
  - `RoutePanel.swift`
  - `RouteLayer.swift`: draw-on trail, comparison route, unavoidable cameras.
  - `RouteStore.swift`: saved routes, local only.
  - `RouteSettingsSection.swift`: engine, endpoint, buffer, cones.
- `docs/MAPS-ROUTING-SELFHOST.md`: run FlockHopper (GraphHopper + Express) locally and point GRID
  at it.
- `LICENSES.md`: FlockHopper's MIT notice for the ported algorithms. **No code from the AGPL
  `deflock-app`.**

### Phase 7 — Print and GPX export (1–2 weeks)
- `Sources/GridCore/Maps/`
  - `CueSheet.swift`: maneuvers become rows, with distance formatting, running totals, camera notes
    and turn glyphs.
  - `GPXWriter.swift`: GPX 1.1 `rte`/`trk`/`wpt` with XML escaping.
  - Both tested.
- `Sources/Grid/Maps/`
  - `PrintMapRenderer.swift`: CoreGraphics vector map from `TileGeometry`, paper and screen
    palettes.
  - `RoutePrintView.swift`: paginated `NSView` for `NSPrintOperation`.
  - `RouteExport.swift`: Print…, GPX…, Copy as Text, Share….
- QA: Letter and A4, black-and-white printer, 1–40 page routes, a trip with unavoidable cameras,
  and GPX imported into OsmAnd and Garmin BaseCamp.

### Phase 7b — On-device routing pack (3–4 weeks)
- `Sources/GridCore/Maps/`
  - `GeofabrikIndex.swift`: parse `index-v1.json`, regions covering a rectangle.
  - `PBFReader.swift` and `PBFClip.swift`: streaming, keeps whole ways, tested with fixtures.
  - `RoutingPackPlan.swift`: download, disk, RAM and time estimates, plus the refusal rule.
  - `RouteHostProtocol.swift`: Codable JSON-lines messages.
- `RouteHost/GridRouteHost.java` + `scripts/build-routehost.sh`: compiled with a JDK at GRID build
  time and copied into `GRID.app/Contents/Resources`.
- `Sources/Grid/Maps/`
  - `RoutingPackInstaller.swift`: pinned SHA-256, Adoptium and Maven Central URLs, unpacking,
    `codesign --verify`.
  - `RouteHostProcess.swift`: `sandbox-exec` profile, `-Xmx`, idle exit, cancellation.
  - `OnDeviceRouteProvider.swift`
  - `RoutingPackSettings.swift`: area picker, map rectangle, progress, Update, Remove.
- `LICENSES.md`: GraphHopper (Apache-2.0, NOTICE), plus a note that the JRE is downloaded from
  Adoptium and not redistributed.
- QA:
  - Build Rhode Island and Colorado on 8 and 16 GB Macs.
  - Cancel mid-build.
  - Remove.
  - Route parity with FlockHopper on 20 fixed trips.
  - The helper can't open a socket (sandbox test).

### Phase 8 — Research: native Swift router (not committed)
- A prototype graph builder (reusing `PBFReader`) and A* with camera penalties per edge.
- If it matches the routing pack's quality, it replaces the Java helper and drops about 200 MB and
  multi-GB build RAM.
- Measure graph size, query time and instruction quality against FlockHopper on the same trips.
- Ship it only if it is good enough to replace a server.

---

## 10. Risks

| Risk | Likelihood / impact | Mitigation |
|---|---|---|
| Custom renderer takes longer than estimated, especially labels | Medium / high | Phase 0 go/no-go. Keep labels minimal (horizontal, z15+ road names, place names). MapLibre fallback is costed. |
| MapLibre fallback: unmaintained AppKit API, self-built binary, C++ parsing of network data | High if chosen | Pin the version, build in CI with a checksum, and watch issue #4088 for official macOS releases. |
| OpenFreeMap disappears or changes | Low–medium / high | Tile URL is a setting. Document PMTiles self-hosting and the offline extract (Phase 5). |
| FlockHopper or DeFlock files move, go stale or are rate-limited | Medium / medium | ETag + date shown in the UI. Fall back to the hourly MVT tiles, then to cell-snapped Overpass. Contact the maintainers before shipping. |
| Public Overpass misuse or blocking | Medium / medium | Overpass isn't the default. Serial requests, cell snapping, 24 h cache, daily budget, backoff, user-chosen endpoint. |
| Traffic terms (restyling, caching) | Medium / medium | BYO key, memory only, verify the terms in Phase 0, keep HERE as an alternative. |
| Location silently denied in notarized builds (missing entitlement) | Medium / high | Entitlement + QA on a Developer ID build in Phase 2. |
| Users misread ALPR data as complete or authoritative | Medium / medium | Neutral wording, a coverage disclaimer in the legend, snapshot age shown, links to OSM for each camera. |
| GPU, battery or memory cost of glow | Medium / low | Glow is skipped with Effects › Glow off. Half-res bloom. Paused when hidden. On-demand frames. |
| Opaque Metal view for accessibility | High / medium | Accessible list view, keyboard camera controls, labelled controls. |
| Routing gives a false sense of being unseen | Medium / high | Wording says "mapped cameras" throughout; unavoidable cameras are listed; the disclaimer is on screen and on every printed page; the data date is shown. |
| Start and end points sent to a third-party engine | High (by design) / high | Routing is off by default; a one-time ROUTE-NET consent names the host; the **on-device routing pack** keeps them local; POST bodies only; nothing stored unless saved. |
| Routing pack: graph builds exhaust RAM, or Java/GraphHopper need security updates | Medium / medium | Peak-RAM estimate with a refusal over 50% of physical memory, cancellable low-priority builds, pinned versions updated with GRID releases, a sandboxed helper with no network, and Remove in one click. |
| The public FlockHopper API changes, rate-limits or disappears (no published terms; deployed v2.0.0 differs from the public source) | Medium / high | It's only a preset after the maintainers agree; the endpoint is configurable; Codable decoding tolerates unknown fields; Valhalla is the second engine. |
| Apple Maps data accidentally used on GRID's map | Low / high | Not imported in the Maps module except for the `maps://` hand-off; a code-review checklist item in ARCHITECTURE.md. |
| GPX navigators re-route through cameras | Medium / medium | Warning in the export dialog; a track (`trk`) is included so the course can be followed as is. |
| Using printed directions while driving | Medium / high | Large type, a safety line on every page, and no in-car live mode. |
| ODbL or CC-BY attribution missed in some state (compact, popover) | Low / high | The attribution strip is part of the map view itself, not the chrome, and is tested in QA at each window size. |

## 11. App size, memory and disk budget

**Baseline.** `GRID.app` 0.4.0 (release build, arm64) is **17 MB**: the `Grid` binary is 16.8 MB and
`GridWidgetHost` is 94 KB. Idle RAM wasn't measured for this plan.

Everything below is an **estimate** except where a source is given. Phase 0 replaces the estimates
with measurements.

**Design rule.** The Maps module loads nothing until the Map page is first shown. It frees its GPU
buffers, tile cache in memory and camera index **30 s after the page is hidden**, the same pattern
as the widget hosts. With the Map never opened, GRID's memory use is unchanged.

### 11.1 App size (download / installed)

| Piece | Adds to `GRID.app` | Basis |
|---|---|---|
| GridMap (custom Metal renderer, data clients, UI, routing client, print/GPX) | **≈ +1–2 MB** | Swift code plus Metal shaders compiled at run time, as the globe does. No bundled map or camera data (ODbL, §1.4). |
| MapLibre Native fallback | **≈ +10–15 MB**, plus 1–3 MB if glyph ranges for the label font are bundled | The iOS dynamic xcframework zip for 6.27.0 is 10.1 MB and holds device and simulator slices. A stripped arm64-only macOS framework should land in this range. The 7.0 zip is 164 MB only because it bundles debug symbols. |
| MapKit (only as a permitted fallback) | 0 | System framework |
| Traffic, ALPR, routing clients, print, GPX | < 0.5 MB together | Pure Swift |
| Routing pack (§7.5) | ≈ 30 KB (`GridRouteHost.jar`) | The JRE and GraphHopper (≈ 75–105 MB download, ≈ 170–200 MB on disk) are an **optional add-on** in Application Support, not part of the app |
| Native Swift router (Phase 8) | < 1 MB of code | The graph is downloaded and built per region, not bundled |

So the recommended path keeps GRID at **about 18–19 MB**. The MapLibre fallback roughly **doubles**
it to about 30 MB.

### 11.2 Memory (resident, unified memory: GPU buffers count)

| State | Recommended (GridMap) | MapLibre fallback | Notes |
|---|---|---|---|
| Map never opened | **+0** | +0 (framework mapped, not touched) | Lazy loading |
| Map visible, browsing a city at z14 | **≈ 80–200 MB** (Phase 0 target: under 200 MB) | ≈ 150–300 MB | GridMap breakdown: up to 60 tiles of vertex buffers (≈ 30–120 MB in dense downtowns), the half-res glow targets (≈ 10–15 MB on a Retina window, 0 with Glow off), the label layer (≈ 5–10 MB) |
| ALPR layer on | **+≈ 10 MB** | same | 160k cameras in a compact struct (≈ 40–60 B each) plus the spatial grid. The 39 MB gz GeoJSON is **stream-parsed** once into a binary file. Loading it whole with `JSONSerialization` would peak far above 1 GB and is ruled out. |
| Traffic on | +≈ 5–20 MB | same | Flow tiles for the viewport, memory only |
| Route computed (remote engine) | +< 5 MB | same | Geometry, maneuvers, scored cameras |
| Printing a route | +≈ 50–150 MB **while printing** | raster snapshots: similar | Freed when the print job finishes |
| Routing pack: building an area | **separate helper process**: about 13× the PBF (Rhode Island ≈ 0.7 GB, Ohio 4 GB, Texas ≈ 9–10 GB) **only during the build** | same | GRID refuses builds over half of physical RAM |
| Routing pack: routing | helper ≈ 0.5–1.5 GB **while routing**, then it exits after 5 min idle | same | Graph memory-mapped |
| Native Swift router (Phase 8) | +≈ 100–300 MB **while routing** | same | Graph memory-mapped; only touched pages count; A* working set grows with trip length |
| Map hidden for more than 30 s | back to **+≈ 0–10 MB** | MapLibre keeps more internal state; ≈ 30–60 MB | Freed by the rule above |

### 11.3 Disk (Application Support, all clearable with Clear Map Data)

| Data | Size | Notes |
|---|---|---|
| Tile cache | **≤ 200 MB** (default cap, adjustable) | `URLCache`, LRU |
| ALPR snapshot | **≈ 6–10 MB** stored. The download is 39 MB, usually weekly. | Converted to a compact binary on arrival; the GeoJSON is deleted |
| Overpass cell cache | < 5 MB | 24 h TTL |
| Saved routes | KB each | Only if saved |
| Offline PMTiles extract (Phase 5) | ≈ 50–150 MB for a metro area, hundreds of MB to ≈ 1 GB for a state at z0–14 | Optional; the planet build is about 139 GB, so never the planet |
| Routing pack engine | ≈ 170–200 MB | JRE + GraphHopper; Remove deletes it |
| Routing pack graph per area | ≈ 0.3× the PBF: Rhode Island ≈ 16 MB, Colorado ≈ 120 MB, Texas ≈ 220 MB (estimates). The PBF itself (53 MB – 1.34 GB) exists only during the build | |
| Native Swift routing graph (Phase 8) | ≈ 100–300 MB per state | Built from a Geofabrik PBF, deleted after the build. California's PBF is 1.34 GB, the whole US 12.3 GB. |

### 11.4 Outside GRID: a self-hosted routing engine

This isn't GRID's memory, but it is the Mac's if the user runs the engine locally:

| Engine | One state | Whole US |
|---|---|---|
| FlockHopper (GraphHopper JVM, contraction hierarchies off) | **Ohio: 4 GB RAM, about 5 min to build** (FlockHopper README) | **28 GB heap / 32 GB RAM, 2–3 h to build, about 15 GB of disk** (FlockHopper README) |
| Valhalla | ≈ 1–2 GB RAM to serve. Building the tiles needs more. | ≈ 8–16 GB RAM to build |

- On macOS, Docker Desktop adds its own VM, roughly 1–2 GB more.
- For the whole US, a separate always-on machine is more practical than a laptop.
- A mid-size state fits on a 16 GB Mac. A large one (California) or the whole US doesn't, so use a
  sub-state or a custom area.
- The **routing pack (§7.5)** uses the same engine without Docker. Its build RAM follows the
  FlockHopper figures above, and serving needs about 0.5–1.5 GB, only while routing.

## 12. Update checker: GRID releases and map data

There are two parts, both under one **Settings › Updates** section:
1. **GRID releases** from GitHub. This doesn't depend on Maps and **can ship first** (Phase U1).
2. **Map data:** ALPR cameras, routing areas, the routing engine and the base tiles. These checks
   ship with the phases that add each kind of data.

### 12.1 Rules

- **Nothing checks until you say so.**
  - The first launch of the version that adds this shows a one-time `StateBlock` choice:
    *"Check GitHub for new GRID versions once a day? GRID sends a plain request to api.github.com
    with no identifiers."* `[Check daily] [Not now]`.
  - **GRID › Check for Updates…** and the palette command `update` always work on demand.
- **Map-data checks** run only when Maps has been enabled (§6, `MAP-NET`). They happen while the
  Map page is in use, never from a background timer.
- **Background checks are energy-friendly.**
  - App checks run at launch and then about every 24 h, through `NSBackgroundActivityScheduler`.
  - Requests are conditional (ETag), so "no change" costs a few hundred bytes.
- **Nothing installs silently.**
  - Every download is confirmed.
  - Every replacement of GRID itself goes through the normal quit confirmation, because quitting
    ends terminal sessions (§12.2).
- **What GitHub learns:** your IP address and a generic `User-Agent: GRID`, without the version
  number, to reduce fingerprinting. No token, no account, no install ID.

### 12.2 GRID releases

**Source:** `GET https://api.github.com/repos/HackitM/grid/releases/latest`.
- That endpoint skips drafts and pre-releases. A "Include pre-releases" option uses
  `/releases?per_page=10` instead.
- Headers: `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28` and
  `If-None-Match` with the stored ETag.
- Unauthenticated calls are limited to 60 an hour per IP. A daily check is far below that, and
  conditional requests answered with 304 should not count against it (**verify**).
- **Fields used:** `tag_name` (`v0.5.0`), `name`, `html_url`, `published_at`, `body` (the release
  notes) and `assets[]` (`name`, `size`, `browser_download_url`).
- **Assets come from `scripts/release.sh`:** `GRID-<version>-macOS.zip` plus
  `GRID-<version>-macOS.zip.sha256`. The checker matches those names exactly.
  - Checked today: the latest release is **v0.5.0**, with a 5.3 MB zip and an 87-byte `.sha256`.
- **Version comparison:** `tag_name` without its `v`, compared as a semantic version with
  `CFBundleShortVersionString`. Pre-release suffixes like `-beta.1` sort below the release.

**How it shows up:**

```
status bar   ◆ GRID 0.5.0 AVAILABLE · VIEW                       (Ares text band, once per version)

┌SETTINGS › UPDATES──────────────────────────────────────────────┐
│GRID          0.4.0 → 0.5.0   released 2026-11-09   ◆ AVAILABLE │
│              checked 2 h ago · [■] check daily · [ ] pre-releases│
│ ── WHAT'S NEW ───────────────────────────────────────────────■ │
│ (release notes from GitHub, plain GRID type, links not followed │
│  until clicked)                                                 │
│ [VIEW ON GITHUB ↗] [DOWNLOAD & VERIFY] [SKIP 0.5.0] [LATER]     │
├─────────────────────────────────────────────────────────────────┤
│ALPR CAMERAS  snapshot 2 d old · 146,410 cameras      ✓ CURRENT  │
│BASE MAP      OpenFreeMap planet 2026-11-01            ✓ CURRENT  │
│ROUTING ENGINE GraphHopper 11.1 · JRE 25.0.5           △ 25.0.6 IN GRID 0.5.1 │
│AREA COLORADO built 41 d ago                [UPDATE · 388 MB · ~5 min] │
└─────────────────────────────────────────────────────────────────┘
```

- **Release notes** come from remote content. They are rendered as plain styled text
  (`AttributedString(markdown:)`, links shown but opened only on click) and never in a web view.
- **VIEW ON GITHUB** opens `html_url` in GRID's browser, or in the default browser if you choose
  that in Settings.
- **SKIP** hides that version until a newer one appears. **LATER** snoozes for 7 days.

**Installing comes in three tiers, shipped in this order:**

| Tier | What GRID does | Trust check | Gatekeeper |
|---|---|---|---|
| **1. Open the release page** (Phase U1) | Opens `html_url`; you download and replace the app as in the README | Yours | Unchanged |
| **2. Download & verify** (Phase U1) | Downloads the zip through the browser's existing download path (confirmed, saved to Downloads, **quarantined**, where-from set). Checks its SHA-256 against the release's `.sha256`. Unzips next to it and **reveals it in Finder** with the steps: quit GRID, replace it in Applications, open it. | SHA-256 catches corruption or truncation. It is **not** proof of authenticity, because both files come from the same release. | Quarantine is **kept on purpose**. Until GRID is notarized, macOS asks for *Open Anyway* again after each update. GRID never strips quarantine, since that would bypass a macOS protection. |
| **3. Install & Relaunch** (Phase U3, **only once releases are Developer-ID signed and notarized**) | Download as in tier 2, verify, then quit through the normal confirmation (or **"Install when I next quit"**, so running terminal sessions aren't cut short). A small relaunch helper waits for GRID to exit, moves the old app to the Trash, moves the new one into place and opens it. | **Authenticity.** (a) The code signature must satisfy a requirement pinned in the running app: the same Developer ID Team ID (`SecStaticCodeCheckValidity`). (b) The notarization check must pass (`SecAssessment`). (c) Optionally, an **Ed25519 signature** of the zip (`.sig` asset, made by `release.sh` with a key kept off GitHub) is verified with CryptoKit against a public key compiled into GRID. A compromised GitHub account alone then can't push an update. | A notarized app opens without prompts |

- **If the app's folder isn't writable** (for example `/Applications` needing an admin), tier 3
  falls back to tier 2. It never asks for admin rights.
- **Ad-hoc-signed builds** (today's) have no stable identity to verify, so tier 3 stays off for them.
- **Sparkle 2** (MIT, EdDSA-signed appcasts, about 3 MB) is the standard alternative for tier 3.
  The plan prefers about 400 lines of our own, because tiers 1–2 already exist and it keeps GRID's
  single-dependency stance. Revisit if installer edge cases pile up.

### 12.3 Map data

| Data | Check | Network | How often | Shown as | Update action |
|---|---|---|---|---|---|
| **ALPR snapshot** (§4.2) | Conditional GET on `cameras.geojson.gz` (`If-None-Match` / `If-Modified-Since`); 304 = current | FlockHopper's data host: that you use the snapshot. **No area.** | At most daily, when the Map or a route is used | `ALPR … snapshot 2 d old` in the status bar and Settings. △ at 7+ days old if a refresh failed | Automatic (small check). The 39 MB download only happens when it changed. |
| **Overpass cells** (§4.4) | 24 h TTL | Overpass: the cell | On view | Cell age in the inspector | Automatic, or ⟳ refresh area |
| **Base map tiles** | Re-read OpenFreeMap's TileJSON when the Map opens. A new planet version means new tile URLs, so the old cache ages out. | OpenFreeMap: nothing beyond normal use | Each Map open | Planet date in Settings | Automatic |
| **Routing areas** (§7.5) | `HEAD` on the area's Geofabrik `.osm.pbf` (`Last-Modified`). Geofabrik rebuilds extracts daily. | Geofabrik: **which region** (as when it was installed) | At most weekly. **Off** if the pack isn't installed. | `AREA COLORADO built 41 d ago` | **Never automatic** (it costs RAM and time). An offer appears after 30 days: `[UPDATE · 388 MB · ~5 min]`. |
| **Routing engine** (JRE + GraphHopper) | None of its own. Versions are pinned in GRID's source, so a GRID update can bring newer pins (security fixes). | — | After GRID updates | `△ 25.0.6 IN GRID 0.5.1` / `△ UPDATE ENGINE (56 MB)` | Offer after a GRID update, with the same SHA-256 and signature checks as the install |
| **Remote routing engines** | `GET /api/v1/health` before the first route of a session (FlockHopper reports `version` and its camera data's `maxAgeHours`) | That engine | Per session | Engine version and its camera data age in the route panel | — |

**Freshness affects routing:**
- If the ALPR snapshot is more than 7 days old and can't be refreshed, routes still compute, with
  △ `CAMERA DATA 9 DAYS OLD` in the route panel and on the printout.
- If a remote engine's camera data is older than GRID's, the route panel says so, because GRID
  re-scores against its own data anyway (§7.2).

### 12.4 Privacy wording (README)

The "Network requests GRID makes on its own" bullet becomes:

> **Network requests GRID makes on its own:** downloading the ad-blocking filter lists from their
> publishers (only while ad blocking is on), Safari's standard fraudulent-site check in the browser,
> **checking GitHub for a new GRID version once a day (only if you turned it on; no identifiers are
> sent)**, and, once you've enabled Maps, refreshing map data while you use the Map (§5.2).
> Everything else happens because you asked for it.

### 12.5 Files and phases

**Phase U1 — App update checker, tiers 1–2 (about 1 week; can ship before any Maps work)**
- `Sources/GridCore/Updates/`
  - `SemanticVersion.swift`: parse, compare, pre-release ordering.
  - `GitHubRelease.swift`: Codable, plus asset matching by `release.sh` names.
  - `UpdatePolicy.swift`: interval, skip, snooze, pre-release opt-in.
  - `ChecksumFile.swift`: parse `shasum -a 256` output.
  - Tests: version edge cases, malformed JSON, missing assets, wrong checksum, 304 handling.
- `Sources/Grid/Updates/`
  - `UpdateChecker.swift`: `NSBackgroundActivityScheduler`, an ephemeral `URLSession`, the stored
    ETag.
  - `UpdateSettingsSection.swift`
  - `UpdateNotice.swift`: status-bar text band.
  - `UpdateDownloader.swift`: reuses the browser's confirmed, quarantined download path, then
    verifies the SHA-256.
- `Settings/Shortcuts.swift` gets `GridCommand.checkForUpdates`, added to the GRID app menu and the
  palette (`update`).
- **Debug-only QA hook:** point the checker at a local JSON fixture (in `#if DEBUG` under `--qa`,
  like the other hooks). Release builds can only reach the real repo.
- **Docs:** README privacy bullet (§12.4), ARCHITECTURE security model, TESTING checklist.

**Map-data checks** are built into Phase 3 (`ALPRStore`), Phase 1 (`TileSource`) and Phase 7b
(`RoutingPackInstaller`). They report to the same Updates section through an `UpdateSource`
protocol (`id`, `status`, `lastChecked`, `check()`, `update()`).

**Phase U3 — Install & Relaunch (after notarization)**
- `scripts/release.sh`: sign with Developer ID and notarize, and optionally write the Ed25519 `.sig`
  asset (key in the release machine's Keychain).
- `Sources/Grid/Updates/Installer.swift`: requirement and notarization checks, "install when I next
  quit".
- `GridUpdateHelper`: a tiny executable target that waits for the PID to exit, swaps the bundles and
  relaunches.

### 12.6 Risks

| Risk | Mitigation |
|---|---|
| A fake or tampered release (compromised GitHub account) | Tiers 1–2 only inform and verify integrity. Tier 3 requires a matching Developer ID **and** notarization, and optionally an Ed25519 key that never touches GitHub. |
| A user replaces the app while terminal jobs are running | Always goes through the existing quit confirmation, with "install when I next quit" |
| GitHub API rate limits or changes | Daily, conditional checks; a failure shows ✕ `UPD-ERR` in Settings and never nags |
| Update checks seen as tracking | Off until opted in, a generic User-Agent, no IDs, documented in the README |
| Stale camera data used for routing | Age shown everywhere it matters; a warning after 7 days |

---

## 13. Out of scope (unless requested)
- Live turn-by-turn voice navigation in GRID. A laptop shouldn't be used while driving; §8's
  exports cover the trip instead.
- Apple Maps data (traffic, routes, search) on GRID's map. Apple's licence forbids it (§2.1).
- Editing OSM, which needs an account.
- Cloud sync of places.
- Any AI or ranking service.
- Background location.
- Notifications about nearby cameras.
