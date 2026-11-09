# Dependencies & Licenses

| Dependency | Version | License | Role | Notes |
|---|---|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.99.3 (pinned `.upToNextMinor`) | MIT | Production: VT/xterm emulation, PTY process, AppKit terminal view | Includes code derived from xterm.js (MIT). Pre-2.0: expect some API churn on minor bumps |
| [swift-png](https://github.com/tayloraswift/swift-png) | 4.5.2 | Apache-2.0 | Transitive (SwiftTerm), used only for non-Apple platforms | Not linked on macOS (trait-conditional) |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache-2.0 | Transitive (SwiftTerm’s sample tool) | Not linked into GRID |
| rarestype/h | 1.0.1 | see repository | Transitive (swift-png) | Not linked on macOS |

Apple system frameworks only otherwise (SwiftUI, AppKit, QuickLookThumbnailing, Darwin/libproc).

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
| mozilla/readability (Apache-2.0), SwiftSoup (MIT) | Planned for Milestone 3 reader mode |
