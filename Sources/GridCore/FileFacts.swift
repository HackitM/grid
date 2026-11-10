import Darwin
import Foundation
import ImageIO

/// Extra facts about one file that matter before you hand it to a shell: is it executable, what
/// interpreter would run it, did it come from the internet, what's inside a text file.
/// Everything is read from the filesystem; nothing is followed or executed. Reads are bounded
/// (first 256 KiB for text stats) and only regular files are opened (never FIFOs or devices).
public struct FileFacts: Equatable, Sendable {
    public var isExecutable = false
    /// First line when the file starts with "#!".
    public var shebang: String?
    /// "Downloaded with Safari · 3 Nov 2026" style origin from com.apple.quarantine.
    public var quarantineAgent: String?
    public var quarantineDate: Date?
    /// URLs from kMDItemWhereFroms (download source / referrer).
    public var whereFrom: [String] = []
    public var text: TextStats?
    public var pixelSize: (width: Int, height: Int)? { pixelWidth.flatMap { w in pixelHeight.map { (w, $0) } } }
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// Extended attribute names (for the curious), excluding the ones summarized above.
    public var otherAttributes: [String] = []

    public struct TextStats: Equatable, Sendable {
        public var lines: Int
        public var encoding: String          // "ASCII" | "UTF-8"
        public var lineEndings: String       // "LF" | "CRLF" | "CR" | "mixed" | "none"
        public var sampledBytes: Int
        public var isComplete: Bool          // false when the file is larger than the sample
    }

    public init() {}

    public static let sampleLimit = 256 * 1024

    /// Reads facts for `path` (does not follow a final symlink for xattrs; text/image reads
    /// require a regular file).
    public static func read(path: String) -> FileFacts {
        var f = FileFacts()
        var st = stat()
        guard lstat(path, &st) == 0 else { return f }
        let isRegular = (st.st_mode & S_IFMT) == S_IFREG
        f.isExecutable = isRegular && access(path, X_OK) == 0

        for name in xattrNames(path) {
            switch name {
            case "com.apple.quarantine":
                if let v = xattr(path, name).flatMap({ String(data: $0, encoding: .utf8) }) {
                    (f.quarantineAgent, f.quarantineDate) = parseQuarantine(v)
                }
            case "com.apple.metadata:kMDItemWhereFroms":
                if let d = xattr(path, name),
                   let arr = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String] {
                    f.whereFrom = arr.filter { !$0.isEmpty }.prefix(3).map { String($0.prefix(300)) }
                }
            default:
                f.otherAttributes.append(name)
            }
        }

