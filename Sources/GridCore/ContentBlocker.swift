import Foundation

// Converts adblock filter lists (uBlock Origin / Adblock Plus syntax) into WebKit content-blocker
// JSON (the format `WKContentRuleListStore.compileContentRuleList` accepts).
//
// Design notes
// - Conservative: a filter that cannot be expressed faithfully is skipped (and counted) rather than
//   approximated. One rejected `url-filter` makes WebKit reject an entire list, and one invalid CSS
//   selector makes WebKit silently drop the rule (and so every selector grouped with it), so every
//   emitted regex and selector is validated against the subset WebKit's compiler accepts.
// - Network output: each "network-N" chunk is [block rules][all exception rules][$important blocks].
//   WebKit evaluates a list in order and `ignore-previous-rules` only cancels earlier rules in the same
//   list, so every chunk carries the full exception set, and `$important` filters are placed after the
//   exceptions so exceptions cannot cancel them (which is what $important means).
// - Untyped network filters omit `resource-type`, so they also apply to top-level navigations and
//   popups. That matches uBlock Origin's "strict blocking" of root documents. Negated types
//   (`$~image`) complement the regular (non-document, non-popup) type set as in uBO.
// - Cosmetic output: generic (`##sel`) and domain-specific (`a.com##sel`) hides live in separate lists
//   ("cosmetic-generic-N" / "cosmetic-specific-N") so `$generichide` / `$specifichide` / `$elemhide` /
//   `$document` exceptions can be expressed as `ignore-previous-rules` scoped by `if-domain` in just the
//   list(s) they affect. Selectors are comma-joined into groups (<= 250 plain selectors, <= 25 when a
//   selector uses functional pseudo-classes, to bound the blast radius of a selector WebKit might still
//   reject). `:has()` is allowed (WebKit supports it); every uBO/ABP procedural extension is rejected.
// - Output is deterministic: lists are processed in order, groups are sorted, and `digest` is a SHA-256
//   over the converter version, the chunk size and every list's name and text.

// MARK: - Public API

/// One downloaded filter list.
public struct FilterList: Hashable, Sendable {
    public let name: String
    public let text: String
    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

/// One compiled rule list, ready for `WKContentRuleListStore.compileContentRuleList(forIdentifier:encodedContentRuleList:)`.
public struct ContentRuleChunk: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case network
        case cosmeticGeneric = "cosmetic-generic"
        case cosmeticSpecific = "cosmetic-specific"
    }
    /// Short, `[a-z0-9-]`, unique within one output: "network-0", "cosmetic-generic-0", "cosmetic-specific-0", …
    public let identifier: String
    public let kind: Kind
    /// A JSON array of `{trigger, action}` objects.
    public let json: String
    public let ruleCount: Int
}

/// Why a filter produced no rule.
public enum ContentBlockerSkipReason: String, CaseIterable, Hashable, Sendable {
    /// `$redirect`, `$csp`, `$removeparam`, `$denyallow`, `$method`, … (or an option misused, e.g. `$elemhide` on a block filter).
    case unsupportedOption
    /// `/regex/` filter using constructs WebKit's regex engine lacks (alternation, `{n}`, `\d`, lookaround, …).
    case unsupportedRegex
    /// Pattern contains non-ASCII characters (WebKit patterns must be ASCII; Foundation has no IDNA encoder).
    case nonASCII
    /// `##+js(…)`, `#%#`, `#$#` and other script / style injection.
    case scriptlet
    /// `##^…` HTML filters and `$$` filters.
    case htmlFilter
    /// `#?#`, `:has-text()`, `:style()`, `:upward()`, … procedural cosmetic filters.
    case proceduralCosmetic
    /// Selector failed the conservative CSS selector check.
    case invalidSelector
    /// Pattern would match every URL and nothing else narrows it.
    case tooGeneric
    /// Both included and excluded domains (WebKit allows only one of `if-domain` / `unless-domain`).
    case mixedDomains
    /// Entity (`example.*`), regex, or non-ASCII domain where the filter could not be narrowed instead.
    case unsupportedDomain
    /// Removed by a matching `$badfilter`.
    case badfilter
    /// Removed by a matching `#@#` cosmetic exception.
    case cosmeticException
    /// Contradictory options (`$third-party,~third-party`, every type negated, …).
    case conflictingOptions
    /// Dropped to stay within the per-list rule budget.
    case ruleBudget
    /// Could not be parsed at all (stray whitespace, malformed options, …).
    case unparsable
}

public struct ContentBlockerListStats: Hashable, Sendable {
    public let name: String
    /// Filter lines (everything that is not blank, a comment or a header).
    public let parsed: Int
    /// Filters that contributed at least one rule (before de-duplication).
    public let converted: Int
    public let skipped: [ContentBlockerSkipReason: Int]
}

public struct ContentBlockerStats: Hashable, Sendable {
    public let parsed: Int
    public let converted: Int
    public let skipped: [ContentBlockerSkipReason: Int]
    /// Identical rules produced by more than one filter (counted once in the output).
    public let duplicates: Int
    public let networkBlockRules: Int
    public let networkExceptionRules: Int
    public let cosmeticRules: Int
    public let cosmeticSelectors: Int
    public let lists: [ContentBlockerListStats]

    public var skippedTotal: Int { skipped.values.reduce(0, +) }
    public var totalRules: Int { networkBlockRules + networkExceptionRules + cosmeticRules }
}

public struct ContentBlockerOutput: Sendable {
    /// Hex SHA-256 over the converter version, the chunk size and every list's name and text.
    public let digest: String
    /// Add these to a `WKUserContentController` in this order.
    public let ruleLists: [ContentRuleChunk]
    /// One line for Settings, e.g. "112,340 rules from 8 lists · 6,021 skipped".
    public let summary: String
    public let stats: ContentBlockerStats
}

public enum ContentBlockerCompiler {
    /// Bump when the conversion changes so cached compiled lists are invalidated.
    public static let formatVersion = 2
    /// WebKit rejects a JSON array with more rules than this ("Too many rules in JSON array").
    public static let webKitRuleLimit = 150_000

    public static func compile(_ lists: [FilterList], maxRulesPerList: Int = 50_000) -> ContentBlockerOutput {
        var compilation = Compilation(maxRulesPerList: min(max(maxRulesPerList, 16), webKitRuleLimit))
        compilation.run(lists)
        return compilation.output(digest: digest(of: lists, maxRulesPerList: maxRulesPerList))
    }

    /// Deterministic content hash of the inputs; equal digests mean `compile` would produce equal output.
    public static func digest(of lists: [FilterList], maxRulesPerList: Int = 50_000) -> String {
        var sha = ContentBlockerSHA256()
        sha.update(Array("grid-content-blocker/\(formatVersion)/\(maxRulesPerList)\n".utf8))
        for list in lists {
            sha.update(Array(list.name.utf8))
            sha.update([0])
            sha.update(Array(list.text.utf8))
            sha.update([0])
        }
        return sha.finalizeHex()
    }
}

// MARK: - Internal model

enum ResourceType: Int, CaseIterable {
    // Order defines the canonical order of `resource-type` arrays.
    case topDocument, childDocument, image, styleSheet, script, font, media, ping, fetch, websocket, other, svgDocument, popup

    var webKitName: String {
        switch self {
        case .topDocument: return "top-document"
        case .childDocument: return "child-document"
        case .image: return "image"
        case .styleSheet: return "style-sheet"
        case .script: return "script"
        case .font: return "font"
        case .media: return "media"
        case .ping: return "ping"
        case .fetch: return "fetch"
        case .websocket: return "websocket"
        case .other: return "other"
        case .svgDocument: return "svg-document"
        case .popup: return "popup"
        }
    }

    /// What an untyped or negated-type filter covers in uBO: everything except root documents and popups.
    static let regular: Set<ResourceType> = [.childDocument, .image, .styleSheet, .script, .font, .media, .ping, .fetch, .websocket, .other, .svgDocument]

    static func named(_ option: Substring) -> ResourceType? {
        switch option {
        case "document", "doc": return .topDocument
        case "subdocument", "frame": return .childDocument
        case "image": return .image
        case "stylesheet", "css": return .styleSheet
        case "script": return .script
        case "font": return .font
        case "media": return .media
        case "ping", "beacon": return .ping
        case "xmlhttprequest", "xhr": return .fetch
        case "websocket": return .websocket
        case "other": return .other
        case "popup": return .popup
        default: return nil
        }
    }

