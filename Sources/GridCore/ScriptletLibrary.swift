import Foundation

/// GRID's own implementations of the uBlock Origin scriptlets that `ScriptletIndex` accepts.
///
/// `script(host:calls:)` builds the user script for one site: it runs in the page's own JavaScript
/// world at document start (scriptlets have to patch the page's `fetch`, `JSON.parse` and so on before
/// the page uses them), and does nothing on any other host. Filter lists supply only the calls'
/// names and string arguments, embedded as JSON data. The script talks to nothing outside the page:
/// no message handlers, no GRID APIs.
///
/// Patched functions are wrapped in `Proxy` objects so they keep looking native to the page.
public enum ScriptletLibrary {
    public static func script(host: String, calls: [[String]]) -> String {
        let hostJSON = json(host)
        let callsJSON = (try? JSONSerialization.data(withJSONObject: calls)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "(() => {\n'use strict';\nif (location.hostname !== \(hostJSON)) return;\nconst CALLS = \(callsJSON);\n\(source)\n})();\n"
    }

    private static func json(_ s: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [s])).flatMap { String(data: $0.dropFirst().dropLast(), encoding: .utf8) } ?? "\"\""
    }

    /// The library body. Expects `CALLS` (`[[name, args…]]`) in scope.
    static let source = #"""
const W = globalThis;
const R = Reflect;
const defineProperty = Object.defineProperty;
const gOPD = Object.getOwnPropertyDescriptor;
const hasOwn = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const JSONparse = JSON.parse;
const JSONstringify = JSON.stringify;
const fnToString = Function.prototype.toString;
const setTimeoutNative = W.setTimeout;
const addListenerNative = typeof EventTarget === 'function' ? EventTarget.prototype.addEventListener : null;
const noop = function () {};
const isObj = v => v !== null && (typeof v === 'object' || typeof v === 'function');
const later = fn => R.apply(setTimeoutNative, W, [fn, 1]);
const listen = (target, type, fn, options) => { if (addListenerNative) R.apply(addListenerNative, target, [type, fn, options]); };

// ---- Patterns: "/re/flags" is a regular expression, anything else a literal substring.
const escapeRE = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const toRegex = (pattern, flags = '') => {
  if (pattern === '') return /^/;
  const m = /^\/(.+)\/([gimsu]*)$/.exec(pattern);
  try { return m ? new RegExp(m[1], m[2] || flags) : new RegExp(escapeRE(pattern), flags); } catch (e) { return null; }
};
// A leading "!" negates. An unusable regex matches nothing.
const matcher = pattern => {
  let not = false;
  if (pattern.startsWith('!')) { not = true; pattern = pattern.slice(1); }
  const re = toRegex(pattern);
  if (re === null) return () => false;
  return s => re.test(s) !== not;
};
const fnText = f => {
  try {
    if (typeof f === 'function') return R.apply(fnToString, f, []);
    if (isObj(f) && typeof f.handleEvent === 'function') return R.apply(fnToString, f.handleEvent, []);
    return String(f);
  } catch (e) { return ''; }
};
// Patched functions are Proxies of the originals. WebKit prints a Proxy as "function ProxyObject()",
// so Function.prototype.toString answers for the original instead, and hides itself the same way.
const disguised = new WeakMap();
let toStringPatched = false;
const disguise = (proxy, original) => {
  if (!toStringPatched) {
    toStringPatched = true;
    const toString = new Proxy(fnToString, {
      apply: (target, thisArg, args) => R.apply(target, disguised.has(thisArg) ? disguised.get(thisArg) : thisArg, args),
    });
    disguised.set(toString, fnToString);
    try { Function.prototype.toString = toString; } catch (e) {}
  }
  disguised.set(proxy, original);
  return proxy;
};
const wrap = (owner, prop, apply) => {
  const original = owner && owner[prop];
  if (typeof original !== 'function') return;
  try { owner[prop] = disguise(new Proxy(original, { apply }), original); } catch (e) {}
};

