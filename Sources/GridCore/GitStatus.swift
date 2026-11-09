import Foundation

/// Parsed `git status --porcelain=v2 --branch` output.
public struct GitStatus: Equatable, Sendable {
    public var branch: String = ""          // "(detached)" when HEAD is detached
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var staged = 0
    public var modified = 0                 // unstaged changes to tracked files
    public var untracked = 0
    public var conflicted = 0

    public init() {}

    public var isClean: Bool { staged == 0 && modified == 0 && untracked == 0 && conflicted == 0 }

    public static func parse(porcelainV2 text: String) -> GitStatus {
        var s = GitStatus()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                s.branch = head == "(detached)" ? "(detached)" : head
            } else if line.hasPrefix("# branch.upstream ") {
                s.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                for part in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if part.hasPrefix("+") { s.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { s.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                // "1 XY ..." — X = index (staged) state, Y = worktree state; "." = unchanged.
                let fields = line.split(separator: " ", maxSplits: 2)
                guard fields.count >= 2, fields[1].count == 2 else { continue }
                let xy = Array(fields[1])
                if xy[0] != "." { s.staged += 1 }
                if xy[1] != "." { s.modified += 1 }
            } else if line.hasPrefix("u ") {
                s.conflicted += 1
            } else if line.hasPrefix("? ") {
                s.untracked += 1
            }
        }
        return s
    }
}