    /// Types uBO knows that WKWebView has no counterpart for. They are dropped from a type set; a filter
    /// whose only types are these is skipped.
    static func isInexpressible(_ option: Substring) -> Bool {
        switch option {
        case "object", "object-subrequest", "webrtc", "inline-script", "inline-font", "cname", "csp-report":
            return true
        default:
            return false
        }
    }
}

struct NetworkFilter {
    var pattern: Substring
    var isException = false
    var isRegex = false
    var types: Set<ResourceType> = []
    var negatedTypes: Set<ResourceType> = []
    var hadInexpressibleType = false
    var all = false
    var thirdParty: Bool?
    var includeDomains: [String] = []
    var excludeDomains: [String] = []
    var droppedDomains = false
    var matchCase = false
    var important = false
    var badfilter = false
    var elemhide = false
    var generichide = false
    var specifichide = false
}

struct NetworkRule: Hashable {
    enum Action { case block, ignorePrevious }
    var urlFilter: String
    var caseSensitive = false
    var resourceTypes: [ResourceType]?
    var loadType: String?
    var ifDomain: [String]?
    var unlessDomain: [String]?
    var ifTopURL: String?
    var action: Action
    var important = false

    var json: String {
        var s = "{\"trigger\":{\"url-filter\":\""
        s += JSON.escape(urlFilter)
        s += "\""
        if caseSensitive { s += ",\"url-filter-is-case-sensitive\":true" }
        if let types = resourceTypes {
            s += ",\"resource-type\":["
            s += types.map { "\"\($0.webKitName)\"" }.joined(separator: ",")
            s += "]"
        }
        if let load = loadType { s += ",\"load-type\":[\"\(load)\"]" }
        if let domains = ifDomain { s += ",\"if-domain\":" + JSON.array(domains) }
        if let domains = unlessDomain { s += ",\"unless-domain\":" + JSON.array(domains) }
        if let top = ifTopURL { s += ",\"if-top-url\":[\"" + JSON.escape(top) + "\"]" }
        s += "},\"action\":{\"type\":\""
        s += action == .block ? "block" : "ignore-previous-rules"
        s += "\"}}"
        return s
    }
}

struct CosmeticFilter {
    var selector: String
    var includeDomains: [String]
    var excludeDomains: [String]
    var isException: Bool
}

enum CosmeticScope { case generic, specific }

enum JSON {
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count + 8)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    static func array(_ strings: [String]) -> String {
        "[" + strings.map { "\"" + escape($0) + "\"" }.joined(separator: ",") + "]"
    }
}

// MARK: - Compilation

struct Compilation {
    let maxRulesPerList: Int

    // Per-list bookkeeping.
    private var listNames: [String] = []
    private var listParsed: [Int] = []
    private var listConverted: [Int] = []
    private var listSkipped: [[ContentBlockerSkipReason: Int]] = []

    // Pass 1 output.
    private var badfilters: Set<String> = []
    private var networkLines: [(list: Int, text: String)] = []
    private var cosmeticLines: [(list: Int, text: String, anchor: Range<String.Index>, marker: String, isException: Bool)] = []

    // Pass 2 output.
    private var blockRules: [NetworkRule] = []
    private var exceptionRules: [NetworkRule] = []
    private var importantRules: [NetworkRule] = []
    private var seenRules: Set<NetworkRule> = []
    private var duplicates = 0
    private var wholeSiteDomains: Set<String> = []
    private var genericHideDomains: Set<String> = []
    private var specificHideDomains: Set<String> = []
    private var cosmeticFilters: [(list: Int, filter: CosmeticFilter)] = []

    private var cosmeticRuleCount = 0
    private var cosmeticSelectorCount = 0

    init(maxRulesPerList: Int) {
        self.maxRulesPerList = maxRulesPerList
    }

    // MARK: Driver

    mutating func run(_ lists: [FilterList]) {
        for (index, list) in lists.enumerated() {
            listNames.append(list.name)
            listParsed.append(0)
            listConverted.append(0)
            listSkipped.append([:])
            classifyLines(of: list.text, list: index)
        }
        for entry in networkLines {
            translateNetwork(entry.text, list: entry.list)
        }
        for entry in cosmeticLines {
            parseCosmetic(entry)
        }
    }

    private mutating func skip(_ reason: ContentBlockerSkipReason, list: Int) {
        listSkipped[list][reason, default: 0] += 1
    }

    private mutating func converted(list: Int) {
        listConverted[list] += 1
    }

    // MARK: Pass 1 — line classification

    private mutating func classifyLines(of text: String, list: Int) {
        var rest = Substring(text)
        while !rest.isEmpty {
            let line: Substring
            if let newline = rest.firstIndex(of: "\n") {
                line = rest[..<newline]
                rest = rest[rest.index(after: newline)...]
            } else {
                line = rest
                rest = rest[rest.endIndex...]
            }
            classify(Compilation.trimmed(line), list: list)
        }
    }

    static func trimmed(_ line: Substring) -> Substring {
        var s = line
        while let first = s.utf8.first, first == 0x20 || first == 0x09 || first == 0x0D { s = s.dropFirst() }
        while let last = s.utf8.last, last == 0x20 || last == 0x09 || last == 0x0D { s = s.dropLast() }
        return s
    }

    private mutating func classify(_ line: Substring, list: Int) {
        guard let first = line.utf8.first else { return }
        if first == UInt8(ascii: "!") || first == UInt8(ascii: "[") { return }
        if Compilation.cosmeticAnchor(in: line) != nil {
            listParsed[list] += 1
            // Indices must belong to the copied String, not to the list's text.
            let text = String(line)
            let cosmetic = Compilation.cosmeticAnchor(in: Substring(text))!
            cosmeticLines.append((list, text, cosmetic.range, cosmetic.marker, cosmetic.isException))
            return
        }
        if first == UInt8(ascii: "#") { return } // hosts-file style comment
        listParsed[list] += 1

        // Hosts-file lines: "0.0.0.0 host [host…]" / "127.0.0.1 host".
        if line.utf8.contains(UInt8(ascii: " ")) || line.utf8.contains(UInt8(ascii: "\t")) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if let address = parts.first, Compilation.hostsAddresses.contains(address), parts.count >= 2 {
                var produced = false
                for host in parts.dropFirst() {
                    if host.hasPrefix("#") { break }
                    let lowered = host.lowercased()
                    if Compilation.hostsIgnored.contains(lowered) { continue }
                    if Compilation.isPlainHostname(Substring(lowered)) {
                        networkLines.append((list, "||\(lowered)^"))
                        produced = true
                    }
                }
                if !produced { skip(.unparsable, list: list) }
                return
            }
            // Otherwise a network filter; whitespace is only legal inside option values (e.g. $csp=…),
            // which are rejected by option, and a pattern containing whitespace is rejected as unparsable.
        }

        // `$$` / `$@$` HTML filtering (AdGuard).
        if let dollar = line.range(of: "$$") ?? line.range(of: "$@$"), Compilation.isDomainListPrefix(line[..<dollar.lowerBound]) {
            skip(.htmlFilter, list: list)
            return
        }

