// The JavaScript side of the widget runtime: `grid.*` builders, the call bridge, and message
// routing. Nothing here is trusted by GRID; it only makes the API pleasant to use.
let prelude = #"""
(function () {
  "use strict";
  const send = globalThis.__grid_send;
  delete globalThis.__grid_send;
  const out = (o) => send(JSON.stringify(o));

  // ---- console -------------------------------------------------------------------------
  const fmt = (args) => args.map((a) => {
    if (typeof a === "string") return a;
    try { return JSON.stringify(a); } catch (e) { return String(a); }
  }).join(" ").slice(0, 2000);
  globalThis.console = {
    log: (...a) => out({ t: "log", level: "log", msg: fmt(a) }),
    info: (...a) => out({ t: "log", level: "log", msg: fmt(a) }),
    warn: (...a) => out({ t: "log", level: "warn", msg: fmt(a) }),
    error: (...a) => out({ t: "log", level: "error", msg: fmt(a) }),
    debug: () => {},
  };

  // ---- bridge --------------------------------------------------------------------------
  class PermissionError extends Error { constructor(m) { super(m); this.name = "PermissionError"; } }
  class GridError extends Error { constructor(m, kind) { super(m); this.name = kind || "GridError"; } }
  globalThis.PermissionError = PermissionError;
  let nextCall = 1;
  const pending = new Map();
  function call(api, args) {
    if (pending.size >= 32) return Promise.reject(new GridError("Too many calls in flight (max 32)."));
    const id = nextCall++;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      out({ t: "call", call: id, api, args });
    });
  }

  // ---- view builders -------------------------------------------------------------------
  const opt = (o) => (o && typeof o === "object" ? o : {});
  const grid = {
    stack: (children, o) => ({ type: "stack", children: (children || []).filter(Boolean), axis: opt(o).axis, gap: opt(o).gap }),
    row: (children, o) => ({ type: "stack", children: (children || []).filter(Boolean), axis: "h", gap: opt(o).gap }),
    text: (text, o) => ({ type: "text", text: String(text ?? ""), style: opt(o).style, tone: opt(o).tone, lines: opt(o).lines }),
    readout: (label, value, detail) => ({ type: "readout", label: String(label ?? ""), value: String(value ?? ""), detail: detail == null ? undefined : String(detail) }),
    bar: (value, o) => ({ type: "bar", value: Number(value) || 0, warnAbove: opt(o).warnAbove, tone: opt(o).tone }),
    display: (value, o) => ({ type: "display", value: String(value ?? ""), detail: opt(o).detail == null ? undefined : String(opt(o).detail), tone: opt(o).tone }),
    spacer: () => ({ type: "spacer" }),
    sparkline: (values, o) => ({ type: "sparkline", values: (values || []).map(Number), max: opt(o).max }),
    kv: (rows) => ({ type: "kv", rows: (rows || []).map((r) => [String(r[0] ?? ""), String(r[1] ?? "")]) }),
    list: (items) => ({ type: "list", items: items || [] }),
    tag: (text, tone) => ({ type: "tag", text: String(text ?? ""), tone }),
    button: (title, action, o) => ({ type: "button", title: String(title ?? ""), action, prominent: !!opt(o).prominent }),
    divider: () => ({ type: "divider" }),
    progress: (value) => ({ type: "progress", value: value == null ? undefined : Number(value) }),
    empty: (title, message) => ({ type: "empty", title: String(title ?? ""), message: String(message ?? "") }),
    code: (text, o) => ({ type: "code", text: String(text ?? ""), lines: opt(o).lines }),
  };

  grid.action = {
    custom: (id, payload) => ({ kind: "custom", value: String(id), payload }),
    copy: (text) => ({ kind: "copy", value: String(text) }),
    openURL: (url) => ({ kind: "openURL", value: String(url) }),
    revealInFiles: (path) => ({ kind: "revealInFiles", value: String(path) }),
    openFile: (path) => ({ kind: "openFile", value: String(path) }),
    insertPath: (path) => (Array.isArray(path) ? { kind: "insertPath", paths: path.map(String) } : { kind: "insertPath", value: String(path) }),
  };
  // Wraps any action so GRID asks first, in its own native dialog that names the widget.
  grid.confirm = (action, message) => Object.assign({}, action, { confirm: String(message ?? "") });
  // Ask for a re-render soon (coalesced by GRID to at most once a second).
  grid.invalidate = () => out({ t: "invalidate" });

  // ---- API -----------------------------------------------------------------------------
  grid.files = { selection: () => call("files.selection", []), folder: () => call("files.folder", []) };
  grid.fs = {
    stat: (p) => call("fs.stat", [String(p)]),
    list: (p, o) => call("fs.list", [String(p), opt(o)]),
    readText: (p, o) => call("fs.readText", [String(p), opt(o).maxBytes ?? null]),
  };
  grid.terminal = { cwd: () => call("terminal.cwd", []), sessions: () => call("terminal.sessions", []) };
  grid.exec = (command, args) => call("exec", [String(command), (args || []).map(String)]);
  grid.net = { fetch: (url, o) => call("net.fetch", [String(url), opt(o)]) };
  grid.system = { stats: () => call("system.stats", []) };
  grid.storage = {
    get: (k) => call("storage.get", [String(k)]),
    set: (k, v) => call("storage.set", [String(k), v === undefined ? null : v]),
    remove: (k) => call("storage.remove", [String(k)]),
    keys: () => call("storage.keys", []),
    clear: () => call("storage.clear", []),
  };

  // ---- registration --------------------------------------------------------------------
  let widget = null;
  grid.widget = (def) => {
    if (widget) throw new GridError("grid.widget() may only be called once.");
    if (!def || typeof def.render !== "function") throw new GridError("grid.widget() needs a render(ctx) function.");
    widget = def;
  };
  Object.freeze(grid.action);
  let lastTree = null;
  globalThis.grid = grid;

  const errText = (e) => (e && e.message ? (e.name && e.name !== "Error" ? e.name + ": " : "") + e.message : String(e)).slice(0, 1000);

  // ---- routing (GRID → host) -----------------------------------------------------------
  globalThis.__grid_dispatch = function (line) {
    let m;
    try { m = JSON.parse(line); } catch (e) { return; }
    switch (m.t) {
      case "load": {
        try {
          for (const s of m.sources || []) {
            (0, eval)(String(s.code) + "\n//# sourceURL=" + String(s.name).replace(/[^A-Za-z0-9._\/-]/g, "_"));
          }
          if (!widget) throw new GridError("The script never called grid.widget({...}).");
          out({ t: "ready", refresh: typeof widget.refresh === "number" ? widget.refresh : null });
        } catch (e) {
          out({ t: "loadError", error: errText(e) });
        }
        break;
      }
      case "render": {
        Promise.resolve()
          .then(() => widget.render(m.ctx || {}))
          .then((result) => {
            // render may return a tree, or {view, refreshIn} to schedule its next refresh.
            let tree = result, refreshIn;
            if (result && typeof result === "object" && !result.type && "view" in result) { tree = result.view; refreshIn = result.refreshIn; }
            const json = JSON.stringify(tree ?? grid.empty("Nothing to show", ""));
            if (json === lastTree) { out({ t: "view", id: m.id, same: true, refreshIn }); return; }   // unchanged: GRID skips redraw
            lastTree = json;
            send('{"t":"view","id":' + Number(m.id) + (typeof refreshIn === "number" ? ',"refreshIn":' + refreshIn : "") + ',"tree":' + json + "}");
          })
          .catch((e) => out({ t: "renderError", id: m.id, error: errText(e) }));
        break;
      }
      case "action": {
        Promise.resolve()
          .then(() => (typeof widget.onAction === "function" ? widget.onAction(m.action, m.payload, m.ctx || {}) : undefined))
          .then(() => out({ t: "actionDone", id: m.id }))
          .catch((e) => out({ t: "actionDone", id: m.id, error: errText(e) }));
        break;
      }
      case "result": {
        const p = pending.get(m.call);
        if (!p) return;
        pending.delete(m.call);
        if (m.ok) p.resolve(m.value);
        else p.reject(m.kind === "PermissionError" ? new PermissionError(m.error) : new GridError(m.error, m.kind));
        break;
      }
    }
  };
})();
"""#