// ---- Aborting a script: a ReferenceError the page's error handlers don't get to see.
let magic = '';
const abortError = () => {
  if (magic === '') {
    magic = 'grid-' + Math.random().toString(36).slice(2);
    listen(W, 'error', e => { if (typeof e.message === 'string' && e.message.includes(magic)) e.preventDefault(); }, true);
  }
  return new ReferenceError(magic);
};

// ---- Property chains ("a.b.c"): runs onLeaf(owner, "c") once a.b exists, now or when assigned.
const trapChain = (owner, chain, onLeaf) => {
  const pos = chain.indexOf('.');
  if (pos === -1) { onLeaf(owner, chain); return; }
  const prop = chain.slice(0, pos);
  const rest = chain.slice(pos + 1);
  const current = owner[prop];
  if (isObj(current)) { trapChain(current, rest, onLeaf); return; }
  const d = gOPD(owner, prop);
  if (d && d.configurable === false) return;
  const prevGet = d && d.get;
  const prevSet = d && d.set;
  let value = current;
  try {
    defineProperty(owner, prop, {
      configurable: true,
      enumerable: d ? d.enumerable : true,
      get() { return prevGet ? R.apply(prevGet, owner, []) : value; },
      set(a) {
        if (prevSet) R.apply(prevSet, owner, [a]); else value = a;
        if (isObj(a)) trapChain(a, rest, onLeaf);
      },
    });
  } catch (e) {}
};

// ---- set-constant
const constants = {
  'undefined': () => undefined, 'null': () => null, 'false': () => false, 'true': () => true,
  '': () => '', "''": () => '', 'emptyStr': () => '', 'NaN': () => NaN, 'Infinity': () => Infinity,
  '{}': () => ({}), 'emptyObj': () => ({}), '[]': () => [], 'emptyArr': () => [],
  'noopFunc': () => function () {}, 'trueFunc': () => function () { return true; },
  'falseFunc': () => function () { return false; }, 'throwFunc': () => function () { throw new Error(); },
  'noopPromiseResolve': () => function () { return Promise.resolve(); },
  'noopPromiseReject': () => function () { return Promise.reject(); },
  'yes': () => 'yes', 'no': () => 'no', 'on': () => 'on', 'off': () => 'off',
  'accept': () => 'accept', 'accepted': () => 'accepted', 'reject': () => 'reject', 'rejected': () => 'rejected',
  'allowed': () => 'allowed', 'denied': () => 'denied', 'ok': () => 'ok',
};
const constantValue = (raw, trusted) => {
  if (hasOwn(constants, raw)) return { v: constants[raw]() };
  if (/^-?\d+$/.test(raw)) {
    const n = parseInt(raw, 10);
    if (Math.abs(n) <= 0x7FFF) return { v: n };
  }
  if (!trusted) return null;
  try {
    const parsed = JSONparse(raw);
    return { v: isObj(parsed) && hasOwn(parsed, 'value') ? parsed.value : parsed };
  } catch (e) { return { v: raw }; }
};
const setConstant = trusted => (chain = '', raw, as = '') => {
  if (chain === '' || raw === undefined) return;
  const c = constantValue(raw, trusted);
  if (c === null) return;
  let value = c.v;
  if (as === 'asFunction') { const v = value; value = function () { return v; }; }
  else if (as === 'asCallback') { const v = value; value = function () { return function () { return v; }; }; }
  else if (as === 'asResolved') value = Promise.resolve(value);
  else if (as === 'asRejected') { const p = Promise.reject(value); p.catch(noop); value = p; }
  trapChain(W, chain, (owner, prop) => {
    const d = gOPD(owner, prop);
    if (d && d.configurable === false) return;
    const prevGet = d && d.get;
    const prevSet = d && d.set;
    // If the site assigns a value of another type, step aside rather than break it.
    let released = false;
    let assigned;
    try {
      defineProperty(owner, prop, {
        configurable: true,
        enumerable: d ? d.enumerable : true,
        get() {
          if (released) return assigned;
          if (prevGet) R.apply(prevGet, owner, []);
          return value;
        },
        set(a) {
          if (prevSet) R.apply(prevSet, owner, [a]);
          if (released) { assigned = a; return; }
          if (value !== undefined && value !== null && a !== undefined && a !== null && typeof a !== typeof value) {
            released = true;
            assigned = a;
          }
        },
      });
    } catch (e) {}
  });
};