        var text = String(line)
        if Compilation.isPlainHostname(line) {
            text = "||\(line.lowercased())^"
        }
        if text.hasSuffix("badfilter"), let (pattern, options) = Compilation.splitOptions(Substring(text)), let options = options {
            var kept: [Substring] = []
            var sawBadfilter = false
            for option in options.split(separator: ",") {
                if option == "badfilter" { sawBadfilter = true } else { kept.append(option) }
            }
            if sawBadfilter {
                badfilters.insert(kept.isEmpty ? String(pattern) : String(pattern) + "$" + kept.joined(separator: ","))
                converted(list: list)
                return
            }
        }
        networkLines.append((list, text))
    }

    static let hostsAddresses: Set<Substring> = ["0.0.0.0", "127.0.0.1", "::1", "::", "0:0:0:0:0:0:0:1", "255.255.255.255", "fe80::1%lo0", "ff00::0", "ff02::1", "ff02::2", "ff02::3"]
    static let hostsIgnored: Set<String> = ["localhost", "localhost.localdomain", "local", "broadcasthost", "ip6-localhost", "ip6-loopback", "ip6-localnet", "ip6-mcastprefix", "ip6-allnodes", "ip6-allrouters", "ip6-allhosts", "0.0.0.0"]

    /// `a-z0-9-` labels joined by dots, at least one dot, no leading/trailing dot or hyphen.
    static func isPlainHostname(_ s: Substring) -> Bool {
        var sawDot = false
        var previous: UInt8 = UInt8(ascii: ".")
        for byte in s.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                break
            case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                break
            case UInt8(ascii: "-"):
                if previous == UInt8(ascii: ".") { return false }
            case UInt8(ascii: "."):
                if previous == UInt8(ascii: ".") || previous == UInt8(ascii: "-") { return false }
                sawDot = true
            default:
                return false
            }
            previous = byte
        }
        return sawDot && previous != UInt8(ascii: ".") && previous != UInt8(ascii: "-")
    }

    /// Finds `##`, `#@#`, `#?#`, `#@?#`, `#$#`, `#@$#`, `#$?#`, `#@$?#`, `#%#`, `#@%#` preceded by a domain list.
    static func cosmeticAnchor(in line: Substring) -> (range: Range<String.Index>, marker: String, isException: Bool)? {
        var i = line.startIndex
        while let hash = line[i...].firstIndex(of: "#") {
            var j = line.index(after: hash)
            var isException = false
            if j < line.endIndex, line[j] == "@" { isException = true; j = line.index(after: j) }
            var marker = ""
            while j < line.endIndex, marker.count < 2, line[j] == "?" || line[j] == "$" || line[j] == "%" {
                marker.append(line[j])
                j = line.index(after: j)
            }
            if j < line.endIndex, line[j] == "#", isDomainListPrefix(line[..<hash]) {
                return (hash..<line.index(after: j), marker, isException)
            }
            i = line.index(after: hash)
        }
        return nil
    }

    static func isDomainListPrefix(_ s: Substring) -> Bool {
        for byte in s.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: ","), UInt8(ascii: "~"), UInt8(ascii: "*"):
                continue
            default:
                if byte >= 0x80 { continue } // non-ASCII domain; rejected later with a precise reason
                return false
            }
        }
        return true
    }

    // MARK: Pass 2 — network filters

    /// Splits `pattern$options`. Returns nil options when the text has no option list; a `$` whose
    /// right-hand side does not look like options (e.g. the `$` anchor inside `/ad$/`) is kept in the pattern.
    static func splitOptions(_ text: Substring) -> (Substring, Substring?)? {
        guard let dollar = text.lastIndex(of: "$") else { return (text, nil) }
        let options = text[text.index(after: dollar)...]
        guard looksLikeOptions(options) else { return (text, nil) }
        return (text[..<dollar], options)
    }

    static func looksLikeOptions(_ options: Substring) -> Bool {
        if options.isEmpty { return false }
        for token in options.split(separator: ",", omittingEmptySubsequences: false) {
            var name = token
            if name.hasPrefix("~") { name = name.dropFirst() }
            if let eq = name.firstIndex(of: "=") { name = name[..<eq] }
            // Names are lowercase words; `1p` / `3p` start with a digit.
            guard let first = name.utf8.first, (first >= UInt8(ascii: "a") && first <= UInt8(ascii: "z")) || (first >= UInt8(ascii: "0") && first <= UInt8(ascii: "9")) || first == UInt8(ascii: "_") else { return false }
            for byte in name.utf8 where !((byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")) {
                return false
            }
        }
        return true
    }

    private mutating func translateNetwork(_ text: String, list: Int) {
        if badfilters.contains(text) {
            skip(.badfilter, list: list)
            return
        }
        guard let filter = parseNetworkFilter(Substring(text), list: list) else { return }

        if filter.isException && (filter.elemhide || filter.generichide || filter.specifichide) {
            guard filter.types.isEmpty, filter.negatedTypes.isEmpty, filter.thirdParty == nil, filter.includeDomains.isEmpty,
                  filter.excludeDomains.isEmpty, !filter.isRegex, let host = Compilation.hostOnly(filter.pattern) else {
                skip(.unsupportedOption, list: list)
                return
            }
            if filter.elemhide || filter.generichide { genericHideDomains.insert(host) }
            if filter.elemhide || filter.specifichide { specificHideDomains.insert(host) }
            converted(list: list)
            return
        }
        if filter.elemhide || filter.generichide || filter.specifichide {
            skip(.unsupportedOption, list: list)
            return
        }

        // `@@||site^$document` / `$all`: whitelist everything on the site's pages, cosmetics included.
        let wholeSite = filter.isException && filter.negatedTypes.isEmpty && (filter.all || filter.types == [.topDocument])
            && filter.thirdParty == nil && filter.includeDomains.isEmpty && filter.excludeDomains.isEmpty
        if wholeSite, !filter.isRegex, let host = Compilation.hostOnly(filter.pattern) {
            wholeSiteDomains.insert(host)
            if filter.all {
                add(NetworkRule(urlFilter: Compilation.hostAnchorPrefix + Compilation.escapeLiteral(host) + "[/:]", action: .ignorePrevious), list: list)
            } else {
                converted(list: list)
            }
            return
        }

        guard let urlFilter = urlFilter(for: filter, list: list) else { return }

        var rule = NetworkRule(urlFilter: urlFilter, action: filter.isException ? .ignorePrevious : .block)
        rule.caseSensitive = filter.matchCase
        rule.important = filter.important && !filter.isException

        if filter.all || (filter.types.isEmpty && filter.negatedTypes.isEmpty) {
            if filter.hadInexpressibleType && !filter.all {
                skip(.unsupportedOption, list: list)
                return
            }
        } else {
            var set = filter.types.isEmpty ? ResourceType.regular : filter.types
            set.subtract(filter.negatedTypes)
            if set.isEmpty {
                skip(.conflictingOptions, list: list)
                return
            }
            rule.resourceTypes = set.sorted { $0.rawValue < $1.rawValue }
        }

        if let third = filter.thirdParty { rule.loadType = third ? "third-party" : "first-party" }

        // Every site the filter was meant for was dropped (e.g. `kat.*` entities): what is left would
        // apply everywhere (or everywhere but its exclusions), so the filter is skipped. This once
        // turned `*$script,1p,domain=~kat.ai|kat.*` into "block first-party scripts on every site".
        if filter.droppedDomains && filter.includeDomains.isEmpty {
            skip(.unsupportedDomain, list: list)
            return
        }
        if !filter.includeDomains.isEmpty && !filter.excludeDomains.isEmpty {
            skip(.mixedDomains, list: list)
            return
        }
        if !filter.includeDomains.isEmpty {
            rule.ifDomain = Compilation.domainConditions(filter.includeDomains)
        } else if !filter.excludeDomains.isEmpty {
            rule.unlessDomain = Compilation.domainConditions(filter.excludeDomains)
        } else if filter.droppedDomains {
            skip(.unsupportedDomain, list: list)
            return
        }

        if wholeSite {
            // `@@|https://site/path$document`: whitelist the page at that URL via if-top-url.
            rule.ifTopURL = rule.urlFilter
            rule.urlFilter = ".*"
            rule.resourceTypes = nil
        } else if filter.isGenericPattern {
            guard rule.ifDomain != nil || rule.unlessDomain != nil || rule.resourceTypes != nil else {
                skip(.tooGeneric, list: list)
                return
            }
        }

        add(rule, list: list)
    }

    private mutating func add(_ rule: NetworkRule, list: Int) {
        converted(list: list)
        if !seenRules.insert(rule).inserted {
            duplicates += 1
            return
        }
        switch rule.action {
        case .ignorePrevious: exceptionRules.append(rule)
        case .block: rule.important ? importantRules.append(rule) : blockRules.append(rule)
        }
    }

    static func domainConditions(_ domains: [String]) -> [String] {
        var seen: Set<String> = []
        return domains.filter { seen.insert($0).inserted }.sorted().map { "*" + $0 }
    }

    private mutating func parseNetworkFilter(_ text: Substring, list: Int) -> NetworkFilter? {
        var text = text
        var filter = NetworkFilter(pattern: text)
        if text.hasPrefix("@@") {
            filter.isException = true
            text = text.dropFirst(2)
        }
        guard let (pattern, options) = Compilation.splitOptions(text) else { return nil }
        filter.pattern = pattern
        if pattern.count > 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
            filter.isRegex = true
            filter.pattern = pattern.dropFirst().dropLast()
        }
        guard let options = options else { return filter }

        for token in options.split(separator: ",") {
            var name = token
            var value: Substring?
            if let eq = token.firstIndex(of: "=") {
                name = token[..<eq]
                value = token[token.index(after: eq)...]
            }
            var negated = false
            if name.hasPrefix("~") { negated = true; name = name.dropFirst() }

            if let type = ResourceType.named(name) {
                if negated { filter.negatedTypes.insert(type) } else { filter.types.insert(type) }
                continue
            }
            if ResourceType.isInexpressible(name) {
                if !negated { filter.hadInexpressibleType = true }
                continue
            }
            switch name {
            case "third-party", "3p":
                if let existing = filter.thirdParty, existing != !negated { skip(.conflictingOptions, list: list); return nil }
                filter.thirdParty = !negated
            case "first-party", "1p":
                if let existing = filter.thirdParty, existing != negated { skip(.conflictingOptions, list: list); return nil }
                filter.thirdParty = negated
            case "match-case":
                filter.matchCase = !negated
            case "important":
                filter.important = true
            case "badfilter":
                filter.badfilter = true
            case "all":
                filter.all = true
            case "elemhide", "ehide":
                filter.elemhide = true
            case "generichide", "ghide":
                filter.generichide = true
            case "specifichide", "shide":
                filter.specifichide = true
            case "_":
                break
            case "domain", "from":
                guard let value = value, !value.isEmpty else { skip(.unparsable, list: list); return nil }
                for raw in value.split(separator: "|") {
                    var domain = raw
                    var exclude = false
                    if domain.hasPrefix("~") { exclude = true; domain = domain.dropFirst() }
                    guard let valid = Compilation.validDomain(domain) else {
                        // Dropping an inclusion narrows the filter (safe); dropping an exclusion would widen it.
                        if exclude { skip(.unsupportedDomain, list: list); return nil }
                        filter.droppedDomains = true
                        continue
                    }
                    if exclude { filter.excludeDomains.append(valid) } else { filter.includeDomains.append(valid) }
                }
            default:
                skip(.unsupportedOption, list: list)
                return nil
            }
        }
        if filter.hadInexpressibleType && filter.types.isEmpty && !filter.all {
            skip(.unsupportedOption, list: list)
            return nil
        }
        return filter
    }

    /// Lowercase ASCII hostname usable in `if-domain`; nil for entities (`example.*`), regexes, non-ASCII, etc.
    static func validDomain(_ raw: Substring) -> String? {
        if raw.isEmpty || raw.utf8.count > 253 { return nil }
        var hasUpper = false
        var previous: UInt8 = UInt8(ascii: ".")
        for byte in raw.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"):
                break
            case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                hasUpper = true
            case UInt8(ascii: "-"):
                if previous == UInt8(ascii: ".") { return nil }
            case UInt8(ascii: "."):
                if previous == UInt8(ascii: ".") { return nil }
            default:
                return nil
            }
            previous = byte
        }
        if previous == UInt8(ascii: ".") { return nil }
        return hasUpper ? raw.lowercased() : String(raw)
    }

    /// The host of a `||host^` / `||host` / `||host/` pattern, or nil for anything else.
    static func hostOnly(_ pattern: Substring) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        var host = pattern.dropFirst(2)
        if host.hasSuffix("^") || host.hasSuffix("/") { host = host.dropLast() }
        guard !host.isEmpty, host.utf8.allSatisfy({ ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") }) else { return nil }
        return String(host)
    }

    static let hostAnchorPrefix = "^[^:]+://+([^:/]+\\.)?"
    static let separatorClass = "[^-_.%a-zA-Z0-9]"

    static func escapeLiteral(_ s: String) -> String {
        var out = ""
        for byte in s.utf8 {
            if Compilation.regexSpecial.contains(byte) { out.append("\\") }
            out.unicodeScalars.append(Unicode.Scalar(byte))
        }
        return out
    }

    static let regexSpecial: Set<UInt8> = Set(".+?()[]{}\\$|^*".utf8)

    private mutating func urlFilter(for filter: NetworkFilter, list: Int) -> String? {
        if filter.isRegex {
            let pattern = String(filter.pattern)
            guard pattern.utf8.allSatisfy({ $0 < 0x80 }) else { skip(.nonASCII, list: list); return nil }
            guard let normalized = WebKitRegex.normalize(pattern), WebKitRegex.isSupported(normalized) else {
                skip(.unsupportedRegex, list: list)
                return nil
            }
            return normalized
        }
        var pattern = filter.pattern
        guard pattern.utf8.allSatisfy({ $0 < 0x80 }) else { skip(.nonASCII, list: list); return nil }
        guard !pattern.utf8.contains(where: { $0 <= 0x20 || $0 == 0x7F }) else { skip(.unparsable, list: list); return nil }

        var anchorHost = false
        var anchorStart = false
        var anchorEnd = false
        if pattern.hasPrefix("||") { anchorHost = true; pattern = pattern.dropFirst(2) }
        else if pattern.hasPrefix("|") { anchorStart = true; pattern = pattern.dropFirst() }
        if pattern.hasSuffix("|") { anchorEnd = true; pattern = pattern.dropLast() }
        if pattern.hasPrefix("*") {
            // `|*foo` / `||*foo`: a wildcard right after the anchor cancels it.
            anchorStart = false
            anchorHost = false
            while pattern.hasPrefix("*") { pattern = pattern.dropFirst() }
        }
        while pattern.hasSuffix("*") {
            anchorEnd = false
            pattern = pattern.dropLast()
        }

        var out = ""
        out.reserveCapacity(pattern.utf8.count + 40)
        if anchorHost { out += Compilation.hostAnchorPrefix }
        else if anchorStart { out += "^" }

        let bytes = Array(pattern.utf8)
        let lower = !filter.matchCase
        var pathStarted = false
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            switch byte {
            case UInt8(ascii: "*"):
                while i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "*") { i += 1 }
                if i + 1 < bytes.count { out += ".*" } // trailing `*` already stripped
            case UInt8(ascii: "^"):
                if i == bytes.count - 1 {
                    if anchorEnd {
                        out += Compilation.separatorClass
                    } else if anchorHost && !pathStarted {
                        // Hostnames in WebKit's normalized URLs are always followed by "/" or ":".
                        out += "[/:]"
                    } else {
                        out += "(" + Compilation.separatorClass + ".*)?$"
                        anchorEnd = false
                    }
                } else {
                    out += Compilation.separatorClass
                }
                pathStarted = true
            case UInt8(ascii: "/"):
                pathStarted = true
                out += "/"
            default:
                if Compilation.regexSpecial.contains(byte) { out.append("\\") }
                let scalar = Unicode.Scalar(lower && byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte)
                out.unicodeScalars.append(scalar)
            }
            i += 1
        }
        if anchorEnd { out += "$" }
        if out.isEmpty || out == "^" { out = ".*" }

        guard WebKitRegex.isSupported(out) else { skip(.unsupportedRegex, list: list); return nil }
        return out
    }

    // MARK: Pass 2 — cosmetic filters

    private mutating func parseCosmetic(_ entry: (list: Int, text: String, anchor: Range<String.Index>, marker: String, isException: Bool)) {
        let list = entry.list
        let body = entry.text[entry.anchor.upperBound...]
        switch entry.marker {
        case "":
            break
        case "?", "$?":
            skip(.proceduralCosmetic, list: list)
            return
        default: // "$" (style injection / ABP snippets), "%" (ABP scriptlets)
            skip(.scriptlet, list: list)
            return
        }
        if body.hasPrefix("^") { skip(.htmlFilter, list: list); return }
        if body.hasPrefix("+js(") || body.hasPrefix("script:inject(") { skip(.scriptlet, list: list); return }
        let selector = String(Compilation.trimmed(body))
        if selector.isEmpty { skip(.unparsable, list: list); return }
        if CSSSelector.hasProceduralExtension(selector) { skip(.proceduralCosmetic, list: list); return }
        guard CSSSelector.isValid(selector) else { skip(.invalidSelector, list: list); return }

        var include: [String] = []
        var exclude: [String] = []
        var droppedInclusion = false
        let domainList = entry.text[..<entry.anchor.lowerBound]
        for raw in domainList.split(separator: ",") {
            var domain = raw
            var excluded = false
            if domain.hasPrefix("~") { excluded = true; domain = domain.dropFirst() }
            guard let valid = Compilation.validDomain(domain) else {
                if excluded || entry.isException { skip(.unsupportedDomain, list: list); return }
                droppedInclusion = true
                continue // dropped inclusion narrows the filter
            }
            if excluded { exclude.append(valid) } else { include.append(valid) }
        }
        // Every site it was meant for was dropped: what's left would hide the element everywhere.
        if droppedInclusion && include.isEmpty {
            skip(.unsupportedDomain, list: list)
            return
        }
        if !domainList.isEmpty && include.isEmpty && exclude.isEmpty {
            skip(.unsupportedDomain, list: list)
            return
        }
        if !include.isEmpty && !exclude.isEmpty {
            skip(.mixedDomains, list: list)
            return
        }
        cosmeticFilters.append((list, CosmeticFilter(selector: selector, includeDomains: include, excludeDomains: exclude, isException: entry.isException)))
    }

    /// Resolves `#@#` exceptions and groups selectors. Returns (generic rules, specific rules).
    private mutating func buildCosmeticRules() -> (generic: [String], specific: [String]) {
        var genericExceptions: Set<String> = []
        var domainExceptions: [String: Set<String>] = [:]
        for (list, filter) in cosmeticFilters where filter.isException {
            if filter.includeDomains.isEmpty {
                genericExceptions.insert(filter.selector)
            } else {
                domainExceptions[filter.selector, default: []].formUnion(filter.includeDomains)
            }
            converted(list: list)
        }

        // selector -> excluded domains (intersection across duplicates: a plain `##sel` anywhere wins).
        var generic: [String: Set<String>] = [:]
        // selector -> included domains (union across duplicates).
        var specific: [String: Set<String>] = [:]

        for (list, filter) in cosmeticFilters where !filter.isException {
            if genericExceptions.contains(filter.selector) {
                skip(.cosmeticException, list: list)
                continue
            }
            if filter.includeDomains.isEmpty {
                let excluded = Set(filter.excludeDomains)
                if let existing = generic[filter.selector] {
                    generic[filter.selector] = existing.intersection(excluded)
                } else {
                    generic[filter.selector] = excluded
                }
                converted(list: list)
            } else {
                var domains = Set(filter.includeDomains)
                if let exceptions = domainExceptions[filter.selector] {
                    domains = domains.filter { domain in
                        !exceptions.contains { Compilation.domain(domain, overlaps: $0) }
                    }
                }
                if domains.isEmpty {
                    skip(.cosmeticException, list: list)
                    continue
                }
                specific[filter.selector, default: []].formUnion(domains)
                converted(list: list)
            }
        }
        for (selector, exceptions) in domainExceptions {
            if var excluded = generic[selector] {
                excluded.formUnion(exceptions)
                generic[selector] = excluded
            }
        }

        var genericGroups: [[String]: [String]] = [:]
        for (selector, excluded) in generic {
            genericGroups[excluded.sorted(), default: []].append(selector)
        }
        var specificGroups: [[String]: [String]] = [:]
        for (selector, included) in specific {
            specificGroups[included.sorted(), default: []].append(selector)
        }

        func emit(_ groups: [[String]: [String]], key: String) -> [String] {
            var rules: [String] = []
            for domains in groups.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                let selectors = groups[domains]!.sorted()
                let condition = domains.isEmpty ? "" : ",\"\(key)\":" + JSON.array(domains.map { "*" + $0 })
                var plain: [String] = []
                var functional: [String] = []
                for selector in selectors {
                    if CSSSelector.usesFunctionalPseudoClass(selector) { functional.append(selector) } else { plain.append(selector) }
                }
                for (chunkSize, list) in [(Compilation.plainGroupSize, plain), (Compilation.functionalGroupSize, functional)] {
                    var start = 0
                    while start < list.count {
                        let end = min(start + chunkSize, list.count)
                        let joined = list[start..<end].joined(separator: ", ")
                        rules.append("{\"trigger\":{\"url-filter\":\".*\"\(condition)},\"action\":{\"type\":\"css-display-none\",\"selector\":\"\(JSON.escape(joined))\"}}")
                        cosmeticSelectorCount += end - start
                        start = end
                    }
                }
            }
            return rules
        }
        let genericRules = emit(genericGroups, key: "unless-domain")
        let specificRules = emit(specificGroups, key: "if-domain")
        cosmeticRuleCount = genericRules.count + specificRules.count
        return (genericRules, specificRules)
    }

    static let plainGroupSize = 250
    static let functionalGroupSize = 25
    static let domainsPerExceptionRule = 2000

    /// True when `domain` equals, is a subdomain of, or is a parent of `other`.
    static func domain(_ domain: String, overlaps other: String) -> Bool {
        if domain == other { return true }
        if domain.hasSuffix("." + other) { return true }
        if other.hasSuffix("." + domain) { return true }
        return false
    }

    static func ignoreRules(forDomains domains: Set<String>) -> [String] {
        let sorted = domains.sorted()
        var rules: [String] = []
        var start = 0
        while start < sorted.count {
            let end = min(start + domainsPerExceptionRule, sorted.count)
            rules.append("{\"trigger\":{\"url-filter\":\".*\",\"if-domain\":" + JSON.array(sorted[start..<end].map { "*" + $0 }) + "},\"action\":{\"type\":\"ignore-previous-rules\"}}")
            start = end
        }
        return rules
    }

    // MARK: Output

    mutating func output(digest: String) -> ContentBlockerOutput {
        var chunks: [ContentRuleChunk] = []

        // Whole-site exceptions cancel network blocks too.
        var networkExceptions = exceptionRules.map(\.json)
        networkExceptions += Compilation.ignoreRules(forDomains: wholeSiteDomains)
        var blocks = blockRules.map(\.json)
        var importants = importantRules.map(\.json)
        var droppedForBudget = 0

        if !blocks.isEmpty || !importants.isEmpty {
            // Exceptions may take at most half of a chunk so blocks always make progress.
            let exceptionCap = maxRulesPerList / 2
            if networkExceptions.count > exceptionCap {
                droppedForBudget += networkExceptions.count - exceptionCap
                networkExceptions.removeLast(networkExceptions.count - exceptionCap)
            }
            var index = 0
            while !blocks.isEmpty || !importants.isEmpty {
                var space = maxRulesPerList - networkExceptions.count
                let takeBlocks = min(space, blocks.count)
                var rules = Array(blocks.prefix(takeBlocks))
                blocks.removeFirst(takeBlocks)
                space -= takeBlocks
                rules += networkExceptions
                let takeImportant = min(space, importants.count)
                rules += importants.prefix(takeImportant)
                importants.removeFirst(takeImportant)
                chunks.append(ContentRuleChunk(identifier: "network-\(index)", kind: .network, json: "[" + rules.joined(separator: ",") + "]", ruleCount: rules.count))
                index += 1
            }
        }

        let cosmetic = buildCosmeticRules()
        func appendCosmetic(_ rules: [String], exceptions: [String], kind: ContentRuleChunk.Kind) {
            guard !rules.isEmpty else { return }
            let perChunk = max(1, maxRulesPerList - exceptions.count)
            var index = 0
            var start = 0
            while start < rules.count {
                let end = min(start + perChunk, rules.count)
                let body = Array(rules[start..<end]) + exceptions
                chunks.append(ContentRuleChunk(identifier: "\(kind.rawValue)-\(index)", kind: kind, json: "[" + body.joined(separator: ",") + "]", ruleCount: body.count))
                index += 1
                start = end
            }
        }
        appendCosmetic(cosmetic.generic, exceptions: Compilation.ignoreRules(forDomains: genericHideDomains.union(wholeSiteDomains)), kind: .cosmeticGeneric)
        appendCosmetic(cosmetic.specific, exceptions: Compilation.ignoreRules(forDomains: specificHideDomains.union(wholeSiteDomains)), kind: .cosmeticSpecific)

        if droppedForBudget > 0, !listSkipped.isEmpty {
            listSkipped[0][.ruleBudget, default: 0] += droppedForBudget
        }

        var totalSkipped: [ContentBlockerSkipReason: Int] = [:]
        var lists: [ContentBlockerListStats] = []
        for i in listNames.indices {
            lists.append(ContentBlockerListStats(name: listNames[i], parsed: listParsed[i], converted: listConverted[i], skipped: listSkipped[i]))
            for (reason, count) in listSkipped[i] { totalSkipped[reason, default: 0] += count }
        }
        let stats = ContentBlockerStats(
            parsed: listParsed.reduce(0, +),
            converted: listConverted.reduce(0, +),
            skipped: totalSkipped,
            duplicates: duplicates,
            networkBlockRules: blockRules.count + importantRules.count,
            networkExceptionRules: exceptionRules.count + Compilation.ignoreRules(forDomains: wholeSiteDomains).count,
            cosmeticRules: cosmeticRuleCount,
            cosmeticSelectors: cosmeticSelectorCount,
            lists: lists
        )
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        func number(_ n: Int) -> String { formatter.string(from: NSNumber(value: n)) ?? String(n) }
        let listWord = listNames.count == 1 ? "list" : "lists"
        let summary = "\(number(stats.totalRules)) rules from \(listNames.count) \(listWord) · \(number(stats.skippedTotal)) skipped"
        return ContentBlockerOutput(digest: digest, ruleLists: chunks, summary: summary, stats: stats)
    }
}

