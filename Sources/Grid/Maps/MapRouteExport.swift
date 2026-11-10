import AppKit
import GridCore
import MetalKit
import UniformTypeIdentifiers

/// Print, GPX and plain-text export of the shown route. Everything is made on this Mac; GPX goes
/// only where the user saves it.
@MainActor
enum MapRouteExport {
    static func title(_ r: MapRouting) -> String {
        "\(r.from?.name ?? "Start") to \(r.to?.name ?? "Destination")"
    }

    static func cameraNote(_ h: CameraExposure.Hit, _ cams: [ALPRCamera]) -> String {
        var s = "Mapped camera \(RouteFormat.distance(h.distance)) from the road"
        if cams.indices.contains(h.camera) {
            let c = cams[h.camera]
            s += c.directions.isEmpty ? ", facing unknown" : ", facing " + c.directions.map { "\($0)°" }.joined(separator: " ")
            if c.vendor != .unknown { s += " (\(c.vendor.label))" }
        }
        return s
    }

    // MARK: Text

    static func text(_ model: MapModel) -> String? {
        let r = model.routing
        guard let leg = r.shownLeg else { return nil }
        let cams = model.alpr.index.cameras
        return CueSheet(path: leg.path, hits: leg.hits).text(title: title(r), distance: RouteFormat.distance, duration: RouteFormat.duration,
                                                             camera: { cameraNote($0, cams) })
            + "\n" + disclaimer + "\n" + attribution + "\n"
    }

    static func copyText(_ model: MapModel) {
        guard let t = text(model) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
        model.app?.flash(.info, "Copied the directions")
    }

    static let disclaimer = "Only cameras mapped in OpenStreetMap and downloaded to GRID are counted. Coverage is incomplete and may be out of date; a route can't be guaranteed unseen. Directions can't re-route around closures: check the road and its signs."
    static let attribution = "Map data © OpenStreetMap contributors (ODbL) · © OpenMapTiles · OpenFreeMap · ALPR: DeFlock/OSM"

    // MARK: GPX

