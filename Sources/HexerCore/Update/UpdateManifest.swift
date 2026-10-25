import Foundation

/// The update manifest (`update.json`): the releases that can be installed, with the disk image's
/// SHA-256, size and signature and every URL it can be downloaded from. It is a plain file, so it
/// can sit on any host (the update server is an S3-compatible bucket, Cloudflare R2; a copy goes
/// on the GitHub release as a fallback) and reading it counts against no API limit. The release
/// workflow writes it (`hexer-cli update manifest`, from `Scripts/publish_update.sh`) and uploads
/// it after the image.
///
///     { "format": 1, "releases": [{
///         "version": "0.4.0", "prerelease": false, "page": "https://…", "notes": "Markdown",
///         "size": 6782206, "sha256": "…", "signature": "<Base64, as in the .sig file>",
///         "urls": ["https://updates.example/Hexer-0.4.0.dmg", "https://github.com/…/Hexer-0.4.0.dmg"] }] }
///
/// Nothing in it needs to be trusted: the app checks the image's signature against the public key
/// it carries, so a host can only withhold an update, never substitute one.
public struct UpdateManifest: Codable, Equatable, Sendable {
    public static let format = 1
    /// How many releases a manifest keeps: enough to offer the newest stable and the newest beta.
    public static let maxReleases = 10

    public struct Entry: Codable, Equatable, Sendable {
        public var version: String
        public var prerelease: Bool
        public var page: String
        public var notes: String
        public var size: Int64
        public var sha256: String
        public var signature: String
        public var urls: [String]

        public init(version: String, prerelease: Bool, page: String, notes: String, size: Int64,
                    sha256: String, signature: String, urls: [String]) {
            self.version = version
            self.prerelease = prerelease
            self.page = page
            self.notes = notes
            self.size = size
            self.sha256 = sha256
            self.signature = signature
            self.urls = urls
        }
    }

    public var format: Int
    public var releases: [Entry]

    public init(releases: [Entry]) {
        format = Self.format
        self.releases = releases
    }

    /// The releases that can be installed: a version, a signature, and at least one download over
    /// HTTPS (or from local files when `allowingFileURLs`, for testing). Others are left out.
    public static func releases(from data: Data, allowingFileURLs: Bool = false) throws -> [UpdateRelease] {
        let manifest: UpdateManifest
        do {
            manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch {
            throw UpdateError.invalidFeed
        }
        guard manifest.format == Self.format else { throw UpdateError.invalidFeed }
        func url(_ string: String) -> URL? {
            guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return nil }
            return scheme == "https" || allowingFileURLs && scheme == "file" ? url : nil
        }
        return manifest.releases.compactMap { entry in
            guard let version = AppVersion(entry.version), !entry.signature.isEmpty, let page = url(entry.page) else { return nil }
            let urls = entry.urls.compactMap(url)
            guard !urls.isEmpty else { return nil }
            return UpdateRelease(version: version, notes: entry.notes, pageURL: page, diskImageURLs: urls,
                                 diskImageSize: entry.size, signature: entry.signature,
                                 isPrerelease: entry.prerelease || version.isPrerelease)
        }
    }

    /// `previous` (a manifest, or nil) with `entry` added: an older entry for the same version is
    /// replaced, the newest `maxReleases` versions are kept, and the newest comes first.
    public static func adding(_ entry: Entry, to previous: Data?) -> UpdateManifest {
        var kept = previous.flatMap { try? JSONDecoder().decode(UpdateManifest.self, from: $0) }?.releases ?? []
        kept.removeAll { AppVersion($0.version) == AppVersion(entry.version) || AppVersion($0.version) == nil }
        kept.append(entry)
        kept.sort { (AppVersion($0.version) ?? AppVersion("0")!) > (AppVersion($1.version) ?? AppVersion("0")!) }
        return UpdateManifest(releases: Array(kept.prefix(maxReleases)))
    }

    /// The manifest as the workflow publishes it: stable key order, one release per block.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }
}
