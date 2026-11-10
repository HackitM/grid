# GRID — Product & Architecture Proposal

GRID is a terminal-first macOS workspace: a real PTY terminal, a file browser, an installed-app
launcher, and (later) web reading — in one keyboard-driven window with a disciplined, Tron-derived
visual language. It is an ordinary macOS app: normal windows, menus, Dock, privacy prompts.

## 1. Repository at start

The project folder contained only `inspo_media/` (8 unique Tron: Legacy board-room stills — 4 files
were byte-identical duplicates — 6 Tron: Ares images, 4 videos). No code. `inspo_media/` is
git-ignored: it is copyrighted reference material and must not be committed or redistributed.

## 2. Visual references reviewed

| Reference | Access | What was taken from it |
|---|---|---|
| gmunk.com/tron-board-room | Reviewed (its 8 images = the local `064.TRONBR.*` files) | Panel grammar: `CALENDAR .APP … END .PROGRAM` headers, double outer frame, indexed corner labels (`OS │ 012`), inverted highlight labels, emacs-style inverted status line, build-on motion (frames draw from corners, inner plates expand from center) |
| gmunk.com/TRON-Legacy | Reviewed (text; images lazy-load, mostly film-sequence work) | Context only; little desktop-UI-relevant content beyond the board room |
| darbyfui.com/tronares | Reviewed (text + images; its screenshot and 3 videos = local files) | Ares motion philosophy: “directive, logical, intentional, nothing cute”; fast pop-on beats; command bars with terminated double rules; `[USERNAME]>>` prompts; translucent highlight bands behind text |
| behance.net/gallery/242785533 | Reviewed (10 images; page served HTTP 403 but rendered) | Ares typography system: red-orange on oxblood-black, letter-spaced small caps, dotted rules, square-pixel mosaic texture. Mostly title cards — few UI screens |
| Local videos (4) | Frame-sampled into contact sheets | Legacy terminal session (eshell, split panes, inverted mode line), panel build-on sequence, Ares “SCANNING::ALL FILES” command bar build |

Interpretation, not reproduction: no logos (ENCOM, Dillinger), no fake telemetry, no film text.

## 3. Stack evaluation

| Criterion | **Native (Swift/SwiftUI + AppKit + SwiftTerm)** | Tauri 2 (xterm.js + portable-pty) | Electron (xterm.js + node-pty) |
|---|---|---|---|
| Terminal maturity | SwiftTerm: MIT, actively maintained (release 2026-11-06), xterm-class emulation, true color, mouse modes, bracketed paste, OSC 7/8/133, Kitty keyboard + graphics, Sixel, CoreText or Metal renderer, VoiceOver support | xterm.js is the most battle-tested emulator (VS Code); portable-pty solid | Same xterm.js; node-pty mature |
| Design flexibility | High (SwiftUI shapes, Core Animation); CSS is faster to iterate | Highest (CSS) | Highest (CSS) |
| Files / app launching | Direct: FileManager, NSWorkspace, LaunchServices, QuickLook, icons | Via Rust crates/plugins; icons need extra work | Via Node/native modules |
| Embedded browser | WKWebView: out-of-process, **no bridge exists unless you add one** | Multi-webview still behind `unstable` (2.12.5); IPC capability config required | WebContentsView: good isolation, Chromium-sized |
| Memory / CPU | Lowest | Low-medium | Highest |
| Accessibility | Native AX | Web AX through WKWebView | Chromium AX |
| Toolchain here | Xcode 27.2 + Swift 6.4 present | **Rust not installed** | Node present |
| Maintenance (1 person) | One language, one dependency | Two languages + JS bundle | JS + native module rebuilds per Electron |

**Recommendation: native.** The highest-priority requirements — a reliable terminal and deep, safe
macOS integration (files, LaunchServices, privacy prompts, process control) — are native APIs. The
web-isolation story is strongest by default: WKWebView pages have no path to native code unless we
explicitly register a message handler, which GRID never does for remote content. The cost is slower
visual iteration than CSS and a smaller pool of terminal-emulator users than xterm.js; SwiftTerm’s
activity and feature list make that an acceptable trade.

Rejected: libghostty — embedding header is explicitly internal (“not designed for external use”),
API signatures in flux. Revisit when a stable embedding API ships.

## 4. Architecture

