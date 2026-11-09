// Renders GRID's app icon (original artwork) into Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (needs iconutil, part of macOS)
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("GRID-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

func render(_ px: Int) -> CGImage {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)
    // macOS icon grid: 824pt body inset 100pt, continuous-ish corner radius.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.45))
    ctx.addPath(shape); ctx.setFillColor(color(0x05090B)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    // Background: vertical gradient, near-black to deep teal at the horizon.
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x02060A), color(0x06222A), color(0x02060A)] as CFArray,
                          locations: [0, 0.42, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // Perspective grid floor below the horizon.
    let horizon: CGFloat = 470, vanishing = CGPoint(x: 512, y: horizon + 160)
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 100, y: 100, width: 824, height: horizon - 100))
    ctx.setLineWidth(3)
    for i in -9...9 {
        let x = 512 + CGFloat(i) * 120
        ctx.move(to: CGPoint(x: x, y: 100)); ctx.addLine(to: vanishing)
    }
    ctx.setStrokeColor(color(0x6FE3F5, 0.28)); ctx.strokePath()
    var y: CGFloat = horizon, gap: CGFloat = 16
    while y > 100 {
        ctx.move(to: CGPoint(x: 100, y: y)); ctx.addLine(to: CGPoint(x: 924, y: y))
        y -= gap; gap *= 1.38
    }
    ctx.setStrokeColor(color(0x6FE3F5, 0.32)); ctx.strokePath()
    ctx.restoreGState()
    // Horizon glow line.
    ctx.setShadow(offset: .zero, blur: 18, color: color(0x2CCBEA, 0.9))
    ctx.setStrokeColor(color(0x9AF1F7)); ctx.setLineWidth(4)
    ctx.move(to: CGPoint(x: 100, y: horizon)); ctx.addLine(to: CGPoint(x: 924, y: horizon)); ctx.strokePath()
    ctx.restoreGState()

    // Clipped plate (Legacy panel motif) with prompt chevron + cursor.
    let plate = CGMutablePath()
    let p = CGRect(x: 250, y: 560, width: 524, height: 250), cut: CGFloat = 46
    plate.move(to: CGPoint(x: p.minX, y: p.minY))
    plate.addLine(to: CGPoint(x: p.maxX, y: p.minY))
    plate.addLine(to: CGPoint(x: p.maxX, y: p.maxY - cut))
    plate.addLine(to: CGPoint(x: p.maxX - cut, y: p.maxY))
    plate.addLine(to: CGPoint(x: p.minX, y: p.maxY))
    plate.closeSubpath()
    ctx.addPath(plate); ctx.setFillColor(color(0x061418, 0.92)); ctx.fillPath()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 14, color: color(0x2CCBEA, 0.8))
    ctx.addPath(plate); ctx.setStrokeColor(color(0x6FE3F5)); ctx.setLineWidth(6); ctx.strokePath()
    // Chevron ">"
    ctx.setLineCap(.square); ctx.setLineJoin(.miter); ctx.setLineWidth(30)
    ctx.move(to: CGPoint(x: 330, y: 740)); ctx.addLine(to: CGPoint(x: 420, y: 685)); ctx.addLine(to: CGPoint(x: 330, y: 630))
    ctx.setStrokeColor(color(0xDDF4F8)); ctx.strokePath()
    // Cursor block
    ctx.setFillColor(color(0x6FE3F5)); ctx.fill(CGRect(x: 470, y: 618, width: 150, height: 32))
    ctx.restoreGState()
    return ctx.makeImage()!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let rep = NSBitmapImageRep(cgImage: render(px))
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