private extension NetworkFilter {
    /// A pattern with no literal characters (`*`, `||^`, empty) matches every URL.
    var isGenericPattern: Bool {
        if isRegex { return false }
        return !pattern.utf8.contains { $0 != UInt8(ascii: "*") && $0 != UInt8(ascii: "|") && $0 != UInt8(ascii: "^") }
    }
}

// MARK: - WebKit regex subset

/// Accepts only the regular-expression subset WebKit's content-blocker compiler supports: literals,
/// `.`, `*`, `+`, `?` (optionally lazy), character classes with ranges and negation, non-capturing
/// plain groups, `^` as the very first character and `$` as the very last. No alternation, counted
/// repetition, shorthand classes (`\d`, `\w`, `\s`, `\b`), lookaround, backreferences or non-ASCII.
enum WebKitRegex {
    /// Rewrites common JavaScript regex constructs into the WebKit subset: `(?:` → `(`, `\d` / `\w` (and
    /// their negations outside classes) → explicit classes, and `{n}` / `{n,}` / `{n,m}` unrolled into
    /// repeated atoms. Returns nil when a construct cannot be rewritten; the result still has to pass
    /// `isSupported`.
    static func normalize(_ pattern: String) -> String? {
        let bytes = Array(pattern.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 16)
        var atomStart: Int? = nil           // index into `out` where the most recent atom begins
        var groupStarts: [Int] = []          // indices into `out` of open parentheses
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            switch byte {
            case UInt8(ascii: "("):
                if i + 2 < bytes.count, bytes[i + 1] == UInt8(ascii: "?"), bytes[i + 2] == UInt8(ascii: ":") {
                    i += 2
                } else if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "?") {
                    return nil // lookaround / named group
                }
                groupStarts.append(out.count)
                out.append(UInt8(ascii: "("))
                atomStart = nil
            case UInt8(ascii: ")"):
                guard let start = groupStarts.popLast() else { return nil }
                out.append(byte)
                atomStart = start
            case UInt8(ascii: "\\"):
                guard i + 1 < bytes.count else { return nil }
                let next = bytes[i + 1]
                atomStart = out.count
                switch next {
                case UInt8(ascii: "d"): out.append(contentsOf: Array("[0-9]".utf8))
                case UInt8(ascii: "D"): out.append(contentsOf: Array("[^0-9]".utf8))
                case UInt8(ascii: "w"): out.append(contentsOf: Array("[0-9A-Za-z_]".utf8))
                case UInt8(ascii: "W"): out.append(contentsOf: Array("[^0-9A-Za-z_]".utf8))
                default:
                    if isAlphanumeric(next) { return nil } // \b \s \1 \x41 …
                    out.append(byte)
                    out.append(next)
                }
                i += 1
            case UInt8(ascii: "["):
                atomStart = out.count
                out.append(byte)
                var j = i + 1
                if j < bytes.count, bytes[j] == UInt8(ascii: "^") { out.append(bytes[j]); j += 1 }
                var closed = false
                while j < bytes.count {
                    let c = bytes[j]
                    if c == UInt8(ascii: "]") { out.append(c); closed = true; break }
                    if c == UInt8(ascii: "\\") {
                        guard j + 1 < bytes.count else { return nil }
                        let next = bytes[j + 1]
                        switch next {
                        case UInt8(ascii: "d"): out.append(contentsOf: Array("0-9".utf8))
                        case UInt8(ascii: "w"): out.append(contentsOf: Array("0-9A-Za-z_".utf8))
                        default:
                            if isAlphanumeric(next) { return nil }
                            out.append(c)
                            out.append(next)
                        }
                        j += 2
                        continue
                    }
                    out.append(c)
                    j += 1
                }
                guard closed else { return nil }
                i = j
            case UInt8(ascii: "{"):
                guard let start = atomStart, let close = bytes[i...].firstIndex(of: UInt8(ascii: "}")) else { return nil }
                let spec = String(decoding: bytes[(i + 1)..<close], as: UTF8.self)
                let parts = spec.split(separator: ",", omittingEmptySubsequences: false)
                guard parts.count <= 2, let minimum = Int(parts[0]) else { return nil }
                let maximum: Int?
                if parts.count == 1 { maximum = minimum }
                else if parts[1].isEmpty { maximum = nil }
                else { guard let m = Int(parts[1]) else { return nil }; maximum = m }
                if let m = maximum, m < minimum { return nil }
                guard minimum <= 64, (maximum ?? 0) <= 64 else { return nil }
                if close + 1 < bytes.count, bytes[close + 1] == UInt8(ascii: "?") { return nil } // lazy counted repeat
                let atom = Array(out[start...])
                // Bound the expansion *before* allocating: nested counted groups grow exponentially.
                guard atom.count * max(minimum, maximum ?? minimum, 1) + out.count <= 4096 else { return nil }
                out.removeSubrange(start...)
                if let m = maximum {
                    // a{2,4} → aaa?a?
                    for _ in 0..<minimum { out.append(contentsOf: atom) }
                    for _ in 0..<(m - minimum) { out.append(contentsOf: atom); out.append(UInt8(ascii: "?")) }
                } else if minimum == 0 {
                    out.append(contentsOf: atom)         // a{0,} → a*
                    out.append(UInt8(ascii: "*"))
                } else {
                    for _ in 0..<minimum { out.append(contentsOf: atom) } // a{2,} → aa+
                    out.append(UInt8(ascii: "+"))
                }
                atomStart = nil
                i = close
            case UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "?"), UInt8(ascii: "^"), UInt8(ascii: "$"), UInt8(ascii: "|"):
                out.append(byte)
                atomStart = nil
            default:
                atomStart = out.count
                out.append(byte)
            }
            i += 1
        }
        guard groupStarts.isEmpty, out.count <= 4096 else { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    static func isSupported(_ pattern: String) -> Bool {
        let bytes = Array(pattern.utf8)
        if bytes.isEmpty { return false }
        var i = 0
        var depth = 0
        var previousWasAtom = false
        var previousWasQuantifier = false
        var lazyUsed = false

        while i < bytes.count {
            let byte = bytes[i]
            if byte >= 0x80 || byte < 0x20 || byte == 0x7F { return false }
            switch byte {
            case UInt8(ascii: "^"):
                if i != 0 { return false }
                previousWasAtom = false
                previousWasQuantifier = false
            case UInt8(ascii: "$"):
                if i != bytes.count - 1 || depth != 0 { return false }
                previousWasAtom = false
            case UInt8(ascii: "|"), UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "]"), UInt8(ascii: ")") where depth == 0:
                return false
            case UInt8(ascii: ")"):
                if !previousWasAtom && !previousWasQuantifier && bytes[i - 1] != UInt8(ascii: "(") { return false }
                depth -= 1
                previousWasAtom = true
                previousWasQuantifier = false
            case UInt8(ascii: "("):
                if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "?") { return false }
                depth += 1
                previousWasAtom = false
                previousWasQuantifier = false
            case UInt8(ascii: "*"), UInt8(ascii: "+"):
                if !previousWasAtom { return false }
                previousWasAtom = false
                previousWasQuantifier = true
                lazyUsed = false
            case UInt8(ascii: "?"):
                if previousWasQuantifier {
                    if lazyUsed { return false }
                    lazyUsed = true
                } else if previousWasAtom {
                    previousWasAtom = false
                    previousWasQuantifier = true
                    lazyUsed = false
                } else {
                    return false
                }
            case UInt8(ascii: "\\"):
                guard i + 1 < bytes.count else { return false }
                let next = bytes[i + 1]
                if isAlphanumeric(next) || next >= 0x80 { return false }
                i += 1
                previousWasAtom = true
                previousWasQuantifier = false
            case UInt8(ascii: "["):
                guard let end = scanClass(bytes, from: i) else { return false }
                i = end
                previousWasAtom = true
                previousWasQuantifier = false
            default:
                previousWasAtom = true
                previousWasQuantifier = false
            }
            i += 1
        }
        return depth == 0
    }

    /// Returns the index of the closing `]`, or nil when the class is malformed.
    private static func scanClass(_ bytes: [UInt8], from start: Int) -> Int? {
        var i = start + 1
        if i < bytes.count, bytes[i] == UInt8(ascii: "^") { i += 1 }
        var members = 0
        var previousWasMember = false
        while i < bytes.count {
            let byte = bytes[i]
            if byte >= 0x80 || byte < 0x20 || byte == 0x7F { return nil }
            switch byte {
            case UInt8(ascii: "]"):
                return members > 0 ? i : nil
            case UInt8(ascii: "\\"):
                guard i + 1 < bytes.count else { return nil }
                let next = bytes[i + 1]
                if isAlphanumeric(next) || next >= 0x80 { return nil }
                i += 1
                members += 1
                previousWasMember = true
            case UInt8(ascii: "-"):
                if previousWasMember, i + 1 < bytes.count, bytes[i + 1] != UInt8(ascii: "]") {
                    // Range: the right side must be a plain or escaped char that sorts after the left side.
                    let left = bytes[i - 1]
                    var right = bytes[i + 1]
                    var rightIndex = i + 1
                    if right == UInt8(ascii: "\\") {
                        guard i + 2 < bytes.count else { return nil }
                        right = bytes[i + 2]
                        rightIndex = i + 2
                        if isAlphanumeric(right) { return nil }
                    } else if right == UInt8(ascii: "[") {
                        return nil
                    }
                    if left > right { return nil }
                    i = rightIndex
                    members += 1
                    previousWasMember = false
                } else {
                    members += 1
                    previousWasMember = true
                }
            case UInt8(ascii: "["):
                return nil
            default:
                members += 1
                previousWasMember = true
            }
            i += 1
        }
        return nil
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
    }
}

