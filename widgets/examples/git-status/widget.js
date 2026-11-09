// Git Status — exec + terminal.cwd event. Mirrors the built-in Git card and adds a commit list
// with copy-hash actions.
//
// Placeholders: the script passes real values and GRID checks them against the approved template
// ({cwd} must be the active terminal's folder; {setting:count} must be the setting's current
// value, as a string). GRID itself prepends `-c core.fsmonitor=false -c core.hooksPath=/dev/null
// --no-pager` to every git call, so a repository can't make git run code for this widget.

const STATUS = (cwd) => ["-C", cwd, "--no-optional-locks", "status", "--porcelain=v2", "--branch", "--ignore-submodules=all"];
const LOG = (cwd, n) => ["-C", cwd, "--no-optional-locks", "log", "--format=%h%x1f%s%x1f%cr", "-n", String(n)];

function parseStatus(out) {
  const s = { branch: "?", ahead: 0, behind: 0, staged: 0, modified: 0, untracked: 0, conflicted: 0 };
  for (const line of out.split("\n")) {
    if (line.startsWith("# branch.head ")) s.branch = line.slice(14);
    else if (line.startsWith("# branch.ab ")) {
      const m = /\+(\d+) -(\d+)/.exec(line);
      if (m) { s.ahead = +m[1]; s.behind = +m[2]; }
    } else if (line.startsWith("1 ") || line.startsWith("2 ")) {
      const xy = line.split(" ")[1];
      if (xy[0] !== ".") s.staged++;
      if (xy[1] !== ".") s.modified++;
    } else if (line.startsWith("u ")) s.conflicted++;
    else if (line.startsWith("? ")) s.untracked++;
  }
  s.clean = !(s.staged || s.modified || s.untracked || s.conflicted);
  return s;
}

grid.widget({
  refresh: 10,
  async render(ctx) {
    const cwd = await grid.terminal.cwd();
    if (!cwd) return grid.empty("No folder", "Open a terminal session; this card follows its folder.");

    const st = await grid.exec("/usr/bin/git", STATUS(cwd));
    if (st.code !== 0) {
      if (/not a git repository/i.test(st.stderr)) {
        return grid.stack([
          grid.text("Not a git repository", { style: "small", tone: "dim" }),
          grid.text(cwd, { style: "small", tone: "mute", lines: 1 })
        ]);
      }
      if (/xcode-select|developer tools|command line tools/i.test(st.stderr)) {
        return grid.text("△ git isn't available (install the Xcode Command Line Tools).", { style: "small", tone: "warn" });
      }
      return grid.text("✕ " + (st.stderr.split("\n")[0] || "git failed"), { style: "small", tone: "danger" });
    }
    const s = parseStatus(st.stdout);

    const header = grid.row([
      grid.text(s.branch, { style: "title", lines: 1 }),
      s.ahead ? grid.text("↑" + s.ahead, { style: "small", tone: "accent" }) : null,
      s.behind ? grid.text("↓" + s.behind, { style: "small", tone: "warn" }) : null,
      grid.spacer(),
      s.clean ? grid.tag("clean", "ok") : null
    ], { gap: 6 });

    const counts = s.clean ? null : grid.row([
      grid.readout("stg", String(s.staged)),
      grid.readout("mod", String(s.modified)),
      grid.readout("new", String(s.untracked)),
      s.conflicted ? grid.readout("cfl", String(s.conflicted)) : null
    ], { gap: 10 });

    const children = [header, counts];

    if (ctx.settings.showLog && (ctx.size === "expanded" || s.clean)) {
      const lg = await grid.exec("/usr/bin/git", LOG(cwd, ctx.settings.count));
      if (lg.code === 0) {
        const rows = lg.stdout.trim().split("\n").filter(Boolean).map(l => {
          const [hash, subject, when] = l.split("\x1f");
          return { title: subject, subtitle: hash, trailing: when, action: grid.action.copy(hash) };
        });
        if (rows.length) children.push(grid.divider(), grid.list(rows));
      }
    }

    children.push(grid.text("terminal · " + cwd, { style: "label", tone: "mute", lines: 1 }));
    return grid.stack(children);
  }
});
