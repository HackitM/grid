import Darwin
import Foundation

/// Read-only inspection of local processes via libproc. Used to learn a shell's *actual* current
/// directory and whether a foreground job is running, without injecting anything into the shell.
public enum ProcessInspector {
    /// Current working directory of `pid` (must be owned by the same user).
    public static func currentDirectory(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard r == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// Short process name (e.g. "zsh", "vim", "node").
    public static func name(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 256)
        let r = proc_name(pid, &buf, UInt32(buf.count))
        guard r > 0 else { return nil }
        return String(cString: buf)
    }

    /// Foreground process group of the terminal whose master side is `fd`.
    public static func foregroundProcessGroup(ptyMaster fd: Int32) -> pid_t? {
        guard fd >= 0 else { return nil }
        let pg = tcgetpgrp(fd)
        return pg > 0 ? pg : nil
    }

    public static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Direct children of `pid`.
    public static func children(of pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(count) * 2)
        let n = proc_listchildpids(pid, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        return Array(buf.prefix(Int(n))).filter { $0 > 0 }
    }

    /// All descendants (depth-first), useful for diagnostics and cleanup verification.
    public static func descendants(of pid: pid_t) -> [pid_t] {
        var out: [pid_t] = []
        var stack = children(of: pid)
        while let p = stack.popLast() {
            out.append(p)
            stack.append(contentsOf: children(of: p))
        }
        return out
    }
}
