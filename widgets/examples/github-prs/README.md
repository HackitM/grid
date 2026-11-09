# GitHub PRs

Pull requests for the GitHub repository behind the terminal's folder. Click a row to open it in
your browser. Falls back to the last cached list when offline or rate-limited.

## Permissions

- `terminal.cwd` + `exec` `git remote get-url origin` on `{cwd}` — finds which repository you're
  in (read-only, sandboxed, no network).
- `net` `api.github.com` — the GitHub REST API, https only, no cookies, redirects not followed.
- Secret setting `token` bound to `api.github.com` — stored in your Keychain. The script never
  sees it; GRID fills `{secret:token}` into the `Authorization` header only for that host.
  `ctx.secrets.token` tells the widget whether one is set.
- `openURL` `github.com` — opening a PR page when you click (a browser click, not a fetch).
- `clipboard.write` — reserved for a future "copy PR URL" row menu; not used yet.

## Notes

- Uses `If-None-Match` so unchanged lists return `304` without touching GitHub's rate limit.
- `lib/remote.js` is loaded before `widget.js` and shares the same global scope.