// ---- Aborting scripts
const abortOnRead = (chain = '') => {
  if (chain === '') return;
  trapChain(W, chain, (owner, prop) => {
    const d = gOPD(owner, prop);
    if (d && d.configurable === false) return;
    try { defineProperty(owner, prop, { configurable: true, get() { throw abortError(); }, set() {} }); } catch (e) {}
  });
};
const resolveOwner = chain => {
  let owner = W;
  for (;;) {
    const pos = chain.indexOf('.');
    if (pos === -1) return [owner, chain];
    owner = owner[chain.slice(0, pos)];
    if (!isObj(owner)) return null;
    chain = chain.slice(pos + 1);
  }
};
const abortOnWrite = (chain = '') => {
  const r = chain === '' ? null : resolveOwner(chain);
  if (r === null) return;
  const [owner, prop] = r;
  const d = gOPD(owner, prop);
  if (d && d.configurable === false) return;
  try {
    delete owner[prop];
    defineProperty(owner, prop, { configurable: true, set() { throw abortError(); } });
  } catch (e) {}
};
const abortCurrentScript = (chain = '', needle = '', context = '') => {
  const r = chain === '' ? null : resolveOwner(chain);
  if (r === null) return;
  const [owner, prop] = r;
  const reNeedle = needle === '' ? null : toRegex(needle, 's');
  const reContext = context === '' ? null : toRegex(context);
  if (reNeedle === null && needle !== '') return;
  const d = gOPD(owner, prop);
  if (d && d.configurable === false) return;
  let value = d && d.get ? undefined : owner[prop];
  const validate = () => {
    const e = document.currentScript;
    if (!(e instanceof HTMLScriptElement)) return;
    if (reContext !== null && !reContext.test(e.src)) return;
    if (reNeedle !== null && !reNeedle.test(e.src === '' ? e.textContent : '')) return;
    throw abortError();
  };
  try {
    defineProperty(owner, prop, {
      configurable: true,
      get() { validate(); return d && d.get ? R.apply(d.get, owner, []) : value; },
      set(a) { validate(); if (d && d.set) R.apply(d.set, owner, [a]); else value = a; },
    });
  } catch (e) {}
};

// ---- Timers, popups, listeners, eval
const timerDefuser = name => (needle = '', delay = '') => {
  if (needle === '' && delay === '') return;
  const matches = needle === '' ? () => true : matcher(needle);
  let delayNot = false;
  if (delay.startsWith('!')) { delayNot = true; delay = delay.slice(1); }
  const ms = parseInt(delay, 10);
  wrap(W, name, (target, thisArg, args) => {
    let defuse = matches(fnText(args[0]));
    if (defuse && delay !== '') defuse = ((Number(args[1]) || 0) === ms) !== delayNot;
    if (!defuse) return R.apply(target, thisArg, args);
    const copy = Array.from(args);
    copy[0] = noop;
    return R.apply(target, thisArg, copy);
  });
};
const timerBooster = name => (needle = '', delay = '', boost = '') => {
  const matches = needle === '' || needle === '*' ? () => true : matcher(needle);
  const ms = delay === '*' ? -1 : (parseInt(delay, 10) || 1000);
  let factor = parseFloat(boost);
  if (!isFinite(factor)) factor = 0.05;
  factor = Math.min(Math.max(factor, 0.001), 50);
  wrap(W, name, (target, thisArg, args) => {
    const given = Number(args[1]) || 0;
    if ((ms !== -1 && given !== ms) || !matches(fnText(args[0]))) return R.apply(target, thisArg, args);
    const copy = Array.from(args);
    copy[1] = given * factor;
    return R.apply(target, thisArg, copy);
  });
};
const noWindowOpenIf = (pattern = '') => {
  const matches = matcher(pattern);
  wrap(W, 'open', (target, thisArg, args) => {
    if (!matches(String(args[0] === undefined ? '' : args[0]))) return R.apply(target, thisArg, args);
    return null;
  });
};
const listenerDefuser = (type = '', pattern = '') => {
  if (type === '' && pattern === '') return;
  const typeMatches = type === '' ? () => true : matcher(type);
  const handlerMatches = pattern === '' ? () => true : matcher(pattern);
  if (typeof EventTarget !== 'function') return;
  wrap(EventTarget.prototype, 'addEventListener', (target, thisArg, args) => {
    if (typeMatches(String(args[0])) && handlerMatches(fnText(args[1]))) return undefined;
    return R.apply(target, thisArg, args);
  });
};
const noEvalIf = (needle = '') => {
  const matches = needle === '' ? () => true : matcher(needle);
  wrap(W, 'eval', (target, thisArg, args) => {
    if (matches(String(args[0]))) return undefined;
    return R.apply(target, thisArg, args);
  });
};

