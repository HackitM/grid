# GRID — Visual Design Specification

Source of truth for tokens: `Sources/Grid/Theme/Theme.swift`. Components: `Theme/Components.swift`.

## Principles
1. **Instrument, not prop.** Every number on screen is measured (cwd, PTY size, item counts, scan
   counts, exit codes). Nothing decorative pretends to be data.
2. **Accent is a signal.** Accent color marks focus, selection, the active tab/panel, and running
   state. Resting UI is hairlines and grey-cyan text.
3. **Shape before color.** Every state also has a non-color cue: focused panel = corner brackets;
   selected row = 2px left bar; running = ◆ glyph + program name; toggles = filled square + ON/OFF;
   errors = ✕ / warnings = △ + code label.
4. **Program output is sacred.** Terminal ANSI colors are one shared palette across themes; GRID
   never recolors output.
5. **Effects are optional.** Glow, motion and the grid backdrop each toggle independently; motion
   is forced off by macOS Reduce Motion. The UI is complete with all effects off.

## Color tokens

| Token | Legacy (default) | Ares | Amber | Use |
|---|---|---|---|---|
| bg0 | `#030608` | `#070404` | `#060504` | window, rail, status bar |
| bg1 | `#070C0F` | `#0D0807` | `#0C0A07` | panel body |
| bg2 | `#0C1418` | `#170D0B` | `#15110B` | header strips, hover, buttons |
| bg3 | `#050A0C` | `#0A0605` | `#090705` | inset fields, previews |
| text | `#DDF4F8` | `#F6E6E1` | `#F5EBDA` | primary content |
| textDim | `#8DB0B9` | `#BE958B` | `#BBA27C` | metadata |
| textMute | `#65858F` | `#9D746A` | `#917C5C` | labels, metadata (≥ 4.6:1 on bg2, WCAG AA) |
| accent | `#6FE3F5` | `#FF4A2B` | `#FFB547` | focus / selection / active |
| accentSoft | accent @ 13% | @ 15% | @ 14% | selected row fill |
| line | accent @ 18% | @ 20% | @ 18% | resting hairline |
| lineStrong | accent @ 75% | @ 85% | @ 80% | focused hairline |
| glow | `#2CCBEA` | `#FF2C10` | `#FF9A1A` | bloom on focused edges only |
| ok / warn / danger | `#7CF0C0` / `#FFC56B` / `#FF6B57` | … / … / `#FFFFFF`* | … | semantic, always with a glyph |

\* In Ares the accent *is* red, so danger is white + ✕ to stay distinguishable.

Terminal: background `#060B0E` (Legacy), foreground `#D6ECF1`, cursor = accent tint, selection =
accent @ 28%. ANSI 16 (all themes): `1A2226 F0605A 5FD99A E8C86A 5AA8F0 D487E8 5ED6E0 C9D3D6 /
56656B FF8A80 8DF0BC FFE08E 8CC6FF EDB0FF 9AF1F7 F4F8F9`.

## Typography
| Role | Spec |
|---|---|
| Section label | SF Mono 9.5 semibold, UPPERCASE, tracking 1.4, textMute (accent when active) |
| Body / lists / paths | SF Mono 12 regular |
| Small / metadata | SF Mono 10.5 |
| Title (state blocks) | SF Mono 15 medium |
| App names | SF Pro 12.5 (proportional reads better for product names) |
| Terminal | user-selectable fixed-pitch family, default SF Mono 13 |

Uppercase is for labels only — never for file names, terminal output, or prose.

## Geometry
- Hairline 1pt. Gutters 8pt. Header strip 24pt. Row 22pt (apps 28pt). Rail 58pt. Status 24pt.
- **Panel**: `ClippedRect` plate (9pt diagonal cut, top-right) · header strip
  `NN TITLE .SUFFIX ……… trailing controls` · hairline divider · body.
- **Focused panel**: lineStrong border + optional 5pt glow + 2pt corner brackets (TL, BL, BR).
- **Palette / confirmations**: clipped top-right *and* bottom-left (12pt / 10pt).
- **Terminated rule**: hairline with 3pt square ends (Ares command-bar motif) for section headers.
- No rounded cards, no pills. Circles only where meaningful (none in M1).

