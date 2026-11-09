import AppKit
import GridCore
import SwiftUI
import WebKit

/// An article extracted by Readability from the current page.
struct ReaderArticle: Equatable, Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let byline: String?
    let siteName: String?
    let html: String
    let length: Int
}

enum Reader {
    static let world = WKContentWorld.world(name: "grid.reader")

    /// Runs Readability on a clone of the page (the live page is never modified), in GRID's own
    /// script world, and returns the article or nil when the page has none.
    @MainActor
    static func extract(from webView: WKWebView) async -> ReaderArticle? {
        guard let url = webView.url else { return nil }
        let script = readabilityJS + """

        ;(() => {
          try {
            const doc = document.cloneNode(true);
            const r = new Readability(doc, { charThreshold: 400 }).parse();
            if (!r || !r.content || (r.length || 0) < 400) return null;
            // Sanitize in the DOM with an allowlist (regexes can be fooled by nested tags).
            const KEEP = new Set(["P","DIV","SPAN","A","H1","H2","H3","H4","H5","H6","UL","OL","LI","BLOCKQUOTE","PRE","CODE","EM","STRONG",
              "B","I","U","S","SUB","SUP","BR","HR","IMG","FIGURE","FIGCAPTION","TABLE","THEAD","TBODY","TFOOT","TR","TD","TH","CAPTION",
              "DL","DT","DD","SECTION","ARTICLE","HEADER","FOOTER","ASIDE","MAIN","MARK","SMALL","ABBR","CITE","Q","TIME","DETAILS",
              "SUMMARY","KBD","SAMP","VAR","DEL","INS","PICTURE"]);
            const ATTRS = new Set(["href","src","alt","title","colspan","rowspan","width","height","datetime","start","reversed"]);
            const safeURL = (v, img) => { try { const u = new URL(v, location.href);
              return u.protocol === "https:" || u.protocol === "http:" || (img && u.protocol === "data:" && /^data:image\\//i.test(v)) ? u.href : null; } catch (e) { return null; } };
            const clean = new DOMParser().parseFromString(r.content, "text/html");
            const walk = (node) => {
              for (const el of [...node.children]) {
                if (!KEEP.has(el.tagName)) {
                  if (["SCRIPT","STYLE","IFRAME","OBJECT","EMBED","FORM","INPUT","BUTTON","SELECT","TEXTAREA","LINK","META","BASE",
                       "SVG","MATH","TEMPLATE","NOSCRIPT","VIDEO","AUDIO","CANVAS","FRAME","FRAMESET"].includes(el.tagName.toUpperCase())) { el.remove(); continue; }
                  walk(el); el.replaceWith(...el.childNodes); continue;      // unknown wrapper: keep its content
                }
                for (const a of [...el.attributes]) {
                  const n = a.name.toLowerCase();
                  if (!ATTRS.has(n)) { el.removeAttribute(a.name); continue; }
                  if (n === "href" || n === "src") { const s = safeURL(a.value, el.tagName === "IMG"); if (s) el.setAttribute(n, s); else el.removeAttribute(a.name); }
                }
                walk(el);
              }
            };
            walk(clean.body);
            return JSON.stringify({ title: r.title || document.title, byline: r.byline, siteName: r.siteName,
                                    content: clean.body.innerHTML, length: r.length || 0 });
          } catch (e) { return null; }
        })()
        """
        let raw: Any? = await withCheckedContinuation { c in
            webView.evaluateJavaScript(script, in: nil, in: world) { result in
                c.resume(returning: try? result.get())
            }
        }
        guard let s = raw as? String, let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let content = o["content"] as? String else { return nil }
        return ReaderArticle(url: url, title: (o["title"] as? String) ?? (webView.title ?? ""), byline: o["byline"] as? String,
                             siteName: o["siteName"] as? String, html: sanitize(content), length: (o["length"] as? Int) ?? 0)
    }

