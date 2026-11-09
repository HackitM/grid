# Testing

## Automated
```bash
swift test          # 33 unit tests (GridCore): quoting (incl. real zsh round-trip), ranking,
                    # paths, URL validation, palette grammar, env, listing, perms, symlinks,
                    # app discovery, libproc cwd tracking
```

## Workflow QA (DEBUG build)
`scripts/bundle.sh debug` builds a DEBUG app with `DebugHooks` (compiled out of release builds).
`source scripts/qa/run.sh` then gives `g`, `gtype`, `gstate`, `gscreen`, `gsnap` helpers that drive
the running app via distributed notifications and read back real state (kernel cwd, foreground
process, PTY size, terminal screen buffer, process tree). `gsnap` captures the composited window.

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
| Remote web content → privileged functions | n/a | no embedded web content in M1 (external browser only); non-http(s) schemes refused (unit tested) |

## Manual checklist (needs a person at the keyboard)
- [ ] Focus ring: click between Files sidebar and terminal — brackets move; terminal cursor goes hollow when unfocused
- [ ] Drag a file from Finder and from the Files list into the terminal
- [ ] ⇧⌘P palette: `app safari`, `files ~/Downloads`, `term /tmp`, `web example.com`, `theme ares`
- [ ] ⌘W on a tab running `sleep 100` → PROCESS.ACTIVE confirmation
- [ ] VoiceOver: rail items, tabs, file rows and app rows announce name + selected state
- [ ] System Settings › Accessibility › Reduce Motion → transitions stop
- [ ] Copy/paste and mouse selection in the terminal; `htop`/`less` mouse scrolling