```
GridApp (SwiftUI App, single Window scene, AppDelegate for quit handling)
└─ AppState (@Observable, main actor) ── cross-feature actions (terminal↔files, open URL)
   ├─ Settings          UserDefaults-backed preferences
   ├─ TerminalManager   sessions, 1 Hz kernel polling, hang-up/cleanup
   │   └─ TerminalSession ── GridTerminalView (SwiftTerm LocalProcessTerminalView subclass)
   ├─ FileBrowserModel  listing, history, sort, filter, recursive search, dir watching
   └─ AppCatalog        discovery, favorites, recents, launch
GridCore (no UI; unit tested)
   ShellQuoting · FuzzyMatch · PathResolver · WebAddress · PaletteGrammar
   ProcessInspector (libproc) · ShellEnvironment · FileListing · AppDiscovery
```

Terminal NSViews are owned by their session, not by SwiftUI; a container NSView re-parents them, so
switching tabs or panels never destroys scrollback or restarts a shell.

### Terminal details
- **PTY**: SwiftTerm `LocalProcess` (forkpty). Shell = user’s login shell from the directory
  service → `$SHELL` → `/bin/zsh`, launched as a login shell (`argv[0] = "-zsh"`) so
  `/etc/zprofile` (path_helper) and `~/.zprofile` produce the user’s normal PATH even when GRID is
  launched from Finder.
- **Environment**: inherited environment minus variables identifying *another* terminal or a parent
  Claude Code session (`TERM_PROGRAM`, `ITERM_*`, `CLAUDECODE`, …); sets `TERM=xterm-256color`,
  `COLORTERM=truecolor`, `TERM_PROGRAM=Grid`, a valid UTF-8 `LANG`. User config such as
  `CLAUDE_CODE_USE_BEDROCK` and `SSH_AUTH_SOCK` is preserved.
- **Directory tracking**: GRID reads the shell’s real cwd from the kernel
  (`proc_pidinfo(PROC_PIDVNODEPATHINFO)`) once per second and on demand. No shell config injection
  is required. If the shell emits OSC 7, it only triggers an immediate re-read (OSC 7 from an ssh
  session describes a remote path). Limitations: it reports the *shell’s* directory — a `cd` inside
  a subshell, `ssh`, or a program’s own internal directory is not reflected; Files never follows
  automatically, only through the explicit “Show terminal directory in Files” action.
- **Busy detection**: foreground process group of the PTY (`tcgetpgrp`) ≠ shell PID ⇒ a job is
  running; its name comes from `proc_name`. Drives tab markers, the status bar, close/quit prompts,
  and “DONE” badges when a background tab’s job finishes.
- **Closing / quitting**: SIGHUP to the foreground job’s process group and the shell (what closing a
  real terminal does; zsh forwards it to its jobs), escalating to SIGKILL after 2 s (1.5 s on quit).
  Deliberately detached processes (`nohup`, `setsid`, `disown`) survive, as in Terminal.app. If
  GRID crashes, the kernel closes the PTY master and the session still receives SIGHUP.
- **Drops**: file drops insert shell-quoted paths (`ShellQuoting`: never emits control characters;
  newline → `$'\n'`), through SwiftTerm’s paste path (bracketed when the program enabled it). No
  newline is ever sent; nothing executes until the user presses Return.

### Files
FileManager listing off the main thread; Finder-like numeric-aware sorting; folders first; hidden
toggle; symlinks shown with target and broken-link state; current-folder **filter** vs **recursive
search** are an explicit, labeled mode switch (recursive search is cancellable, debounced, capped at
1,000 results, and reports real scanned / unreadable-skipped counts). A vnode watcher refreshes the
listing when the folder changes. Errors map to distinct states: permission denied (with the
privacy explanation), not found, not a folder, other.

### Apps
Directory scan of `/Applications`, `/System/Applications`, `/System/Library/CoreServices/Applications`,
`~/Applications` (+ Finder), up to 3 folder levels, never descending into bundles, deduplicated by
resolved path, skipping `LSBackgroundOnly` agents. Launch uses `NSWorkspace.openApplication`
(LaunchServices). Favorites and recents store paths plus bundle IDs, so a moved app is followed on
the next scan; missing apps are flagged, never silently launched. Same-name apps get a location hint.
Spotlight (`NSMetadataQuery`) is not used: a deterministic scan works with indexing disabled and
found 163 apps on the development Mac.

