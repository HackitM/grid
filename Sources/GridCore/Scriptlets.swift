import Foundation

/// uBlock Origin's scriptlet filters (`example.com##+js(name, arg, …)`), the rules that defeat ads
/// WebKit's content blocker can't reach, such as YouTube's pre-roll ads that arrive inside the
/// player's JSON.
///
/// A filter list only ever supplies a scriptlet *name* and its *arguments*. The code that runs is
/// GRID's own (`ScriptletLibrary`), so a list can't make a page run anything GRID didn't ship, and
/// scriptlets whose arguments are themselves code (`rpnt`, `trusted-rpnt`, `trusted-edit-inbound-object`
/// and friends) aren't supported at all. `trusted-*` scriptlets are accepted only from uBlock's own
/// lists, as in uBlock.
///
/// Only site-specific rules are kept: generic ones (`##+js(…)` or `*##+js(…)`) are skipped.
public struct ScriptletIndex: Sendable {
    struct Rule: Sendable {
        let call: [String]
        let exclude: [String]
    }

    private var rules: [Rule] = []
    /// Domain (`youtube.com`) or entity (`google.*`) → rule indices.
    private var byDomain: [String: [Int]] = [:]
    /// Domain, entity or `*` → call keys excepted there (`""` excepts every scriptlet).
    private var exceptions: [String: Set<String>] = [:]
    public private(set) var skipped = 0

    public init() {}

    public var ruleCount: Int { rules.count }
    public var isEmpty: Bool { rules.isEmpty }

    /// The scriptlet calls (`[name, args…]`) for a page on `host`, in list order, without duplicates.
    public func calls(for host: String) -> [[String]] {
        let keys = Self.lookupKeys(for: host.lowercased())
        guard !keys.isEmpty else { return [] }
        var excepted = exceptions["*"] ?? []
        for k in keys { if let e = exceptions[k] { excepted.formUnion(e) } }
        if excepted.contains("") { return [] }
        var indices: [Int] = []
        for k in keys { indices += byDomain[k] ?? [] }
        var seen = Set<String>()
        var out: [[String]] = []
        for i in indices.sorted() {
            let rule = rules[i]
            if rule.exclude.contains(where: keys.contains) { continue }
            let key = Self.key(rule.call)
            guard !excepted.contains(key), seen.insert(key).inserted else { continue }
            out.append(rule.call)
        }
        return out
    }

    // MARK: Building

    /// Reads the scriptlet rules out of filter lists, honouring `!#if` blocks. `isTrusted` names the
    /// lists whose `trusted-*` scriptlets are accepted.
    public static func build(_ lists: [FilterList], isTrusted: (String) -> Bool = { $0.hasPrefix("ublock-") }) -> ScriptletIndex {
        var index = ScriptletIndex()
        for list in lists {
            let trusted = isTrusted(list.name)
            var conditions = Preprocessor()
            list.text.enumerateLines { line, _ in
                if line.hasPrefix("!#") { conditions.directive(line); return }
                guard conditions.active, !line.hasPrefix("!"), line.contains("#+js(") else { return }
                index.add(line, trusted: trusted)
            }
        }
        return index
    }

    private mutating func add(_ line: String, trusted: Bool) {
        let isException: Bool
        let anchor: Range<String.Index>
        if let r = line.range(of: "#@#+js(") { isException = true; anchor = r }
        else if let r = line.range(of: "##+js(") { isException = false; anchor = r }
        else { return }
        let body = line[anchor.upperBound...].trimmingCharacters(in: .whitespaces)
        guard body.hasSuffix(")") else { skipped += 1; return }
        let inner = body.dropLast()
        var domains = (include: [String](), exclude: [String](), dropped: false, generic: false)
        for raw in line[..<anchor.lowerBound].split(separator: ",") {
            var d = raw.trimmingCharacters(in: .whitespaces).lowercased()
            let negated = d.hasPrefix("~")
            if negated { d.removeFirst() }
            if d == "*" { domains.generic = true; continue }
            guard Self.validDomain(d) else { domains.dropped = true; continue }
            if negated { domains.exclude.append(d) } else { domains.include.append(d) }
        }

        if isException {
            let call = inner.trimmingCharacters(in: .whitespaces).isEmpty ? [] : Self.parseCall(inner, trusted: true)
            if call == nil { return }   // an exception for a scriptlet GRID doesn't run anyway
            let key = call.map(Self.key) ?? ""
            let scope = domains.include.isEmpty && !domains.dropped ? ["*"] : domains.include
            for d in scope { exceptions[d, default: []].insert(key) }
            return
        }
        // Generic, or every site it names is one GRID can't express: skip rather than widen.
        guard !domains.include.isEmpty else { skipped += 1; return }
        guard let call = Self.parseCall(inner, trusted: trusted) else { skipped += 1; return }
        let i = rules.count
        rules.append(Rule(call: call, exclude: domains.exclude))
        for d in Set(domains.include) { byDomain[d, default: []].append(i) }
    }

