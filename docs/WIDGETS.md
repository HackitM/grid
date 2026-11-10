# GRID Widget API (v1)

Build your own widgets for the deck. A widget is a folder with a manifest and some JavaScript.
The script runs in an isolated JavaScript engine and returns a **view tree** of GRID components,
which GRID draws natively, so every widget matches the app's design language automatically.

GRID's own widgets (Clock, System, Git, File Inspector, …) are built in. This document is about
**packages**: widgets you write or install.

## Contents
1. [Quick start](#quick-start)
2. [Package layout](#package-layout)
3. [Manifest](#manifest)
4. [Script lifecycle](#script-lifecycle)
5. [View components](#view-components)
6. [Actions](#actions)
7. [API (`grid.*`)](#api)
8. [Permissions](#permissions)
9. [Guardrails](#guardrails)
10. [Efficiency](#efficiency)
11. [Semantics worth knowing](#semantics-worth-knowing)
12. [Host protocol (internal)](#host-protocol-internal)

Examples: [`widgets/examples/`](../widgets/examples) (git status, GitHub PRs with a Keychain token,
top processes, Homebrew services, Hacker News, pomodoro, disk usage, downloads, file inspector).

## Quick start
Deck › **+** › **New Widget…** (or Settings › Widgets › New Widget…) creates a working package in
`~/Library/Application Support/GRID/Widgets/Dev/<name>/` and adds it to the deck. Edit `widget.js`
in any editor and GRID reloads it when you save. Your own widgets show a **DEV** tag; installed
ones show **3RD**.

```js
// widget.js
grid.widget({
  async render(ctx) {
    const sel = await grid.files.selection();          // needs "files.selection"
    if (sel.length === 0) return grid.empty("Nothing selected", "Select files in Files.");
    return grid.stack([
      grid.readout("ITEMS", String(sel.length)),
      grid.list(sel.slice(0, 5).map((f) => ({ title: f.name, subtitle: f.kind, icon: f.path,
                                              action: grid.action.insertPath(f.path) }))),
    ]);
  },
});
```

To share a widget, send the folder. Recipients use **Install…**, review the permissions, and GRID
copies it into `Widgets/Installed/<id>/`.

## Package layout
```
my-widget/
  manifest.json        required
  widget.js            entry script (name set by "entry")
  README.md            optional
  lib/*.js             optional extra scripts, loaded in order via "scripts" (one shared scope)
```
Limits: 1 MiB total, 64 files, folders nested at most 4 deep. Only `.js`, `.json` and `.md` files
are read; anything else is ignored and never executed. Symbolic links and special files make the
package invalid.

## Manifest
```json
{
  "api": 1,
  "id": "com.example.git-log",
  "name": "Git Log",
  "version": "1.0.0",
  "description": "Recent commits in the terminal's repository.",
  "author": "You",
  "entry": "widget.js",
  "scripts": [],
  "refresh": 30,
  "events": ["terminal.cwd"],
  "settings": [
    { "key": "count", "type": "number", "label": "Commits", "default": 5, "min": 1, "max": 30 }
  ],
  "permissions": {
    "terminal.cwd": true,
    "exec": [ { "command": "/usr/bin/git", "args": ["-C", "{cwd}", "log", "--oneline", "-n", "{setting:count}"] } ]
  }
}
```
| Field | Notes |
|---|---|
| `api` | `1` |
| `id` | reverse-DNS, `[a-z0-9.-]`, unique |
| `name` | 1–40 characters |
| `description`, `author` | optional; at most 300 / 60 characters (no control or bidi characters) |
| `version` | `1`, `1.2`, `1.2.3` … |
| `entry`, `scripts` | `.js` paths inside the package |
| `refresh` | seconds between automatic renders (1–3600), or 0 for events/actions only |
| `events` | re-render when these change: `files.selection`, `files.folder`, `terminal.cwd`, `terminal.sessions`, `theme`. Each needs the matching permission. |
| `settings` | drawn natively on the card's ⚙ face (below) |
| `permissions` | see [Permissions](#permissions); anything undeclared is unavailable |

### Settings
| `type` | Extra fields | In `ctx.settings` |
|---|---|---|
| `string` | `maxLength` | string |
| `number` | `min`, `max` | number |
| `bool` | | boolean |
| `choice` | `options` (required) | string |
| `secret` | `hosts` (required, each also in `net`); no `default` | **not present**; `ctx.secrets[key]` is `true` when set |

Secrets are stored in your Keychain and are never given to the script. Use `{secret:key}` in a
`grid.net.fetch` header value or body; GRID substitutes it only for requests to the secret's
`hosts`:

```js
const r = await grid.net.fetch("https://api.github.com/user", {
  headers: { Authorization: "Bearer {secret:token}" },
});
```

## Script lifecycle
- `grid.widget({ refresh, render(ctx), onAction(id, payload, ctx) })` registers the widget, once.
- `render(ctx)` runs on start, on refresh ticks, on subscribed events, after actions and after
  settings change. Return a view tree, or `{ view, refreshIn }` to schedule the next render in
  `refreshIn` seconds (overrides `refresh` for that one tick). A Promise of either is fine.
- `grid.invalidate()` asks for a render soon (coalesced to at most once a second).
- `ctx`: `settings`, `secrets` (which are set), `size` (`"compact" | "expanded"`, the card's ↗),
  `theme` (`"legacy" | "ares" | "amber"`), `now` (ISO time), `reason` (`"start" | "refresh" |
  "event:<name>" | "action" | "settings" | "invalidate"`).
- `onAction(id, payload, ctx)` handles `grid.action.custom` clicks; GRID re-renders afterward.
- No timers (`setTimeout`/`setInterval`), no `fetch`, no `require`/modules. Use `refresh`,
  `refreshIn`, events and the API.
- A thrown error shows the card's error state with the message; the last good view stays dimmed.
- `console.log` / `warn` / `error` go to Settings › Widgets › Logs (last 200 lines, memory only,
  rate-limited).

## View components
All builders are pure functions that return plain objects. GRID validates and draws them; widgets
can't supply colors, fonts, images or custom layout.

| Builder | Draws |
|---|---|
| `grid.stack(children, {axis: "v"\|"h", gap})` | vertical (default) or horizontal group |
| `grid.row(children, {gap})` | horizontal group |
| `grid.spacer()` | flexible space (push items apart in a row) |
| `grid.text(str, {style, tone, lines})` | style `body\|small\|label\|title\|mono`; tone `default\|dim\|mute\|accent\|ok\|warn\|danger` |
| `grid.display(value, {detail, tone})` | big light digits (like the Clock) |
| `grid.readout(label, value, detail?)` | GRID readout row |
| `grid.bar(fraction, {warnAbove, tone})` | segmented level bar (0–1) |
| `grid.sparkline(numbers, {max})` | line chart |
| `grid.kv([[key, value], …])` | inspector-style rows |
| `grid.list(items)` | rows `{title, subtitle?, trailing?, tone?, icon?, action?}`; `icon` is an absolute file path (its Finder icon), an SF Symbol name, or a 1–2 character glyph |
| `grid.tag(text, tone?)` | inverted label block |
| `grid.button(title, action, {prominent})` | GRID button |
| `grid.divider()` | terminated rule |
| `grid.progress(fraction?)` | progress bar (indeterminate when omitted) |
| `grid.empty(title, message)` | empty-state block |
| `grid.code(text, {lines})` | monospaced block |

Limits: 400 nodes, depth 12, 4,000 characters per text, 100 list rows, 60 kv rows. Bigger trees
are truncated with a warning in the logs. Unknown components are skipped.

## Actions
Actions run only when you click a button or list row; a script can never trigger them itself.
Hovering shows exactly what a click will do.

| Action | Effect | Permission |
|---|---|---|
| `grid.action.custom(id, payload)` | calls `onAction` | none |
| `grid.action.copy(text)` | copies text | `clipboard.write` |
| `grid.action.openURL(url)` | opens an https URL in your browser | `openURL` |
| `grid.action.revealInFiles(path)` | shows the item in GRID's Files panel | `fs.read` covering it |
| `grid.action.openFile(path)` | GRID asks first (naming the item and the app that opens it), then opens it; its "Run?" check still applies | `fs.read` covering it |
| `grid.action.insertPath(path \| [paths])` | inserts shell-quoted paths at the prompt; never runs anything | `terminal.insertPath` |
| `grid.confirm(action, message)` | wraps any action: GRID asks first, in its own dialog naming the widget | – |

## API
Every call returns a Promise. Failures reject with an `Error` whose `name` is one of
`PermissionError` (not declared/approved), `AccessDenied` (macOS refused), `NotFound`,
`RateLimited`, `NetworkError`, `QuotaExceeded`, `NotText`, `GridError`.

| Call | Returns | Permission |
|---|---|---|
| `grid.files.selection()` | `[FileInfo]` selected in Files (max 500) | `files.selection` |
| `grid.files.folder()` | `FileInfo` of the Files folder | `files.selection` |
| `grid.fs.stat(path)` | `FileInfo` + `mode`, `created` | `fs.read` |
| `grid.fs.list(path, {limit, includeHidden, sortBy})` | `[FileInfo]` (max 2,000; `sortBy` `name\|modified\|size`) | `fs.read` |
| `grid.fs.readText(path, {maxBytes})` | UTF-8 text (default 64 KiB, max 256 KiB; regular files only) | `fs.read` |
| `grid.terminal.cwd()` | the active session's folder | `terminal.cwd` |
| `grid.terminal.sessions()` | `[{number, cwd, running, title, active, exited}]`, never contents | `terminal.sessions` |
| `grid.exec(command, args)` | `{code, stdout, stderr, timedOut, truncated}` (256 KiB each) | `exec` (must match a template) |
| `grid.net.fetch(url, {method, headers, body})` | `{status, headers, text}` (1 MiB, 10 s) | `net` |
| `grid.system.stats()` | `{cpu, memUsed, memTotal, load, cores, cpuHistory}` | none |
| `grid.storage.get/set/remove(key)`, `.keys()`, `.clear()` | JSON values, 256 KiB per package (shared by its cards) | none |

`FileInfo` is `{path, name, kind, isFolder, isPackage, size, modified, isHidden, isSymlink, uti}`.
Paths are absolute; `~` is accepted in arguments.

## Permissions
Declared in the manifest and **approved by you**. GRID shows every capability in plain words with
exact paths, commands and hosts, marks risk (· low, △ worth a look, ✕ GRID can't tell what it does),
and spells out risky combinations ("Can read files and send data to api.example.com"). Unapproved
widgets never start.

| Permission | Shape | Notes |
|---|---|---|
| `files.selection` | `true` | Files selection and folder |
| `terminal.cwd` | `true` | active terminal's folder |
| `terminal.sessions` | `true` | sessions' folders and running program names (no contents, ever) |
| `terminal.insertPath` | `true` | quoted paths at the prompt, only on click |
| `clipboard.write` | `true` | only on click |
| `fs.read` | `["~/Projects/**", "/etc/hosts", "{selection}", "{selection}/**", "{cwd}/*", "{folder}/**"]` | read-only globs: `*` within a name, `**` any depth. Placeholder values are matched literally. |
| `exec` | `[{command, args, timeout?, userInitiated?, net?, writes?}]` | see below |
| `net` | `["api.github.com", "*.example.com"]` | https only; `*.` matches subdomains only |
| `openURL` | `"any"` or `["github.com"]` | https links you click |

Protected locations are off-limits to `fs.read` unless a pattern names them (or a path inside them)
explicitly: every dot-entry directly in your home folder (`~/.ssh`, `~/.zshrc`, `~/.config`, …)
and `~/Library`. Credential stores inside those (`~/.ssh`, `~/.aws`, Keychains, browser profiles,
`~/Library/Preferences`, password managers, GRID's own data, …) must be named themselves; `~/**`
or `~/Library/**` never reach them. A `{cwd}`/`{folder}`/`{selection}` pattern reaches inside only
when that folder is itself inside (you navigated there). `/dev` is never readable.

### Exec templates
```json
{ "command": ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
  "args": ["services", "restart", "{token}"],
  "timeout": 30, "userInitiated": true, "writes": true }
```
- `command`: one absolute path, or up to 4 alternatives for the same program (the first that
  exists runs; the script may call any of them).
- `args`: each is a literal, or a placeholder. The script passes real values; GRID checks them:

  | Placeholder | Accepts |
  |---|---|
  | `{cwd}` | exactly the active terminal's folder (`terminal.cwd`) |
  | `{folder}` | exactly the Files folder (`files.selection`) |
  | `{selection}` | one of the selected paths (`files.selection`) |
  | `{int}` | `1`–`999999999` |
  | `{word}` | `[A-Za-z0-9._][A-Za-z0-9._-]{0,63}` |
  | `{token}` | `[A-Za-z0-9][A-Za-z0-9@._+:-]{0,63}` (e.g. `php@8.3`) |
  | `{setting:key}` | the current value of a `number`, `bool` or `choice` setting |

  Substituted values never start with `-` and never contain control characters. Put `--` before
  path placeholders when the program supports it.
- `timeout`: 1–60 s (default 5). On timeout you get what was printed so far, with `timedOut: true`.
- `userInitiated`: runs only while `onAction` handles your click, **once per click**. Required
  for commands that change things (kill, `brew services start`, `git push`, …, marked △ at
  approval); read-only commands may run on refresh. `kill`/`pkill`/`killall` can never target GRID
  or a widget host, by process id or by the names `Grid` and `GridWidgetHost`.
- Commands run **without a shell**, with a clean environment, in a temporary working folder, under
  a sandbox that blocks all networking including local sockets such as ssh-agent or docker
  (unless `net: true`), file writes outside that temporary folder (unless `writes: true`),
  credential files, the Keychain, and Apple Events. Nothing in your home folder, temp folders or
  external volumes can be executed except the approved program itself, and git can't start a
  shell, so a cloned repository's config can't make git run its scripts. Login items, shell
  startup files, `~/.gitconfig` and `~/Library/Preferences` stay unwritable even with
  `writes: true`. The read-only setuid tools `ps` and `top` run outside the sandbox (macOS won't
  start setuid programs inside one); any other setuid program is refused.
- Refused outright: shells, interpreters (`python*`, `perl*`, `ruby*`, `node*`, `php*`, …),
  launchers (`env`, `xargs`, `sudo`, `open`, `launchctl`, `osascript`, `nohup`, …), network
  tools (`curl`, `ssh`, `nc`, `rsync`, …), terminal drivers (`tmux`, `screen`), `security`,
  editors and pagers, `find`, `sqlite3`, and others that turn arguments into code.
- git: templates can't use `-c`, `--exec-path`, `--upload-pack`, `--receive-pack`,
  `--config-env`, `--git-dir`, `--work-tree`; GRID always adds `-c core.fsmonitor=false
  -c core.hooksPath=/dev/null --no-pager`.

There is **no** permission to write files (besides `grid.storage`), run shell strings, send
keystrokes or text to a terminal, read terminal contents, or use the camera, microphone, location
or contacts.

## Guardrails
- **No ambient authority.** The engine has no file, network, process, timer or module APIs. The
  only way out is `grid.*`, and every call is checked in the GRID app against what you approved.
  The widget process is treated as hostile: everything it sends is validated.
- **Isolated process.** Each card runs in its own `GridWidgetHost` process: JavaScriptCore with
  the JIT off, no inherited environment, small resource limits, and a deny-everything macOS
  sandbox entered before any widget code runs (no files, network, or new processes;
  `GridWidgetHost --selftest` proves it).
- **Budgets.** A widget is paused, with the reason shown, if a render or action uses more than
  2 s of its own time (time spent waiting on GRID doesn't count) or 30 s of wall-clock time
  (longer if an approved command's timeout needs it), it sustains more than 25% of a CPU core for
  10 s, it goes over 150 MB of memory, it has more than 32 calls in flight, it sends more than
  3,000 messages in half a second (logs and `invalidate()` included), or it sends malformed or
  oversized messages.
  It restarts after 5 s, then 10 s; after 3 strikes it stays stopped until you press Restart.
- **Rate limits.** `exec` and `net`: bursts of 10, then 30 per minute each; all other calls 600
  per minute. Logs and `invalidate()` are throttled too.
- **Network.** https only, listed hosts only, no cookies or cache, no redirects (you get the 3xx),
  and hosts that resolve to private, loopback or link-local addresses are refused. `Cookie`,
  `Host`, `Origin`, `Proxy-*` and similar headers can't be set.
- **Integrity.** An installed widget's approval is pinned to a SHA-256 of its files: any change
  disables it until you review it again. GRID installs by copying only the validated bytes, and
  approves exactly the version you reviewed. Installing a different package over an existing id
  clears the old one's saved data and Keychain secrets.
  Development widgets reload on save, but ask again whenever their permissions or secret hosts
  change.
- **Clicks only.** Clipboard, opening URLs/files, inserting paths and commands that change things
  happen only from your clicks. File icons in list rows are shown only for paths the widget may
  read.
  `grid.confirm` prompts are drawn by GRID and name the widget, and cards carry a DEV/3RD tag, so a
  widget can't pass itself off as GRID.

## Efficiency
- A card's process runs only while the card is on the deck and expanded. Collapsing or hiding
  the deck stops its refreshes at once and ends the process 30 s later (so quick toggles don't
  pay a restart).
- Renders happen on refresh ticks, events (debounced 200 ms, so arrowing through Files doesn't
  re-render on every row), actions and settings changes. One render at a time; superseded
  requests are dropped.
- The host compares each tree with the last one and sends "unchanged" instead of the tree; GRID
  redraws only what changed.
- Minimum refresh is 1 s for widgets without `exec`/`net`, 5 s otherwise. Refreshes pause while
  GRID is in the background and not visible.
- Prefer events over short refresh intervals, and avoid heavy commands (`du`, `brew`) on every
  tick: cache in `grid.storage` and use `refreshIn` to back off.

## Semantics worth knowing
- Module-level variables persist between renders until the process restarts (hide/show after
  30 s, package reload, strike).
- All scripts share one global scope, loaded in `scripts` order, then `entry`.
- Response header names are lower-cased; `set-cookie` is dropped.
- `exec` resolves with the output even when the exit code is non-zero; it rejects only when the
  call isn't allowed or the program is missing.
- Storage writes are saved to disk shortly after the last change.

## Host protocol (internal)
GRID ↔ `GridWidgetHost` speak newline-delimited JSON over stdin/stdout (max 1 MiB per message).

App → host:
- `{"t":"load","sources":[{"name":"widget.js","code":"…"}]}`
- `{"t":"render","id":N,"ctx":{…}}`
- `{"t":"action","id":N,"action":"…","payload":…,"ctx":{…}}`
- `{"t":"result","call":N,"ok":true,"value":…}` or `{"t":"result","call":N,"ok":false,"error":"…","kind":"PermissionError"}`

Host → app:
- `{"t":"ready","refresh":N?}`, `{"t":"loadError","error":"…"}`
- `{"t":"view","id":N,"tree":{…},"refreshIn":S?}` or `{"t":"view","id":N,"same":true}`
- `{"t":"renderError","id":N,"error":"…"}`, `{"t":"actionDone","id":N,"error":"…"?}`
- `{"t":"call","call":N,"api":"fs.readText","args":[…]}` (at most 32 in flight)
- `{"t":"log","level":"log|warn|error","msg":"…"}`, `{"t":"invalidate"}`