// ---- The DOM
const removeNodeText = (nodeName = '', pattern = '') => {
  if (nodeName === '' || pattern === '' || typeof MutationObserver !== 'function') return;
  const name = nodeName.toLowerCase();
  const re = toRegex(pattern, 'ms');
  if (re === null) return;
  const handle = node => {
    if (node.nodeName.toLowerCase() !== name) return;
    const text = node.textContent;
    if (text && re.test(text)) node.textContent = '';
  };
  // Parser-inserted scripts can be emptied before they run; stop once parsing is over.
  const observer = new MutationObserver(records => {
    for (const r of records) for (const n of r.addedNodes) handle(n);
  });
  observer.observe(document, { childList: true, subtree: true });
  listen(document, 'DOMContentLoaded', () => {
    for (const r of observer.takeRecords()) for (const n of r.addedNodes) handle(n);
    observer.disconnect();
  }, { once: true });
};
const removeFrom = kind => (raw = '', selector = '', behavior = '') => {
  const names = raw.split(/\s*\|\s*/).filter(Boolean);
  if (names.length === 0 || typeof document === 'undefined') return;
  const sel = selector !== '' ? selector : names.map(n => kind === 'attr' ? `[${CSS.escape(n)}]` : `.${CSS.escape(n)}`).join(',');
  const run = () => {
    let elements;
    try { elements = document.querySelectorAll(sel); } catch (e) { return; }
    for (const el of elements) for (const n of names) {
      if (kind === 'attr') el.removeAttribute(n); else el.classList.remove(n);
    }
  };
  const tokens = behavior.split(/\s+/);
  const start = () => {
    run();
    if (!tokens.includes('stay')) return;
    let queued = false;
    new MutationObserver(() => {
      if (queued) return;
      queued = true;
      later(() => { queued = false; run(); });
    }).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: kind === 'attr' ? names : ['class'] });
  };
  if (tokens.includes('asap')) run();
  if (tokens.includes('complete')) {
    if (document.readyState === 'complete') start(); else listen(W, 'load', start, { once: true });
  } else if (document.readyState === 'loading') {
    listen(document, 'DOMContentLoaded', start, { once: true });
  } else {
    start();
  }
};

