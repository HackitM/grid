// Downloads — fs.list with sort/limit + the three path actions. Polls every 15 s because there is
// no filesystem-change event yet; the sorted, limited listing keeps each poll cheap.

const DIR = "~/Downloads";   // `~` is accepted in fs.* arguments and expanded by GRID
const PARTIAL = /\.(download|crdownload|part|partial)$/i;

function ago(iso) {
  const s = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
  if (s < 60) return "now";
  if (s < 3600) return Math.floor(s / 60) + "m";
  if (s < 86400) return Math.floor(s / 3600) + "h";
  return Math.floor(s / 86400) + "d";
}

function size(n) {
  if (n == null) return "";
  if (n >= 1 << 30) return (n / (1 << 30)).toFixed(1) + " GB";
  if (n >= 1 << 20) return (n / (1 << 20)).toFixed(0) + " MB";
  if (n >= 1024) return (n / 1024).toFixed(0) + " KB";
  return n + " B";
}

grid.widget({
  refresh: 15,
  async render(ctx) {
    let items;
    try {
      // Ask for a few more than we show so filtering partial downloads still fills the list.
      items = await grid.fs.list(DIR, { sortBy: "modified", limit: ctx.settings.count + 10, includeHidden: false });
    } catch (e) {
      if (e.name === "AccessDenied") return grid.empty("No access to Downloads", "Allow GRID to access Downloads in System Settings › Privacy & Security › Files and Folders.");
      if (e.name === "NotFound") return grid.empty("No Downloads folder", DIR);
      throw e;
    }
    if (ctx.settings.hidePartial) items = items.filter(f => !PARTIAL.test(f.name));
    const top = items.slice(0, ctx.settings.count);
    if (!top.length) return grid.empty("Empty", "Nothing in Downloads.");

    const act = (f) => ctx.settings.rowClick === "insert" ? grid.action.insertPath(f.path)
               : ctx.settings.rowClick === "open" ? grid.action.openFile(f.path)   // GRID's "Run?" check still applies to executables
               : grid.action.revealInFiles(f.path);

    return grid.stack([
      grid.list(top.map(f => ({
        title: f.name,
        subtitle: f.isFolder ? "folder" : f.kind,
        trailing: (f.isFolder || f.size == null ? "" : size(f.size) + " · ") + ago(f.modified),
        icon: f.path,
        action: act(f)
      }))),
      grid.row([
        grid.button("Insert newest", grid.action.insertPath(top[0].path)),
        grid.button("Copy newest path", grid.action.copy(top[0].path)),
        grid.spacer(),
        grid.text("click to " + ctx.settings.rowClick, { style: "label", tone: "mute" })
      ], { gap: 6 })
    ]);
  }
});
