import AppKit

/// Runs work that blocks its thread (child processes, DNS lookups, slow or network volumes) on
/// Grand Central Dispatch instead of Swift's cooperative pool.
///
/// The cooperative pool has one thread per core and expects tasks to yield. A widget waiting on
/// a few slow commands inside `Task.detached` would occupy those threads and stall every other
/// `async` function in GRID until the commands finished. GCD adds threads when its workers block.
enum BlockingWork {
    private static let queue = DispatchQueue(label: "grid.widgets.blocking", qos: .utility, attributes: .concurrent)

    static func run<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}

/// Whether anything of GRID can be seen right now. Polling widgets (git status, recent files,
/// third-party refresh timers) skip their work while it can't: GRID in the background with every
/// window covered or minimised, or the screen locked. A floating widget kept above other apps
/// counts as visible, so it keeps updating.
@MainActor
enum AppVisibility {
    static var isOnScreen: Bool {
        NSApp.isActive || NSApp.windows.contains { $0.occlusionState.contains(.visible) }
    }
}

extension Date {
    /// `2026-01-31T12:00:00Z`, as widgets receive dates. A format style rather than
    /// `ISO8601DateFormatter`, which is costly to create for every file in a listing.
    var widgetISO8601: String { formatted(.iso8601) }
}