// ---- JSON pruning: paths like "a.b", "[].a" (every array element), "*.a", "list.[-].ad" (drop elements that have .ad)
const keysOf = o => Array.isArray(o) ? o.map((_, i) => i) : Object.keys(o);
const hasPath = (obj, segs, i) => {
  if (i === segs.length) return true;
  if (!isObj(obj)) return false;
  const s = segs[i];
  if (s === '[]' || s === '*' || s === '[-]') return keysOf(obj).some(k => hasPath(obj[k], segs, i + 1));
  return hasOwn(obj, s) && hasPath(obj[s], segs, i + 1);
};
const prunePath = (obj, segs, i) => {
  if (!isObj(obj) || i >= segs.length) return false;
  const s = segs[i];
  const last = i === segs.length - 1;
  if (s === '[-]') {
    if (!Array.isArray(obj) || last) return false;
    let removed = false;
    for (let k = obj.length - 1; k >= 0; k--) {
      if (hasPath(obj[k], segs, i + 1)) { obj.splice(k, 1); removed = true; }
    }
    return removed;
  }
  if (s === '[]' || s === '*') {
    if (last) return false;
    let removed = false;
    for (const k of keysOf(obj)) removed = prunePath(obj[k], segs, i + 1) || removed;
    return removed;
  }
  if (!hasOwn(obj, s)) return false;
  if (last) { delete obj[s]; return true; }
  return prunePath(obj[s], segs, i + 1);
};
const pruner = (rawPrune = '', rawNeedles = '') => {
  const prune = rawPrune.split(/\s+/).filter(Boolean).map(p => p.split('.'));
  const needles = rawNeedles.split(/\s+/).filter(Boolean).map(p => p.split('.'));
  if (prune.length === 0) return null;
  return obj => {
    if (!isObj(obj)) return false;
    if (needles.length !== 0 && !needles.every(n => hasPath(obj, n, 0))) return false;
    let changed = false;
    for (const p of prune) { try { changed = prunePath(obj, p, 0) || changed; } catch (e) {} }
    return changed;
  };
};
const jsonPruners = [];
const jsonPrune = (rawPrune = '', rawNeedles = '', stackNeedle = '') => {
  if (stackNeedle !== '') return;   // needs the call stack; not supported
  const p = pruner(rawPrune, rawNeedles);
  if (p === null) return;
  if (jsonPruners.length === 0) {
    wrap(JSON, 'parse', (target, thisArg, args) => {
      const obj = R.apply(target, thisArg, args);
      for (const f of jsonPruners) f(obj);
      return obj;
    });
    if (typeof Response === 'function') {
      wrap(Response.prototype, 'json', (target, thisArg, args) =>
        R.apply(target, thisArg, args).then(obj => { for (const f of jsonPruners) f(obj); return obj; }));
    }
  }
  jsonPruners.push(p);
};

// ---- Requests: "propsToMatch" is "url-pattern" or "key:pattern" pairs (url, method, body), all must match.
const requestMatcher = (raw = '') => {
  const tests = [];
  for (const token of raw.split(/\s+/).filter(Boolean)) {
    const c = token.indexOf(':');
    const key = c > 0 ? token.slice(0, c) : '';
    if (key === 'url' || key === 'method' || key === 'body') tests.push([key, matcher(token.slice(c + 1))]);
    else if (/^[a-zA-Z]+$/.test(key) && !/^https?$/.test(key)) return () => false;   // a property GRID can't check
    else tests.push(['url', matcher(token)]);
  }
  return info => tests.every(([key, test]) => test(String(info[key])));
};
const extraArgs = rest => {
  const out = {};
  for (let i = 0; i + 1 < rest.length; i += 2) out[rest[i]] = rest[i + 1];
  return out;
};
const responseBody = (raw, trusted) => {
  if (raw === 'emptyObj' || raw === '{}') return '{}';
  if (raw === 'emptyArr' || raw === '[]') return '[]';
  if (raw === 'true') return Math.random().toString(36).slice(2);
  return trusted ? raw : '';
};
const absolute = url => { try { return new URL(String(url), W.location.href).href; } catch (e) { return String(url); } };
// Text edits run first, then JSON pruning; returns the new text, or null when nothing changed.
const transformText = (text, transforms) => {
  let out = text;
  for (const t of transforms) if (t.text) out = t.text(out);
  if (transforms.some(t => t.json)) {
    let obj;
    try { obj = JSONparse(out); } catch (e) { obj = undefined; }
    if (isObj(obj)) {
      let changed = false;
      for (const t of transforms) if (t.json) changed = t.json(obj) || changed;
      if (changed) out = JSONstringify(obj);
    }
  }
  return out === text ? null : out;
};

