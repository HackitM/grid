import AppKit
import GridCore
import SwiftUI

/// GRID's own file icons for the Files grid view: solid single-colour silhouettes on a 24-unit
/// grid with GRID's angled corner cuts (inspired by eDEX-UI's filesystem grid, drawn from
/// scratch). Folders are accent-coloured with a front flap; known folders carry a glyph punched
/// out of the flap; files show their extension punched out of the page.
enum FileGlyph: Equatable {
    case folder(badge: String?)
    case up
    case package
    case file(tag: String)
    case executable
    case broken

    static func of(_ e: FileEntry) -> FileGlyph {
        if e.isBrokenSymlink { return .broken }
        if e.isNavigableFolder { return .folder(badge: folderBadge(e)) }
        if e.isPackage { return .package }
        if e.isRegularFile, e.fileExtension.isEmpty, FileManager.default.isExecutableFile(atPath: e.url.path) { return .executable }
        if ["sh", "command", "zsh", "bash", "fish"].contains(e.fileExtension) { return .executable }
        return .file(tag: String(e.fileExtension.uppercased().prefix(5)))
    }

    /// SF Symbol punched into a well-known folder.
    private static func folderBadge(_ e: FileEntry) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = e.url.standardizedFileURL.path
        if path == home { return "house.fill" }
        let parentIsHome = e.url.deletingLastPathComponent().standardizedFileURL.path == home
        switch e.name {
        case ".git": return "arrow.triangle.branch"
        case "node_modules": return "shippingbox.fill"
        case ".github": return "chevron.left.forwardslash.chevron.right"
        case "Applications": return "square.grid.2x2.fill"
        case "Desktop" where parentIsHome: return "menubar.dock.rectangle"
        case "Documents" where parentIsHome: return "doc.text.fill"
        case "Downloads" where parentIsHome: return "arrow.down"
        case "Music" where parentIsHome: return "music.note"
        case "Pictures" where parentIsHome: return "photo.fill"
        case "Movies" where parentIsHome: return "film.fill"
        case "Library": return "books.vertical.fill"
        case "Public" where parentIsHome: return "person.2.fill"
        default: return nil
        }
    }
}

/// Draws a FileGlyph. `build` (0…1) runs the build-on: the outline traces, then the silhouette
/// fills with a brief Ares flash.
struct FileGlyphView: View, Animatable {
    let glyph: FileGlyph
    let color: Color
    /// The background the glyph sits on (punched-out details use it).
    let cutout: Color
    var dimmed = false
    var symlink = false
    var build: CGFloat = 1
    var animatableData: CGFloat { get { build } set { build = newValue } }

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 24
            let ox = (size.width - 24 * s) / 2, oy = (size.height - 24 * s) / 2
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
            func poly(_ p: [(CGFloat, CGFloat)]) -> Path {
                var path = Path()
                path.move(to: pt(p[0].0, p[0].1))
                for q in p.dropFirst() { path.addLine(to: pt(q.0, q.1)) }
                path.closeSubpath()
                return path
            }
            let trace = min(1, build / 0.55)
            let fill = Double(max(0, (build - 0.35) / 0.65))
            let flash = build < 1 ? Double(max(0, 1 - abs(build - 0.7) / 0.3)) * 0.35 : 0
            ctx.opacity = dimmed ? 0.6 : 1

            func silhouette(_ outline: Path, _ draw: (inout GraphicsContext) -> Void) {
                if fill > 0 {
                    var c = ctx
                    c.opacity = ctx.opacity * fill
                    draw(&c)
                }
                if build < 1 {
                    ctx.stroke(outline.trimmedPath(from: 0, to: trace), with: .color(color.opacity(1 - fill * 0.6)), lineWidth: max(1, s * 0.6))
                }
                if flash > 0 { ctx.fill(outline, with: .color(.white.opacity(flash))) }
            }

