import Darwin
import Foundation

/// One running `GridWidgetHost` process: spawns it, writes JSON lines to its stdin, reads JSON
/// lines from its stdout, and measures its CPU and memory. Everything it sends is untrusted.
final class WidgetHostProcess: @unchecked Sendable {
    static let maxMessage = 1 << 20

    /// Called on the main queue for each message, and once with nil when the process exits.
    var onMessage: (@MainActor ([String: Any]?) -> Void)?

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let writeQueue = DispatchQueue(label: "grid.widget.host.write")
    private var buffer = Data()
    private var closed = false

    static var executableURL: URL? {
        let dir = Bundle.main.executableURL?.deletingLastPathComponent()
        let url = dir?.appendingPathComponent("GridWidgetHost")
        return url.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    deinit {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    var pid: pid_t { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    func start() throws {
        guard let exe = Self.executableURL else {
            throw NSError(domain: "GRID", code: 1, userInfo: [NSLocalizedDescriptionKey: "GridWidgetHost is missing from the app bundle."])
        }
        process.executableURL = exe
        process.arguments = []
        // Nothing inherited: no PATH, no tokens, no HOME tricks.
        process.environment = ["LANG": "en_US.UTF-8"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish() } }
        }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.received(d)
        }
        try process.run()
        // A host that dies while we write must not take GRID down with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func send(_ obj: [String: Any]) {
        let box = UncheckedBox(obj)
        // Serialization (large results) happens off the main thread.
        writeQueue.async { [weak self] in
            guard let self, !self.closed,
                  var line = try? JSONSerialization.data(withJSONObject: box.value, options: [.fragmentsAllowed]) else { return }
            line.append(0x0A)
            // A host that stops reading would block us forever; writes go to a background queue
            // and the watchdog kills unresponsive hosts.
            try? self.stdin.fileHandleForWriting.write(contentsOf: line)
        }
    }

    func terminate() {
        guard !closed else { return }
        closed = true
        stdout.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? stdin.fileHandleForWriting.close()
    }

    @MainActor private func finish() {
        closed = true
        stdout.fileHandleForReading.readabilityHandler = nil
        onMessage?(nil)
        onMessage = nil
    }

    private func received(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty else { continue }
            let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    // Malformed lines are reported as a protocol violation.
                    self?.onMessage?(obj ?? ["t": "__malformed"])
                }
            }
        }
        if buffer.count > Self.maxMessage {
            buffer.removeAll()
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onMessage?(["t": "__oversize"]) } }
        }
    }

    // MARK: Measurement

    struct Usage { var cpuSeconds: Double; var footprint: UInt64 }

    /// CPU time (user + system) and physical footprint, or nil if the process is gone.
    func usage() -> Usage? {
        guard process.isRunning else { return nil }
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(process.processIdentifier, RUSAGE_INFO_V4, $0) }
        }
        guard r == 0 else { return nil }
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        let ns = Double(info.ri_user_time + info.ri_system_time) * Double(tb.numer) / Double(tb.denom)
        return Usage(cpuSeconds: ns / 1e9, footprint: info.ri_phys_footprint)
    }
}

/// Moves a JSON-compatible value to the write queue (it is never mutated after sending).
private struct UncheckedBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ v: [String: Any]) { value = v }
}
