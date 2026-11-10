import AppKit
import GridCore
import WebKit

/// Downloads started from any tab: ask first, save to ~/Downloads, quarantine.
///
/// Owned by the browser rather than by the tab that started the download, because the delegate
/// is what quarantines the file. A tab can go away mid-download (the user closes it, or a popup
/// calls `window.close()` on itself the moment the download is accepted); if the tab's own
/// delegate handled downloads, the file would then land in Downloads without the quarantine flag
/// that makes Gatekeeper check it on first open.
@MainActor
final class BrowserDownloads: NSObject, WKDownloadDelegate {
    weak var model: BrowserModel?

    /// A download in progress. Holding `download` keeps it alive after its tab is gone.
    private struct Active {
        let download: WKDownload
        var destination: URL?
        var acceptedAt: Date?
    }
    private var active: [ObjectIdentifier: Active] = [:]

    private var app: AppState? { model?.app }

    /// Takes over a download WebKit just started from a navigation.
    func adopt(_ download: WKDownload) {
        active[ObjectIdentifier(download)] = Active(download: download)
        download.delegate = self
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let key = ObjectIdentifier(download)
        guard let app, await confirm(suggestedFilename, response: response, app: app) else {
            active[key] = nil       // returning nil cancels the download
            return nil
        }
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = FileNaming.uniqueURL(in: folder, name: FileNaming.sanitizedDownloadName(suggestedFilename))
        active[key]?.destination = destination
        active[key]?.acceptedAt = Date()
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let destination = active.removeValue(forKey: ObjectIdentifier(download))?.destination else { return }
        BrowserTabCoordinator.quarantine(destination, from: download.originalRequest?.url)
        app?.flash(.info, "Downloaded \(destination.lastPathComponent)", actionLabel: "Reveal") {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let failed = active.removeValue(forKey: ObjectIdentifier(download)) { removePartialFile(of: failed) }
        app?.flash(.error, "Download failed: \(error.localizedDescription)")
    }

    // MARK: Steps

    /// Asks before anything is written: the name as it will be saved, where it comes from, its size.
    private func confirm(_ suggestedFilename: String, response: URLResponse, app: AppState) async -> Bool {
        let name = FileNaming.sanitizedDownloadName(suggestedFilename)
        let size = response.expectedContentLength > 0
            ? " (" + ByteCountFormatter.string(fromByteCount: response.expectedContentLength, countStyle: .file) + ")" : ""
        let host = response.url?.host ?? "this site"
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let shown = app.present(Confirmation(code: "WEB.DOWNLOAD", title: "Download “\(name)”?",
                                                 message: "From \(host)\(size). It will be saved to Downloads.",
                                                 confirmLabel: "Download", destructive: false,
                                                 onConfirm: { c.resume(returning: true) }, onCancel: { c.resume(returning: false) }))
            if !shown { c.resume(returning: false) }
        }
    }

    /// A failed download leaves the bytes received so far at its destination, unquarantined and
    /// under the final name. GRID doesn't resume downloads, so the fragment is removed — but only
    /// if it is a plain file created since this download was accepted, so a failure can never
    /// delete something that was already there.
    private func removePartialFile(of failed: Active) {
        guard let file = failed.destination, let acceptedAt = failed.acceptedAt,
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let created = values.creationDate, created >= acceptedAt.addingTimeInterval(-1) else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
