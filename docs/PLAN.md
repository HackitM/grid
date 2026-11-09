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

## Milestone 2 — Daily-use polish (next)
- [ ] Split panes (⌘D / ⇧⌘D) inside a terminal tab
- [ ] File operations: new folder, rename, copy/move with conflict dialog, Move to Trash (never
      permanent delete by default), undo where possible
- [ ] Multi-select in Files (⇧/⌘ click, ⇧↑↓), drag multiple paths
- [ ] Quick Look panel (Space) and “Open With…” submenu
- [ ] Persist layout: sidebar/inspector visibility, widths (draggable dividers), last folder,
      window frame; optionally restore session directories (not processes)
- [ ] Terminal find bar styling; per-session title overrides; bell indicator
- [ ] Keyboard shortcut customization beyond the palette key
- [ ] App icon; release script copying SwiftTerm LICENSE into the bundle
- [ ] Accessibility pass with VoiceOver; contrast check for textMute on all themes
- [ ] Performance: profile large folders (10k+ entries) and heavy terminal output
- [ ] Optional OSC 7 / OSC 133 shell integration file (opt-in, documented) for prompt marks

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
