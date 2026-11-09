import AppKit
import GridCore
import Observation

/// Checks GitHub for a newer GRID release (docs/MAPS-PLAN.md §12, Phase U1).
///
/// - Nothing is checked until you agree (the one-time question in the status bar or Settings ›
///   Updates). "Check for Updates…" always works on demand.
/// - Daily checks run through `NSBackgroundActivityScheduler` (energy-friendly), are conditional
///   (ETag, so "no change" is a few hundred bytes), and send a plain `User-Agent: GRID` with no
///   version, token, account or install ID.
/// - Nothing installs: GRID shows the release, opens its page, or downloads and verifies the zip
///   (UpdateDownloader). You replace the app yourself.
@Observable
@MainActor
final class UpdateChecker {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// Newest acceptable release from the last successful check (kept across launches).
    private(set) var latest: GitHubRelease?
    private(set) var policy: UpdatePolicy { didSet { savePolicy() } }
    var download: UpdateDownloader.State = .none

    @ObservationIgnored weak var app: AppState?
    @ObservationIgnored private let feed = UpdateFeed.grid
    @ObservationIgnored private var scheduler: NSBackgroundActivityScheduler?
    @ObservationIgnored private let d = UserDefaults.standard
    @ObservationIgnored private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    /// The running version.
    private(set) var current: SemanticVersion
    #if DEBUG
    /// QA: read releases from a local JSON file instead of GitHub (`{"cmd":"updates","feed":path}`).
    @ObservationIgnored var debugFeed: URL?
    #endif

    init() {
        current = SemanticVersion(GridInfo.version) ?? SemanticVersion(major: 0, minor: 0, patch: 0)
        policy = (d.data(forKey: "updates.policy")).flatMap { try? JSONDecoder().decode(UpdatePolicy.self, from: $0) } ?? UpdatePolicy()
        latest = cachedRelease()
    }

    // MARK: Derived state

    /// The one-time "check daily?" question hasn't been answered.
    var needsConsent: Bool { policy.checkDaily == nil }
    var checksDaily: Bool { policy.checkDaily == true }
    var includePrereleases: Bool { policy.includePrereleases }
    var lastCheck: Date? { policy.lastCheck }

    /// A release newer than the running version.
    var available: GitHubRelease? {
        guard let r = latest, let v = r.version, UpdatePolicy.isNewer(v, than: current) else { return nil }
        return r
    }

    /// Whether the status bar should offer `available` (respects skip, later and "already seen").
    var showsNotice: Bool {
        guard let v = available?.version else { return false }
        return policy.shouldNotify(v, current: current, now: Date())
    }

    var isSkipped: Bool {
        guard let v = available?.version, let s = policy.skipped.flatMap(SemanticVersion.init) else { return false }
        return v <= s
    }

    // MARK: Choices

    func start() {
        if checksDaily { schedule() }
        if policy.isCheckDue(now: Date()) { Task { await check(manual: false) } }
    }

    func setCheckDaily(_ on: Bool) {
        policy.checkDaily = on
        if on {
            schedule()
            if policy.isCheckDue(now: Date()) { Task { await check(manual: false) } }
        } else {
            scheduler?.invalidate(); scheduler = nil
        }
    }

    func setIncludePrereleases(_ on: Bool) {
        guard on != policy.includePrereleases else { return }
        policy.includePrereleases = on
        // A different endpoint: forget the conditional-request state and the cached answer.
        d.removeObject(forKey: "updates.etag"); d.removeObject(forKey: "updates.body")
        latest = nil
        if status != .idle || checksDaily { Task { await check(manual: true) } }
    }

    func dismissNotice() { if let v = available?.version { policy.noticed = v.description } }
    func skipAvailable() { if let v = available?.version { policy.skip(v); policy.noticed = v.description } }
    func later() { policy.later(now: Date()); if let v = available?.version { policy.noticed = v.description } }
    func unskip() { policy.skipped = nil }

    func openReleasePage() {
        guard let r = available ?? latest else { return }
        dismissNotice()
        app?.openURL(r.pageURL.absoluteString)
    }

    /// GRID › Check for Updates… / palette "update": checks now and reports the result.
    func checkNowAndReport() {
        Task {
            await check(manual: true)
            guard let app else { return }
            switch status {
            case .failed(let msg): app.flash(.error, "Update check failed: \(msg)")
            default:
                if let r = available {
                    app.flash(.info, "GRID \(r.version?.description ?? r.tagName) is available", actionLabel: "View") { app.settingsSection = "updates"; app.show(.settings) }
                } else {
                    app.flash(.info, "GRID \(current) is up to date")
                }
            }
        }
    }

    // MARK: Checking

    func check(manual: Bool) async {
        guard status != .checking else { return }
        status = .checking
        var url = policy.includePrereleases ? feed.listURL : feed.latestURL
        #if DEBUG
        if let f = debugFeed { url = f }
        #endif
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("GRID", forHTTPHeaderField: "User-Agent")
        if let etag = d.string(forKey: "updates.etag"), d.data(forKey: "updates.body") != nil {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, response) = try await session.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 200   // file:// fixtures have no status
            let body: Data
            switch code {
            case 200:
                guard data.count < 2_000_000 else { throw UpdateError("response too large") }
                body = data
                if let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") { d.set(etag, forKey: "updates.etag") }
                d.set(data, forKey: "updates.body")
            case 304:
                guard let cached = d.data(forKey: "updates.body") else { throw UpdateError("empty cache") }
                body = cached
            case 403, 429:
                throw UpdateError("GitHub rate limit reached; try again later")
            case 404:
                throw UpdateError("no published releases found")
            default:
                throw UpdateError("GitHub answered \(code)")
            }
            latest = try feed.newest(from: body, includePrereleases: policy.includePrereleases)
            policy.lastCheck = Date()
            status = available == nil ? .upToDate : .idle
        } catch let e as UpdateError {
            status = .failed(e.message)
        } catch is DecodingError {
            status = .failed("unexpected response from GitHub")
        } catch {
            status = .failed((error as NSError).localizedDescription)
        }
    }

    private func cachedRelease() -> GitHubRelease? {
        guard let data = d.data(forKey: "updates.body") else { return nil }
        return try? feed.newest(from: data, includePrereleases: policy.includePrereleases)
    }

    private func schedule() {
        guard scheduler == nil else { return }
        let s = NSBackgroundActivityScheduler(identifier: "local.grid.workspace.updates")
        s.repeats = true
        s.interval = UpdatePolicy.interval
        s.tolerance = 3600
        s.qualityOfService = .utility
        s.schedule { [weak self] done in
            Task { @MainActor in
                if let self, self.policy.isCheckDue(now: Date()) { await self.check(manual: false) }
                done(.finished)
            }
        }
        scheduler = s
    }

    private func savePolicy() {
        if let data = try? JSONEncoder().encode(policy) { d.set(data, forKey: "updates.policy") }
    }

    #if DEBUG
    func debugSetCurrent(_ v: String) { if let s = SemanticVersion(v) { current = s } }
    func debugReset() {
        policy = UpdatePolicy(); latest = nil; status = .idle; download = .none
        ["updates.etag", "updates.body"].forEach { d.removeObject(forKey: $0) }
    }
    #endif
}

struct UpdateError: Error {
    let message: String
    init(_ m: String) { message = m }
}
