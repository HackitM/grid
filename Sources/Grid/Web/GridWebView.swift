import AppKit
import WebKit

/// A WKWebView whose right-click menu is drawn by GRID. WebKit still decides what the menu holds
/// (link, image, selection and extension items) and still performs the chosen item; GRID only
/// replaces the presentation. With standard menus selected (or VoiceOver on) WebKit's own menu
/// shows unchanged.
final class GridWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard !GridMenu.shared.usesSystemMenus else { return }
        let items = GridMenu.items(from: menu)
        guard !items.isEmpty else { return }
        // WebKit's items only work while its menu is open, so the GRID menu runs modally here
        // (tracking events like a system menu) and the chosen item is performed before WebKit
        // shows its menu. That menu is then empty, and an empty menu isn't shown.
        GridMenu.shared.showModal(items, title: "page", anchor: .point(GridMenu.screenLocation(of: event)), window: window)
        menu.removeAllItems()
    }
}
