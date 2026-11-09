import Darwin
import Foundation
import JavaScriptCore

// GridWidgetHost: runs one widget's JavaScript with no ambient authority.
//
// Security model (docs/WIDGETS.md): this process is treated as fully untrusted by GRID. It gets
// a bare JavaScriptCore context (no file, network, process, timer or module APIs), enters a
// deny-by-default macOS sandbox before any widget code is evaluated, and can only talk to GRID by
// writing JSON lines to stdout. GRID checks every request against the user's approvals.

// The JIT is not needed for small widget scripts; the interpreter is a smaller attack surface.
setenv("JSC_useJIT", "false", 1)

// MARK: - Resource limits

var noCore = rlimit(rlim_cur: 0, rlim_max: 0)
setrlimit(RLIMIT_CORE, &noCore)
var files = rlimit(rlim_cur: 16, rlim_max: 16)
setrlimit(RLIMIT_NOFILE, &files)
var procs = rlimit(rlim_cur: 0, rlim_max: 0)
setrlimit(RLIMIT_NPROC, &procs)

// MARK: - Memory guard
// GRID samples this process every half second; a tight allocation loop can outrun that, so the
// host also checks its own footprint every 20 ms and exits past 200 MB (GRID records the strike).
func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}
let memoryGuard = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
memoryGuard.schedule(deadline: .now(), repeating: .milliseconds(20))
memoryGuard.setEventHandler { if footprint() > 200 * 1024 * 1024 { _exit(4) } }
memoryGuard.resume()

// MARK: - Output

let maxMessage = 1 << 20
let outLock = NSLock()

func emit(_ line: String) {
    var data = Data(line.utf8)
    if data.count > maxMessage {
        data = Data(#"{"t":"log","level":"error","msg":"message larger than 1 MiB dropped"}"#.utf8)
    }
    data.append(0x0A)
    outLock.lock()
    data.withUnsafeBytes { buf in
        var off = 0
        while off < buf.count {
            let n = write(1, buf.baseAddress! + off, buf.count - off)
            if n <= 0 { if errno == EINTR { continue }; exit(0) }   // GRID went away
            off += n
        }
    }
    outLock.unlock()
}

func emitJSON(_ obj: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) { emit(s) }
}

// MARK: - JavaScript context

guard let context = JSContext() else { emitJSON(["t": "loadError", "error": "JavaScript engine unavailable"]); exit(1) }
context.name = "GRID widget"
context.exceptionHandler = { _, exception in
    let msg = exception?.toString() ?? "unknown error"
    let line = exception?.objectForKeyedSubscript("line")?.toInt32() ?? 0
    emitJSON(["t": "log", "level": "error", "msg": "Uncaught: \(msg)" + (line > 0 ? " (line \(line))" : "")])
}

let send: @convention(block) (String) -> Void = { s in emit(s) }
context.setObject(send, forKeyedSubscript: "__grid_send" as NSString)
context.evaluateScript(prelude, withSourceURL: URL(string: "grid://prelude.js"))
let dispatchFn = context.objectForKeyedSubscript("__grid_dispatch")!

// Warm up everything JavaScriptCore loads lazily from disk (ICU locale, collation, number and
// time zone data) before the sandbox closes the filesystem; touching it later would kill the host.
context.evaluateScript(#"""
(function () {
  const d = new Date(1700000000000);
  d.toLocaleString(); d.toLocaleDateString(); d.toLocaleTimeString(); d.toString();
  new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(d);
  new Intl.DateTimeFormat("en-US", { timeZone: "UTC", weekday: "long", month: "long" }).format(d);
  (1234567.891).toLocaleString(); new Intl.NumberFormat(undefined, { style: "percent" }).format(0.5);
  new Intl.NumberFormat("en-US", { notation: "compact" }).format(12345);
  new Intl.RelativeTimeFormat(undefined, { numeric: "auto" }).format(-1, "day");
  new Intl.PluralRules().select(2); new Intl.ListFormat ? new Intl.ListFormat().format(["a", "b"]) : 0;
  "a".localeCompare("b"); ["b", "a"].sort(new Intl.Collator().compare);
  "Straße".toLocaleUpperCase(); "İ".toLocaleLowerCase();
  "x".normalize("NFD"); /\p{L}/u.test("é");
})();
"""#)

// MARK: - Sandbox

@_silgen_name("sandbox_init")
func sandbox_init(_ profile: UnsafePointer<CChar>, _ flags: UInt64, _ errorbuf: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

/// Deny everything. Frameworks are already loaded and stdin/stdout are already open, so the host
/// needs no new file, network, IPC or process access to do its job.
let profile = """
(version 1)
(deny default)
(allow sysctl-read)
"""
var sbError: UnsafeMutablePointer<CChar>?
if sandbox_init(profile, 0, &sbError) != 0 {
    let why = sbError.map { String(cString: $0) } ?? "unknown"
    emitJSON(["t": "loadError", "error": "Could not enter the widget sandbox (\(why)); refusing to run."])
    exit(2)
}

// `GridWidgetHost --selftest` proves the sandbox holds: each probe must fail. Used by
// scripts/qa and the test suite; it prints one line and exits.
if CommandLine.arguments.contains("--selftest") {
    var leaks: [String] = []
    if open("/etc/hosts", O_RDONLY) >= 0 { leaks.append("read /etc/hosts") }
    if open(NSHomeDirectory() + "/.zshrc", O_RDONLY) >= 0 { leaks.append("read ~/.zshrc") }
    if open(NSTemporaryDirectory() + "grid-host-probe", O_WRONLY | O_CREAT, 0o600) >= 0 { leaks.append("write tmp") }
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    if sock >= 0 {
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                               sin_port: in_port_t(UInt16(80).bigEndian), sin_addr: in_addr(s_addr: inet_addr("1.1.1.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if r == 0 || errno == EINPROGRESS { leaks.append("network connect") }
    }
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
    if posix_spawn(&pid, "/usr/bin/true", nil, nil, argv, nil) == 0 { leaks.append("spawn process") }
    print(leaks.isEmpty ? "SANDBOX OK" : "SANDBOX LEAK: " + leaks.joined(separator: ", "))
    exit(leaks.isEmpty ? 0 : 1)
}

// MARK: - Input

/// Reads newline-delimited JSON from stdin on a background thread; JavaScript runs on main.
Thread.detachNewThread {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = read(0, &chunk, chunk.count)
        if n <= 0 { if n < 0 && errno == EINTR { continue }; exit(0) }      // GRID closed the pipe
        buffer.append(contentsOf: chunk[0..<n])
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            DispatchQueue.main.async { _ = dispatchFn.call(withArguments: [line]) }
        }
        if buffer.count > maxMessage * 4 { exit(3) }                       // malformed input
    }
}

dispatchMain()
