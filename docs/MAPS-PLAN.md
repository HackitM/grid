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
| Routing | **Routes that avoid mapped ALPR cameras** through a **FlockHopper-compatible engine**: self-hosted (recommended) or the public FlockHopper API if its maintainers agree. A Valhalla engine comes second and an on-device router is researched later. **GRID re-scores every route against its own camera data** (§7). | Start and end points go to the engine you choose. "Out of view" can only mean "away from *mapped* cameras". |
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
| **On-device router in GRID** | Full, with camera penalties applied per edge | **Nothing** | A drivable graph built from a Geofabrik state extract (California's PBF is 1.34 GB) into a compact file of about 100–300 MB (estimate). A* with penalties. Our own turn instructions, using the `osrm-text-instructions` phrase templates (BSD-2) | **Later research (Phase 8)**, not committed. It's the most private option but costs about 3–6 weeks (estimate) plus graph-building tools; turn restrictions and access tags are the hard parts. |
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

### Phase 8 — Research: on-device routing (not committed)
- A prototype graph builder (Geofabrik state PBF → compact edge file) and A* with camera penalties
  per edge.
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
| Start and end points sent to a third-party engine | High (by design) / high | Routing is off by default; a one-time ROUTE-NET consent names the host; self-hosting is documented and recommended; POST bodies only; nothing stored unless saved. |
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
| On-device router (Phase 8) | < 1 MB of code | The graph is downloaded and built per region, not bundled |

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
| On-device routing (Phase 8) | +≈ 100–300 MB **while routing** | same | Graph memory-mapped; only touched pages count; A* working set grows with trip length |
| Map hidden for more than 30 s | back to **+≈ 0–10 MB** | MapLibre keeps more internal state; ≈ 30–60 MB | Freed by the rule above |

### 11.3 Disk (Application Support, all clearable with Clear Map Data)

| Data | Size | Notes |
|---|---|---|
| Tile cache | **≤ 200 MB** (default cap, adjustable) | `URLCache`, LRU |
| ALPR snapshot | **≈ 6–10 MB** stored. The download is 39 MB, usually weekly. | Converted to a compact binary on arrival; the GeoJSON is deleted |
| Overpass cell cache | < 5 MB | 24 h TTL |
| Saved routes | KB each | Only if saved |
| Offline PMTiles extract (Phase 5) | ≈ 50–150 MB for a metro area, hundreds of MB to ≈ 1 GB for a state at z0–14 | Optional; the planet build is about 139 GB, so never the planet |
| On-device routing graph (Phase 8) | ≈ 100–300 MB per state | Built from a Geofabrik PBF, deleted after the build. California's PBF is 1.34 GB, the whole US 12.3 GB. |

### 11.4 Outside GRID: a self-hosted routing engine

This isn't GRID's memory, but it is the Mac's if the user runs the engine locally:

| Engine | One state | Whole US |
|---|---|---|
| FlockHopper (GraphHopper JVM, contraction hierarchies off) | ≈ 2–4 GB RAM | ≈ 8–16 GB RAM |
| Valhalla | ≈ 1–2 GB RAM to serve. Building the tiles needs more. | ≈ 8–16 GB RAM to build |

- On macOS, Docker Desktop adds its own VM, roughly 1–2 GB more.
- For the whole US, a separate always-on machine is more practical than a laptop.
- One state fits comfortably on a 16 GB Mac.
- Phase 0 measures this for one state (§9).

## 12. Out of scope (unless requested)
- Live turn-by-turn voice navigation in GRID. A laptop shouldn't be used while driving; §8's
  exports cover the trip instead.
- Apple Maps data (traffic, routes, search) on GRID's map. Apple's licence forbids it (§2.1).
- Editing OSM, which needs an account.
- Cloud sync of places.
- Any AI or ranking service.
- Background location.
- Notifications about nearby cameras.
