// Site theme packs. Each maps a site's own design tokens (CSS custom properties, read from the live
// sites' stylesheets) to GRID's palette (--grid-* variables injected alongside), so layouts stay the
// site's and only colour and type change. Selectors are scoped to html[data-grid-theme="…"], which
// GRID's injected script sets only while the theme is on. `!important` lets the overrides win over
// the site's own light/dark token definitions without depending on selector specificity.
enum SiteThemePacks {
    /// Shared by every pack: selection, scrollbars, focus rings.
    static let base = """
    html[data-grid-theme] { scrollbar-color: var(--grid-line-strong) var(--grid-bg1); accent-color: var(--grid-accent); }
    html[data-grid-theme] ::selection { background: var(--grid-accent-soft); }
    html[data-grid-theme] :focus-visible { outline-color: var(--grid-accent) !important; }
    """

    static let css: [String: String] = [
        "github": base + """
        html[data-grid-theme="github"], html[data-grid-theme="github"] [data-color-mode] {
          --bgColor-default: var(--grid-bg1) !important; --bgColor-muted: var(--grid-bg2) !important; --bgColor-inset: var(--grid-bg0) !important;
          --bgColor-emphasis: var(--grid-bg2) !important; --bgColor-inverse: var(--grid-text) !important;
          --bgColor-accent-emphasis: var(--grid-accent) !important; --bgColor-accent-muted: var(--grid-accent-soft) !important;
          --bgColor-neutral-muted: var(--grid-accent-soft) !important; --bgColor-neutral-emphasis: var(--grid-mute) !important;
          --fgColor-default: var(--grid-text) !important; --fgColor-muted: var(--grid-dim) !important; --fgColor-subtle: var(--grid-mute) !important;
          --fgColor-accent: var(--grid-accent) !important; --fgColor-link: var(--grid-accent) !important; --fgColor-onEmphasis: var(--grid-on-accent) !important;
          --borderColor-default: var(--grid-line) !important; --borderColor-muted: var(--grid-line) !important;
          --borderColor-accent-emphasis: var(--grid-accent) !important; --borderColor-accent-muted: var(--grid-line-strong) !important;
          --header-bgColor: var(--grid-bg0) !important; --header-borderColor-divider: var(--grid-line) !important;
          --header-fgColor-default: var(--grid-text) !important; --header-fgColor-logo: var(--grid-accent) !important;
          --underlineNav-borderColor-active: var(--grid-accent) !important;
          --button-default-bgColor-rest: var(--grid-bg2) !important; --button-default-bgColor-hover: var(--grid-bg3) !important;
          --button-default-borderColor-rest: var(--grid-line) !important; --button-default-fgColor-rest: var(--grid-text) !important;
          --button-primary-bgColor-rest: var(--grid-accent) !important; --button-primary-bgColor-hover: var(--grid-accent) !important;
          --button-primary-fgColor-rest: var(--grid-on-accent) !important; --button-primary-borderColor-rest: var(--grid-accent) !important;
          --control-bgColor-rest: var(--grid-bg3) !important; --control-borderColor-rest: var(--grid-line) !important;
          --overlay-bgColor: var(--grid-bg2) !important; --focus-outlineColor: var(--grid-accent) !important;
          --fontStack-sansSerif: var(--grid-mono) !important; --fontStack-sansSerifDisplay: var(--grid-mono) !important;
          --fontStack-system: var(--grid-mono) !important; --fontStack-monospace: var(--grid-mono) !important;
          --color-canvas-default: var(--grid-bg1) !important; --color-canvas-subtle: var(--grid-bg2) !important; --color-canvas-inset: var(--grid-bg0) !important;
          --color-fg-default: var(--grid-text) !important; --color-fg-muted: var(--grid-dim) !important; --color-accent-fg: var(--grid-accent) !important;
          --color-border-default: var(--grid-line) !important; --color-border-muted: var(--grid-line) !important;
          --color-btn-bg: var(--grid-bg2) !important; --color-btn-border: var(--grid-line) !important; --color-header-bg: var(--grid-bg0) !important;
        }
        html[data-grid-theme="github"] body { background: var(--grid-bg1) !important; }
        """,

        "hackernews": base + """
        html[data-grid-theme="hackernews"], html[data-grid-theme="hackernews"] body { background: var(--grid-bg1) !important; }
        html[data-grid-theme="hackernews"] body, html[data-grid-theme="hackernews"] td, html[data-grid-theme="hackernews"] .pagetop,
        html[data-grid-theme="hackernews"] .title, html[data-grid-theme="hackernews"] .comment, html[data-grid-theme="hackernews"] input,
        html[data-grid-theme="hackernews"] textarea { font-family: var(--grid-mono) !important; }
        html[data-grid-theme="hackernews"] #hnmain { background: var(--grid-bg1) !important; width: 100% !important; max-width: 1100px; }
        html[data-grid-theme="hackernews"] #hnmain > tbody > tr:first-child > td,
        html[data-grid-theme="hackernews"] td[bgcolor="#ff6600"] { background: var(--grid-bg2) !important; border-bottom: 1px solid var(--grid-line-strong); }
        html[data-grid-theme="hackernews"] .pagetop, html[data-grid-theme="hackernews"] .pagetop a { color: var(--grid-dim) !important; }
        html[data-grid-theme="hackernews"] .hnname a, html[data-grid-theme="hackernews"] .pagetop b a { color: var(--grid-accent) !important; letter-spacing: 1px; }
        html[data-grid-theme="hackernews"] td[style*="border:1px white"] img, html[data-grid-theme="hackernews"] a[href="https://news.ycombinator.com"] img { filter: grayscale(1) brightness(1.4); }
        html[data-grid-theme="hackernews"] a:link, html[data-grid-theme="hackernews"] .titleline > a { color: var(--grid-text) !important; }
        html[data-grid-theme="hackernews"] a:visited, html[data-grid-theme="hackernews"] .titleline > a:visited { color: var(--grid-mute) !important; }
        html[data-grid-theme="hackernews"] .titleline > a:hover { color: var(--grid-accent) !important; }
        html[data-grid-theme="hackernews"] .rank { color: var(--grid-accent) !important; }
        html[data-grid-theme="hackernews"] .sitebit, html[data-grid-theme="hackernews"] .sitestr, html[data-grid-theme="hackernews"] .subtext,
        html[data-grid-theme="hackernews"] .subtext a, html[data-grid-theme="hackernews"] .comhead, html[data-grid-theme="hackernews"] .comhead a,
        html[data-grid-theme="hackernews"] .age a, html[data-grid-theme="hackernews"] .yclinks a { color: var(--grid-mute) !important; }
        html[data-grid-theme="hackernews"] .score { color: var(--grid-dim) !important; }
        html[data-grid-theme="hackernews"] .hnuser { color: var(--grid-dim) !important; }
        html[data-grid-theme="hackernews"] .commtext, html[data-grid-theme="hackernews"] .commtext a, html[data-grid-theme="hackernews"] .toptext { color: var(--grid-text) !important; }
        html[data-grid-theme="hackernews"] .commtext.cdd, html[data-grid-theme="hackernews"] .commtext.c5a, html[data-grid-theme="hackernews"] .commtext.c73,
        html[data-grid-theme="hackernews"] .commtext.c82, html[data-grid-theme="hackernews"] .commtext.c88, html[data-grid-theme="hackernews"] .commtext.c9c,
        html[data-grid-theme="hackernews"] .commtext.cae, html[data-grid-theme="hackernews"] .commtext.cbe, html[data-grid-theme="hackernews"] .commtext.cce { color: var(--grid-mute) !important; }
        html[data-grid-theme="hackernews"] .commtext a { color: var(--grid-accent) !important; }
        html[data-grid-theme="hackernews"] .votearrow { filter: invert(0.75) sepia(1) hue-rotate(140deg) saturate(3); }
        html[data-grid-theme="hackernews"] input, html[data-grid-theme="hackernews"] textarea {
          background: var(--grid-bg3) !important; color: var(--grid-text) !important; border: 1px solid var(--grid-line) !important; }
        html[data-grid-theme="hackernews"] td[bgcolor="#ff6600"] table { background: transparent !important; }
        html[data-grid-theme="hackernews"] .morelink { color: var(--grid-accent) !important; }
        """,

        "mdn": base + """
        html[data-grid-theme="mdn"], html[data-grid-theme="mdn"] [data-theme] {
          --color-background-page: var(--grid-bg1) !important; --color-background-primary: var(--grid-bg1) !important;
          --color-background-secondary: var(--grid-bg2) !important;
          --color-background-blue: var(--grid-accent-soft) !important; --color-background-purple: var(--grid-accent-soft) !important;
          --color-background-green: var(--grid-accent-soft) !important; --color-background-orange: var(--grid-accent-soft) !important;
          --color-background-yellow: var(--grid-accent-soft) !important; --color-background-red: var(--grid-accent-soft) !important;
          --color-border-primary: var(--grid-line) !important; --color-border-secondary: var(--grid-line) !important; --color-border-active: var(--grid-accent) !important;
          --color-text-primary: var(--grid-text) !important; --color-text-secondary: var(--grid-dim) !important;
          --color-text-blue: var(--grid-accent) !important; --color-text-purple: var(--grid-accent) !important; --color-text-green: var(--grid-ok) !important;
          --color-text-orange: var(--grid-warn) !important; --color-text-yellow: var(--grid-warn) !important; --color-text-red: var(--grid-danger) !important;
          --color-link-normal: var(--grid-accent) !important; --color-link-visited: var(--grid-dim) !important;
          --color-scrollbar-thumb: var(--grid-line-strong) !important;
          --font-family-text: var(--grid-mono) !important; --font-family-code: var(--grid-mono) !important;
        }
        html[data-grid-theme="mdn"], html[data-grid-theme="mdn"] body { background: var(--grid-bg1) !important; }
        """,

        "wikipedia": base + """
        html[data-grid-theme="wikipedia"], html[data-grid-theme="wikipedia"] .skin-invert, html[data-grid-theme="wikipedia"] .notheme,
        html[data-grid-theme="wikipedia"] body {
          --background-color-base: var(--grid-bg1) !important; --background-color-base-fixed: var(--grid-bg1) !important;
          --background-color-neutral: var(--grid-bg2) !important; --background-color-neutral-subtle: var(--grid-bg2) !important;
          --background-color-interactive: var(--grid-bg2) !important; --background-color-interactive--hover: var(--grid-bg3) !important;
          --background-color-interactive--active: var(--grid-bg3) !important; --background-color-interactive-subtle: var(--grid-bg2) !important;
          --background-color-interactive-subtle--hover: var(--grid-bg3) !important; --background-color-notice-subtle: var(--grid-bg2) !important;
          --background-color-progressive: var(--grid-accent) !important; --background-color-progressive--hover: var(--grid-accent) !important;
          --background-color-progressive-subtle: var(--grid-accent-soft) !important; --background-color-progressive-subtle--hover: var(--grid-accent-soft) !important;
          --background-color-inverted: var(--grid-text) !important; --background-color-backdrop-light: rgba(0,0,0,0.6) !important;
          --color-base: var(--grid-text) !important; --color-base-fixed: var(--grid-text) !important; --color-emphasized: var(--grid-text) !important;
          --color-subtle: var(--grid-dim) !important; --color-placeholder: var(--grid-mute) !important; --color-inverted: var(--grid-on-accent) !important;
          --color-progressive: var(--grid-accent) !important; --color-progressive--hover: var(--grid-accent) !important;
          --color-progressive--active: var(--grid-accent) !important; --color-visited: var(--grid-dim) !important; --color-visited--hover: var(--grid-text) !important;
          --border-color-base: var(--grid-line) !important; --border-color-subtle: var(--grid-line) !important; --border-color-muted: var(--grid-line) !important;
          --border-color-emphasized: var(--grid-line-strong) !important; --border-color-interactive: var(--grid-line-strong) !important;
          --border-color-progressive: var(--grid-accent) !important; --accent-color-base: var(--grid-accent) !important;
          --box-shadow-color-base: var(--grid-line) !important; --outline-color-progressive--focus: var(--grid-accent) !important;
        }
        html[data-grid-theme="wikipedia"] body, html[data-grid-theme="wikipedia"] .mw-page-container { background: var(--grid-bg1) !important; }
        html[data-grid-theme="wikipedia"] body, html[data-grid-theme="wikipedia"] .vector-body, html[data-grid-theme="wikipedia"] .mw-body h1,
        html[data-grid-theme="wikipedia"] .mw-body-content h2, html[data-grid-theme="wikipedia"] .mw-body-content h3 { font-family: var(--grid-mono) !important; }
        html[data-grid-theme="wikipedia"] .mw-logo-wordmark, html[data-grid-theme="wikipedia"] .mw-logo-tagline, html[data-grid-theme="wikipedia"] .mw-logo-icon { filter: invert(1) grayscale(1) brightness(1.2); }
        html[data-grid-theme="wikipedia"] .cdx-text-input__input, html[data-grid-theme="wikipedia"] .cdx-search-input__end-button,
        html[data-grid-theme="wikipedia"] .cdx-button, html[data-grid-theme="wikipedia"] .cdx-menu {
          background: var(--grid-bg3) !important; color: var(--grid-text) !important; border-color: var(--grid-line) !important; }
        html[data-grid-theme="wikipedia"] .infobox, html[data-grid-theme="wikipedia"] .wikitable, html[data-grid-theme="wikipedia"] .navbox {
          background: var(--grid-bg2) !important; color: var(--grid-text) !important; border-color: var(--grid-line) !important; }
        html[data-grid-theme="wikipedia"] .wikitable > tr > th, html[data-grid-theme="wikipedia"] .wikitable > * > tr > th,
        html[data-grid-theme="wikipedia"] .navbox-title, html[data-grid-theme="wikipedia"] .navbox-group, html[data-grid-theme="wikipedia"] .infobox-above,
        html[data-grid-theme="wikipedia"] .infobox-header { background: var(--grid-bg3) !important; color: var(--grid-text) !important; }
        """,

        "stackoverflow": base + """
        html[data-grid-theme="stackoverflow"] body, html[data-grid-theme="stackoverflow"] body * {
          --white: var(--grid-bg1) !important; --black: var(--grid-text) !important;
          --black-025: var(--grid-bg1) !important; --black-050: var(--grid-bg1) !important; --black-075: var(--grid-bg2) !important;
          --black-100: var(--grid-bg2) !important; --black-150: var(--grid-bg2) !important; --black-200: var(--grid-bg3) !important;
          --black-225: var(--grid-line) !important; --black-250: var(--grid-line) !important; --black-300: var(--grid-line-strong) !important;
          --black-350: var(--grid-mute) !important; --black-400: var(--grid-mute) !important; --black-500: var(--grid-dim) !important;
          --black-600: var(--grid-text) !important; --black-700: var(--grid-text) !important; --black-800: var(--grid-text) !important; --black-900: var(--grid-text) !important;
          --blue-050: var(--grid-accent-soft) !important; --blue-100: var(--grid-accent-soft) !important; --blue-200: var(--grid-line-strong) !important;
          --blue-300: var(--grid-accent) !important; --blue-400: var(--grid-accent) !important; --blue-500: var(--grid-accent) !important;
          --blue-600: var(--grid-accent) !important; --blue-700: var(--grid-accent) !important;
          --powder-050: var(--grid-accent-soft) !important; --powder-100: var(--grid-accent-soft) !important; --powder-200: var(--grid-accent-soft) !important;
          --powder-300: var(--grid-line-strong) !important; --powder-700: var(--grid-accent) !important; --powder-800: var(--grid-accent) !important;
          --orange-400: var(--grid-accent) !important; --orange-500: var(--grid-accent) !important;
          --yellow-050: var(--grid-bg2) !important; --yellow-100: var(--grid-bg2) !important; --yellow-200: var(--grid-line) !important;
          --yellow-300: var(--grid-line-strong) !important; --purple-050: var(--grid-bg2) !important; --purple-100: var(--grid-bg2) !important;
          --theme-secondary-050: var(--grid-bg2) !important; --theme-secondary-100: var(--grid-bg2) !important;
          --theme-primary: var(--grid-accent) !important; --theme-primary-custom: var(--grid-accent) !important;
          --theme-background-color: var(--grid-bg1) !important; --theme-content-background-color: var(--grid-bg1) !important;
          --theme-content-border-color: var(--grid-line) !important; --theme-link-color: var(--grid-accent) !important;
          --theme-link-color-hover: var(--grid-accent) !important; --theme-link-color-visited: var(--grid-dim) !important;
          --theme-body-font-color: var(--grid-text) !important; --theme-body-font-family: var(--grid-mono) !important;
          --fc-light: var(--grid-mute) !important; --fc-medium: var(--grid-dim) !important; --fc-dark: var(--grid-text) !important;
          --bc-lightest: var(--grid-line) !important; --bc-light: var(--grid-line) !important; --bc-medium: var(--grid-line) !important; --bc-darker: var(--grid-line-strong) !important;
          --highlight-bg: var(--grid-bg3) !important; --highlight-color: var(--grid-text) !important;
          --ff-sans: var(--grid-mono) !important; --ff-mono: var(--grid-mono) !important;
        }
        html[data-grid-theme="stackoverflow"], html[data-grid-theme="stackoverflow"] body { background: var(--grid-bg1) !important; color: var(--grid-text) !important; }
        """,
    ]
}