    /// `name, arg, …` → `[canonical name, args…]`, or nil for a scriptlet GRID doesn't implement.
    static func parseCall(_ text: Substring, trusted: Bool) -> [String]? {
        var parts = parseArgs(text)
        guard !parts.isEmpty else { return nil }
        var name = parts[0]
        if name.hasSuffix(".js") { name.removeLast(3) }
        guard let canonical = aliases[name] ?? (aliases.values.contains(name) ? name : nil) else { return nil }
        if canonical.hasPrefix("trusted-"), !trusted { return nil }
        parts[0] = canonical
        return parts
    }

    /// Splits scriptlet arguments the way uBlock does: commas separate, `\,` is a literal comma,
    /// an argument wrapped in quotes ('…', "…" or `…`) may contain commas, and whitespace around
    /// each argument is dropped. Other backslashes are kept (they're usually regex escapes).
    static func parseArgs(_ text: Substring) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var i = 0
        func skipSpaces() { while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 } }
        while true {
            skipSpaces()
            var arg = ""
            var quoted = false
            if i < chars.count, chars[i] == "'" || chars[i] == "\"" || chars[i] == "`" {
                // Quoted only if the closing quote is followed by a comma or the end.
                let q = chars[i]
                var j = i + 1
                var s = ""
                while j < chars.count, chars[j] != q {
                    if chars[j] == "\\", j + 1 < chars.count, chars[j + 1] == q { s.append(q); j += 2; continue }
                    s.append(chars[j]); j += 1
                }
                if j < chars.count {
                    var k = j + 1
                    while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
                    if k == chars.count || chars[k] == "," { arg = s; quoted = true; i = k }
                }
            }
            if !quoted {
                while i < chars.count, chars[i] != "," {
                    if chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "," { arg.append(","); i += 2; continue }
                    arg.append(chars[i]); i += 1
                }
                arg = arg.trimmingCharacters(in: .whitespaces)
            }
            out.append(arg)
            guard i < chars.count, chars[i] == "," else { break }
            i += 1
        }
        if out == [""] { return [] }
        return out
    }

    /// Short and long names → the name `ScriptletLibrary` implements.
    static let aliases: [String: String] = [
        "set": "set-constant", "set-constant": "set-constant",
        "trusted-set": "trusted-set-constant", "trusted-set-constant": "trusted-set-constant",
        "aopr": "abort-on-property-read", "abort-on-property-read": "abort-on-property-read",
        "aopw": "abort-on-property-write", "abort-on-property-write": "abort-on-property-write",
        "acs": "abort-current-script", "abort-current-script": "abort-current-script",
        "acis": "abort-current-script", "abort-current-inline-script": "abort-current-script",
        "nowoif": "no-window-open-if", "no-window-open-if": "no-window-open-if",
        "prevent-window-open": "no-window-open-if", "window.open-defuser": "no-window-open-if",
        "nostif": "no-setTimeout-if", "no-setTimeout-if": "no-setTimeout-if",
        "prevent-setTimeout": "no-setTimeout-if", "setTimeout-defuser": "no-setTimeout-if",
        "nosiif": "no-setInterval-if", "no-setInterval-if": "no-setInterval-if",
        "prevent-setInterval": "no-setInterval-if", "setInterval-defuser": "no-setInterval-if",
        "nano-stb": "nano-setTimeout-booster", "nano-setTimeout-booster": "nano-setTimeout-booster",
        "nano-sib": "nano-setInterval-booster", "nano-setInterval-booster": "nano-setInterval-booster",
        "rmnt": "remove-node-text", "remove-node-text": "remove-node-text",
        "aeld": "addEventListener-defuser", "addEventListener-defuser": "addEventListener-defuser",
        "prevent-addEventListener": "addEventListener-defuser",
        "ra": "remove-attr", "remove-attr": "remove-attr",
        "rc": "remove-class", "remove-class": "remove-class",
        "noeval": "noeval", "noeval-if": "noeval-if", "prevent-eval-if": "noeval-if",
        "no-fetch-if": "no-fetch-if", "prevent-fetch": "no-fetch-if",
        "trusted-prevent-fetch": "trusted-prevent-fetch",
        "no-xhr-if": "no-xhr-if", "prevent-xhr": "no-xhr-if",
        "trusted-prevent-xhr": "trusted-prevent-xhr",
        "json-prune": "json-prune",
        "json-prune-fetch-response": "json-prune-fetch-response",
        "json-prune-xhr-response": "json-prune-xhr-response",
        "trusted-rpfr": "trusted-replace-fetch-response", "trusted-replace-fetch-response": "trusted-replace-fetch-response",
        "trusted-rpxr": "trusted-replace-xhr-response", "trusted-replace-xhr-response": "trusted-replace-xhr-response",
    ]

    static func key(_ call: [String]) -> String { call.joined(separator: "\u{1F}") }

    /// A hostname or an entity (`name.*`); no wildcards elsewhere, regexes or uBlock's `>>` forms.
    static func validDomain(_ d: String) -> Bool {
        var name = Substring(d)
        if name.hasSuffix(".*") { name = name.dropLast(2) }
        guard !name.isEmpty, name.count <= 253, !name.hasPrefix("."), !name.hasSuffix("."), !name.contains("..") else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// The keys a host is filed under: itself and each parent domain, plus the entity form
    /// (`google.*`) of any part followed by what looks like a public suffix (`com`, `co.uk`).
    static func lookupKeys(for host: String) -> Set<String> {
        let labels = host.split(separator: ".").map(String.init)
        guard !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty }) else { return [] }
        var keys = Set<String>()
        for i in labels.indices {
            keys.insert(labels[i...].joined(separator: "."))
            let rest = labels[(i + 1)...]
            if rest.count == 1 || (rest.count == 2 && rest.first!.count <= 3) {
                keys.insert(labels[i] + ".*")
            }
        }
        return keys
    }
}

