import Foundation

/// A published release that can update Hexer: its disk image and the image's signature, as
/// `.github/workflows/release.yml` uploads them (`Hexer-VERSION.dmg`, `Hexer-VERSION.dmg.sig`).
public struct UpdateRelease: Equatable, Sendable {
    public var version: AppVersion
    /// The release notes (Markdown), which open with the version's section of CHANGELOG.md.
    public var notes: String
    /// The release's page, for downloading by hand.
    public var pageURL: URL
    public var diskImageURL: URL
    public var diskImageSize: Int64
    public var signatureURL: URL
    public var isPrerelease: Bool

    public init(version: AppVersion, notes: String, pageURL: URL, diskImageURL: URL, diskImageSize: Int64,
                signatureURL: URL, isPrerelease: Bool) {
        self.version = version
        self.notes = notes
        self.pageURL = pageURL
        self.diskImageURL = diskImageURL
        self.diskImageSize = diskImageSize
        self.signatureURL = signatureURL
        self.isPrerelease = isPrerelease
    }

    /// The disk image's file name for a version.
    public static func diskImageName(_ version: String) -> String { "Hexer-\(version).dmg" }
}

/// Reads the list of releases from GitHub's REST API (`GET /repos/OWNER/REPO/releases`) and picks
/// the one to offer.
public enum UpdateFeed {
    private struct GitHubRelease: Decodable {
        var tag_name: String
        var draft: Bool?
        var prerelease: Bool?
        var body: String?
        var html_url: String
        var assets: [Asset]?

        struct Asset: Decodable {
            var name: String
            var size: Int64?
            var browser_download_url: String
        }
    }

    /// The releases that can be installed: not drafts, a version tag (`v0.2.0`), and both the disk
    /// image and its signature attached, downloadable over HTTPS (or from local files when
    /// `allowingFileURLs`, for testing). Others are left out.
    public static func releases(fromGitHubJSON data: Data, allowingFileURLs: Bool = false) throws -> [UpdateRelease] {
        let decoded: [GitHubRelease]
        do {
            decoded = try JSONDecoder().decode([GitHubRelease].self, from: data)
        } catch {
            throw UpdateError.invalidFeed
        }
        func url(_ string: String) -> URL? {
            guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return nil }
            return scheme == "https" || allowingFileURLs && scheme == "file" ? url : nil
        }
        return decoded.compactMap { release in
            guard release.draft != true, let version = AppVersion(release.tag_name) else { return nil }
            let imageName = UpdateRelease.diskImageName(version.description)
            let assets = release.assets ?? []
            guard let image = assets.first(where: { $0.name == imageName }),
                  let signature = assets.first(where: { $0.name == imageName + ".sig" }),
                  let imageURL = url(image.browser_download_url), let signatureURL = url(signature.browser_download_url),
                  let page = url(release.html_url) else { return nil }
            return UpdateRelease(version: version, notes: release.body ?? "", pageURL: page, diskImageURL: imageURL,
                                 diskImageSize: image.size ?? 0, signatureURL: signatureURL,
                                 isPrerelease: release.prerelease == true || version.isPrerelease)
        }
    }

    /// The newest release after `current`, or nil when there is none or it is `skipped` (a newer
    /// one than the skipped version is offered again). Pre-releases count only when asked for.
    public static func newest(in releases: [UpdateRelease], after current: AppVersion,
                              includingPrereleases: Bool, skipping skipped: AppVersion? = nil) -> UpdateRelease? {
        let newest = releases.filter { $0.version > current && (includingPrereleases || !$0.isPrerelease) }
            .max { $0.version < $1.version }
        guard let newest, newest.version != skipped else { return nil }
        return newest
    }
}
