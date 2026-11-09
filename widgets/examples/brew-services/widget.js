// Services — exec with command alternatives (Apple silicon / Intel brew), {token} names, long
// timeouts, and mutating actions gated by userInitiated + writes + grid.confirm.

const BREW = "/opt/homebrew/bin/brew";   // any path listed in the template is accepted; GRID runs the first that exists
const TOKEN = /^[A-Za-z0-9][A-Za-z0-9@._+:-]{0,63}$/;

let pending = null;   // { name, verb } while an action's brew call is still running

function rows(list, confirmStop) {
  return list.map(s => {
    const running = s.status === "started" || s.status === "scheduled";
    const err = s.status === "error";
    const verb = running ? "stop" : "start";
    let action = grid.action.custom(verb, { name: s.name });
    if (verb === "stop" && confirmStop) action = grid.confirm(action, "Stop " + s.name + "?");
    const busy = pending && pending.name === s.name;
    return {
      title: s.name,
      subtitle: busy ? pending.verb + "ing…" : (s.user ? "as " + s.user : (s.status || "none")),
      trailing: busy ? "…" : (err ? "error" : (running ? "on" : "off")),
      tone: busy ? "accent" : (err ? "danger" : (running ? "ok" : "dim")),
      action: busy ? undefined : action
    };
  });
}

grid.widget({
  refresh: 30,
  async render(ctx) {
    let r;
    try { r = await grid.exec(BREW, ["services", "list", "--json"]); }
    catch (e) {
      if (e.name === "NotFound") return grid.empty("Homebrew not found", "Install Homebrew to use this card.");
      throw e;
    }
    if (r.timedOut) return grid.empty("brew is slow", "brew services list didn't finish in 20 s; will retry.");
    if (r.code !== 0) return grid.text("✕ " + (r.stderr.split("\n")[0] || "brew failed"), { style: "small", tone: "danger" });
    let list;
    try { list = JSON.parse(r.stdout); } catch (_) { throw new Error("Unexpected brew output"); }
    if (!list.length) return grid.empty("No services", "brew install something with a service, e.g. redis.");

    const on = list.filter(s => s.status === "started" || s.status === "scheduled").length;
    return grid.stack([
      grid.readout("svc", on + "/" + list.length, "running"),
      grid.list(rows(list, ctx.settings.confirmStop)),
      grid.text("brew services · click to toggle", { style: "label", tone: "mute" })
    ]);
  },

  onAction(id, payload) {
    const name = String(payload && payload.name || "");
    if (!TOKEN.test(name) || !["start", "stop", "restart"].includes(id)) return;
    pending = { name, verb: id };
    // Start the (userInitiated) brew call now, while this click is being handled, but don't await
    // it: returning lets GRID re-render immediately with the "…ing" row, and grid.invalidate()
    // redraws once brew finishes (up to 30 s later).
    grid.exec(BREW, ["services", id, "--", name]).then(r => {
      if (r.code !== 0) console.error("brew services " + id + " " + name + " failed:", r.stderr.trim());
    }, e => console.error(String(e))).finally(() => { pending = null; grid.invalidate(); });
  }
});