/// uBlock's `!#if` / `!#else` / `!#endif` blocks, evaluated for GRID: none of uBlock's environment
/// tokens (`env_chromium`, `cap_html_filtering`, `ext_ubol`, …) describe GRID, so all are false.
struct Preprocessor {
    private var stack: [(outer: Bool, condition: Bool, inElse: Bool)] = []

    var active: Bool { stack.allSatisfy { $0.inElse ? !$0.condition : $0.condition } }

    mutating func directive(_ line: String) {
        if line.hasPrefix("!#if ") {
            stack.append((active, Self.evaluate(String(line.dropFirst(5))), false))
        } else if line.hasPrefix("!#else") {
            if !stack.isEmpty { stack[stack.count - 1].inElse = true }
        } else if line.hasPrefix("!#endif") {
            _ = stack.popLast()
        }
    }

    static func evaluate(_ expression: String, tokens: Set<String> = []) -> Bool {
        var parser = ExpressionParser(text: expression, truths: tokens)
        return parser.parseOr()
    }

    private struct ExpressionParser {
        let chars: [Character]
        let truths: Set<String>
        var i = 0

        init(text: String, truths: Set<String>) {
            chars = Array(text)
            self.truths = truths
        }

        mutating func skip() { while i < chars.count, chars[i].isWhitespace { i += 1 } }

        mutating func parseOr() -> Bool {
            var v = parseAnd()
            while true {
                skip()
                guard i + 1 < chars.count, chars[i] == "|", chars[i + 1] == "|" else { return v }
                i += 2
                let r = parseAnd()
                v = v || r
            }
        }

        mutating func parseAnd() -> Bool {
            var v = parseUnary()
            while true {
                skip()
                guard i + 1 < chars.count, chars[i] == "&", chars[i + 1] == "&" else { return v }
                i += 2
                let r = parseUnary()
                v = v && r
            }
        }

        mutating func parseUnary() -> Bool {
            skip()
            guard i < chars.count else { return false }
            if chars[i] == "!" { i += 1; return !parseUnary() }
            if chars[i] == "(" {
                i += 1
                let v = parseOr()
                skip()
                if i < chars.count, chars[i] == ")" { i += 1 }
                return v
            }
            var name = ""
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { name.append(chars[i]); i += 1 }
            if name.isEmpty { i += 1; return false }
            return truths.contains(name)
        }
    }
}
