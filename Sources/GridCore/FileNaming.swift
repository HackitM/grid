import Darwin
import Foundation

public enum FileNaming {
    /// Finder-style non-conflicting name: "report.pdf" -> "report 2.pdf" -> "report 3.pdf";
    /// folders and extensionless names: "untitled folder" -> "untitled folder 2".
    public static func uniqueName(for name: String, isDirectory: Bool = false, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let ns = name as NSString
        let ext = isDirectory ? "" : ns.pathExtension
        var stem = ext.isEmpty ? name : ns.deletingPathExtension
        // "report 2" -> continue numbering from 2 instead of producing "report 2 2".
        var n = 2
        if let r = stem.range(of: #" (\d+)$"#, options: .regularExpression), let v = Int(stem[r].dropFirst()) {
            stem = String(stem[..<r.lowerBound])
            n = v + 1
        }
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// Returns an error message if `name` cannot be used as a single file name, else nil.
    public static func validate(_ name: String) -> String? {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "Name can't be empty." }
        if t != name && (name.hasPrefix(" ") || name.hasSuffix(" ")) { return "Name can't start or end with a space." }
        if name == "." || name == ".." { return "“\(name)” is reserved." }
        if name.contains("/") { return "Name can't contain “/”." }
        if name.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 || $0.value == 0x7F }) {
            return "Name can't contain control characters."
        }
        if name.utf8.count > 255 { return "Name is too long (max 255 bytes)." }
        return nil
    }

    /// Whether anything occupies `path`, without following a final symlink. A dangling link
    /// still takes up its name, which `FileManager.fileExists` (it follows links) reports as free.
    public static func itemExists(atPath path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// True for a real directory; false for files and for symlinks, even ones that point at a
    /// directory (moving or copying a link never descends into its target).
    public static func isRealDirectory(atPath path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// True if `child` is `ancestor` or lies inside it (path-component aware).
    public static func isSameOrInside(_ child: URL, _ ancestor: URL) -> Bool {
        let c = child.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let a = ancestor.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return c.count >= a.count && Array(c.prefix(a.count)) == a
    }
}
