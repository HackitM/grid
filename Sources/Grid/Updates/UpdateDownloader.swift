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

    nonisolated static let maxZipBytes = 300 * 1024 * 1024
    nonisolated static let bundleID = "local.grid.workspace"

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
        do {
            let expected = try await publishedDigest(for: zip, from: sums)
            let archive = try await download(zip, reportingTo: checker)
            checker.download = .verifying
            try await verify(archive, against: expected)
            checker.download = .unpacking
            let appURL = try await unpack(archive, expecting: version)
            BrowserTabCoordinator.quarantine(appURL, from: zip.downloadURL)
            checker.download = .done(appURL)
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        } catch let e as UpdateError {
            checker.download = .failed(e.message)
        } catch {
            checker.download = .failed((error as NSError).localizedDescription)
        }
    }

    // MARK: Steps

    /// Step 1: the SHA-256 the release publishes for `zip`.
    private static func publishedDigest(for zip: GitHubRelease.Asset, from sums: GitHubRelease.Asset) async throws -> String {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: sums.downloadURL, timeoutInterval: 20)
        req.setValue("GRID", forHTTPHeaderField: "User-Agent")
        let guardian = RedirectGuard()
        let (data, response) = try await session.data(for: req, delegate: guardian)
        if let host = guardian.refusedHost { throw UpdateError.unexpectedRedirect(host) }
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 64 * 1024,
              let file = ChecksumFile(String(decoding: data, as: UTF8.self)),
              let expected = file.digest(for: zip.name) else { throw UpdateError("The checksum file couldn't be read.") }
        return expected
    }

    /// Step 2: the zip, into Downloads, marked as downloaded from the internet. Returns where it landed.
    private static func download(_ zip: GitHubRelease.Asset, reportingTo checker: UpdateChecker) async throws -> URL {
        let fm = FileManager.default
        let temp = try await ZipDownload(limit: maxZipBytes) { p in
            Task { @MainActor in if case .downloading = checker.download { checker.download = .downloading(p) } }
        }.run(zip.downloadURL)
        let dest = FileNaming.uniqueURL(in: downloadsFolder, name: zip.name)
        do {
            try fm.moveItem(at: temp, to: dest)
        } catch {
            try? fm.removeItem(at: temp)   // our own temporary copy; don't leave it behind
            throw error
        }
        BrowserTabCoordinator.quarantine(dest, from: zip.downloadURL)
        return dest
    }

    /// Step 3: compare with the published digest; a mismatching file goes to the Trash.
    private static func verify(_ archive: URL, against expected: String) async throws {
        let actual = try await Task.detached(priority: .userInitiated) { try sha256(of: archive) }.value
        guard ChecksumFile.matches(actual, expected) else {
            try? FileManager.default.trashItem(at: archive, resultingItemURL: nil)
            throw UpdateError("The download didn't match the published SHA-256, so it was moved to the Trash.")
        }
    }

    /// Step 4: unzip next to the archive and check what came out. Returns the new GRID.app.
    private static func unpack(_ archive: URL, expecting version: SemanticVersion) async throws -> URL {
        let fm = FileManager.default
        let folder = FileNaming.uniqueURL(in: downloadsFolder, name: "GRID-\(version)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            try await Task.detached(priority: .userInitiated) { try unzip(archive, into: folder) }.value
        } catch {
            try? fm.trashItem(at: folder, resultingItemURL: nil)   // whatever was partly unpacked
            throw error
        }
        let appURL = folder.appendingPathComponent("GRID.app")
        guard isExpectedApp(appURL, in: folder, version: version) else {
            try? fm.trashItem(at: folder, resultingItemURL: nil)
            throw UpdateError("The zip didn't contain GRID \(version) as expected; the unpacked files were moved to the Trash.")
        }
        return appURL
    }

    private static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// The folder holds exactly one item, a real `GRID.app` directory (not a link to something
    /// else on disk) whose Info.plist sits inside it and names this app and the expected version.
    nonisolated static func isExpectedApp(_ appURL: URL, in folder: URL, version: SemanticVersion) -> Bool {
        let fm = FileManager.default
        guard (try? fm.contentsOfDirectory(atPath: folder.path)) == [appURL.lastPathComponent],
              let kind = try? appURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              kind.isDirectory == true, kind.isSymbolicLink != true else { return false }
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard FileNaming.isSameOrInside(plist, appURL), let info = NSDictionary(contentsOf: plist) else { return false }
        return info["CFBundleIdentifier"] as? String == bundleID
            && (info["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init) == version
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unzips with `ditto` (the tool `release.sh` zips with), run directly with an argument list
    /// (no shell). It refuses paths that would land outside `folder`. Only ever called on an
    /// archive whose SHA-256 was just verified.
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

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, UpdateFeed.isTrustedDownloadHost(url) else {
            completionHandler(nil)
            task.cancel()
            finish(.failure(UpdateError.unexpectedRedirect(request.url?.host ?? "?")))
            return
        }
        completionHandler(request)
    }
}

/// Follows redirects only to GitHub's own HTTPS hosts (`UpdateFeed.isTrustedDownloadHost`) and
/// remembers a refused one so the caller can say what happened.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var refused: String?
    var refusedHost: String? { lock.withLock { refused } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if let url = request.url, UpdateFeed.isTrustedDownloadHost(url) {
            completionHandler(request)
        } else {
            lock.withLock { refused = request.url?.host ?? "?" }
            completionHandler(nil)
        }
    }
}

extension UpdateError {
    static func unexpectedRedirect(_ host: String) -> UpdateError {
        UpdateError("The download was redirected to an unexpected server (\(host)), so it was stopped.")
    }
}
