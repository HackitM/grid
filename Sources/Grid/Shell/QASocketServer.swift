#if DEBUG
import Darwin
import Foundation

/// Minimal one-message-per-connection Unix-domain socket server for DEBUG QA hooks.
///
/// Compiled into debug builds only. Access control: the socket file is 0600 inside the per-user
/// temporary directory, and every connection's peer UID is checked against ours before a single
/// byte is read. It only receives; nothing is ever written back to the peer.
final class QASocketServer: @unchecked Sendable {
    private let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "grid.qa.socket")
    private let onMessage: @Sendable (String) -> Void

    init?(path: String, onMessage: @escaping @Sendable (String) -> Void) {
        self.path = path
        self.onMessage = onMessage
        Self.removeStaleSocket(at: path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { close(fd); return nil }      // the path is not ours to remove
        guard chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { close(fd); unlink(path); return nil }
        let listening = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: listening, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne(on: listening) }
        // The descriptor is closed by the source once it has stopped watching it: closing it
        // while the source is still armed is undefined (and the number could be reused).
        src.setCancelHandler { close(listening) }
        src.resume()
        source = src
    }

    /// Removes a socket left behind by an earlier run. Anything that is not a socket is left
    /// alone (bind then fails and QA hooks stay off).
    private static func removeStaleSocket(at path: String) {
        var st = stat()
        if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK { unlink(path) }
    }

    private func acceptOne(on listening: Int32) {
        let client = accept(listening, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < 1 << 20 {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        if let s = String(data: data, encoding: .utf8) { onMessage(s) }
    }

    func stop() {
        guard let source else { return }
        source.cancel()            // its cancel handler closes the descriptor
        self.source = nil
        fd = -1
        unlink(path)
    }

    deinit { stop() }
}
#endif