const fetchBlocks = [];
const fetchTransforms = [];
let fetchWrapped = false;
const wrapFetch = () => {
  if (fetchWrapped || typeof W.fetch !== 'function') return;
  fetchWrapped = true;
  const requestInfo = args => {
    const [input, init] = args;
    const info = { url: '', method: 'GET', body: '' };
    try {
      if (typeof Request === 'function' && input instanceof Request) { info.url = input.url; info.method = input.method; }
      else info.url = absolute(input);
      if (init && init.method) info.method = String(init.method);
      if (init && typeof init.body === 'string') info.body = init.body;
    } catch (e) {}
    info.method = info.method.toUpperCase();
    return info;
  };
  wrap(W, 'fetch', (target, thisArg, args) => {
    const info = requestInfo(args);
    for (const b of fetchBlocks) {
      if (!b.match(info)) continue;
      const fake = new Response(b.body, { status: 200, statusText: 'OK' });
      try { defineProperty(fake, 'url', { value: info.url }); } catch (e) {}
      return Promise.resolve(fake);
    }
    const transforms = fetchTransforms.filter(t => t.match(info));
    const pending = R.apply(target, thisArg, args);
    if (transforms.length === 0) return pending;
    return pending.then(response => {
      const type = response.headers.get('content-type') || '';
      if (response.type === 'opaque' || [101, 204, 205, 304].includes(response.status) || /^(video|audio|image)\/|octet-stream|protobuf/.test(type)) return response;
      return response.clone().text().then(text => {
        const out = transformText(text, transforms);
        if (out === null) return response;
        const replaced = new Response(out, { status: response.status, statusText: response.statusText, headers: response.headers });
        try {
          defineProperty(replaced, 'url', { value: response.url });
          defineProperty(replaced, 'type', { value: response.type });
          defineProperty(replaced, 'redirected', { value: response.redirected });
        } catch (e) {}
        return replaced;
      }).catch(() => response);
    });
  });
};

const xhrBlocks = [];
const xhrTransforms = [];
const xhrState = new WeakMap();
let xhrWrapped = false;
const wrapXHR = () => {
  if (xhrWrapped || typeof XMLHttpRequest !== 'function') return;
  xhrWrapped = true;
  const P = XMLHttpRequest.prototype;
  wrap(P, 'open', (target, thisArg, args) => {
    xhrState.set(thisArg, { method: String(args[0] || 'GET').toUpperCase(), url: absolute(args[1]) });
    return R.apply(target, thisArg, args);
  });
  wrap(P, 'send', (target, thisArg, args) => {
    const st = xhrState.get(thisArg);
    if (st) {
      const info = { url: st.url, method: st.method, body: typeof args[0] === 'string' ? args[0] : '' };
      const block = xhrBlocks.find(b => b.match(info));
      if (block) { fakeXHR(thisArg, st, block.body); return undefined; }
      st.transforms = xhrTransforms.filter(t => t.match(info));
      st.cache = {};
    }
    return R.apply(target, thisArg, args);
  });
  const getter = (name, fn) => {
    const d = gOPD(P, name);
    if (!d || typeof d.get !== 'function') return;
    const get = disguise(new Proxy(d.get, { apply: (target, thisArg, args) => fn(thisArg, () => R.apply(target, thisArg, args)) }), d.get);
    try { defineProperty(P, name, { configurable: d.configurable, enumerable: d.enumerable, get, set: d.set }); } catch (e) {}
  };
  for (const name of ['readyState', 'status', 'statusText', 'responseURL']) {
    getter(name, (x, original) => { const st = xhrState.get(x); return st && st.fake ? st.fake[name] : original(); });
  }
  for (const name of ['response', 'responseText']) {
    getter(name, (x, original) => {
      const st = xhrState.get(x);
      if (st && st.fake) return st.fake[name];
      const value = original();
      if (!st || !st.transforms || st.transforms.length === 0 || x.readyState !== 4) return value;
      if (hasOwn(st.cache, name)) return st.cache[name];
      let out = value;
      if (typeof value === 'string') {
        const t = transformText(value, st.transforms);
        if (t !== null) out = t;
      } else if (isObj(value) && !(value instanceof ArrayBuffer) && !(typeof Blob === 'function' && value instanceof Blob)) {
        for (const t of st.transforms) if (t.json) t.json(value);
      }
      st.cache[name] = out;
      return out;
    });
  }
};
// A request that is never sent but completes as if the server had answered `body`.
const fakeXHR = (x, st, body) => {
  st.fake = { readyState: 1, status: 0, statusText: '', response: '', responseText: '', responseURL: '' };
  later(() => {
    const type = x.responseType;
    let response = body;
    if (type === 'json') { try { response = JSONparse(body); } catch (e) { response = null; } }
    else if (type !== '' && type !== 'text') response = null;
    st.fake = { readyState: 4, status: 200, statusText: 'OK', response, responseText: type === '' || type === 'text' ? body : '', responseURL: st.url };
    x.dispatchEvent(new Event('readystatechange'));
    for (const t of ['load', 'loadend']) x.dispatchEvent(typeof ProgressEvent === 'function' ? new ProgressEvent(t) : new Event(t));
  });
};

