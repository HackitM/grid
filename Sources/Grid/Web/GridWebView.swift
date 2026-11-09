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
        // (AppKit has already started tracking WebKit's menu when this is called) and the chosen
        // item is performed before returning. Then WebKit's menu is emptied and its tracking
        // cancelled: left open, AppKit would show it with only the system Services items and it
        // would swallow the next click.
        menu.allowsContextMenuPlugIns = false
        GridMenu.shared.showModal(items, title: "page", anchor: .point(GridMenu.screenLocation(of: event)), window: window)
        menu.removeAllItems()
        menu.cancelTrackingWithoutAnimation()
        // Tracking may not have fully started yet; cancel again once it has.
        DispatchQueue.main.async { menu.cancelTrackingWithoutAnimation() }
    }
}
