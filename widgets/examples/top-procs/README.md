# Top

Busiest processes by CPU or memory, CPU/memory readouts, a CPU sparkline when expanded, and an
opt-in "click to quit" action with a native confirmation.

## Permissions

- `exec` `ps -Aceo … -r` / `-m` — read-only process listing (two templates because the sort flag
  is a literal; placeholder values may never start with `-`).
- `exec` `kill -TERM {int}` (`userInitiated`) — only callable while handling your click, and only
  offered when the "Click a row to quit" setting is on. The row action is wrapped in
  `grid.confirm(...)`, so GRID shows its own "Top asks: Quit …?" dialog before the widget runs
  anything. `{int}` is non-negative, so `kill -1` (every process) is impossible.
- No permission needed for `grid.system.stats()`; it reuses GRID's own sampler, including
  `cpuHistory` for the sparkline.