const blockRequests = (list, install, trusted) => (props = '', body = '') => {
  if (props === '') return;   // uBlock only logs requests without a filter
  list.push({ match: requestMatcher(props), body: responseBody(body, trusted) });
  install();
};
const pruneResponses = (list, install) => (rawPrune = '', rawNeedles = '', ...rest) => {
  const p = pruner(rawPrune, rawNeedles);
  if (p === null) return;
  list.push({ match: requestMatcher(extraArgs(rest).propsToMatch || ''), json: p });
  install();
};
const replaceResponses = (list, install) => (pattern = '', replacement = '', props = '') => {
  if (pattern === '') return;
  const re = toRegex(pattern, 'gms');
  if (re === null) return;
  list.push({ match: requestMatcher(props), text: s => s.replace(re, replacement) });
  install();
};

const scriptlets = {
  'set-constant': setConstant(false),
  'trusted-set-constant': setConstant(true),
  'abort-on-property-read': abortOnRead,
  'abort-on-property-write': abortOnWrite,
  'abort-current-script': abortCurrentScript,
  'no-window-open-if': noWindowOpenIf,
  'no-setTimeout-if': timerDefuser('setTimeout'),
  'no-setInterval-if': timerDefuser('setInterval'),
  'nano-setTimeout-booster': timerBooster('setTimeout'),
  'nano-setInterval-booster': timerBooster('setInterval'),
  'addEventListener-defuser': listenerDefuser,
  'noeval': () => noEvalIf(''),
  'noeval-if': noEvalIf,
  'remove-node-text': removeNodeText,
  'remove-attr': removeFrom('attr'),
  'remove-class': removeFrom('class'),
  'json-prune': jsonPrune,
  'json-prune-fetch-response': pruneResponses(fetchTransforms, wrapFetch),
  'json-prune-xhr-response': pruneResponses(xhrTransforms, wrapXHR),
  'trusted-replace-fetch-response': replaceResponses(fetchTransforms, wrapFetch),
  'trusted-replace-xhr-response': replaceResponses(xhrTransforms, wrapXHR),
  'no-fetch-if': blockRequests(fetchBlocks, wrapFetch, false),
  'trusted-prevent-fetch': blockRequests(fetchBlocks, wrapFetch, true),
  'no-xhr-if': blockRequests(xhrBlocks, wrapXHR, false),
  'trusted-prevent-xhr': blockRequests(xhrBlocks, wrapXHR, true),
};
for (const call of CALLS) {
  const f = hasOwn(scriptlets, call[0]) ? scriptlets[call[0]] : null;
  if (f === null) continue;
  try { f(...call.slice(1).map(String)); } catch (e) {}
}
"""#
}
