// Sends one DEBUG-build QA command to a running GRID that was launched with `--qa`.
// Usage: gridctl '<json>'
// Transport: Unix socket at $DARWIN_USER_TEMP_DIR/grid-qa.sock (per-user, not reachable by others).
import Darwin
import Foundation

let json = CommandLine.arguments.dropFirst().joined(separator: " ")
let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("grid-qa.sock")

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fputs("gridctl: socket() failed\n", stderr); exit(1) }
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let bytes = Array(path.utf8)
withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    raw.copyBytes(from: bytes)
    raw[bytes.count] = 0
}
let ok = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard ok == 0 else {
    fputs("gridctl: GRID is not listening (debug build launched with --qa?) at \(path)\n", stderr)
    exit(1)
}
let payload = Array(json.utf8)
_ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
close(fd)
