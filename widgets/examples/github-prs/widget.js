// GitHub PRs — net + exec + a secret setting.
//
// The token is a `secret` setting: it lives in the Keychain, never reaches this script
// (ctx.secrets.token is only true/false), and is substituted into the "{secret:token}" header
// placeholder by GRID, only for the hosts the manifest binds it to (api.github.com).

const REMOTE = (cwd) => ["-C", cwd, "remote", "get-url", "origin"];
const AUTH = { "Authorization": "Bearer {secret:token}", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" };

function ago(iso) {
  const s = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
  if (s < 3600) return Math.floor(s / 60) + "m";
  if (s < 86400) return Math.floor(s / 3600) + "h";
  return Math.floor(s / 86400) + "d";
}

async function repoFor(cwd) {
  const r = await grid.exec("/usr/bin/git", REMOTE(cwd));
  return r.code === 0 ? parseGitHubRemote(r.stdout.trim()) : null;
}

async function me() {
  let login = await grid.storage.get("me");
  if (login) return login;
  const r = await grid.net.fetch("https://api.github.com/user", { headers: AUTH });
  if (r.status !== 200) return null;
  login = JSON.parse(r.text).login;
  await grid.storage.set("me", login);
  return login;
}

grid.widget({
  refresh: 120,
  async render(ctx) {
    if (!ctx.secrets.token) {
      return grid.empty("No token", "Add a GitHub token in this widget's settings. It's stored in your Keychain and only ever sent to api.github.com.");
    }
    const cwd = await grid.terminal.cwd();
    const repo = cwd ? await repoFor(cwd) : null;
    if (!repo) return grid.empty("Not a GitHub repo", "The terminal's folder has no github.com origin.");

    const slug = repo.owner + "/" + repo.repo;
    const cacheKey = "prs:" + slug + ":" + ctx.settings.state;
    const cached = await grid.storage.get(cacheKey);
    let prs, stale = false;
    try {
      const q = "?state=" + ctx.settings.state + "&per_page=" + Math.min(30, ctx.settings.count * 2) + "&sort=updated&direction=desc";
      const headers = Object.assign({}, AUTH);
      if (cached && cached.etag) headers["If-None-Match"] = cached.etag;   // 304 keeps the cache and costs no rate limit
      const res = await grid.net.fetch("https://api.github.com/repos/" + slug + "/pulls" + q, { method: "GET", headers });
      if (res.status === 304 && cached) prs = cached.prs;
      else if (res.status === 401) return grid.empty("Bad token", "GitHub rejected the token (401). Replace it in settings.");
      else if (res.status === 403 || res.status === 429) {
        const reset = res.headers["x-ratelimit-reset"];
        if (!cached) return grid.empty("Rate limited", reset ? "Resets at " + new Date(+reset * 1000).toLocaleTimeString() : "Try again later.");
        prs = cached.prs; stale = true;
      } else if (res.status !== 200) return grid.text("✕ HTTP " + res.status, { style: "small", tone: "danger" });
      else {
        prs = JSON.parse(res.text).map(p => ({ n: p.number, t: p.title, u: p.user.login, d: !!p.draft, url: p.html_url, up: p.updated_at }));
        await grid.storage.set(cacheKey, { at: Date.now(), etag: res.headers["etag"] || null, prs });
      }
    } catch (e) {
      if (e.name === "NetworkError" && cached) { prs = cached.prs; stale = true; }   // offline: show the last good list
      else throw e;
    }

    if (ctx.settings.mineOnly) {
      const login = await me();
      if (login) prs = prs.filter(p => p.u === login);
    }

    const rows = prs.slice(0, ctx.settings.count).map(p => ({
      title: "#" + p.n + "  " + p.t,
      subtitle: p.u + (p.d ? " · draft" : ""),
      trailing: ago(p.up),
      tone: p.d ? "dim" : "default",
      action: grid.action.openURL(p.url)
    }));

    return grid.stack([
      grid.readout(ctx.settings.state, String(prs.length), slug),
      rows.length ? grid.list(rows) : grid.text("No " + ctx.settings.state + " pull requests.", { style: "small", tone: "mute" }),
      grid.text("github · every 2 min" + (stale ? " · offline, showing cached" : ""), { style: "label", tone: stale ? "warn" : "mute" })
    ]);
  }
});
