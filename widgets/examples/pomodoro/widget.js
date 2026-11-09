// Pomodoro — storage + custom actions + dynamic refresh. Zero permissions.
//
// render returns { view, refreshIn }: 1 s while counting down (allowed because this widget has no
// exec/net), and no refresh at all while idle or paused, so the host sleeps.

const PHASES = { focus: "focus", short: "break", long: "long break" };

function mmss(s) {
  s = Math.max(0, Math.round(s));
  return String(Math.floor(s / 60)).padStart(2, "0") + ":" + String(s % 60).padStart(2, "0");
}

const today = () => new Date().toISOString().slice(0, 10);

async function load() {
  const st = (await grid.storage.get("state")) || { phase: "focus", endsAt: null, pausedLeft: null, done: 0, day: today() };
  if (st.day !== today()) { st.done = 0; st.day = today(); }
  return st;
}

const duration = (st, s) => 60 * (st.phase === "focus" ? s.focus : st.phase === "short" ? s.shortBreak : s.longBreak);

async function render(ctx) {
    const st = await load();
    const total = duration(st, ctx.settings);
    const running = st.endsAt != null && st.pausedLeft == null;
    let left = st.pausedLeft != null ? st.pausedLeft : (running ? (st.endsAt - Date.now()) / 1000 : total);

    if (running && left <= 0) {
      // Phase finished: advance and persist. (A notification would be nice here; see README.)
      if (st.phase === "focus") { st.done += 1; st.phase = st.done % 4 === 0 ? "long" : "short"; }
      else st.phase = "focus";
      st.endsAt = null; st.pausedLeft = null;
      await grid.storage.set("state", st);
      return render(ctx);
    }

    const label = PHASES[st.phase].toUpperCase();
    const state = running ? "" : (st.pausedLeft != null ? " · PAUSED" : " · READY");
    const view = grid.stack([
      grid.display(mmss(left), { detail: label + state, tone: running ? "default" : "dim" }),
      grid.bar(1 - left / total, { tone: st.phase === "focus" ? "accent" : "ok" }),
      grid.row([
        running
          ? grid.button("Pause", grid.action.custom("pause"))
          : grid.button(st.pausedLeft != null ? "Resume" : "Start", grid.action.custom("start"), { prominent: true }),
        grid.button("Skip", grid.action.custom("skip")),
        grid.spacer(),
        grid.button("Reset", grid.confirm(grid.action.custom("reset"), "Reset the timer and today's tally?"))
      ], { gap: 6 }),
      grid.text(st.done + " focus block" + (st.done === 1 ? "" : "s") + " today", { style: "label", tone: "mute" })
    ]);
    return { view, refreshIn: running ? 1 : 0 };
}

grid.widget({
  render,

  async onAction(id, _payload, ctx) {
    const st = await load();
    const total = duration(st, ctx.settings);
    switch (id) {
      case "start":
        st.endsAt = Date.now() + 1000 * (st.pausedLeft != null ? st.pausedLeft : total);
        st.pausedLeft = null;
        break;
      case "pause":
        if (st.endsAt) { st.pausedLeft = Math.max(0, (st.endsAt - Date.now()) / 1000); st.endsAt = null; }
        break;
      case "skip":
        st.phase = st.phase === "focus" ? "short" : "focus";
        st.endsAt = null; st.pausedLeft = null;
        break;
      case "reset":
        st.endsAt = null; st.pausedLeft = null; st.done = 0;
        break;
    }
    await grid.storage.set("state", st);
  }
});
