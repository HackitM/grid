# Hacker News

Top/best/new/ask/show stories. A row click opens the article (or the comments page, per setting)
in your browser.

## Permissions

- `net` `hacker-news.firebaseio.com` — the public HN API, https only, no cookies.
- `openURL` `"any"` — story links point at arbitrary sites, so clicking a row may open any https
  URL in your browser. This only happens on your click; the widget can't fetch from those hosts.

## Still open

- A row has exactly one action, and there is no hook after a built-in action runs, so "dim the
  stories I've already opened" can't be implemented (that would need `onActionPerformed` or a
  `then:` chain on built-in actions).
