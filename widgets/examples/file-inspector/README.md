# Inspector

Stat, type, line count, text preview and last commit for the file selected in the Files panel.
With several files selected: a summary list plus "Insert all paths" / "Copy paths".

## Permissions

- `files.selection` — what's selected in Files (and the `files.selection` event that re-renders
  this card as you move through a folder).
- `fs.read` `{selection}` and `{selection}/**` — reading only the selected items and, for a
  selected folder, what's inside it. Binary files are refused by GRID (`NotText`), so the preview
  only shows text.
- `exec` `wc -l -- {selection}` — line count; `git log -1 -- {selection}` in `{cwd}` — the last
  commit touching the file (only when the file is inside the terminal's folder). Both read-only,
  sandboxed.
- `terminal.cwd` — needed for the `{cwd}` placeholder above.
- `terminal.insertPath` — inserting the shell-quoted path(s) at the prompt when you click.
- `clipboard.write` — copying a path or commit hash when you click.

## Notes

- `FileInfo` now carries `uti`, `isPackage`, and `fs.stat` adds `mode` and `created`, so no
  `file(1)` exec is needed for the type.
