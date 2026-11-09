# Git Status

Branch, ahead/behind, working-tree counts and (when expanded or clean) recent commits for the
active terminal's folder. Click a commit to copy its hash.

## Permissions

- `terminal.cwd` — the folder to inspect follows the active terminal (also drives the
  `terminal.cwd` event so the card updates when you `cd`).
- `exec` `git status` / `git log` on `{cwd}` — read-only queries. GRID runs them in a sandbox with
  no network or file writes and hardens git (`core.fsmonitor=false`, `core.hooksPath=/dev/null`,
  no pager, no credential prompts). The commit count comes from the `count` setting via
  `{setting:count}`.
- `clipboard.write` — copying a commit hash when you click a row.

## Notes

- Two execs per 10 s refresh = 12/min, inside the 30/min budget (burst 10).
- A stale result (folder changed while `git status` ran) is discarded by GRID because renders are
  serialized and a newer request supersedes the queued one.
