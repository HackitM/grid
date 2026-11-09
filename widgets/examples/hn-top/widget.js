// Hacker News — net fetcher with many requests per render (1 + N), storage caching, and
// `openURL: "any"` so rows can open arbitrary article hosts on click.

const API = "https://hacker-news.firebaseio.com/v0/";
const ITEM_TTL = 15 * 60 * 1000;

async function json(url) {
  const r = await grid.net.fetch(url, { method: "GET" });
  if (r.status !== 200) throw new Error("HTTP " + r.status + " for " + url);
  return JSON.parse(r.text);
}

function host(u) {
  const m = /^https?:\/\/([^/]+)/.exec(u || "");
  return m ? m[1].replace(/^www\./, "") : "";
}

grid.widget({
  refresh: 300,
  async render(ctx) {
    const feed = ctx.settings.feed + "stories";
    const count = ctx.settings.count;
    const cache = (await grid.storage.get("items")) || {};

    let ids;
    try {
      ids = (await json(API + feed + ".json")).slice(0, count * 2);
      await grid.storage.set("last:" + feed, ids);
    } catch (e) {
      ids = await grid.storage.get("last:" + feed);   // offline: reuse the last id list
      if (!ids) throw e;
    }

    // 1 + up to 2N requests per render at a 5-minute refresh ≈ 3–8/min, under the 30/min bucket
    // (burst 10). Items are cached so unchanged stories cost nothing; RateLimited just means we
    // show what we have.
    const items = [];
    for (const id of ids) {
      if (items.length >= count) break;
      let it = cache[id];
      if (!it || Date.now() - it.at > ITEM_TTL) {
        try {
          const full = await json(API + "item/" + id + ".json");
          if (!full || full.dead || full.deleted) continue;
          it = { at: Date.now(), t: full.title, u: full.url || null, s: full.score || 0, c: full.descendants || 0, id };
          cache[id] = it;
        } catch (e) {
          if (e.name === "RateLimited" || e.name === "NetworkError") { if (it) items.push(it); continue; }
          continue;
        }
      }
      if (it.s >= ctx.settings.minScore) items.push(it);
    }
    for (const k of Object.keys(cache)) if (!ids.includes(+k)) delete cache[k];   // keep storage small
    await grid.storage.set("items", cache);

    const comments = (it) => "https://news.ycombinator.com/item?id=" + it.id;
    const rows = items.map(it => ({
      title: it.t,
      subtitle: host(it.u) || "news.ycombinator.com",
      trailing: it.s + "▲ · " + it.c + " cm",
      // openURL is https-only; plain-http article links fall back to the comments page.
      action: grid.action.openURL(ctx.settings.open === "comments" || !/^https:\/\//.test(it.u || "") ? comments(it) : it.u)
    }));

    return grid.stack([
      rows.length ? grid.list(rows) : grid.empty("No stories", "Nothing above " + ctx.settings.minScore + " points right now."),
      grid.text("hn · " + ctx.settings.feed + " · every 5 min · click opens " + ctx.settings.open, { style: "label", tone: "mute" })
    ]);
  }
});
