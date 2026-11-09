// Top — exec ps + grid.system.stats() (which includes GRID's own CPU history, so no per-widget
// sampling or storage) + a destructive action gated by `userInitiated` and grid.confirm.

function parsePs(out) {
  return out.trim().split("\n").slice(1).map(l => {
    const m = /^\s*(\d+)\s+([\d.]+)\s+([\d.]+)\s+(\d+)\s+(.*)$/.exec(l);
    return m ? { pid: +m[1], cpu: +m[2], mem: +m[3], rssKB: +m[4], name: m[5] } : null;
  }).filter(Boolean);
}

function kb(n) {
  if (n >= 1048576) return (n / 1048576).toFixed(1) + " GB";
  if (n >= 1024) return (n / 1024).toFixed(0) + " MB";
  return Math.round(n) + " KB";
}

grid.widget({
  refresh: 5,   // exec widgets can't refresh faster than 5 s anyway
  async render(ctx) {
    const stats = await grid.system.stats();
    const byMem = ctx.settings.sort === "mem";
    const ps = await grid.exec("/bin/ps", ["-Aceo", "pid,pcpu,pmem,rss,comm", byMem ? "-m" : "-r"]);
    if (ps.code !== 0) throw new Error(ps.stderr.split("\n")[0] || "ps failed");
    const procs = parsePs(ps.stdout).slice(0, ctx.settings.rows);

    const quit = ctx.settings.allowQuit;
    const rows = procs.map(p => ({
      title: p.name,
      subtitle: String(p.pid),
      trailing: byMem ? kb(p.rssKB) : p.cpu.toFixed(1) + "%",
      tone: p.cpu > 80 ? "warn" : "default",
      action: quit && p.pid > 1
        ? grid.confirm(grid.action.custom("quit", { pid: p.pid, name: p.name }), "Quit " + p.name + " (pid " + p.pid + ")? Unsaved work in it may be lost.")
        : undefined
    }));

    const cpu = stats.cpu == null ? null : stats.cpu;
    return grid.stack([
      grid.readout("cpu", cpu == null ? "—" : Math.round(cpu * 100) + "%", stats.load ? "load " + stats.load.map(x => x.toFixed(2)).join(" · ") : "measuring…"),
      grid.bar(cpu || 0),
      ctx.size === "expanded" && stats.cpuHistory ? grid.sparkline(stats.cpuHistory, { max: 1 }) : null,
      stats.memUsed == null ? null : grid.readout("mem", kb(stats.memUsed / 1024), "of " + kb(stats.memTotal / 1024)),
      stats.memUsed == null ? null : grid.bar(stats.memUsed / stats.memTotal, { warnAbove: 0.9 }),
      grid.divider(),
      grid.list(rows),
      grid.text("ps · every 5 s · " + (byMem ? "by memory" : "by cpu") + (quit ? " · click to quit" : ""), { style: "label", tone: "mute" })
    ]);
  },

  async onAction(id, payload) {
    if (id !== "quit") return;
    const pid = Number(payload && payload.pid);
    if (!Number.isInteger(pid) || pid <= 1) return;
    // `kill` is a userInitiated template: GRID refuses it outside onAction, and the row action is
    // wrapped in grid.confirm so GRID asked first in its own dialog.
    const r = await grid.exec("/bin/kill", ["-TERM", String(pid)]);
    if (r.code !== 0) console.warn("kill failed:", r.stderr.trim());
  }
});
