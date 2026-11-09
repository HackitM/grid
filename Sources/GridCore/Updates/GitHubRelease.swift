import Foundation

/// A GitHub release as returned by `GET /repos/{owner}/{repo}/releases[/latest]`, reduced to the
/// fields the update checker uses. Everything in it is remote data: URLs are only accepted when
/// they point at the expected repository on github.com (see `UpdateFeed.validated`).
public struct GitHubRelease: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public let name: String
        public let size: Int
        public let downloadURL: URL

        enum CodingKeys: String, CodingKey { case name, size, downloadURL = "browser_download_url" }
        public init(name: String, size: Int, downloadURL: URL) { self.name = name; self.size = size; self.downloadURL = downloadURL }
    }

    public let tagName: String
    public let name: String?
    public let pageURL: URL
    public let publishedAt: Date?
    public let body: String?
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", name, pageURL = "html_url", publishedAt = "published_at", body, draft, prerelease, assets
    }

    public init(tagName: String, name: String?, pageURL: URL, publishedAt: Date?, body: String?,
                draft: Bool = false, prerelease: Bool = false, assets: [Asset]) {
        self.tagName = tagName; self.name = name; self.pageURL = pageURL; self.publishedAt = publishedAt
        self.body = body; self.draft = draft; self.prerelease = prerelease; self.assets = assets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try c.decode(String.self, forKey: .tagName)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        pageURL = try c.decode(URL.self, forKey: .pageURL)
        publishedAt = (try c.decodeIfPresent(String.self, forKey: .publishedAt)).flatMap { ISO8601DateFormatter().date(from: $0) }
        body = try c.decodeIfPresent(String.self, forKey: .body)
        draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        prerelease = try c.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }

    public var version: SemanticVersion? { SemanticVersion(tagName) }

    /// The app zip and its checksum, by the names `scripts/release.sh` gives them.
    public var appAsset: Asset? { version.flatMap { v in assets.first { $0.name == "GRID-\(v)-macOS.zip" } } }
    public var checksumAsset: Asset? { appAsset.flatMap { a in assets.first { $0.name == a.name + ".sha256" } } }
}

/// Where releases come from and what counts as trustworthy in a response.
public struct UpdateFeed: Sendable {
    public let owner: String
    public let repo: String

    public static let grid = UpdateFeed(owner: "HackitM", repo: "grid")

    public init(owner: String, repo: String) { self.owner = owner; self.repo = repo }

    public var latestURL: URL { URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")! }
    public var listURL: URL { URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=10")! }

    /// True for `https://github.com/<owner>/<repo>/…` only.
    public func isRepositoryURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.port == nil else { return false }
        let parts = url.path.split(separator: "/")
        return parts.count >= 2 && parts[0].lowercased() == owner.lowercased() && parts[1].lowercased() == repo.lowercased()
    }

    /// Drops a release whose page or download links leave the repository (a tampered or
    /// unexpected response); keeps only asset links under `/releases/download/`.
    public func validated(_ r: GitHubRelease) -> GitHubRelease? {
        guard isRepositoryURL(r.pageURL), r.version != nil else { return nil }
        let assets = r.assets.filter { isRepositoryURL($0.downloadURL) && $0.downloadURL.path.contains("/releases/download/") && $0.size >= 0 }
        return GitHubRelease(tagName: r.tagName, name: r.name, pageURL: r.pageURL, publishedAt: r.publishedAt, body: r.body,
                             draft: r.draft, prerelease: r.prerelease, assets: assets)
    }

    /// Parses a `/releases/latest` (one object) or `/releases` (array) response and returns the
    /// newest acceptable release: never drafts, pre-releases only when asked for.
    public func newest(from data: Data, includePrereleases: Bool) throws -> GitHubRelease? {
        let decoder = JSONDecoder()
        let all: [GitHubRelease]
        if let one = try? decoder.decode(GitHubRelease.self, from: data) {
            all = [one]
        } else {
            all = try decoder.decode([GitHubRelease].self, from: data)
        }
        return all.compactMap(validated)
            .filter { !$0.draft && (includePrereleases || (!$0.prerelease && !($0.version?.isPrerelease ?? true))) }
            .max { ($0.version ?? SemanticVersion(major: 0, minor: 0, patch: 0)) < ($1.version ?? SemanticVersion(major: 0, minor: 0, patch: 0)) }
    }
}
