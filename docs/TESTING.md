# Testing

## Automated
```bash
swift test          # 114 unit tests (GridCore): quoting (incl. real zsh round-trip), ranking,
                    # paths, URL validation, palette grammar, env, listing, perms, symlinks,
                    # app discovery, libproc cwd tracking, widget manifests/permissions/exec
                    # matching/path & net rules/view trees/packages, file facts
.build/debug/GridWidgetHost --selftest   # proves the widget sandbox blocks files, network, spawn
```

## Workflow QA (DEBUG build)
`scripts/bundle.sh qa` builds a DEBUG app as `build/GRID-QA.app` with its own bundle ID and
preferences (so it runs beside your everyday GRID), and `open -g build/GRID-QA.app --args --qa`
enables the QA hooks for that launch only (status bar: “△ QA HOOKS”). Release builds have no hooks.
Build the controller with `swiftc -O -o build/gridctl scripts/qa/gridctl.swift`, then
`source scripts/qa/run.sh` for `g`, `gtype`, `gstate`, `gscreen`, `gsnap` helpers. They talk to the
app over a private Unix socket (`$DARWIN_USER_TEMP_DIR/grid-qa.sock`, 0600, same-user only) and read
back real state (kernel cwd, foreground process, PTY size, terminal screen buffer, process tree).
`gsnap` captures the composited window. For automated quit tests, temporarily set
`defaults write local.grid.workspace term.confirmBusy -bool false` (and delete the key after).

Note: synthesized key events (`keyEquiv`) don't carry Shift the way real keyboard events do (plain
AppKit shows the same: ⇧⌘D never matches, ⌘D matches a ⇧⌘D item), so test ⇧ shortcuts by hand.

Note: SwiftTerm cannot be rendered offscreen, and macOS stops redrawing while the screen is locked,
so QA verifies terminal content through the screen buffer and uses real window captures when the
display is awake.

## Results (2026-11-08, macOS 27.2, Apple Silicon)