### Panes, find, and shortcuts
Each tab's panes form a `SplitTree` (GridCore, unit tested): leaves are pane IDs, splits hold an
axis and size fractions. Splitting joins a same-axis parent instead of nesting; closing a pane gives
its share to a neighbour and collapses or flattens splits. Find uses SwiftTerm's search API
(`findNext`, `findPrevious`, `searchMatchSummary`) behind GRID's own bar. Shortcuts are data
(`KeyBinding`, GridCore), stored as per-command overrides; every menu command reads its binding
from `ShortcutStore`. SwiftUI doesn't re-evaluate `Commands` when @Observable state changes, and
it rebuilds its NSMenu items lazily, so `CommandsRefresher` observes exactly the state the menus
read, republishes it, and asks the menus to refresh. Otherwise titles, enabled states, and new
shortcuts would stay stale until a menu was opened.

### Workspace docking and drag-and-drop
The Terminal workspace is itself a `SplitTree` whose leaves are fixed panel IDs (Files, Terminal,
Deck). `WorkspaceLayout` persists it as JSON (validated and repaired on load) with point-based
minimum sizes per panel.

Re-docking uses **GRID's own drag tracking** (`Shell/DockDrag.swift`), not the system
drag-and-drop:
- **Why:** the system mechanism (`NSDraggingSession` via `.onDrag`/`.onDrop`) didn't reliably tell
  a drop target when the pointer moved on to another target or when a drag was cancelled. That left
  several highlights lit at once and drops unapplied.
- **How:** these drags never leave the window, so sources (panel title bars, pane headers, tabs,
  widget handles) use a plain `DragGesture`. Targets register their window frames. `DockDrag` picks
  the single innermost target that accepts the payload, plus the nearest edge for panels and panes.
  One overlay draws one highlight and a label that follows the pointer. The move is applied on
  mouse-up; Esc cancels.
- **Rules:** which payload may land where, and what a drop does, live in
  `AppState.configureDocking()`.
- **Testing:** the QA hooks drive the same controller with simulated pointer paths.

System drag-and-drop is still used where it belongs: dragging files to Finder, other apps, or the
terminal. Terminal NSViews stay owned by their sessions, so moving a pane only changes where its
host view sits.

### Widget deck
`WidgetStore` keeps an ordered list of `WidgetInstance` (kind, collapsed, expanded, string-map
config) persisted as JSON in UserDefaults, so new options never break saved layouts.
`SystemMonitor` samples CPU (`host_processor_info` tick deltas), memory
(`host_statistics64`: active + wired + compressed), load (`getloadavg`), network (`getifaddrs`
byte counters, 32-bit wrap handled), and power (IOKit power sources) every 2 s. It runs only
while a widget that needs it is on screen (reference-counted). The Git widget runs `/usr/bin/git`
with structured arguments, `-c core.fsmonitor=false`, `--no-optional-locks`, no terminal prompts,
and a 3 s timeout. It first checks that developer tools exist (`xcode-select -p`), so a periodic
refresh can never trigger the "install tools" dialog. Results for a stale folder are discarded.
The File Inspector widget reads `FileFacts` (GridCore) off the main thread, debounced: executable
bit, shebang, `com.apple.quarantine` origin, `kMDItemWhereFroms`, text stats from the first
256 KiB (regular files only, `O_NOFOLLOW|O_NONBLOCK`), image size; folder totals only on request,
cancellable and capped.

Deck arrangement: `DeckRows` (GridCore, tested) keeps cards as an ordered list with a per-card
"beside the previous card" flag, so rows round-trip through the saved deck. Dropping a card on
another card's edge (`DockTarget.widget` uses edges) places it beside (left/right) or on a new row
(top/bottom); `DeckRowLayout` draws each row as equal-width, equal-height cards and wraps them
when cards would get narrower than 190 pt. Drop targets inside the deck's scroll view are clipped
to its visible area (`dockClipToBounds`).

### Widget packages (third-party / your own)
Spec and guardrails: [WIDGETS.md](WIDGETS.md). Pieces:
- `GridCore/WidgetSecurity.swift` — manifest validation, exec templates (denylist by name and stem,
  git hardening, risk tiers, placeholder matching, `sandbox-exec` profile for children),
  `PathRule` (component globs, symlink-resolved, credential roots need explicit naming),
  `NetRule` (https host patterns, private-address refusal, `{secret:key}` expansion), view-tree
  parser with limits, token bucket. `WidgetPackage.swift` — package loading limits, SHA-256 digest,
  plain-language permission text and combination warnings. All unit tested.
- `GridWidgetHost` (separate executable) — JavaScriptCore with JIT off, rlimits, deny-default
  `sandbox_init` before any widget code; JSON lines over stdin/stdout; a JS prelude provides the
  `grid.*` builders and call bridge and diffs trees.