// MARK: - CSS selector check

/// A conservative CSS selector grammar check. WebKit silently drops a `css-display-none` rule whose
/// selector it cannot parse, so anything doubtful is rejected here instead.
enum CSSSelector {
    static let proceduralMarkers: [String] = [
        ":has-text(", ":-abp-", ":xpath(", ":upward(", ":remove(", ":style(", ":matches-css", ":min-text-length(",
        ":watch-attr(", ":others(", ":if(", ":if-not(", ":nth-ancestor(", ":matches-path(", ":matches-attr(",
        ":matches-media(", ":spath(", ":remove-attr(", ":remove-class(", ":contains(", ":matches-prop(",
    ]

    static func hasProceduralExtension(_ selector: String) -> Bool {
        let lowered = selector.lowercased()
        return proceduralMarkers.contains { lowered.contains($0) }
    }

    static let allowedPseudoClasses: Set<String> = [
        "not", "is", "where", "has",
        "nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type",
        "first-child", "last-child", "only-child", "first-of-type", "last-of-type", "only-of-type",
        "empty", "root", "link", "visited", "any-link", "hover", "active", "focus", "focus-within", "focus-visible",
        "target", "checked", "disabled", "enabled", "required", "optional", "read-only", "read-write",
        "placeholder-shown", "default", "indeterminate", "valid", "invalid", "in-range", "out-of-range",
        "lang", "dir", "scope", "defined",
    ]
    static let selectorListPseudoClasses: Set<String> = ["not", "is", "where", "has"]
    static let nthPseudoClasses: Set<String> = ["nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type"]
    static let allowedPseudoElements: Set<String> = ["before", "after", "first-letter", "first-line", "selection", "placeholder", "marker", "backdrop"]

