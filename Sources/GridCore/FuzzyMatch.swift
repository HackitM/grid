import Foundation

/// Small, predictable ranking for names (apps, commands, files). Higher is better; nil = no match.
public enum FuzzyMatch {
    public static func score(_ query: String, in candidate: String) -> Int? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return 0 }
        let c = candidate.lowercased()
        if c == q { return 1000 }
        if c.hasPrefix(q) { return 900 - min(c.count - q.count, 100) }
        if let r = wordBoundaryRange(of: q, in: c) {
            return 700 - min(c.distance(from: c.startIndex, to: r.lowerBound), 100)
        }
        if let r = c.range(of: q) {
            return 500 - min(c.distance(from: c.startIndex, to: r.lowerBound), 100)
        }
        if let initials = initialsScore(q, c) { return initials }
        return subsequenceScore(q, c)
    }

    private static func isBoundary(_ ch: Character) -> Bool {
        ch == " " || ch == "-" || ch == "_" || ch == "." || ch == "/" || ch == "("
    }

    private static func wordBoundaryRange(of q: String, in c: String) -> Range<String.Index>? {
        var searchStart = c.startIndex
        while let r = c.range(of: q, range: searchStart..<c.endIndex) {
            if r.lowerBound == c.startIndex || isBoundary(c[c.index(before: r.lowerBound)]) { return r }
            searchStart = c.index(after: r.lowerBound)
        }
        return nil
    }

    /// "vsc" matches "Visual Studio Code".
    private static func initialsScore(_ q: String, _ c: String) -> Int? {
        var initials = ""
        var prev: Character = " "
        for ch in c {
            if isBoundary(prev) && !isBoundary(ch) { initials.append(ch) }
            prev = ch
        }
        guard initials.count >= q.count, initials.hasPrefix(q) else { return nil }
        return 600
    }

    private static func subsequenceScore(_ q: String, _ c: String) -> Int? {
        var qi = q.startIndex
        var score = 100
        var run = 0
        for ch in c {
            guard qi < q.endIndex else { break }
            if ch == q[qi] {
                run += 1
                score += run * 2
                qi = q.index(after: qi)
            } else {
                run = 0
                score -= 1
            }
        }
        return qi == q.endIndex ? max(score, 1) : nil
    }
}
