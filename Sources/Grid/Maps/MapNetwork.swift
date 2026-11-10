import Foundation

/// The Maps feature's only way onto the network. One ephemeral session (no cookies, no URL
/// cache), an identifying User-Agent, https only, a host allow-list per request, redirects only
/// within the same host, and a byte cap enforced while the body arrives (so a compressed body
/// can't inflate past it).
final class MapNetwork: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = MapNetwork()

    struct Response: Sendable {
        let data: Data
        let status: Int
        let etag: String?
        let lastModified: String?
        let finalURL: URL?
        var contentLength: Int64? = nil
    }

    enum NetError: LocalizedError, Equatable {
        case blockedURL(String), tooLarge(Int), http(Int), cancelled, transport(String)
        var errorDescription: String? {
            switch self {
            case .blockedURL(let u): "Blocked request to \(u)."
            case .tooLarge(let n): "The response was larger than \(ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file))."
            case .http(let s): "The server answered \(s)."
            case .cancelled: "Cancelled."
            case .transport(let m): m
            }
        }
    }

    static var userAgent: String {
        "GRID/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") (+https://github.com/HackitM/grid)"
    }

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 300
        c.httpMaximumConnectionsPerHost = 6
        c.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    private final class Pending {
        var data = Data()
        /// Large downloads stream into this file instead of `data`.
        var sink: FileHandle?
        var written: Int64 = 0
        var progress: (@Sendable (Int64, Int64) -> Void)?
        var response: HTTPURLResponse?
        let maxBytes: Int
        let host: String
        let continuation: CheckedContinuation<Response, Error>
        var done = false
        init(maxBytes: Int, host: String, continuation: CheckedContinuation<Response, Error>) {
            self.maxBytes = maxBytes; self.host = host; self.continuation = continuation
        }
    }
    private var pending: [Int: Pending] = [:]
    private let lock = NSLock()

    /// Validates a URL against the allow-list: https, no userinfo or port, host in `hosts`
    /// (exact, or `*.suffix` entries).
    static func isAllowed(_ url: URL, hosts: Set<String>) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let h = url.host?.lowercased(), !h.isEmpty else { return false }
        return hosts.contains { allowed in
            allowed.hasPrefix("*.") ? (h.hasSuffix(String(allowed.dropFirst(1))) || h == String(allowed.dropFirst(2))) : h == allowed
        }
    }

    /// The size a GET would return (HEAD's Content-Length), or nil when the server doesn't say.
    func size(of url: URL, hosts: Set<String>) async throws -> (status: Int, bytes: Int64?) {
        guard Self.isAllowed(url, hosts: hosts) else { throw NetError.blockedURL(Self.describe(url)) }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.httpMethod = "HEAD"
        let r = try await run(req, maxBytes: 1 << 16, host: url.host?.lowercased() ?? "")
        return (r.status, r.contentLength)
    }

    /// GET streamed into `file` (which must already exist, empty), capped at `maxBytes`, with
    /// progress (bytes so far, expected or -1). The returned response has no data.
    func download(_ url: URL, to file: URL, hosts: Set<String>, maxBytes: Int64,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> Response {
        guard Self.isAllowed(url, hosts: hosts) else { throw NetError.blockedURL(Self.describe(url)) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        return try await run(req, maxBytes: Int(clamping: maxBytes), host: url.host?.lowercased() ?? "", sink: handle, progress: progress)
    }

    /// Runs one request to its end. `host` is the request's own host: redirects may only stay on
    /// it. Cancelling the calling task cancels the request.
    private func run(_ req: URLRequest, maxBytes: Int, host: String, sink: FileHandle? = nil,
                     progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> Response {
        let task = session.dataTask(with: req)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Response, Error>) in
                lock.withLock {
                    let p = Pending(maxBytes: maxBytes, host: host, continuation: c)
                    p.sink = sink; p.progress = progress
                    pending[task.taskIdentifier] = p
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// GET with a byte cap. `etag` makes it conditional (a 304 comes back with empty data).
    func get(_ url: URL, hosts: Set<String>, maxBytes: Int, etag: String? = nil, timeout: TimeInterval = 30) async throws -> Response {
        guard Self.isAllowed(url, hosts: hosts) else { throw NetError.blockedURL(Self.describe(url)) }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return try await run(req, maxBytes: maxBytes, host: url.host?.lowercased() ?? "")
    }

    /// A URL as named in an error message: scheme, host and path only. The query can hold what
    /// the user searched for or the area they were looking at, which has no place in a message
    /// that may be shown, copied or reported.
    static func describe(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.host ?? "an invalid address" }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.string ?? (url.host ?? "an invalid address")
    }

    private func finish(_ id: Int, _ result: Result<Response, Error>) {
        let p: Pending? = lock.withLock {
            guard let p = pending[id], !p.done else { return nil }
            p.done = true
            pending[id] = nil
            return p
        }
        p?.continuation.resume(with: result)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let cap = lock.withLock { pending[dataTask.taskIdentifier]?.maxBytes } ?? 0
        if let http, http.expectedContentLength > 0, http.expectedContentLength > Int64(cap),
           http.value(forHTTPHeaderField: "Content-Encoding") == nil {
            completionHandler(.cancel)
            finish(dataTask.taskIdentifier, .failure(NetError.tooLarge(cap)))
            return
        }
        lock.withLock { pending[dataTask.taskIdentifier]?.response = http }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var over = 0
        var report: (@Sendable (Int64, Int64) -> Void)?
        var sofar: Int64 = 0, expected: Int64 = -1
        var writeFailed = false
        lock.withLock {
            guard let p = pending[dataTask.taskIdentifier] else { return }
            if let sink = p.sink {
                if p.written + Int64(data.count) > Int64(p.maxBytes) { over = p.maxBytes; return }
                do { try sink.write(contentsOf: data) } catch { writeFailed = true; return }
                p.written += Int64(data.count)
                report = p.progress; sofar = p.written; expected = p.response?.expectedContentLength ?? -1
            } else if p.data.count + data.count > p.maxBytes { over = p.maxBytes } else { p.data.append(data) }
        }
        report?(sofar, expected)
        if writeFailed {
            dataTask.cancel()
            finish(dataTask.taskIdentifier, .failure(NetError.transport("Couldn't write the download to disk.")))
            return
        }
        if over > 0 {
            dataTask.cancel()
            finish(dataTask.taskIdentifier, .failure(NetError.tooLarge(over)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = lock.withLock { pending[task.taskIdentifier]?.host } ?? ""
        if let url = request.url, Self.isAllowed(url, hosts: [host]) {
            completionHandler(request)
        } else {
            completionHandler(nil)   // the redirect response itself is returned (and treated as an error status)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let p = lock.withLock { pending[task.taskIdentifier] }
        guard let p else { return }
        if let error {
            let ns = error as NSError
            finish(task.taskIdentifier, .failure(ns.code == NSURLErrorCancelled ? NetError.cancelled : NetError.transport(ns.localizedDescription)))
            return
        }
        let status = p.response?.statusCode ?? 0
        let r = Response(data: p.data, status: status, etag: p.response?.value(forHTTPHeaderField: "ETag"),
                         lastModified: p.response?.value(forHTTPHeaderField: "Last-Modified"), finalURL: p.response?.url,
                         contentLength: (p.response?.expectedContentLength).flatMap { $0 >= 0 ? $0 : nil })
        finish(task.taskIdentifier, .success(r))
    }
}