        guard isRegular, let sample = readPrefix(path, limit: sampleLimit) else { return f }
        if sample.starts(with: Array("#!".utf8)) {
            let line = sample.prefix(while: { $0 != 0x0A && $0 != 0x0D }).prefix(200)
            f.shebang = String(decoding: line, as: UTF8.self)
        }
        f.text = textStats(sample, complete: Int64(st.st_size) <= Int64(sample.count))
        if f.text == nil, let src = CGImageSourceCreateWithData(sample as CFData, nil) ?? CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           CGImageSourceGetCount(src) > 0,
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any] {
            f.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
            f.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
        }
        return f
    }

    /// "0083;6543a1b2;Safari;UUID" → ("Safari", date). Agent may be empty.
    public static func parseQuarantine(_ v: String) -> (String?, Date?) {
        let parts = v.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let date = parts.count > 1 ? UInt64(parts[1], radix: 16).map { Date(timeIntervalSince1970: TimeInterval($0)) } : nil
        let agent = parts.count > 2 && !parts[2].isEmpty ? String(parts[2].prefix(80)) : nil
        return (agent, date)
    }

    /// Line count, encoding and line-ending style; nil for binary data (NUL bytes or invalid UTF-8).
    public static func textStats(_ data: Data, complete: Bool) -> TextStats? {
        if data.isEmpty { return TextStats(lines: 0, encoding: "ASCII", lineEndings: "none", sampledBytes: 0, isComplete: complete) }
        if data.contains(0) { return nil }
        // Allow a multi-byte character cut at the sample boundary.
        var valid = String(data: data, encoding: .utf8) != nil
        if !valid && !complete {
            for cut in 1...3 where data.count > cut {
                if String(data: data.dropLast(cut), encoding: .utf8) != nil { valid = true; break }
            }
        }
        guard valid else { return nil }
        var lf = 0, crlf = 0, cr = 0
        var prevCR = false
        var ascii = true
        for b in data {
            if b >= 0x80 { ascii = false }
            if b == 0x0A {
                if prevCR { crlf += 1; cr -= 1 } else { lf += 1 }
            }
            if b == 0x0D { cr += 1 }
            prevCR = b == 0x0D
        }
        let kinds = [(lf, "LF"), (crlf, "CRLF"), (cr, "CR")].filter { $0.0 > 0 }
        let endings = kinds.isEmpty ? "none" : (kinds.count == 1 ? kinds[0].1 : "mixed")
        let breaks = lf + crlf + cr
        let lastIsBreak = data.last == 0x0A || data.last == 0x0D
        return TextStats(lines: breaks + (lastIsBreak ? 0 : 1), encoding: ascii ? "ASCII" : "UTF-8",
                         lineEndings: endings, sampledBytes: data.count, isComplete: complete)
    }

    static func readPrefix(_ path: String, limit: Int) -> Data? {
        let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        var buf = [UInt8](repeating: 0, count: limit)
        let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, limit) }
        guard n >= 0 else { return nil }
        return Data(buf.prefix(n))
    }

    static func xattrNames(_ path: String) -> [String] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buf = [CChar](repeating: 0, count: size)
        let n = listxattr(path, &buf, size, XATTR_NOFOLLOW)
        guard n > 0 else { return [] }
        return buf.prefix(n).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }

    static func xattr(_ path: String, _ name: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size < 64 * 1024 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        let n = getxattr(path, name, &buf, size, 0, XATTR_NOFOLLOW)
        return n > 0 ? Data(buf.prefix(n)) : nil
    }

    public static func == (a: FileFacts, b: FileFacts) -> Bool {
        a.isExecutable == b.isExecutable && a.shebang == b.shebang && a.quarantineAgent == b.quarantineAgent
            && a.quarantineDate == b.quarantineDate && a.whereFrom == b.whereFrom && a.text == b.text
            && a.pixelWidth == b.pixelWidth && a.pixelHeight == b.pixelHeight && a.otherAttributes == b.otherAttributes
    }
}

/// Total size of a folder's contents, measured on demand (cancellable, bounded).
public enum FolderMeasure {
    public struct Result: Equatable, Sendable {
        public var bytes: Int64
        public var files: Int
        public var folders: Int
        public var unreadable: Int
        public var truncated: Bool     // stopped at the item limit
    }

    /// Walks `url` without following symlinks or entering packages' symlinked contents. Stops after
    /// `limit` items or when `isCancelled` returns true.
    public static func measure(_ url: URL, limit: Int = 200_000, isCancelled: () -> Bool = { false }) -> Result {
        var r = Result(bytes: 0, files: 0, folders: 0, unreadable: 0, truncated: false)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                     errorHandler: { _, _ in r.unreadable += 1; return true }) else { return r }
        let keySet = Set(keys)
        var seen = 0
        while let item = e.nextObject() as? URL {
            seen += 1
            if seen > limit { r.truncated = true; break }
            if seen % 512 == 0, isCancelled() { r.truncated = true; break }
            guard let v = try? item.resourceValues(forKeys: keySet) else { r.unreadable += 1; continue }
            if v.isSymbolicLink == true { r.files += 1; continue }
            if v.isDirectory == true { r.folders += 1; continue }
            r.files += 1
            r.bytes += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return r
    }
}
