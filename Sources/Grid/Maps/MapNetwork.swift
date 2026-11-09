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

    /// GET with a byte cap. `etag` makes it conditional (a 304 comes back with empty data).
    func get(_ url: URL, hosts: Set<String>, maxBytes: Int, etag: String? = nil, timeout: TimeInterval = 30) async throws -> Response {
        guard Self.isAllowed(url, hosts: hosts) else { throw NetError.blockedURL(url.absoluteString) }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let task = session.dataTask(with: req)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Response, Error>) in
                lock.withLock { pending[task.taskIdentifier] = Pending(maxBytes: maxBytes, host: url.host?.lowercased() ?? "", continuation: c) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
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
        lock.withLock {
            guard let p = pending[dataTask.taskIdentifier] else { return }
            if p.data.count + data.count > p.maxBytes { over = p.maxBytes } else { p.data.append(data) }
        }
        if over > 0 {
            dataTask.cancel()
            finish(dataTask.taskIdentifier, .failure(NetError.tooLarge(over)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = lock.withLock { pending[task.taskIdentifier]?.host } ?? ""
        if let url = request.url, url.scheme == "https", url.host?.lowercased() == host {
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
                         lastModified: p.response?.value(forHTTPHeaderField: "Last-Modified"), finalURL: p.response?.url)
        finish(task.taskIdentifier, .success(r))
    }
}
