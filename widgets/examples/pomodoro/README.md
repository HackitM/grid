# Pomodoro

Focus/break countdown with a daily tally. Requires **no permissions**; state lives in the
widget's private storage.

## Permissions

None. The card only uses `grid.storage` and custom actions.

## Notes

- `render` returns `{ view, refreshIn: 1 }` only while a phase is counting down; otherwise no
  refresh is scheduled and the host process idles (and is stopped 30 s after the card is hidden).
- Uses `grid.display` for the hero digits, `grid.bar` with a `tone`, and `grid.confirm` on Reset.

## Still open

- No way to alert you when a phase ends (no `grid.notify`), and a collapsed/hidden card cannot
  fire at the end time (no `grid.wake(at)`), so the finished state only shows once the card is
  visible again.
