# Disk Usage

Total size of the Files panel's current folder, its largest direct children (click to reveal),
and a re-measure button. Results are cached per folder for a configurable time.

## Permissions

- `files.selection` — the Files folder (via `grid.files.folder()`, the `{folder}` placeholder and
  the `files.folder` event that re-renders when you navigate).
- `exec` `du -kx -d 1 -- {folder}` (timeout 30 s) — read-only; on a huge tree GRID returns the
  partial output with `timedOut: true`, which the card shows as "partial".
- `fs.read` `{folder}/**` — only so "reveal in Files" works for children of the current folder;
  nothing is read.
- `terminal.insertPath` — inserting the folder's path at the prompt when you click.