    static func saveGPX(_ model: MapModel) {
        let r = model.routing
        guard let doc = gpx(model), let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gpx") ?? .xml]
        panel.nameFieldStringValue = safeFileName(title(r)) + ".gpx"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(doc.utf8).write(to: url, options: [.atomic])
                model.app?.flash(.info, "Saved \(url.lastPathComponent)")
            } catch {
                model.app?.flash(.error, "Couldn't save the GPX file: \(error.localizedDescription)")
            }
        }
    }

    /// A file name from free text (place names can come from the search server): no slashes,
    /// colons, control or invisible formatting characters, no leading or trailing dots or spaces,
    /// at most 80 characters. The save panel adds the extension and the user picks the folder.
    static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines)
        let edges = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "."))
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.map { bad.contains($0) ? " " : $0 }))
            .trimmingCharacters(in: edges)
        // Cutting to length can expose a new trailing space or dot.
        let name = String(cleaned.prefix(80)).trimmingCharacters(in: edges)
        return name.isEmpty ? "GRID route" : name
    }

    // MARK: Print

    static func printRoute(_ model: MapModel) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let op = operation(model) else { return }
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// The print job (page setup from the shared print info), or one that saves a PDF to `pdf`.
    static func operation(_ model: MapModel, pdf: URL? = nil) -> NSPrintOperation? {
        let r = model.routing
        guard let leg = r.shownLeg else { return nil }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 40; info.rightMargin = 40
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        let width = max(300, info.paperSize.width - info.leftMargin - info.rightMargin)
        let map = mapImage(model, leg: leg, size: CGSize(width: width, height: width * 0.72))
        let body = document(model, leg: leg, map: map, width: width)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.isEditable = false
        view.drawsBackground = true
        view.backgroundColor = .white
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textStorage?.setAttributedString(body)
        view.sizeToFit()
        if let pdf {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = pdf
        }
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = title(r)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        return op
    }

    /// The GPX document for the shown route.
    static func gpx(_ model: MapModel) -> String? {
        let r = model.routing
        guard let leg = r.shownLeg else { return nil }
        let cams = model.alpr.index.cameras
        var points: [GPXWriter.Waypoint] = []
        if let a = r.from { points.append(.init(at: a.coordinate, name: "Start: \(a.name)")) }
        if let b = r.to { points.append(.init(at: b.coordinate, name: "Destination: \(b.name)")) }
        for h in leg.hits where cams.indices.contains(h.camera) {
            points.append(.init(at: cams[h.camera].coordinate, name: "Mapped ALPR camera", detail: cameraNote(h, cams)))
        }
        return GPXWriter.document(name: title(r), steps: leg.path.steps, track: leg.path.points, waypoints: points, created: Date())
    }

    /// The route's area drawn in the paper palette by a renderer of its own, all tiles uploaded.
    static func mapImage(_ model: MapModel, leg: RouteService.Leg, size: CGSize) -> NSImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let view = MTKView(frame: NSRect(origin: .zero, size: size), device: device)
        guard let renderer = MapRenderer(view: view), let frame = model.printFrame(leg: leg, viewport: SIMD2(Double(size.width), Double(size.height))) else { return nil }
        renderer.uploadBudget = .infinity
        renderer.setFrame(frame)
        guard let cg = renderer.renderImage(size: size, scale: 3) else { return nil }
        return NSImage(cgImage: cg, size: size)
    }

    static func document(_ model: MapModel, leg: RouteService.Leg, map: NSImage?, width: CGFloat) -> NSAttributedString {
        let r = model.routing
        let cams = model.alpr.index.cameras
        let sheet = CueSheet(path: leg.path, hits: leg.hits)
        let out = NSMutableAttributedString()
        func add(_ s: String, _ font: NSFont, _ color: NSColor = .black, spacing: CGFloat = 4, tabs: [NSTextTab] = [], indent: CGFloat = 0) {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = spacing
            p.tabStops = tabs
            p.headIndent = indent
            out.append(NSAttributedString(string: s + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p]))
        }
        add(title(r), .systemFont(ofSize: 18, weight: .bold), spacing: 2)
        let n = leg.hits.count
        add("\(RouteFormat.distance(leg.path.distance)) · \(RouteFormat.duration(leg.path.duration)) · \(n) mapped camera\(n == 1 ? "" : "s") on this route"
            + (r.outcome?.avoiding != nil ? (r.shown == .avoiding ? " (route avoiding mapped cameras)" : " (fastest route)") : ""),
            .systemFont(ofSize: 11), NSColor(white: 0.25, alpha: 1), spacing: 10)
        if let map {
            let a = NSTextAttachment()
            a.image = map
            a.bounds = CGRect(origin: .zero, size: map.size)
            out.append(NSAttributedString(attachment: a))
            add("", .systemFont(ofSize: 6))
            add("Blue: the route · A: start · B: destination · orange squares: mapped cameras it passes", .systemFont(ofSize: 8.5), NSColor(white: 0.35, alpha: 1), spacing: 12)
        }
        let numberTab = NSTextTab(textAlignment: .left, location: 30)
        let distTab = NSTextTab(textAlignment: .right, location: width)
        for row in sheet.rows {
            let dist = row.distance > 0 ? "\t" + RouteFormat.distance(row.distance) : ""
            add(String(format: "%02d", row.number) + "\t" + row.text + dist, .systemFont(ofSize: 13, weight: .medium), spacing: row.cameras.isEmpty ? 7 : 2,
                tabs: [numberTab, distTab], indent: 30)
            for c in row.cameras {
                add("\t⚠︎ " + cameraNote(c, cams), .systemFont(ofSize: 10.5), NSColor(calibratedRed: 0.75, green: 0.3, blue: 0, alpha: 1), spacing: 7,
                    tabs: [numberTab], indent: 30)
            }
        }
        add("", .systemFont(ofSize: 8))
        add(disclaimer, .systemFont(ofSize: 8.5), NSColor(white: 0.3, alpha: 1), spacing: 3)
        add(attribution + " · Printed by GRID " + Date().formatted(date: .abbreviated, time: .shortened), .systemFont(ofSize: 7.5), NSColor(white: 0.45, alpha: 1))
        return out
    }
}