    static func usesFunctionalPseudoClass(_ selector: String) -> Bool {
        selector.utf8.contains(UInt8(ascii: "("))
    }

    static func isValid(_ selector: String) -> Bool {
        var parser = Parser(bytes: Array(selector.utf8))
        guard parser.parseSelectorList(allowLeadingCombinator: false, hasDepth: 0), parser.atEnd else { return false }
        return true
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { i >= bytes.count }
        var current: UInt8? { i < bytes.count ? bytes[i] : nil }
        func peek(_ offset: Int = 1) -> UInt8? { i + offset < bytes.count ? bytes[i + offset] : nil }

        mutating func skipWhitespace() -> Bool {
            var skipped = false
            while let c = current, c == 0x20 || c == 0x09 { i += 1; skipped = true }
            return skipped
        }

        static func isNameStart(_ c: UInt8) -> Bool {
            (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z")) || c == UInt8(ascii: "_") || c >= 0x80
        }
        static func isNameChar(_ c: UInt8) -> Bool {
            isNameStart(c) || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: "-")
        }
        static func isHex(_ c: UInt8) -> Bool {
            (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "f")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "F"))
        }

        /// `\` already at `i`.
        mutating func parseEscape() -> Bool {
            guard current == UInt8(ascii: "\\"), let next = peek() else { return false }
            if next == 0x0A || next == 0x0D { return false }
            i += 1
            if Parser.isHex(next) {
                var count = 0
                while let c = current, Parser.isHex(c), count < 6 { i += 1; count += 1 }
                if let c = current, c == 0x20 { i += 1 }
            } else {
                i += 1
            }
            return true
        }

        /// CSS identifier; returns the lowercase ASCII name (escapes collapsed to "\u{0}" markers are not needed for matching).
        mutating func parseIdentifier() -> String? {
            let start = i
            var name: [UInt8] = []
            if current == UInt8(ascii: "-") {
                name.append(UInt8(ascii: "-"))
                i += 1
                if current == UInt8(ascii: "-") { name.append(UInt8(ascii: "-")); i += 1 }
            }
            guard let first = current else { i = start; return nil }
            if first == UInt8(ascii: "\\") {
                guard parseEscape() else { i = start; return nil }
                name.append(UInt8(ascii: "?"))
            } else if Parser.isNameStart(first) || (name.count == 2 && Parser.isNameChar(first)) {
                name.append(first)
                i += 1
            } else {
                i = start
                return nil
            }
            while let c = current {
                if c == UInt8(ascii: "\\") {
                    guard parseEscape() else { i = start; return nil }
                    name.append(UInt8(ascii: "?"))
                } else if Parser.isNameChar(c) {
                    name.append(c)
                    i += 1
                } else {
                    break
                }
            }
            return String(decoding: name, as: UTF8.self).lowercased()
        }

        mutating func parseString() -> Bool {
            guard let quote = current, quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else { return false }
            i += 1
            while let c = current {
                if c == quote { i += 1; return true }
                if c == 0x0A || c == 0x0D { return false }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard current != nil else { return false }
                    i += 1
                    continue
                }
                i += 1
            }
            return false
        }

        mutating func parseSelectorList(allowLeadingCombinator: Bool, hasDepth: Int) -> Bool {
            while true {
                _ = skipWhitespace()
                guard parseComplexSelector(allowLeadingCombinator: allowLeadingCombinator, hasDepth: hasDepth) else { return false }
                _ = skipWhitespace()
                guard let c = current else { return true }
                if c == UInt8(ascii: ",") { i += 1; continue }
                if c == UInt8(ascii: ")") { return true }
                return false
            }
        }

        mutating func parseComplexSelector(allowLeadingCombinator: Bool, hasDepth: Int) -> Bool {
            if allowLeadingCombinator, let c = current, c == UInt8(ascii: ">") || c == UInt8(ascii: "+") || c == UInt8(ascii: "~") {
                i += 1
                _ = skipWhitespace()
            }
            guard parseCompoundSelector(hasDepth: hasDepth) else { return false }
            while true {
                let save = i
                let sawWhitespace = skipWhitespace()
                guard let c = current else { return true }
                if c == UInt8(ascii: ",") || c == UInt8(ascii: ")") { i = save; _ = skipWhitespace(); return true }
                if c == UInt8(ascii: ">") || c == UInt8(ascii: "+") || c == UInt8(ascii: "~") {
                    i += 1
                    _ = skipWhitespace()
                    guard parseCompoundSelector(hasDepth: hasDepth) else { return false }
                    continue
                }
                if sawWhitespace {
                    guard parseCompoundSelector(hasDepth: hasDepth) else { return false }
                    continue
                }
                return false
            }
        }

        mutating func parseCompoundSelector(hasDepth: Int) -> Bool {
            var count = 0
            var sawPseudoElement = false
            if current == UInt8(ascii: "*") {
                i += 1
                count += 1
            } else if let c = current, Parser.isNameStart(c) || c == UInt8(ascii: "-") || c == UInt8(ascii: "\\") {
                guard parseIdentifier() != nil else { return false }
                count += 1
            }
            while let c = current {
                switch c {
                case UInt8(ascii: "#"), UInt8(ascii: "."):
                    if sawPseudoElement { return false }
                    i += 1
                    guard parseIdentifier() != nil else { return false }
                case UInt8(ascii: "["):
                    if sawPseudoElement { return false }
                    guard parseAttribute() else { return false }
                case UInt8(ascii: ":"):
                    i += 1
                    if current == UInt8(ascii: ":") {
                        i += 1
                        guard let name = parseIdentifier(), CSSSelector.allowedPseudoElements.contains(name), current != UInt8(ascii: "(") else { return false }
                        sawPseudoElement = true
                    } else {
                        guard parsePseudoClass(hasDepth: hasDepth) else { return false }
                    }
                default:
                    return count > 0
                }
                count += 1
            }
            return count > 0
        }

        mutating func parseAttribute() -> Bool {
            guard current == UInt8(ascii: "[") else { return false }
            i += 1
            _ = skipWhitespace()
            guard parseIdentifier() != nil else { return false }
            _ = skipWhitespace()
            if current == UInt8(ascii: "]") { i += 1; return true }
            guard let c = current else { return false }
            if c == UInt8(ascii: "~") || c == UInt8(ascii: "|") || c == UInt8(ascii: "^") || c == UInt8(ascii: "$") || c == UInt8(ascii: "*") {
                i += 1
            }
            guard current == UInt8(ascii: "=") else { return false }
            i += 1
            _ = skipWhitespace()
            var quoted = false
            if let q = current, q == UInt8(ascii: "\"") || q == UInt8(ascii: "'") {
                guard parseString() else { return false }
                quoted = true
            } else {
                guard parseIdentifier() != nil else { return false }
            }
            let sawWhitespace = skipWhitespace()
            // `[a="b" i]` and `[a="b"i]` are both valid; after an unquoted value the flag needs whitespace.
            if sawWhitespace || quoted, let flag = current, flag == UInt8(ascii: "i") || flag == UInt8(ascii: "s") || flag == UInt8(ascii: "I") || flag == UInt8(ascii: "S"),
               peek() == UInt8(ascii: "]") || peek() == 0x20 {
                i += 1
                _ = skipWhitespace()
            }
            guard current == UInt8(ascii: "]") else { return false }
            i += 1
            return true
        }

        /// `:` already consumed.
        mutating func parsePseudoClass(hasDepth: Int) -> Bool {
            guard let name = parseIdentifier(), CSSSelector.allowedPseudoClasses.contains(name) else { return false }
            if current != UInt8(ascii: "(") {
                return !CSSSelector.selectorListPseudoClasses.contains(name) && !CSSSelector.nthPseudoClasses.contains(name) && name != "lang" && name != "dir"
            }
            i += 1
            if CSSSelector.selectorListPseudoClasses.contains(name) {
                let isHas = name == "has"
                if isHas && hasDepth > 0 { return false } // nested :has() is invalid
                guard parseSelectorList(allowLeadingCombinator: isHas, hasDepth: hasDepth + (isHas ? 1 : 0)) else { return false }
            } else if CSSSelector.nthPseudoClasses.contains(name) {
                guard parseNth() else { return false }
                _ = skipWhitespace()
                if current != UInt8(ascii: ")") {
                    // "An+B of <selector-list>" is only valid for :nth-child / :nth-last-child.
                    guard name == "nth-child" || name == "nth-last-child", let o = current, o == UInt8(ascii: "o") || o == UInt8(ascii: "O"),
                          let f = peek(), f == UInt8(ascii: "f") || f == UInt8(ascii: "F") else { return false }
                    i += 2
                    guard skipWhitespace(), parseSelectorList(allowLeadingCombinator: false, hasDepth: hasDepth) else { return false }
                }
            } else if name == "lang" || name == "dir" {
                _ = skipWhitespace()
                guard parseIdentifier() != nil || parseString() else { return false }
                _ = skipWhitespace()
            } else {
                return false // pseudo-class that takes no arguments
            }
            guard current == UInt8(ascii: ")") else { return false }
            i += 1
            return true
        }

        /// An+B: `odd`, `even`, `3`, `2n`, `2n+1`, `-n+3`, `n`.
        mutating func parseNth() -> Bool {
            _ = skipWhitespace()
            let start = i
            var text: [UInt8] = []
            while let c = current, c != UInt8(ascii: ")"), !(c == 0x20 && text.last == 0x20) {
                if c == UInt8(ascii: "o") || c == UInt8(ascii: "O") {
                    // Could be "odd" or " of"; stop at " of".
                    if let p = peek(), p == UInt8(ascii: "f") || p == UInt8(ascii: "F"), text.last == 0x20 { break }
                }
                text.append(c)
                i += 1
            }
            while text.last == 0x20 { text.removeLast() }
            if text.isEmpty { i = start; return false }
            let lowered = String(decoding: text, as: UTF8.self).lowercased().replacingOccurrences(of: " ", with: "")
            if lowered == "odd" || lowered == "even" { return true }
            var sawDigitOrN = false
            var sawN = false
            var previous: Character = " "
            for ch in lowered {
                switch ch {
                case "0"..."9": sawDigitOrN = true
                case "n":
                    if sawN { i = start; return false }
                    sawN = true
                    sawDigitOrN = true
                case "+", "-":
                    if previous == "+" || previous == "-" { i = start; return false }
                default: i = start; return false
                }
                previous = ch
            }
            if !sawDigitOrN || previous == "+" || previous == "-" { i = start; return false }
            return true
        }
    }
}

