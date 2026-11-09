import AppKit
import CryptoKit
import GridCore

/// "Download & Verify" (update tier 2): downloads the release zip to Downloads after you confirm,
/// marks it as downloaded from the internet (quarantine + where-from, like the browser), checks it
/// against the release's published SHA-256, unzips it next to itself and reveals the new GRID.app
/// in Finder. You quit GRID and replace the app yourself.
///
/// The checksum catches a corrupt or truncated download; it is not proof of authenticity (both
/// files come from the same release). Quarantine is kept on purpose: until GRID is notarized,
/// macOS asks for "Open Anyway" after each update, and GRID never removes that check.
@MainActor
enum UpdateDownloader {
    enum State: Equatable {
        case none
        case downloading(Double)
        case verifying
        case unpacking
        case done(URL)
        case failed(String)

        var busy: Bool {
            switch self { case .downloading, .verifying, .unpacking: true; default: false }
        }
    }

    static let maxZipBytes = 300 * 1024 * 1024
    static let bundleID = "local.grid.workspace"

    static func run(_ checker: UpdateChecker) {
        guard !checker.download.busy, let app = checker.app else { return }
        guard let release = checker.available, let version = release.version,
              let zip = release.appAsset, let sums = release.checksumAsset else {
            checker.download = .failed("This release has no GRID zip and checksum to verify.")
            return
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(zip.size), countStyle: .file)
        app.present(Confirmation(
            code: "UPD.DOWNLOAD", title: "Download GRID \(version)?",
            message: "\(zip.name) (\(size)) from github.com. GRID saves it to Downloads, checks it against the release's SHA-256, unzips it there and shows it in Finder. GRID doesn't replace itself: you quit it and move the new app into Applications.",
            confirmLabel: "Download", destructive: false,
            onConfirm: { Task { await perform(checker, version: version, zip: zip, sums: sums) } }))
    }

    private static func perform(_ checker: UpdateChecker, version: SemanticVersion,
                                zip: GitHubRelease.Asset, sums: GitHubRelease.Asset) async {
        checker.download = .downloading(0)
        let fm = FileManager.default
        do {
            // 1. The published checksum.
            var req = URLRequest(url: sums.downloadURL, timeoutInterval: 20)
            req.setValue("GRID", forHTTPHeaderField: "User-Agent")
            let (sumData, sumResponse) = try await URLSession(configuration: .ephemeral).data(for: req)
            guard ((sumResponse as? HTTPURLResponse)?.statusCode ?? 200) == 200, sumData.count < 64 * 1024,
                  let file = ChecksumFile(String(decoding: sumData, as: UTF8.self)),
                  let expected = file.digest(for: zip.name) else { throw UpdateError("The checksum file couldn't be read.") }

            // 2. The zip, into Downloads, marked as downloaded from the internet.
            let temp = try await ZipDownload(limit: maxZipBytes) { p in
                Task { @MainActor in if case .downloading = checker.download { checker.download = .downloading(p) } }
            }.run(zip.downloadURL)
            let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let dest = FileNaming.uniqueURL(in: downloads, name: zip.name)
            try fm.moveItem(at: temp, to: dest)
            BrowserTabCoordinator.quarantine(dest, from: zip.downloadURL)

            // 3. Verify.
            checker.download = .verifying
            let actual = try await Task.detached(priority: .userInitiated) { try sha256(of: dest) }.value
            guard ChecksumFile.matches(actual, expected) else {
                try? fm.trashItem(at: dest, resultingItemURL: nil)
                throw UpdateError("The download didn't match the published SHA-256, so it was moved to the Trash.")
            }

            // 4. Unzip next to it and check what came out.
            checker.download = .unpacking
            let folder = FileNaming.uniqueURL(in: downloads, name: "GRID-\(version)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            try await Task.detached(priority: .userInitiated) { try unzip(dest, into: folder) }.value
            let appURL = folder.appendingPathComponent("GRID.app")
            let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
            let items = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            guard items == ["GRID.app"],
                  info?["CFBundleIdentifier"] as? String == bundleID,
                  (info?["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init) == version else {
                try? fm.trashItem(at: folder, resultingItemURL: nil)
                throw UpdateError("The zip didn't contain GRID \(version) as expected; the unpacked files were moved to the Trash.")
            }
            BrowserTabCoordinator.quarantine(appURL, from: zip.downloadURL)
            checker.download = .done(appURL)
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        } catch let e as UpdateError {
            checker.download = .failed(e.message)
        } catch {
            checker.download = .failed((error as NSError).localizedDescription)
        }
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unzips with `ditto` (the tool `release.sh` zips with), run directly with an argument list
    /// (no shell). It refuses paths that would land outside `folder`.
    nonisolated static func unzip(_ zip: URL, into folder: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, folder.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("The zip couldn't be unpacked.") }
    }
}

/// One file download with progress, into a temporary file. Refuses anything over `limit` bytes
/// and any answer other than 200.
private final class ZipDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let limit: Int
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()

    init(limit: Int, progress: @escaping @Sendable (Double) -> Void) {
        self.limit = limit; self.progress = progress
    }

    func run(_ url: URL) async throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("GRID", forHTTPHeaderField: "User-Agent")
        return try await withCheckedThrowingContinuation { c in
            lock.withLock { continuation = c }
            session.downloadTask(with: req).resume()
        }
    }

    private func finish(_ r: Result<URL, Error>) {
        let c = lock.withLock { () -> CheckedContinuation<URL, Error>? in defer { continuation = nil }; return continuation }
        c?.resume(with: r)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            downloadTask.cancel()
            finish(.failure(UpdateError("The download is larger than expected.")))
            return
        }
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            finish(.failure(UpdateError("GitHub answered \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0) for the download.")))
            return
        }
        // The file is deleted when this returns: move it somewhere of ours first.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("grid-update-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            finish(.success(keep))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
