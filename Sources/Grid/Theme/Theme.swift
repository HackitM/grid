import AppKit
import SwiftUI

/// Design tokens. Every color in the UI comes from here; see docs/DESIGN.md.
enum ThemeID: String, CaseIterable, Identifiable, Codable {
    case legacy, ares, amber
    var id: String { rawValue }
    var label: String {
        switch self { case .legacy: "LEGACY // CYAN"; case .ares: "ARES // RED"; case .amber: "ENCOM // AMBER" }
    }
}

struct Theme: Equatable {
    let id: ThemeID

    // Surfaces (near-black, faintly tinted toward the accent hue)
    let bg0: Color     // window / void
    let bg1: Color     // panel body
    let bg2: Color     // raised: headers, hover
    let bg3: Color     // inset: fields

    // Text
    let text: Color         // primary readable (cool white)
    let textDim: Color      // secondary (metadata)
    let textMute: Color     // tertiary (labels, disabled)
    let textOnAccent: Color // text on solid accent fills

    // Accent
    let accent: Color       // active / focus
    let accentSoft: Color   // selection fill
    let glow: Color         // bloom color for edges

    // Lines
    let line: Color         // resting hairline
    let lineStrong: Color   // focused hairline

    // Semantic (always paired with a glyph or word; never color alone)
    let ok: Color
    let warn: Color
    let danger: Color

    // Terminal (ANSI palette is shared across themes so program output keeps its meaning)
    let termBackground: NSColor
    let termForeground: NSColor
    let termCursor: NSColor
    let termSelection: NSColor

    static func make(_ id: ThemeID) -> Theme {
        switch id {
        case .legacy:
            return Theme(id: id,
                bg0: Color(hex: 0x030608), bg1: Color(hex: 0x070C0F), bg2: Color(hex: 0x0C1418), bg3: Color(hex: 0x050A0C),
                text: Color(hex: 0xDDF4F8), textDim: Color(hex: 0x8DB0B9), textMute: Color(hex: 0x557079), textOnAccent: Color(hex: 0x021014),
                accent: Color(hex: 0x6FE3F5), accentSoft: Color(hex: 0x6FE3F5, alpha: 0.13), glow: Color(hex: 0x2CCBEA),
                line: Color(hex: 0x6FE3F5, alpha: 0.18), lineStrong: Color(hex: 0x6FE3F5, alpha: 0.75),
                ok: Color(hex: 0x7CF0C0), warn: Color(hex: 0xFFC56B), danger: Color(hex: 0xFF6B57),
                termBackground: NSColor(hex: 0x060B0E), termForeground: NSColor(hex: 0xD6ECF1),
                termCursor: NSColor(hex: 0x8EEBF8), termSelection: NSColor(hex: 0x6FE3F5, alpha: 0.28))
        case .ares:
            return Theme(id: id,
                bg0: Color(hex: 0x070404), bg1: Color(hex: 0x0D0807), bg2: Color(hex: 0x170D0B), bg3: Color(hex: 0x0A0605),
                text: Color(hex: 0xF6E6E1), textDim: Color(hex: 0xBE958B), textMute: Color(hex: 0x7A5850), textOnAccent: Color(hex: 0x140302),
                accent: Color(hex: 0xFF4A2B), accentSoft: Color(hex: 0xFF4A2B, alpha: 0.15), glow: Color(hex: 0xFF2C10),
                line: Color(hex: 0xFF4A2B, alpha: 0.20), lineStrong: Color(hex: 0xFF5A3C, alpha: 0.85),
                ok: Color(hex: 0x8FE3C2), warn: Color(hex: 0xFFD27A), danger: Color(hex: 0xFFFFFF),
                termBackground: NSColor(hex: 0x0B0606), termForeground: NSColor(hex: 0xF1DDD7),
                termCursor: NSColor(hex: 0xFF5A3C), termSelection: NSColor(hex: 0xFF4A2B, alpha: 0.30))
        case .amber:
            return Theme(id: id,
                bg0: Color(hex: 0x060504), bg1: Color(hex: 0x0C0A07), bg2: Color(hex: 0x15110B), bg3: Color(hex: 0x090705),
                text: Color(hex: 0xF5EBDA), textDim: Color(hex: 0xBBA27C), textMute: Color(hex: 0x76654B), textOnAccent: Color(hex: 0x140D02),
                accent: Color(hex: 0xFFB547), accentSoft: Color(hex: 0xFFB547, alpha: 0.14), glow: Color(hex: 0xFF9A1A),
                line: Color(hex: 0xFFB547, alpha: 0.18), lineStrong: Color(hex: 0xFFB547, alpha: 0.80),
                ok: Color(hex: 0x8FE3C2), warn: Color(hex: 0xFFE08A), danger: Color(hex: 0xFF6B57),
                termBackground: NSColor(hex: 0x0A0806), termForeground: NSColor(hex: 0xEFE3CF),
                termCursor: NSColor(hex: 0xFFC266), termSelection: NSColor(hex: 0xFFB547, alpha: 0.28))
        }
    }

    /// 16-color ANSI palette tuned for dark backgrounds. Deliberately *not* tinted per theme:
    /// red must still read as red (errors, diffs) even in the cyan theme, and vice versa.
    static let ansi: [NSColor] = [
        NSColor(hex: 0x1A2226), NSColor(hex: 0xF0605A), NSColor(hex: 0x5FD99A), NSColor(hex: 0xE8C86A),
        NSColor(hex: 0x5AA8F0), NSColor(hex: 0xD487E8), NSColor(hex: 0x5ED6E0), NSColor(hex: 0xC9D3D6),
        NSColor(hex: 0x56656B), NSColor(hex: 0xFF8A80), NSColor(hex: 0x8DF0BC), NSColor(hex: 0xFFE08E),
        NSColor(hex: 0x8CC6FF), NSColor(hex: 0xEDB0FF), NSColor(hex: 0x9AF1F7), NSColor(hex: 0xF4F8F9),
    ]
}

/// Type scale. Monospace carries technical content; labels are small uppercase with tracking.
enum GridFont {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static let label = Font.system(size: 9.5, weight: .semibold, design: .monospaced)   // + uppercase, tracking 1.4
    static let body = Font.system(size: 12, weight: .regular, design: .monospaced)
    static let bodyStrong = Font.system(size: 12, weight: .semibold, design: .monospaced)
    static let small = Font.system(size: 10.5, weight: .regular, design: .monospaced)
    static let title = Font.system(size: 15, weight: .medium, design: .monospaced)
    static let ui = Font.system(size: 12.5)  // proportional, for app names and prose
}

enum Metrics {
    static let hairline: CGFloat = 1
    static let railWidth: CGFloat = 58
    static let statusHeight: CGFloat = 24
    static let headerHeight: CGFloat = 24
    static let rowHeight: CGFloat = 22
    static let gutter: CGFloat = 8
    static let cornerCut: CGFloat = 9
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.make(.legacy) }
private struct EffectsKey: EnvironmentKey { static let defaultValue = Effects() }

struct Effects: Equatable {
    var glow = true
    var motion = true
    var gridBackdrop = false
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
    var effects: Effects {
        get { self[EffectsKey.self] }
        set { self[EffectsKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
