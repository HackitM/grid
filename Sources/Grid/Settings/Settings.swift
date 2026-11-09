import AppKit
import Observation
import SwiftUI

/// User preferences, persisted to UserDefaults on every change. Local only.
@Observable
@MainActor
final class Settings {
    @ObservationIgnored private let d = UserDefaults.standard

    var theme: ThemeID { didSet { d.set(theme.rawValue, forKey: "theme") } }
    var glow: Bool { didSet { d.set(glow, forKey: "fx.glow") } }
    var motion: Bool { didSet { d.set(motion, forKey: "fx.motion") } }
    var gridBackdrop: Bool { didSet { d.set(gridBackdrop, forKey: "fx.grid") } }
    var terminalFontName: String { didSet { d.set(terminalFontName, forKey: "term.font") } }
    var terminalFontSize: Double { didSet { d.set(terminalFontSize, forKey: "term.size") } }
    var optionAsMeta: Bool { didSet { d.set(optionAsMeta, forKey: "term.optionMeta") } }
    var scrollback: Int { didSet { d.set(scrollback, forKey: "term.scrollback") } }
    var confirmCloseBusy: Bool { didSet { d.set(confirmCloseBusy, forKey: "term.confirmBusy") } }
    var shellOverride: String { didSet { d.set(shellOverride, forKey: "term.shell") } }
    var showHiddenFiles: Bool { didSet { d.set(showHiddenFiles, forKey: "files.hidden") } }

    /// System "Reduce motion" wins over the in-app toggle.
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    init() {
        d.register(defaults: [
            "theme": ThemeID.legacy.rawValue, "fx.glow": true, "fx.motion": true, "fx.grid": false,
            "term.font": "", "term.size": 13.0, "term.optionMeta": true, "term.scrollback": 10_000,
            "term.confirmBusy": true, "term.shell": "",
            "files.hidden": false,
        ])
        theme = ThemeID(rawValue: d.string(forKey: "theme") ?? "") ?? .legacy
        glow = d.bool(forKey: "fx.glow")
        motion = d.bool(forKey: "fx.motion")
        gridBackdrop = d.bool(forKey: "fx.grid")
        terminalFontName = d.string(forKey: "term.font") ?? ""
        terminalFontSize = d.double(forKey: "term.size")
        optionAsMeta = d.bool(forKey: "term.optionMeta")
        scrollback = d.integer(forKey: "term.scrollback")
        confirmCloseBusy = d.bool(forKey: "term.confirmBusy")
        shellOverride = d.string(forKey: "term.shell") ?? ""
        showHiddenFiles = d.bool(forKey: "files.hidden")

        NotificationCenter.default.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
    }

    var themeValue: Theme { Theme.make(theme) }
    var effects: Effects { Effects(glow: glow, motion: motion && !reduceMotion, gridBackdrop: gridBackdrop) }

    var terminalFont: NSFont {
        let size = CGFloat(min(max(terminalFontSize, 8), 32))
        if !terminalFontName.isEmpty, let f = NSFont(name: terminalFontName, size: size) { return f }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Installed fixed-pitch font families for the font picker.
    static let monospaceFamilies: [String] = {
        let fm = NSFontManager.shared
        return (fm.availableFontNames(with: .fixedPitchFontMask) ?? [])
            .compactMap { NSFont(name: $0, size: 12)?.familyName }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }()
}
