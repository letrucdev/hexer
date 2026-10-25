import Foundation

/// A published release that can update Hexer: its disk image (`Hexer-VERSION.dmg`), the image's
/// signature and every place it can be downloaded from, as the release workflow lists them in the
/// update manifest `update.json` (see `UpdateManifest`).
public struct UpdateRelease: Equatable, Sendable {
    public var version: AppVersion
    /// The release notes (Markdown), which open with the version's section of CHANGELOG.md.
    public var notes: String
    /// The release's page, for downloading by hand.
    public var pageURL: URL
    /// Where the disk image can be downloaded, in the order to try; never empty.
    public var diskImageURLs: [URL]
    public var diskImageSize: Int64
    /// The image's Ed25519 signature, Base64 (see `UpdateSignature`).
    public var signature: String
    public var isPrerelease: Bool

    public init(version: AppVersion, notes: String, pageURL: URL, diskImageURLs: [URL], diskImageSize: Int64,
                signature: String, isPrerelease: Bool) {
        precondition(!diskImageURLs.isEmpty, "a release needs a disk image to download")
        self.version = version
        self.notes = notes
        self.pageURL = pageURL
        self.diskImageURLs = diskImageURLs
        self.diskImageSize = diskImageSize
        self.signature = signature
        self.isPrerelease = isPrerelease
    }

    /// The preferred place to download the image from.
    public var diskImageURL: URL { diskImageURLs[0] }

    /// The disk image's file name for a version.
    public static func diskImageName(_ version: String) -> String { "Hexer-\(version).dmg" }
}

/// Picks the release to offer from the ones a feed lists.
public enum UpdateFeed {
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
