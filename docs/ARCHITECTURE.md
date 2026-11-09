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

### Command palette
Application commands only — never sent to a shell. Free text ranks commands, sessions, apps; input
that looks like a path offers Files / new terminal / open; a web address offers “open in default
browser”. A small namespaced grammar: `app …`, `files …`, `term …`, `web …`, `theme …` (an optional
leading `grid` is ignored). Default shortcut ⇧⌘P (⌘K stays “clear scrollback”, as in Terminal.app);
configurable to ⌘K or ⇧⌘Space.

A global `grid` CLI is **deferred**: any IPC channel that lets local processes drive GRID needs an
authentication design (e.g. a per-user socket with peer-credential checks) first.

### Web (Milestone 3 — research summary)
- M1 ships **external open only**: http(s) addresses go to the default browser; other schemes are
  refused.
- **Text/reader mode (planned)**: load the page in a non-persistent, JavaScript-enabled WKWebView
  that is never shown, run Mozilla Readability (Apache-2.0) in an isolated `WKContentWorld`, take the
  extracted article HTML, sanitize it (SwiftSoup, MIT), and render it natively in a monospaced
  layout with numbered links. Chosen over wrapping w3m/lynx (no JS, licensing/packaging friction)
  and browsh/carbonyl (headless Firefox / stale Chromium). Limitations to state in the UI: no forms,
  logins, media, or web apps — “Open in browser” always available.
- **Embedded browsing (evaluate after reader mode)**: WKWebView with a non-persistent or dedicated
  data store, no `WKScriptMessageHandler` and no `userContentController` bridges for remote content,
  navigation policy restricted to http(s), downloads require confirmation, themed chrome only
  (tabs, address bar, progress) — page styles are never globally overridden.

## 5. Security & privacy
- No telemetry, accounts, network services, or AI features. Settings live in UserDefaults; terminal
  contents are never logged or persisted.
- Remote web content cannot reach terminal/filesystem/app-launch code (no bridge exists).
- Structured APIs everywhere (NSWorkspace, FileManager, libproc); the only strings that ever reach a
  shell are those the user types or explicitly inserts (quoted paths).
- The QA automation hook (`DebugHooks.swift`, `QASocketServer.swift`) can type into a shell, so it
  is layered: compiled out of release builds (`#if DEBUG`); in debug builds only enabled when
  launched with `--qa` (status bar shows “△ QA HOOKS”); transport is a 0600 Unix socket inside the
  per-user 0700 temp directory with a peer-UID check. (An earlier version used distributed
  notifications, which any app in the login session can post; replaced after review.)
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

## 6. Uncertainties that needed testing (and results)
| Question | Result |
|---|---|
| Do full-screen TUIs work (alt screen, cursor keys)? | Yes: vim edited and saved a file; Claude Code’s TUI rendered and responded to arrows |
| Does resize reach programs? | Yes: PTY size follows the window; `trap WINCH` saw the new size |
| Is cwd tracking reliable without shell integration? | Yes for the shell itself (kernel-reported) |
| Can a hostile filename execute on drop? | No: newline/quotes became one inert `$'…'` word |
| Does quitting leave orphans? | See docs/TESTING.md |
| Offscreen screenshots of SwiftTerm | Not possible (it renders from a per-frame snapshot pipeline); QA reads the screen buffer instead |
