# Dependencies & Licenses

| Dependency | Version | License | Role | Notes |
|---|---|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.99.3 (pinned `.upToNextMinor`) | MIT | Production: VT/xterm emulation, PTY process, AppKit terminal view | Includes code derived from xterm.js (MIT). Pre-2.0: expect some API churn on minor bumps |
| [swift-png](https://github.com/tayloraswift/swift-png) | 4.5.2 | Apache-2.0 | Transitive (SwiftTerm), used only for non-Apple platforms | Not linked on macOS (trait-conditional) |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache-2.0 | Transitive (SwiftTerm’s sample tool) | Not linked into GRID |
| rarestype/h | 1.0.1 | see repository | Transitive (swift-png) | Not linked on macOS |

| [mozilla/readability](https://github.com/mozilla/readability) | 0.6.0 (vendored in `ThirdParty/readability`, embedded by `scripts/embed-readability.sh`) | Apache-2.0 | Production: reader view article extraction | SHA-256 of Readability.js `34dcab3d…f174`. License shipped in the app bundle |

Apple system frameworks otherwise (SwiftUI, AppKit, WebKit, QuickLookThumbnailing, Darwin/libproc).

**Ad-blocking filter lists are not bundled.** When ad blocking is on, GRID downloads them from their
publishers at runtime and keeps them in Application Support: uBlock filters (+ badware, privacy,
unbreak, quick fixes) — GPLv3, uBlock Origin project; EasyList and EasyPrivacy — GPLv3 / CC BY-SA 3.0,
The EasyList authors; Peter Lowe's list — see pgl.yoyo.org. GRID's converter is original code.

**Map data is not bundled either.** It is fetched at runtime after you enable it, and cached in
Application Support:
- **Base map:** vector tiles from [OpenFreeMap](https://openfreemap.org) in the OpenMapTiles schema
  (© OpenMapTiles, CC-BY 4.0). The data is © OpenStreetMap contributors (ODbL 1.0).
- **Region boundaries:** Geofabrik's `index-v1.json` (© Geofabrik GmbH and OpenStreetMap
  contributors, ODbL 1.0).
- **ALPR cameras:** OpenStreetMap data (ODbL 1.0), as published by DeFlock / FlockHopper, or
  queried from an Overpass server.

The map always shows the attribution. GRID's earcut triangulation is a port of
[mapbox/earcut](https://github.com/mapbox/earcut) (ISC, © Mapbox); the notice is kept in
`Sources/GridCore/Maps/Earcut.swift`.

Obligation: distribute SwiftTerm’s MIT notice (copyright Miguel de Icaza, xterm.js authors,
SourceLair) with binary releases — e.g. copy `.build/checkouts/SwiftTerm/LICENSE` into the app’s
Resources as part of the release script.

## Reviewed, not used
| Project | Why not |
|---|---|
| ghostty / libghostty | Embedding API is internal / unstable |
| xterm.js + node-pty / portable-pty | Belong to the web-stack alternatives that were not chosen |
| stevenwanderski/tauri-terminal, marc2332/tauri-terminal | No license (cannot reuse); proofs of concept; the former exposes a webview → shell command |
| WalrusQuant/launchpad | Tauri terminal workspace (Apache-2.0); architectural reference only |
| abue-ammar/tinycast | AGPL-3.0 launcher; reference only for directory-scan discovery |
| SwiftSoup (MIT) | Not needed: the reader view sanitizes with a CSP + JavaScript-off web view + a small sanitizer |
| uBlock Origin / uBO Lite (GPLv3) as an embedded extension | Its full engine needs browser APIs WebKit lacks; its default lists are used through WebKit's native content blocker instead |
| Chromium Embedded Framework | ~170 MB per app, own security-update burden; WebKit chosen |