## Components
`Panel` · `SectionLabel` · `Tag` (inverted accent block, Legacy “ENCOM CORP” motif) · `KeyCap` ·
`GridButtonStyle` (rect, hairline, prominent = solid accent) · `IconButton` (22×20, tooltip +
AX label mandatory) · `GridField` (inset, border lights on focus, optional prompt glyph) ·
`GridToggleStyle` ([■] ON / [ ] OFF) · `StateBlock` (empty / warning / error, glyph + code + title +
message + actions; used for permission, missing, empty, and no-match states) ·
`gridRowBackground` · `TerminatedRule` · `GridBackdrop`.

## Motion
Taken from the reference films (`Theme/Motion.swift`). All motion is short, never delays input,
and is skipped when Motion is off or macOS Reduce Motion is on.

| Event | Motion (reference) | Duration |
|---|---|---|
| Window opens | **Startup build-on** (Legacy board room): the window frame traces from the top-left corner, the bar rules and rail divider extend, a scan line passes down the window, the bars fade in and the panels build on | ≤ 800 ms, skippable in Settings › Effects |
| Menu opens / closes | **Unfold**: a bright line draws across the edge nearest the pointer, the plate unfolds from it under a scan band, the title types on; closing folds the plate back into the line, like a CRT switching off | 220 ms / 130 ms |
| Panel appears (page switch, reopen, re-dock) | **Build-on** (Legacy light table): a bright trace runs around the frame from the top-left corner, the header rule extends, the plate expands from its centre; **Ares flash**: the plate lights as an accent fill that resolves | 340 ms |
| Page switch | old page leaves at once; the new page builds on (no cross-fade) | 340 ms |
| Command palette | build-on (both clipped corners) + header rule extends; first results cascade in | 340 ms |
| List rows (open folder, new app search, palette open) | **Cascade** (Legacy cells popping in): rows slide in one after another; rows that appear by scrolling don't animate | 14 ms stagger, 160 ms |
| Status notice | **Ares text band**: types on behind a sweeping highlight band that dims | 240 ms + 450 ms fade |
| Empty / error states | left status bar draws top to bottom; title types on | 340 ms |
| Focus change | border/glow ease-out; corner brackets snap in from just outside | 140 ms |
| Rail / tab selection | the active marker slides to the new item (Ares selector) | spring 260 ms |
| Dock target while dragging | half-panel highlight with a scan band sweeping toward the edge | 800 ms loop, only while hovering |
| DONE / BELL tags | pop in from 60% with a brief flash | spring 260 ms |
| Widget readouts | update in place (no animation) | – |

One startup build-on that never delays typing; no idle animation, no flicker, no scanlines.

Performance rule: never animate values that refresh on a timer (readouts, clocks, widget
displays), and never leave a shadow or an animation overlay in the view tree once it's done. Any
animated change inside a panel makes SwiftUI re-render that panel on the CPU every frame: rolling
digits on a 2-second CPU readout cost ~40% of a core; without them the whole deck idles at ~1%.

## Layout
```
┌ ● ● ●  GRID │ 01 TERMINAL ──────────────────────────────── COMMAND ⇧⌘P ┐
│ 01  │ ┌02 FILES .NAV───────┐ ┌01 TERMINAL .TTY-01──────────── ▤ ⇄ + ┐ │
│TERM │ │‹ › ↑  / Users / ~  │ │01 zsh × │02 ◆ vim ×│ 03 node DONE ×   │ │
│ 02  │ │⌕ filter  [HERE|DEEP]│ │                                       │ │
│FILES│ │▸ Desktop           │ │  $ …                                  │ │
│ 03  │ │▸ Projects          │ │                                       │ │
│APPS │ │· notes.txt         │ │                                       │ │
│ 04  │ │ 31 items           │ │                                       │ │
│WEB  │ └────────────────────┘ └───────────────────────────────────────┘ │
│ 05  │                                                                  │
├─────┴──────────────────────────────────────────────────────────────────┤
│TTY-01│ zsh │ ~/Projects │ IDLE │ 120×40 │          ✓ notice │ 3 SESSIONS │ LEGACY // CYAN │
└────────────────────────────────────────────────────────────────────────┘
```
Compact window (≥ 820×480): hide the Files sidebar (⌘B). Large: Files panel + inspector.
