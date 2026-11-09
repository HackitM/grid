# Staged Implementation Checklist

## Milestone 0 — Research & specification ✅
- [x] Repository inspection (empty apart from reference media)
- [x] Visual references: 4 web portfolios + local stills + frame-sampled videos
- [x] GitHub research (terminal components, workspaces, launchers, readers, palettes) → LICENSES.md
- [x] Stack comparison and recommendation (native) → ARCHITECTURE.md
- [x] Design tokens, panel grammar, motion rules → DESIGN.md

## Milestone 1 — Vertical slice ✅
- [x] SwiftPM project, `.app` bundling script, ad-hoc signing
- [x] Themed shell: top bar, nav rail, panels, status bar with real data only
- [x] Real PTY terminal (SwiftTerm): login shell, clean env, tabs, focus indication, exit state
- [x] Busy detection, close/quit confirmation, SIGHUP→SIGKILL cleanup
- [x] Kernel-based cwd tracking; “Open terminal here” / “Show terminal directory in Files”
- [x] Safe quoted path insertion on drop
- [x] File browser: breadcrumbs, editable path, back/forward/up, hidden toggle, 4-way sort,
      filter vs recursive search, open, reveal, copy path, inspector + preview, error states,
      live refresh on change
- [x] App launcher: discovery, search, icons, pins, recents, duplicate hints, moved/missing apps
- [x] Command palette with namespaced grammar
- [x] Settings: theme (3), effects, terminal font/size/meta/scrollback/shell, palette shortcut
- [x] Web: external open only, scheme-validated
- [x] 36 unit tests + workflow QA (docs/TESTING.md)
- [x] Code review fixes: locked-down QA hook, ⌘W never quits, single-confirmation guard,
      regular-file-only previews, identity-checked kill escalation, run confirmation for executables

## Milestone 2 — Daily-use polish ✅ (mostly)
- [x] Fixes: command-palette scroll lag (shadow off the scrolling layer, results cached, no
      per-second re-renders from terminal polling); grid backdrop drawn inside panels
- [x] Split panes (⌘D / ⇧⌘D, ⌥⌘←/→), up to 4 per tab, one axis per tab
- [x] File operations: new folder, rename, duplicate, copy/move with Replace/Keep Both/Skip,
      Move to Trash, Delete Immediately (confirmed), multi-step undo (incl. restoring replaced items)
- [x] Multi-select (⌘/⇧ click, ⇧↑↓, ⌘A), multi-path drag into the terminal, drop into Files
- [x] Quick Look (Space) and Open With
- [x] Persist layout: sidebar/inspector/deck visibility, draggable widths, last folder
      (window frame is restored by macOS)
- [x] Tab rename (double-click); bell indicator
- [x] App icon; SwiftTerm license shipped in the bundle
- [x] Contrast: textMute raised to ≥ 4.6:1 (WCAG AA) on all themes
- [x] Performance: cached file listing; 2M-line output in ~4 s
- [x] Themed terminal find bar: case / regex / whole-word options, live match count, ⌘G / ⇧⌘G
- [x] Customizable keyboard shortcuts for every command (recorder in Settings, with validation)
- [x] Split tree: split right or down anywhere, up to 6 panes per tab
- [x] Draggable pane dividers (double-click to even out)
- [x] Fix: menu titles, enabled states, and shortcuts went stale (SwiftUI didn't re-evaluate
      Commands); now refreshed on every relevant state change
- [ ] VoiceOver walkthrough (needs a person; skipped by request)
- [ ] Optional OSC 7 / OSC 133 shell integration file (opt-in, documented) for prompt marks

## Workspace docking ✅
- [x] Close buttons on Files / Terminal / Deck title bars and on each pane; closing Terminal keeps sessions
- [x] Drag panel title bars onto another panel's edge (tree-based layout, persisted, resizable, reset)
- [x] Drag panes onto pane edges, onto tabs (move into tab), onto the tab bar (new tab); drag tabs to reorder
- [x] SplitTree `inserting` / `moving` / `balanced` / Codable (GridCore, 27 new tests)

## Docking rewrite and folder tree ✅
- [x] GRID's own drag tracking replaces system drag-and-drop for panels, panes, tabs, widget cards
      (one target and one highlight at a time, pointer label, Esc cancels, testable end to end)
- [x] Expandable folder tree in Files: disclosure triangles, indented levels with guides,
      async children with loading/error rows, keyboard → ← ⌥→, ancestor-preserving filter, nested
      selection and file operations
- [ ] Persist folder expansion across launches

## Layout fixes and motion ✅
- [x] Dynamic layout fixes: drag sessions always end, drops apply reliably, point-based
      panel minimums, terminal-dominant docking, repaired v1 layouts, collapsing title bars
- [x] Motion from the reference films: panel build-on + accent flash, row cascades, Ares text bands,
      sliding selectors, scan-band drop targets, popping tags, rolling numbers

## Widget deck ✅
- [x] Deck panel (⌘J) with drag-reorder, settings face, expand/collapse, remove, gallery, persistence
- [x] Clock, System, Network, Storage, Power, Sessions, Pinned Apps, Git, Notes, Recent Files
- [x] File Inspector widget (quoted insertion preview, exec/quarantine warnings, text/image facts)
- [x] Widget packages: manifest + JS in a sandboxed JavaScriptCore helper, approval with risk
      tiers, digest pinning, Keychain secrets, sandboxed exec, budgets/strikes, hot-reloading Dev
      widgets, Install…, Settings › Widgets with logs, 9 examples (docs/WIDGETS.md)
- [ ] Ideas: calendar (EventKit needs a permission prompt), weather (network — out of scope
      unless requested), per-widget accent, a full-screen deck panel

## Milestone 3 — Web
- [ ] Reader prototype: hidden non-persistent WKWebView + Readability in isolated content world →
      sanitized HTML → native monospaced renderer with numbered links (`f 12` to follow)
- [ ] Clear “READER VIEW — simplified” labelling; “Open in browser” always available
- [ ] Decide on embedded browsing against real needs; if built: no script bridges, http(s)-only
      navigation policy, separate data store, download confirmation, themed chrome only
- [ ] Test: page JavaScript cannot reach any GRID function

## Later / needs a design decision first
- [ ] System-wide launcher hotkey (Carbon `RegisterEventHotKey` needs no extra permission;
      event taps would need Accessibility/Input Monitoring — avoided)
- [ ] `grid` CLI (requires an authenticated local IPC design)