| Workflow | Result | Evidence |
|---|---|---|
| Interactive program (vim, alt screen) | ✅ | fg=`vim`; inserted text, `:wq` saved file; back to shell |
| Claude Code | ✅ | `claude --version` 2.1.319; TUI trust screen rendered; ↑/↓ moved selection; redraw on resize; exited cleanly (folder not trusted) |
| Clean environment | ✅ | `TERM=xterm-256color COLORTERM=truecolor TERM_PROGRAM=Grid`, parent `CLAUDECODE` not leaked |
| Ctrl-C / Ctrl-D | ✅ | `sleep 100` interrupted; `cat` ended by EOF |
| Resize during use | ✅ | `stty size` 42×101 → 30×66 → 46×128; `trap WINCH` fired with new size |
| ANSI / truecolor / Unicode | ✅ | real capture: 8 colors unaltered, 24-bit, bold, inverse, é, 日本語, ✓, 🚀 |
| Dir with spaces + Unicode | ✅ | `Dir With Spaces ✦ 日本`: listed, terminal opened there, `pwd` correct |
| terminal → Files sync | ✅ | after `cd "sub folder"`, “Show terminal directory in Files” landed there (kernel cwd) |
| Path drop safety | ✅ | `it's; rm -rf ~⏎whoami` inserted as `$'…\n…'`, nothing executed |
| Open file in default app | ✅ | `.txt` opened in TextEdit via LaunchServices |
| Missing file | ✅ | notice “no longer exists”, listing refreshed |
| Permission-denied folder | ✅ | ACCESS.DENIED state with explanation + actions |
| Launch installed app | ✅ | Calculator launched via `NSWorkspace.openApplication`; added to Recents |
| App discovery | ✅ | 163 apps; Finder, Terminal found; no duplicate paths |
| Quit without orphans | ✅ | fg job, vim, bg job, bg subshell, `yes \| cat` pipeline all gone after quit; `nohup` job intentionally survives (as in Terminal.app) |
| Quit confirmation (busy) | ✅ | in-app QUIT.ACTIVE confirmation; cleanup ran after confirm |
| TCC behaviour | ✅ (expected) | first access to `~/Desktop` from a shell or Files prompts “GRID would like to access…”; work waits off the main thread, UI stays responsive |
| Review fixes (2026-11-08, code review) | ✅ | QA socket absent without `--qa`, 0600 + same-user with it, removed on quit; confirmations can't overwrite each other; 13 FIFO selections then `/usr/bin` still lists; `.command` and Mach-O ask before running (script did not run); pipeline with dead group leader + HUP-ignoring member killed on close; quit leaves no orphans; release binary has 0 QA symbols/strings |
| Palette scroll lag (fix) | ✅ | shadow moved off the scrolling layer; results computed per query; terminal poll no longer re-assigns unchanged values (it re-rendered every observer once a second) |
| Grid backdrop (fix) | ✅ | visible inside panel bodies (minor + major lines), off by default |
| Split panes | ✅ | 3 panes created, focused-pane marker, closing focused pane refocuses neighbour; new pane opens in focused pane's cwd |
| File operations (on disk) | ✅ | new folder → inline rename (invalid name rejected); ⌘/⇧ multi-select (2, then 5); Keep Both → `a 2.txt` with original intact; Replace moves the existing item to Trash; undo restores copies, replacements, and trashed items; copy-into-itself refused; duplicate → `b 2.txt` |
| Widget deck | ✅ | 7 widgets added/expanded/configured; CPU, memory, and load measured; network rates live; time zones with offsets; Git shows branch + counts in a repo and "Not a git repository" elsewhere |
| Git widget race (found + fixed) | ✅ | a slower refresh for the previous folder overwrote the current one; now dropped; rapid `cd repo → /tmp → repo → /tmp` settles correctly |
| Bell indicator | ✅ | BEL from an unfocused pane sets the pane/tab BELL tag |
| Heavy output | ✅ | `seq 1 2000000` completed in 4.3 s, UI responsive |
| Quit with split panes | ✅ | jobs in multiple panes incl. a HUP-ignoring pipeline member: no orphans |
| Contrast | ✅ | textMute ≥ 4.6:1 on bg2 in all themes (was 3.0–3.5) |
| Release bundle | ✅ | icon + SwiftTerm license in Resources; 0 QA strings |
| Split tree | ✅ | split right then down → `H[1 \| V[2 / 3]]`; divider drags clamp; PTY sizes follow (56×41, 46×19); closing collapses to `H[1 \| 2]` |
| Find in terminal | ✅ | 120 plain matches with next stepping; case-sensitive 1 vs insensitive 2; regex `line 1[0-9]{2} ` = 21; invalid regex flagged; close clears |
| Shortcut validation | ✅ | ⌃C refused (terminal), ⌘T refused (in use by New Tab), ⌘K refused (Clear Scrollback) |
| Menu staleness (found + fixed) | ✅ | menu titles/shortcuts didn't update ("Show Files Sidebar" stuck; rebinding ignored until a menu opened); now refreshed on change: after rebinding Split Right to ⌥⌘E, ⌥⌘E splits and ⌘D no longer does |
| Workspace docking | ✅ | default `H[files \| terminal]`; show deck; deck→left of files; files→bottom of terminal; close terminal (notice says sessions keep running); reopen; close all → empty state; rebuild; layout identical after relaunch |
| Narrow docks (found + fixed) | ✅ | docking beside a small panel left both at 9%; now every panel keeps ≥ 20% (`balanced`) |
| Docking review fixes | ✅ | balance recursion removed (re-balance once per change; `balanced` made idempotent, 5,000-case test + the exact oscillating input); per-kind private drag types (foreign text/files never match; payload read from the drop, round trip verified for panel/pane/tab, not exposed as plain text); full-width tab-bar drop zone; 6-pane cap on drops; "done" badge respects a closed terminal panel; hover cursors can't get stuck; 120 rapid re-docks stable |
| Dynamic layout fixes | ✅ | stuck "DOCK" highlight: drag sessions now end themselves (mouse-state watcher runs inside AppKit's drag loop), highlights clear whenever the drag ends; drops resolve the payload synchronously when the private type matches; panels have point minimums (terminal ≥ 360 pt), docking shares by weight (terminal 3 : 1 : 1), squeezed v1 layouts repaired on load (seeded `[0.55, 0.17, 0.28]` → `[0.33, 0.50, 0.17]`); narrow title bars collapse to title + ⋯ instead of vanishing |
| Animations | ✅ | frame captures at 50–140 ms show the build-on trace + accent flash on panels and palette; page switches no longer double-expose |
| Widget host sandbox | ✅ | `GridWidgetHost --selftest`: reading /etc/hosts and ~/.zshrc, writing tmp, network connect and process spawn all denied; JS engine exposes no `setTimeout`/`fetch`/`require`/XHR/`process` |
| Widget guardrails (hostile test widget) | ✅ | undeclared fs/exec/net/selection/cwd calls → `PermissionError`; `~/.ssh/id_rsa` and `~/.zsh_history` refused even under an approved `~/**`; exec with a spoofed `{cwd}` or a leading `-` refused; clicks on insertPath/openURL without permission blocked and logged; log flood capped at 40 lines |
| Widget budgets | ✅ | `while(true)` in an action → suspended after 2 s, restarted after 5 s backoff; memory hog → suspended (app limit 150 MB, host self-limit 200 MB) |
| Widget exec sandbox | ✅ | git status works; writes outside its temp folder, reading ~/.ssh, network and Keychain access fail; setuid `ps` runs (read-only allowlist), other setuid programs refused |
| Widget lifecycle / efficiency | ✅ | 8 example hosts ≈ 123 MB RSS total, ~0% CPU idle; hide deck → all hosts gone after 30 s; quick re-show reuses them; removing a card kills its host at once |
| Widget actions | ✅ | custom actions + storage counter, copy, native `grid.confirm` dialog naming the widget, approval re-required after a Dev widget's exec template changed |
| Example widgets | ✅ | pomodoro, git status, top (ps + system stats), inspector, disk usage, brew services, Hacker News (live), GitHub PRs (no-token state) all render; found + fixed: ICU locale data must be warmed before the sandbox, setuid `ps` under sandbox-exec, `du -s` with `-d`, readouts wrapping in rows, hosts orphaned when the deck was hidden |
| Widget security review fixes | ✅ | Security review (16 findings) fixed and re-tested live: userInitiated exec refused from render and limited to one per click; `kill` of GRID's pid refused; `~/.zshrc` / `~/Library/Preferences` refused under `~/**`; file icons only for readable paths; openFile always confirms; git can't run a repo's `diff.external` (direct or via shell) under the exec sandbox; SIGPIPE-safe host pipe; wall-clock and in-flight call limits |
| Browser | ✅ | pages load lazily (restored tabs stay unloaded until the Web page shows); TLS/HTTP prompt; navigation policy unit-tested; page snapshots via WebKit (works with the window in the background) |
| Site themes | ✅ | HN, MDN, Wikipedia, Stack Overflow themed via `adoptedStyleSheets` (CSP-safe); live toggle on/off; switching GRID to Ares recolours open pages; GitHub (Primer tokens) themed too |
| Reader view | ✅ | Wikipedia article extracted (live page untouched), rendered GRID-style with JS off + deny-all CSP |
| Ad blocking | ✅ | 8 lists → ~129k rules in 5 WebKit lists (~8 s first run, cached by digest after); MDN's ad endpoint blocked, loads with "off for this site", blocked again when back on; blocked top-level address shows WEB.BLOCKED with "Allow This Site" (found + fixed: it targeted the previous page) |
| Extensions | ✅ | test extension (colourful icon, popup, badge, content script): GRID install review; icon drawn as a monochrome glyph with an accent badge; content script runs; popup opens as a popover; approvals persist across relaunch (found + fixed: WebKit keeps grants in memory only; restored tabs were created before the extension controller) |
| Browser security review fixes | ✅ | independent review (8 confirmed): a 300-char download "extension" used to crash GRID before the prompt — now prompts and saves a 200-char name; extensions containing symlinks/special files are refused (tested with a link to ~/.ssh) and re-checked at launch; reader HTML sanitized in the DOM with an allowlist and only GRID's own load may navigate the reader view; external-app prompts only after a real click/keypress; nested regex counts can't blow up the converter (unit test); extension tabs.create policy-checked; crash-reload loop capped; page dialogs always name their origin |
| Deck rows (side by side) | ✅ | real drags through the controller: card → right edge of another = beside, → top edge = new row above; deck docked at the bottom + Place All Side by Side = one row of 5 equal-height cards; docked at the side the same rows wrap to one card per line; drop highlight clipped to the deck's visible area; found + fixed: measuring cards at a made-up width in the row layout's ideal-size pass caused an endless AppKit layout loop |
| File Inspector widget | ✅ | quoted insertion preview, text stats (lines/encoding/line endings), mode, default app, xattrs, preview in expanded mode, actions |
| GRID drag tracking (replaces system DnD) | ✅ | real controller driven by simulated pointer paths: targets register true frames (panels, panes, tab, tab bar, widget cards, list end); deck→bottom of files, files→right of terminal, self-drop ignored, cancel leaves no state; pane→pane edge, pane→tab bar (new tab), tab reorder, pane→into tab, widget reorder; mid-drag capture shows exactly one highlight + pointer label |
| Folder tree | ✅ | expand to depth 3 with indentation guides; inline error row for unreadable folders; packages not expandable; → ← ⌥→; expansion restored on back; filter shows nested match with ancestors; nested rename/duplicate stay in their folder; watcher picks up changes in expanded folders |
| Pane moves | ✅ | `H[1 \| 2 \| 3]` → 3 to bottom of 1 → `H[V[1 / 3] \| 2]` → 2 to left of 1 → `V[H[2 \| 1] / 3]` |
| Remote web content → privileged functions | n/a | no embedded web content in M1 (external browser only); non-http(s) schemes refused (unit tested) |

## Manual checklist (needs a person at the keyboard)
- [ ] Focus ring: click between Files sidebar and terminal — brackets move; terminal cursor goes hollow when unfocused
- [ ] Drag a file from Finder and from the Files list into the terminal
- [ ] ⇧⌘P palette: `app safari`, `files ~/Downloads`, `term /tmp`, `web example.com`, `theme ares`
- [ ] ⌘W on a tab running `sleep 100` → PROCESS.ACTIVE confirmation
- [ ] VoiceOver: rail items, tabs, file rows and app rows announce name + selected state
- [ ] System Settings › Accessibility › Reduce Motion → transitions stop
- [ ] Copy/paste and mouse selection in the terminal; `htop`/`less` mouse scrolling
- [ ] Scroll the command palette quickly (lag fix)
- [ ] Browser: sign in to a site, download a file (confirm, quarantine, Reveal), upload a file,
      camera prompt on a video-call site, extension popup interaction
- [ ] Widgets: New Widget… → edit widget.js in an editor → card reloads on save; Install… an example
      folder → approval screen → card runs; set the GitHub PRs token (Keychain) and see PRs
- [ ] File Inspector: drag its icon into the terminal → quoted path inserted, nothing runs
- [ ] Drag widget cards to reorder; drag panel dividers; double-click a divider to reset
- [ ] Drag several selected files into the terminal (all paths inserted, quoted)
- [ ] Space opens Quick Look on the selection; Open With submenu lists apps
- [ ] Double-click a terminal tab to rename it
- [ ] Settings › Keyboard: record a new shortcut, try a conflicting one, reset
- [ ] ⌘F in a pane, then ⏎ / ⇧⏎ / ⌘G / ⇧⌘G; drag a pane divider; ⇧⌘D works with the real keyboard
- [ ] Drag a panel title bar onto each edge of another panel (highlight shows the target half)
- [ ] Drag a pane header onto another pane, onto a tab, and onto empty tab-bar space; drag a tab to reorder
- [ ] Close each panel with ×; reopen with ⌘B / ⌥⌘0 / ⌘J
- [ ] Files: click a folder's ▸ (expands in place, no navigation); ⌥-click; ⇧-click a range across levels; drag a nested file into the terminal
- [ ] Cancel a panel drag with Esc / release outside the window: no highlight remains
- [ ] Narrow the terminal panel: header collapses to `01 TERMINAL ⋯ ×` with a working menu
- [ ] Switch pages, open the palette, open a folder: build-on / cascade feel quick, not in the way
- [ ] Settings › Effects › Motion off (and macOS Reduce Motion): all animation stops
