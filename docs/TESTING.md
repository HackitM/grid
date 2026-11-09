# Testing

## Automated
```bash
swift test          # 42 unit tests (GridCore): quoting (incl. real zsh round-trip), ranking,
                    # paths, URL validation, palette grammar, env, listing, perms, symlinks,
                    # app discovery, libproc cwd tracking
```

## Workflow QA (DEBUG build)
`scripts/bundle.sh debug` builds a DEBUG app with QA hooks (compiled out of release builds), and
`open build/GRID.app --args --qa` enables them for that launch only (status bar: “△ QA HOOKS”).
Build the controller with `swiftc -O -o build/gridctl scripts/qa/gridctl.swift`, then
`source scripts/qa/run.sh` for `g`, `gtype`, `gstate`, `gscreen`, `gsnap` helpers. They talk to the
app over a private Unix socket (`$DARWIN_USER_TEMP_DIR/grid-qa.sock`, 0600, same-user only) and read
back real state (kernel cwd, foreground process, PTY size, terminal screen buffer, process tree).
`gsnap` captures the composited window. For automated quit tests, temporarily set
`defaults write local.grid.workspace term.confirmBusy -bool false` (and delete the key after).

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
| Review fixes (2026-11-08, Fable review) | ✅ | QA socket absent without `--qa`, 0600 + same-user with it, removed on quit; confirmations can't overwrite each other; 13 FIFO selections then `/usr/bin` still lists; `.command` and Mach-O ask before running (script did not run); pipeline with dead group leader + HUP-ignoring member killed on close; quit leaves no orphans; release binary has 0 QA symbols/strings |
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
- [ ] Drag widget cards to reorder; drag panel dividers; double-click a divider to reset
- [ ] Drag several selected files into the terminal (all paths inserted, quoted)
- [ ] Space opens Quick Look on the selection; Open With submenu lists apps
- [ ] Double-click a terminal tab to rename it