- `Widgets/Platform/` — `WidgetLibrary` (scan, approvals pinned to digest or permissions, install
  by copying validated bytes, Keychain secrets, storage, logs, FSEvents hot reload, scaffold);
  `WidgetRuntime` (one per visible card: process lifecycle, debounced events, refresh scheduling,
  JS-time/CPU/memory budgets with strikes and backoff, the broker that checks every call, click
  actions); `WidgetNodeView` (native renderer); approval overlay and Settings › Widgets.

### Command palette
Application commands only — never sent to a shell. Free text ranks commands, sessions, apps; input
that looks like a path offers Files / new terminal / open; a web address offers “open in default
browser”. A small namespaced grammar: `app …`, `files …`, `term …`, `web …`, `theme …` (an optional
leading `grid` is ignored). Default shortcut ⇧⌘P (⌘K stays “clear scrollback”, as in Terminal.app);
configurable to ⌘K or ⇧⌘Space.

A global `grid` CLI is **deferred**: any IPC channel that lets local processes drive GRID needs an
authentication design (e.g. a per-user socket with peer-credential checks) first.

### Web (embedded browser, Milestone 3)
Engine choice: **WebKit (`WKWebView`)** — part of macOS (no bundle growth, OS-delivered security
updates), the lightest memory/energy profile, Safari-level compatibility. Chromium (CEF) was
rejected (~170 MB, own update burden, C++ glue); Gecko has no embeddable macOS build. The app's
minimum is macOS 15; extensions use WebKit's `WKWebExtension` API and need 15.4.

- `GridCore/BrowserCore.swift` (tested): address/search interpretation, the navigation policy
  (http(s)/blob/about load inside; `file:` and `javascript:` refused; top-level `data:` refused;
  mailto/tel/zoom… only after a click and a GRID confirmation; everything else refused), site keys,
  the site-theme catalog, download-name sanitizing (no path parts, control or bidi characters).
- `Web/BrowserModel.swift`: tabs (a page's web view is created only when the tab is first shown;
  restored tabs load lazily), a dedicated persistent `WKWebsiteDataStore` separate from everything
  else (Settings › Browser › Clear Browsing Data), per-tab `WKUserContentController`. The
  coordinator decides navigations, turns non-renderable responses and `Content-Disposition:
  attachment` into downloads (always confirmed, saved to Downloads with a unique name,
  `com.apple.quarantine` + where-from set), draws page `alert/confirm` as GRID dialogs labelled
  with the page's host (rate-limited), supports file upload via an open panel, and leaves camera
  and microphone to WebKit's prompt. **No script message handlers exist**: pages have no channel
  into GRID.
- `Web/Reader.swift`: Mozilla Readability (vendored, Apache-2.0, `scripts/embed-readability.sh`)
  runs in the `grid.reader` content world on a clone of the document; the article renders in a
  second web view with JavaScript off, a deny-all CSP (images allowed), a sanitizer, an ephemeral
  data store and GRID typography (numbered links via CSS counters).
- `Web/SiteThemes.swift` + `Web/SiteThemeLibrary.swift` + `GridCore/SiteThemePack.swift` (tested):
  per-site CSS packs (`site-themes/packs/*.css`, a header comment naming id, version, hosts and
  paths) that remap each site's own design tokens to GRID's `--grid-*` palette, injected by a user
  script in the `grid.themes` content world as a constructed stylesheet (`adoptedStyleSheets`, not
  blocked by strict `style-src`), toggled live per site and re-coloured when GRID's theme changes.
  Packs come from three places, the user's own winning, then the newer of downloaded and built-in:
  built-in (bundled into `Contents/Resources/SiteThemes` by `scripts/bundle.sh`), downloaded
  (opt-in daily check of `site-themes/index.json` on the repository's master branch; https from
  raw.githubusercontent.com only, no redirects, size caps, SHA-256 from the index, then parsed
  again) and the user's folder (`Application Support/GRID/Browser/SiteThemes/Yours`, regular files
  only). Every pack passes `SiteThemeCSS.violations`: no `@import`, no `url()`/`image()`-style loads
  except inline `data:`, no `expression()`/`-moz-binding`/`behavior`, checked after CSS escapes and
  comments are decoded, so a theme can't load anything or exfiltrate what a page shows. Edit a pack,
  bump its version and run `scripts/site-themes-index.sh`.