// MARK: - SHA-256 (Foundation has no hashing API without CryptoKit)

struct ContentBlockerSHA256 {
    private var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    mutating func update(_ bytes: [UInt8]) {
        length &+= UInt64(bytes.count)
        var offset = 0
        if !buffer.isEmpty {
            let need = 64 - buffer.count
            if bytes.count < need {
                buffer.append(contentsOf: bytes)
                return
            }
            buffer.append(contentsOf: bytes[0..<need])
            bytes.withUnsafeBufferPointer { _ in }
            buffer.withUnsafeBufferPointer { compress($0.baseAddress!) }
            buffer.removeAll(keepingCapacity: true)
            offset = need
        }
        bytes.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            while offset + 64 <= bytes.count {
                compress(base + offset)
                offset += 64
            }
        }
        if offset < bytes.count { buffer.append(contentsOf: bytes[offset...]) }
    }

    mutating func finalizeHex() -> String {
        var tail = buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bits = length &* 8
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8((bits >> UInt64(shift)) & 0xff)) }
        tail.withUnsafeBufferPointer { pointer in
            var offset = 0
            while offset < tail.count {
                compress(pointer.baseAddress! + offset)
                offset += 64
            }
        }
        var hex = ""
        hex.reserveCapacity(64)
        for word in state { hex += String(format: "%08x", word) }
        return hex
    }

    private mutating func compress(_ block: UnsafePointer<UInt8>) {
        var w = [UInt32](repeating: 0, count: 64)
        for t in 0..<16 {
            w[t] = UInt32(block[t * 4]) << 24 | UInt32(block[t * 4 + 1]) << 16 | UInt32(block[t * 4 + 2]) << 8 | UInt32(block[t * 4 + 3])
        }
        for t in 16..<64 {
            let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3], e = state[4], f = state[5], g = state[6], h = state[7]
        for t in 0..<64 {
            let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = h &+ S1 &+ ch &+ ContentBlockerSHA256.k[t] &+ w[t]
            let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = S0 &+ maj
            h = g; g = f; f = e; e = d &+ temp1; d = c; c = b; b = a; a = temp1 &+ temp2
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }

    private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
}
