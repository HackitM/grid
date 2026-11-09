# Services

Homebrew services with click-to-toggle start/stop (stop asks first by default).

## Permissions

- `exec` `brew services list --json` (timeout 20 s) — read-only. `command` lists both Homebrew
  locations (`/opt/homebrew/bin/brew`, `/usr/local/bin/brew`); GRID runs the first that exists.
- `exec` `brew services start|stop|restart -- {token}` (`userInitiated`, `writes`, timeout 30 s) —
  these change things (launch agents are written), so they are only callable while handling your
  click, are allowed to write files, and show as "modifies" in the approval sheet. `{token}`
  accepts names like `postgresql@16` but can never start with `-`.

## Notes

- Brew needs no network for these commands; `HOMEBREW_NO_AUTO_UPDATE=1` is set by GRID.
- Pattern for slow actions: start the exec inside `onAction` without awaiting it, return so the
  card can show the pending row, then call `grid.invalidate()` when the call settles.
