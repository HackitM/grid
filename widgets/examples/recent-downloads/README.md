# Downloads

Newest items in `~/Downloads`. A row click reveals, inserts the path, or opens the item
(configurable); buttons act on the newest one.

## Permissions

- `fs.read` `~/Downloads/**` — listing the folder (names, sizes, dates). Needed for the reveal and
  open actions too. `~/Downloads` is protected by macOS, so GRID itself may be asked for access the
  first time; the card then shows an `AccessDenied` hint.
- `terminal.insertPath` — inserting a shell-quoted path at the prompt when you click.
- `clipboard.write` — copying the newest item's path when you click.

## Still open

- No filesystem-change event, so the card polls every 15 s (cheap: `fs.list` with
  `sortBy: "modified"` and a small `limit`). An `fs:<path>` watch event would make it event-only.
- A row has one action; the native Recent Files card offers a context menu (reveal / insert).
