// Disk Usage — exec du on the Files folder ({folder} placeholder), event-only refresh, per-folder
// result cache in storage with a small LRU index (storage.keys() makes pruning simple).

const MAX_CACHED = 12;

function kb(n) {
  if (n >= 1048576) return (n / 1048576).toFixed(1) + " GB";
  if (n >= 1024) return (n / 1024).toFixed(0) + " MB";
  return n + " KB";
}

function parseDu(out, root) {
  let total = 0;
  const kids = [];
  for (const line of out.split("\n")) {
    const m = /^(\d+)\t(.*)$/.exec(line);
    if (!m) continue;
    const size = +m[1], path = m[2];
    if (path === root) total = size;
    else kids.push({ size, path, name: path.slice(root.length + 1) });
  }
  kids.sort((a, b) => b.size - a.size);
  if (!total) total = kids.reduce((a, k) => a + k.size, 0);
  return { total, kids };
}

async function prune() {
  const keys = (await grid.storage.keys()).filter(k => k.startsWith("du:"));
  if (keys.length <= MAX_CACHED) return;
  const entries = [];
  for (const k of keys) entries.push({ k, at: ((await grid.storage.get(k)) || {}).at || 0 });
  entries.sort((a, b) => a.at - b.at);
  for (const e of entries.slice(0, entries.length - MAX_CACHED)) await grid.storage.remove(e.k);
}

grid.widget({
  refresh: 0,
  async render(ctx) {
    const folder = await grid.files.folder();
    if (!folder) return grid.empty("No folder", "Open a folder in the Files panel.");

    const key = "du:" + folder.path;
    const cached = await grid.storage.get(key);
    let data = cached && Date.now() - cached.at < ctx.settings.cacheMin * 60e3 ? cached : null;

    if (!data) {
      const r = await grid.exec("/usr/bin/du", ["-kx", "-d", "1", "--", folder.path]);
      // du exits 1 when some subfolders are unreadable but still prints what it could; on timeout
      // GRID returns the partial stdout with timedOut: true.
      if (!r.stdout.trim()) {
        return grid.stack([
          grid.empty("Can't measure", r.timedOut ? "du didn't finish in 30 s." : (r.stderr.split("\n")[0] || "du failed")),
          grid.button("Retry", grid.action.custom("remeasure"))
        ]);
      }
      const parsed = parseDu(r.stdout, folder.path);
      data = { at: Date.now(), total: parsed.total, kids: parsed.kids.slice(0, 25).map(k => ({ n: k.name, s: k.size, p: k.path })), partial: r.code !== 0 || r.timedOut };
      try { await grid.storage.set(key, data); await prune(); }
      catch (e) { if (e.name === "QuotaExceeded") await grid.storage.clear(); else throw e; }
    }

    const rows = data.kids.slice(0, ctx.settings.rows).map(k => ({
      title: k.n,
      trailing: kb(k.s),
      icon: k.p,
      action: grid.action.revealInFiles(k.p)   // allowed by fs.read {folder}/**
    }));
    const biggest = data.kids[0] ? data.kids[0].s / Math.max(data.total, 1) : 0;
    return grid.stack([
      grid.readout("size", kb(data.total), folder.name + (data.partial ? " · partial" : "")),
      grid.bar(biggest, { tone: biggest > 0.9 ? "warn" : "accent" }),
      grid.text("largest child · " + Math.round(biggest * 100) + "%", { style: "label", tone: "mute" }),
      grid.list(rows),
      grid.row([
        grid.button("Re-measure", grid.action.custom("remeasure")),
        grid.button("Insert path", grid.action.insertPath(folder.path))
      ], { gap: 6 }),
      grid.text("du · " + new Date(data.at).toLocaleTimeString(), { style: "label", tone: "mute" })
    ]);
  },

  async onAction(id) {
    if (id !== "remeasure") return;
    const folder = await grid.files.folder();
    if (folder) await grid.storage.remove("du:" + folder.path);   // the follow-up render re-measures
  }
});