            func folderShape(badge: String?, isUp: Bool) {
                let outline = poly([(2, 5), (9, 5), (11.5, 7.5), (22, 7.5), (22, 18.5), (20.5, 20), (2, 20)])
                silhouette(outline) { c in
                    // Back plate (tab + top), dimmer; front flap, full colour, below a cut line.
                    c.fill(poly([(2, 5), (9, 5), (11.5, 7.5), (22, 7.5), (22, 10), (2, 10)]), with: .color(color.opacity(0.62)))
                    c.fill(poly([(2, 10.9), (22, 10.9), (22, 18.5), (20.5, 20), (2, 20)]), with: .color(color))
                    if isUp {
                        var arrow = Path()
                        arrow.move(to: pt(12, 12.6)); arrow.addLine(to: pt(12, 18.2))
                        arrow.move(to: pt(9.4, 15.2)); arrow.addLine(to: pt(12, 12.6)); arrow.addLine(to: pt(14.6, 15.2))
                        c.stroke(arrow, with: .color(cutout), style: StrokeStyle(lineWidth: 1.6 * s, lineCap: .square))
                    } else if let badge {
                        var img = c.resolve(Image(systemName: badge))
                        img.shading = .color(cutout)
                        let box = CGRect(origin: pt(8.6, 12), size: CGSize(width: 6.8 * s, height: 6.8 * s))
                        c.draw(img, in: box.insetBy(dx: 0.3 * s, dy: 0.3 * s))
                    }
                }
            }

            func fileShape(tag: String, exec: Bool) {
                let outline = poly([(4, 2), (14, 2), (20, 8), (20, 22), (4, 22)])
                silhouette(outline) { c in
                    c.fill(outline, with: .color(color.opacity(0.88)))
                    // The folded corner, set apart by a cut.
                    c.fill(poly([(14.9, 2.6), (19.4, 7.1), (14.9, 7.1)]), with: .color(cutout.opacity(0.55)))
                    c.fill(poly([(14.9, 2.6), (19.4, 7.1), (14.9, 7.1)]), with: .color(color.opacity(0.35)))
                    if !tag.isEmpty {
                        let size = (tag.count > 4 ? 3.9 : tag.count > 3 ? 4.6 : 5.4) * s
                        let text = Text(tag).font(.system(size: size, weight: .heavy, design: .monospaced)).foregroundColor(cutout)
                        c.draw(text, at: pt(12, exec ? 14.5 : 16), anchor: .center)
                    }
                    if !exec {
                        // Two short rules above the tag, like lines of text.
                        c.fill(Path(CGRect(origin: pt(6.5, 9.4), size: CGSize(width: 7 * s, height: 0.9 * s))), with: .color(cutout.opacity(0.8)))
                        c.fill(Path(CGRect(origin: pt(6.5, 11.4), size: CGSize(width: 10 * s, height: 0.9 * s))), with: .color(cutout.opacity(0.8)))
                    }
                }
            }

            switch glyph {
            case .folder(let badge):
                folderShape(badge: badge, isUp: false)
            case .up:
                folderShape(badge: nil, isUp: true)
            case .package:
                // An octagonal module with a punched inner frame.
                let outline = poly([(7, 3), (17, 3), (21, 7), (21, 17), (17, 21), (7, 21), (3, 17), (3, 7)])
                silhouette(outline) { c in
                    c.fill(outline, with: .color(color))
                    c.stroke(poly([(9, 8), (15, 8), (16, 9), (16, 15), (15, 16), (9, 16), (8, 15), (8, 9)]),
                             with: .color(cutout), lineWidth: 1.4 * s)
                }
            case .file(let tag):
                fileShape(tag: tag, exec: false)
            case .executable:
                fileShape(tag: ">_", exec: true)
            case .broken:
                let outline = poly([(4, 2), (14, 2), (20, 8), (20, 22), (4, 22)])
                ctx.stroke(outline, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1.2 * s, dash: [2 * s, 1.6 * s]))
                var x = Path()
                x.move(to: pt(9, 11)); x.addLine(to: pt(15, 17)); x.move(to: pt(15, 11)); x.addLine(to: pt(9, 17))
                ctx.stroke(x, with: .color(color.opacity(0.7)), lineWidth: 1.2 * s)
            }

            if symlink {
                // Link badge, bottom-left: a small plate with an arrow out.
                let plate = poly([(0.5, 15.5), (8, 15.5), (8.5, 16), (8.5, 23.5), (0.5, 23.5)])
                ctx.fill(plate, with: .color(cutout))
                ctx.stroke(plate, with: .color(color), lineWidth: max(1, 0.8 * s))
                var arrow = Path()
                arrow.move(to: pt(2.8, 21.2)); arrow.addLine(to: pt(6.4, 17.6))
                arrow.move(to: pt(3.6, 17.6)); arrow.addLine(to: pt(6.4, 17.6)); arrow.addLine(to: pt(6.4, 20.4))
                ctx.stroke(arrow, with: .color(color), lineWidth: 1.1 * s)
            }
        }
        .accessibilityHidden(true)
    }
}