- `Web/AdBlocker.swift` + `GridCore/ContentBlocker.swift` (tested, verified against WebKit's
  compiler with the real lists): uBlock Origin's default lists are downloaded at runtime (nothing
  bundled), converted to `WKContentRuleList` JSON (network rules with exceptions/important ordering
  per chunk, cosmetic `css-display-none` groups), compiled once and cached by a digest of the list
  contents. Per-site off removes every list from that tab's next load. Redirects and procedural
  cosmetics have no WebKit equivalent and are skipped (counted in Settings).
- Scriptlets (`GridCore/Scriptlets.swift` + `GridCore/ScriptletLibrary.swift`, tested, including in
  JavaScriptCore): the lists' site-specific `##+js(…)` rules are indexed by domain and entity
  (`!#if` blocks evaluated, exceptions honoured, `trusted-*` only from uBlock's own lists). GRID
  implements ~25 common scriptlets itself (`set-constant`, `json-prune` and its fetch/XHR forms,
  `trusted-replace-fetch/xhr-response`, `no-fetch-if`, `no-xhr-if`, timer boosters and defusers,
  `abort-*`, `remove-node-text`, `remove-attr/class`, …); a list supplies only names and string
  arguments, embedded as JSON. Generic rules and scriptlets whose arguments are code (`rpnt`,
  `trusted-rpnt`, `trusted-edit-inbound-object`) are never run. The script for a host is added as
  a page-world, main-frame, document-start user script just before that host's first navigation in
  the tab, and checks `location.hostname` first; patched functions are Proxies whose `toString`
  still reads as native. Scripts accumulate per tab (WebKit can only remove all user scripts) and
  are rebuilt only when a setting or the lists change.
- `Web/BrowserExtensions.swift` (macOS 15.4+): install from a folder/.zip/.crx after a review of
  the requested permissions and hosts; the approved set is stored and re-granted at each launch
  (later requests are prompted by GRID). Toolbar buttons render as monochrome template glyphs in
  GRID's colours, collapse into an `EXT n` menu past three, and are absent with no extensions.
- UI (`Web/BrowserPanel.swift`): GRID tab strip, address bar (`TLS ▸` / `HTTP ▸` security
  prompt), 1 px progress line (no idle animation), find bar, new-tab page with local history, and
  header toggles for theme / reader / blocking. ⌘T ⌘W ⌘F ⌘[ ⌘] ⌘L and ⇧⌘[ ⇧⌘] act on the browser
  while the Web page is showing; a Browser menu adds Reload, Reader View and zoom.

### Map (page 05)

The authoritative plan is `docs/maps/IMPLEMENTATION.md`.

**GridCore/Maps** is pure Swift and unit-tested:
- `TileMath`/`MapProjection` (Web Mercator, view projection, tile cover).
- `MVTDecoder`, `Earcut`, `LineTessellator`, `OpenMapTilesSchema` and `TileGeometryBuilder`
  (tile-local geometry, uniform-table classes).
- `LabelPlacer` and `TileSource`.
- For cameras: `OSMSurveillance`, `DeFlock` (build, index, tiles), `GeoPolygon` math,
  `RegionCatalog`, `OverpassQuery`, `CameraIndex`, `RegionPackage` (binary, bounds-checked) and
  `FetchPolicy`.

**Grid/Maps** is the app side:
- **Rendering:** `MapRenderer` and `MapShaders` (Metal: grid floor, fills, stencil-masked ancestor
  tiles, analytic line glow, extrusions, SDF overlays) and `MapMetalView` (on-demand drawing,
  paused when hidden or unfocused).
- **Data:** `TileStore` (disk cache, decoding off the main thread, memory LRU), `ALPRStore`
  (catalogue, download plans, DeFlock and Overpass downloads, per-region storage, freshness) and
  `LocationProvider` (one fix per click).
- **Network and storage:** `MapNetwork` and `MapStorage`.
- **Page:** `MapModel` and `MapPanel`.

## 5. Security & privacy
- No telemetry, accounts, network services, or AI features. Settings live in UserDefaults; terminal
  contents are never logged or persisted.
- Remote web content cannot reach terminal/filesystem/app-launch code: the embedded browser has no
  script message handlers or custom schemes, GRID's own page scripts run in isolated content
  worlds, non-web schemes need a click plus confirmation, downloads are confirmed and quarantined,
  and browsing data lives in a separate store.
- Structured APIs everywhere (NSWorkspace, FileManager, libproc); the only strings that ever reach a
  shell are those the user types or explicitly inserts (quoted paths).
- The QA automation hook (`DebugHooks.swift`, `QASocketServer.swift`) can type into a shell, so it
  is layered: compiled out of release builds (`#if DEBUG`); in debug builds only enabled when
  launched with `--qa` (status bar shows “△ QA HOOKS”); transport is a 0600 Unix socket inside the
  per-user 0700 temp directory with a peer-UID check. (An earlier version used distributed
  notifications, which any app in the login session can post; replaced after review.)
- Third-party widgets: no ambient authority (sandboxed JavaScriptCore process, deny-default
  profile); every capability is declared, shown in plain words, approved, and checked by the app;
  approvals of installed packages are pinned to their SHA-256; commands run without a shell under
  `sandbox-exec` (no network, writes, credentials, Keychain or Apple Events by default); secrets
  live in the Keychain and never reach scripts; side effects only on clicks. See WIDGETS.md.
- Opening a file that would *execute* (a native executable, or anything whose default app is a
  terminal, e.g. `.command`) requires confirmation; apps are launched normally.
- Previews only read regular files, with `O_NONBLOCK`, so pipes and devices cannot hang the app.
- Close/quit escalation records exact process identities (PID + start time) at hang-up and only
  SIGKILLs processes that still match, covering every member of the foreground process group
  (even if the group leader already exited) and never a reused PID.
- **Sandboxing**: GRID is not App-Sandboxed — a terminal whose shell can’t reach your files isn’t a
  terminal (Terminal.app, iTerm2 and Ghostty are unsandboxed too). That rules out the Mac App Store.
  macOS privacy (TCC) still applies: the first time something in GRID touches Desktop, Documents,
  Downloads, removable/network volumes, or another app via Apple Events, macOS asks, attributing
  the request to GRID. Full Disk Access is optional and only granted by the user.
- **Distribution**: Developer ID signing + hardened runtime + notarization (see README).
- **Map** (`Maps/`, `GridCore/Maps/`):
  - **Network:** nothing is fetched before the user enables map data.
    - All traffic goes through `MapNetwork`: one ephemeral session (no cookies, no URL cache),
      an identifying User-Agent, https only, and a host allow-list per request.
    - Redirects are followed only within the same host.
    - Byte caps are enforced while the body arrives.
  - **Remote data is untrusted:** tiles, TileJSON, the DeFlock index and tiles, the Geofabrik
    catalogue, Overpass JSON, and region files on disk.
    - It's parsed by total decoders with hard limits, fuzz-tested, and never trapping.
    - Tile URLs come only from validated templates with integer substitution.
  - **Paths:**
    - Only integers, `RegionDescriptor.storageKey`, and a SHA-256 key for the tile source become
      path components.
    - The Maps folder and its parents are checked not to be symlinks; writes are atomic.
  - **Downloads:** each camera download is confirmed with its host, request count and size.
    Overpass requests are serial, with backoff and a daily budget.
  - **Location:** read only on Locate, held in memory, never written, logged or put in a URL.
- **Update checks** (`Updates/`, `GridCore/Updates/`): off until the user agrees; then at most one
  conditional request a day to `api.github.com` (`User-Agent: GRID`, no version, token or IDs),
  scheduled with `NSBackgroundActivityScheduler`. Release data is remote and untrusted: page and
  download links must point at `https://github.com/HackitM/grid/…` or the release is ignored;
  release notes are drawn as plain GRID text (inline Markdown only, no images, links opened only
  on click and only for https). Nothing installs: "Download & Verify" asks first, saves the zip to
  Downloads with quarantine and where-from (like browser downloads), checks it against the
  release's `.sha256` (integrity, not authenticity), unzips it with `ditto` run without a shell,
  checks the result is exactly `GRID.app` with GRID's bundle ID and the expected version, keeps it
  quarantined and reveals it. Self-install (tier 3) waits for Developer ID signing and
  notarization (docs/MAPS-PLAN.md §12).

## 6. Uncertainties that needed testing (and results)
| Question | Result |
|---|---|
| Do full-screen TUIs work (alt screen, cursor keys)? | Yes: vim edited and saved a file; Claude Code’s TUI rendered and responded to arrows |
| Does resize reach programs? | Yes: PTY size follows the window; `trap WINCH` saw the new size |
| Is cwd tracking reliable without shell integration? | Yes for the shell itself (kernel-reported) |
| Can a hostile filename execute on drop? | No: newline/quotes became one inert `$'…'` word |
| Does quitting leave orphans? | See docs/TESTING.md |
| Offscreen screenshots of SwiftTerm | Not possible (it renders from a per-frame snapshot pipeline); QA reads the screen buffer instead |