    /// Defence in depth (the reader view also runs with JavaScript off and a deny-all CSP).
    static func sanitize(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "iframe", "object", "embed", "form", "noscript", "template", "svg", "math", "video", "audio", "canvas"] {
            s = s.replacingOccurrences(of: "<\(tag)\\b[\\s\\S]*?</\(tag)\\s*>", with: "", options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(of: "<\(tag)\\b[^>]*/?>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        for tag in ["link", "meta", "base", "input", "button", "select", "textarea"] {
            s = s.replacingOccurrences(of: "<\(tag)\\b[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "\\s+on[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "\\s+style\\s*=\\s*(\"[^\"]*\"|'[^']*')", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "(href|src)\\s*=\\s*([\"'])\\s*(javascript|vbscript|data):[^\"']*\\2", with: "$1=\"#\"", options: [.regularExpression, .caseInsensitive])
        return s
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The reader page: GRID typography, numbered links, deny-all CSP (images allowed).
    static func page(_ a: ReaderArticle, theme: Theme, fontSize: Int) -> String {
        let site = a.siteName ?? a.url.host ?? ""
        let minutes = max(1, a.length / 1100)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http: data:; style-src 'unsafe-inline'">
        <meta name="viewport" content="width=device-width">
        <style>
        \(SiteThemes.tokens(theme))
        html { background: var(--grid-bg1); }
        body { counter-reset: link; margin: 0; padding: 28px 32px 80px; color: var(--grid-text); background: var(--grid-bg1);
               font: \(fontSize)px/1.65 var(--grid-mono); -webkit-font-smoothing: antialiased; }
        main { max-width: 74ch; margin: 0 auto; }
        header { border-left: 2px solid var(--grid-accent); padding: 2px 0 2px 14px; margin-bottom: 26px; }
        .tag { display: inline-block; background: var(--grid-accent); color: var(--grid-on-accent); font-size: 9px; font-weight: 700;
               letter-spacing: 1px; padding: 1px 5px; text-transform: uppercase; }
        .meta { color: var(--grid-mute); font-size: 10.5px; letter-spacing: 1.2px; text-transform: uppercase; margin-top: 10px; }
        h1.title { font-size: 1.55em; font-weight: 500; line-height: 1.3; margin: 10px 0 0; color: var(--grid-text); }
        h1, h2, h3, h4, h5, h6 { font-weight: 600; line-height: 1.35; color: var(--grid-text); margin: 1.8em 0 .6em; }
        h2 { font-size: 1.25em; border-bottom: 1px solid var(--grid-line); padding-bottom: 6px; }
        h3 { font-size: 1.08em; } h4, h5, h6 { font-size: 1em; color: var(--grid-dim); }
        p, li { color: var(--grid-text); } p { margin: 0 0 1.1em; }
        a { color: var(--grid-accent); text-decoration: none; border-bottom: 1px solid var(--grid-line); }
        a::after { counter-increment: link; content: "[" counter(link) "]"; color: var(--grid-mute); font-size: .7em;
                   vertical-align: super; margin-left: 1px; }
        a:hover { border-bottom-color: var(--grid-accent); }
        img, figure { max-width: 100%; height: auto; } figure { margin: 1.4em 0; }
        img { border: 1px solid var(--grid-line); background: var(--grid-bg3); }
        figcaption { color: var(--grid-mute); font-size: .85em; margin-top: 6px; }
        blockquote { margin: 1.2em 0; padding: 2px 0 2px 14px; border-left: 2px solid var(--grid-line-strong); color: var(--grid-dim); }
        pre, code { font-family: var(--grid-mono); } code { background: var(--grid-bg3); padding: 1px 4px; border: 1px solid var(--grid-line); font-size: .92em; }
        pre { background: var(--grid-bg3); border: 1px solid var(--grid-line); padding: 12px 14px; overflow-x: auto; line-height: 1.5; }
        pre code { border: 0; padding: 0; background: none; }
        hr { border: 0; border-top: 1px solid var(--grid-line); margin: 2em 0; }
        table { border-collapse: collapse; width: 100%; font-size: .92em; } td, th { border: 1px solid var(--grid-line); padding: 5px 8px; text-align: left; }
        th { background: var(--grid-bg2); color: var(--grid-dim); font-weight: 600; }
        ::selection { background: var(--grid-accent-soft); }
        </style></head><body><main>
        <header><span class="tag">Reader view — simplified</span>
          <h1 class="title">\(escape(a.title))</h1>
          <div class="meta">\(escape(site))\(a.byline.map { " · " + escape($0) } ?? "") · \(minutes) min read</div>
        </header>
        \(a.html)
        </main></body></html>
        """
    }
}

/// Shows a reader article. JavaScript is off, the CSP denies everything but images, and the store
/// is ephemeral; clicking a link opens it in the tab (leaving reader view).
struct ReaderView: NSViewRepresentable {
    let article: ReaderArticle
    let theme: Theme
    let fontSize: Int
    let openLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(openLink: openLink) }
    #if DEBUG
    @MainActor static weak var lastWebView: WKWebView?
    #endif

    func makeNSView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .nonPersistent()
        c.defaultWebpagePreferences.allowsContentJavaScript = false
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        let w = GridWebView(frame: .zero, configuration: c)
        w.navigationDelegate = context.coordinator
        w.underPageBackgroundColor = NSColor(theme.bg1)
        w.appearance = NSAppearance(named: .darkAqua)
        #if DEBUG
        ReaderView.lastWebView = w
        #endif
        return w
    }

    func updateNSView(_ w: WKWebView, context: Context) {
        context.coordinator.openLink = openLink
        let key = "\(article.id)|\(theme.id)|\(fontSize)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        w.underPageBackgroundColor = NSColor(theme.bg1)
        context.coordinator.expectingLoad = true
        w.loadHTMLString(Reader.page(article, theme: theme, fontSize: fontSize), baseURL: article.url)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var openLink: (URL) -> Void
        var loadedKey = ""
        init(openLink: @escaping (URL) -> Void) { self.openLink = openLink }

        /// Set right before each loadHTMLString: exactly one navigation (ours) may load.
        var expectingLoad = false

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if expectingLoad && action.navigationType == .other && action.targetFrame?.isMainFrame == true {
                expectingLoad = false
                decisionHandler(.allow); return     // the loadHTMLString GRID just issued
            }
            if action.targetFrame?.isMainFrame == false { decisionHandler(.cancel); return }
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated, let u = action.request.url, u.fragment == nil || u.path != webView.url?.path {
                MainActor.assumeIsolated { openLink(u) }
            }
        }
    }
}
