// Inspector — files.selection event + fs.stat/list/readText on {selection} + exec with {selection}.
// Event-only (refresh 0): GRID debounces selection changes (~200 ms) and skips superseded renders.

function size(n) {
  if (n == null) return "—";
  if (n >= 1 << 30) return (n / (1 << 30)).toFixed(2) + " GB";
  if (n >= 1 << 20) return (n / (1 << 20)).toFixed(1) + " MB";
  if (n >= 1024) return (n / 1024).toFixed(0) + " KB";
  return n + " B";
}

const when = (iso) => iso ? new Date(iso).toLocaleString() : "—";

async function lastCommit(cwd, path) {
  if (!cwd || !path.startsWith(cwd + "/")) return null;
  const lg = await grid.exec("/usr/bin/git", ["-C", cwd, "--no-optional-locks", "log", "-1", "--format=%h%x1f%s%x1f%cr", "--", path]);
  if (lg.code !== 0 || !lg.stdout.trim()) return null;
  const [h, s, w] = lg.stdout.trim().split("\x1f");
  return { title: s, subtitle: h, trailing: w, action: grid.action.copy(h) };
}

grid.widget({
  refresh: 0,
  async render(ctx) {
    const sel = await grid.files.selection();
    if (sel.length === 0) return grid.empty("Nothing selected", "Select a file in the Files panel.");

    if (sel.length > 1) {
      const total = sel.reduce((a, f) => a + (f.size || 0), 0);
      return grid.stack([
        grid.readout("items", String(sel.length), size(total)),
        grid.list(sel.slice(0, ctx.settings.previewLines).map(f => ({ title: f.name, subtitle: f.kind, trailing: size(f.size), icon: f.path, action: grid.action.revealInFiles(f.path) }))),
        grid.row([
          grid.button("Insert all paths", grid.action.insertPath(sel.map(f => f.path))),
          grid.button("Copy paths", grid.action.copy(sel.map(f => f.path).join("\n")))
        ], { gap: 6 })
      ]);
    }

    const f = sel[0];
    const st = await grid.fs.stat(f.path);
    const kv = [
      ["path", f.path],
      ["size", st.isFolder ? "—" : size(st.size)],
      ["modified", when(st.modified)],
      ["created", when(st.created)],
      ["mode", st.mode || "—"],
      ["type", (st.uti || st.kind) + (st.isSymlink ? " · symlink" : "") + (st.isPackage ? " · package" : "") + (st.isHidden ? " · hidden" : "")]
    ];
    const children = [grid.list([{ title: f.name, subtitle: st.kind, icon: f.path, action: grid.action.openFile(f.path) }]), grid.kv(kv)];

    if (st.isFolder) {
      const kids = await grid.fs.list(f.path, { includeHidden: false, sortBy: "modified", limit: 2000 });
      const folders = kids.filter(k => k.isFolder).length;
      children.push(grid.readout("items", String(kids.length), folders + " folders · " + (kids.length - folders) + " files"));
      if (kids.length) children.push(grid.list(kids.slice(0, 3).map(k => ({ title: k.name, subtitle: "newest", trailing: size(k.size), icon: k.path, action: grid.action.revealInFiles(k.path) }))));
    } else if (st.size <= 4 * 1024 * 1024) {
      // Text or not? Try to read; GRID rejects binary files with a NotText error.
      try {
        const [text, wc] = await Promise.all([
          grid.fs.readText(f.path, { maxBytes: 16 * 1024 }),
          grid.exec("/usr/bin/wc", ["-l", "--", f.path])
        ]);
        if (wc.code === 0) kv.push(["lines", wc.stdout.trim().split(/\s+/)[0]]);
        const lines = text.split("\n").slice(0, ctx.settings.previewLines).join("\n");
        children.push(grid.divider(), grid.code(lines, { lines: ctx.settings.previewLines }));
      } catch (e) {
        if (e.name !== "NotText") throw e;
        kv.push(["content", "binary"]);
      }
    }

    const commit = await lastCommit(await grid.terminal.cwd(), f.path);
    if (commit) children.push(grid.divider(), grid.list([commit]));

    children.push(grid.row([
      grid.button("Insert path", grid.action.insertPath(f.path)),
      grid.button("Copy path", grid.action.copy(f.path)),
      grid.button("Reveal", grid.action.revealInFiles(f.path))
    ], { gap: 6 }));
    return grid.stack(children);
  }
});
