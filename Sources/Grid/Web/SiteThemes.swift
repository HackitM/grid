import AppKit
import GridCore
import Observation
import SwiftUI
import WebKit

/// Per-site GRID themes for well-known sites. Each pack is plain CSS that maps the site's own
/// design tokens (CSS variables) to GRID's palette, so layouts stay intact and only colours and
/// type change. Packs are opt-in per site, toggled from the toolbar, and remembered.
///
/// Injection: one user script in an isolated content world (`grid.themes`) adds the pack as a
/// constructed stylesheet (`adoptedStyleSheets`, which strict `style-src` policies don't block),
/// falling back to a `<style>` element. Page scripts can't see or call it.
@Observable
@MainActor
final class SiteThemes {
    static let world = WKContentWorld.world(name: "grid.themes")

    private(set) var enabled: [String: Bool] { didSet { save() } }
    /// Turn themes on automatically for every supported site (individual sites can still opt out).
    var allByDefault: Bool { didSet { UserDefaults.standard.set(allByDefault, forKey: "browser.themes.all"); onChange?() } }
    @ObservationIgnored var onChange: (() -> Void)?

    init() {
        enabled = (UserDefaults.standard.dictionary(forKey: "browser.themes") as? [String: Bool]) ?? [:]
        allByDefault = UserDefaults.standard.bool(forKey: "browser.themes.all")
    }

    private func save() { UserDefaults.standard.set(enabled, forKey: "browser.themes") }

    func isEnabled(_ id: String) -> Bool { enabled[id] ?? allByDefault }

    func setEnabled(_ id: String, _ on: Bool) {
        enabled[id] = on
        onChange?()
    }

    /// The script every tab carries: picks the pack for the page's host, applies it if enabled,
    /// and exposes `__gridTheme.set(on)` (in its own world) for live toggling.
    func userScript(theme: Theme) -> WKUserScript {
        let packs = SiteThemeCatalog.entries.reduce(into: [String: String]()) { $0[$1.id] = SiteThemePacks.css[$1.id] ?? "" }
        let match = SiteThemeCatalog.entries.map { [$0.id, $0.hosts] as [Any] }
        let flags = SiteThemeCatalog.entries.reduce(into: [String: Bool]()) { $0[$1.id] = isEnabled($1.id) }
        func json(_ o: Any) -> String {
            String(data: (try? JSONSerialization.data(withJSONObject: o, options: [.fragmentsAllowed])) ?? Data("null".utf8), encoding: .utf8) ?? "null"
        }
        let source = """
        (() => {
          // Re-injection (theme or settings change) replaces the previous instance cleanly.
          if (window.__gridTheme && window.__gridTheme.dispose) window.__gridTheme.dispose();
          const PACKS = \(json(packs));
          const MATCH = \(json(match));
          const ENABLED = \(json(flags));
          const VARS = \(json(Self.tokens(theme)));
          const host = location.hostname.toLowerCase();
          const hit = MATCH.find(([id, hosts]) => hosts.some(p => p.startsWith("*.")
              ? (host === p.slice(2) || host.endsWith(p.slice(1)))
              : (host === p || host === "www." + p)));
          if (!hit) { window.__gridTheme = { set() {} }; return; }
          const id = hit[0];
          const css = VARS + "\\n" + PACKS[id];
          let sheet = null, el = null;
          function on() {
            try {
              if (!sheet) { sheet = new CSSStyleSheet(); sheet.replaceSync(css); }
              if (!document.adoptedStyleSheets.includes(sheet)) document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
            } catch (e) {
              if (!el) { el = document.createElement("style"); el.textContent = css; }
              (document.head || document.documentElement).appendChild(el);
            }
            document.documentElement.setAttribute("data-grid-theme", id);
          }
          function off() {
            if (sheet) document.adoptedStyleSheets = document.adoptedStyleSheets.filter(s => s !== sheet);
            if (el) el.remove();
            document.documentElement.removeAttribute("data-grid-theme");
          }
          let active = !!ENABLED[id];
          window.__gridTheme = { set(v) { active = !!v; active ? on() : off(); }, dispose() { active = false; off(); } };
          if (active) on();
          // Single-page apps can replace adoptedStyleSheets on navigation: re-check then (no polling).
          for (const ev of ["turbo:load", "pjax:end", "popstate", "DOMContentLoaded", "load"])
            addEventListener(ev, () => { if (active) on(); }, { passive: true });
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world)
    }

    /// GRID's palette as CSS variables the packs refer to.
    nonisolated static func tokens(_ t: Theme) -> String {
        func hex(_ c: Color) -> String {
            let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
            return String(format: "#%02x%02x%02x", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
        }
        func rgba(_ c: Color, _ a: Double) -> String {
            let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
            return String(format: "rgba(%d,%d,%d,%.2f)", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255), a)
        }
        return """
        :root {
          --grid-bg0: \(hex(t.bg0)); --grid-bg1: \(hex(t.bg1)); --grid-bg2: \(hex(t.bg2)); --grid-bg3: \(hex(t.bg3));
          --grid-text: \(hex(t.text)); --grid-dim: \(hex(t.textDim)); --grid-mute: \(hex(t.textMute));
          --grid-accent: \(hex(t.accent)); --grid-accent-soft: \(rgba(t.accent, 0.14)); --grid-line: \(rgba(t.accent, 0.20));
          --grid-line-strong: \(rgba(t.accent, 0.60)); --grid-ok: \(hex(t.ok)); --grid-warn: \(hex(t.warn)); --grid-danger: \(hex(t.danger));
          --grid-on-accent: \(hex(t.textOnAccent));
          --grid-mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace;
        }
        """
    }
}
