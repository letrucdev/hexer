import CryptoKit
import Foundation
import Testing
@testable import HexerCore

@Suite struct AppVersionTests {
    private func v(_ s: String) -> AppVersion { AppVersion(s)! }

    @Test func parsesTagsAndShortVersions() {
        #expect(v("v0.2.0").core == [0, 2, 0] && v("v0.2.0").description == "0.2.0")
        #expect(v("0.1") == v("0.1.0") && v("1") == v("1.0.0"))
        #expect(v("0.3.0-beta.1").prerelease == ["beta", "1"] && v("0.3.0-beta.1").isPrerelease)
        #expect(v("1.0.0+build.5") == v("1.0.0"))
        for bad in ["", "v", "1.2.3.4", "1..2", "a.b", "1.2.x", "1.2.3-", "1.2.3-beta..1", "1.2.3-bêta", "-1.0"] {
            #expect(AppVersion(bad) == nil, "\(bad)")
        }
    }

    @Test func ordersBySemanticVersioningPrecedence() {
        // The example from semver.org §11, then the cases this project's tags produce.
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                       "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1", "2.0.0"].map(v)
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            #expect(a < b, "\(a) < \(b)")
            #expect(!(b < a), "!(\(b) < \(a))")
        }
        #expect(v("0.1") < v("0.1.1") && v("0.1.1") < v("0.2.0-beta.1") && v("0.2.0-beta.1") < v("0.2.0"))
        #expect(v("0.10.0") > v("0.9.9"))
        #expect(!(v("0.2") < v("0.2.0")) && !(v("0.2.0") < v("0.2")))
    }
}

@Suite struct ReleaseNotesTests {
    /// The notes of the v0.2.0 release as GitHub returns them (with CRLF line endings, as the API
    /// sometimes does), shortened.
    static let notes = """
        A hex editor for macOS 15 Sequoia or later, on Apple silicon and Intel Macs.

        ## What's new
        - The first time Hexer starts without a file, a short welcome tour shows what it can do.
        - Find All lists every match
          in the results drawer.

        ## Có gì mới
        - Lần đầu Hexer mở mà không kèm tệp, một màn hình chào ngắn sẽ giới thiệu app.
        - Tìm tất cả liệt kê mọi kết quả trong ngăn kết quả.

        ## Install

        1. Download **Hexer-0.2.0.dmg**, open it and drag **Hexer** onto **Applications**.
        - Not a change.

        SHA-256: `69c79ffb`
        """.replacingOccurrences(of: "\n", with: "\r\n")

    @Test func listsTheChangesInTheUILanguage() {
        #expect(ReleaseNotes.items(in: Self.notes, vietnamese: false) == [
            "The first time Hexer starts without a file, a short welcome tour shows what it can do.",
            "Find All lists every match in the results drawer.",
        ])
        #expect(ReleaseNotes.items(in: Self.notes, vietnamese: true) == [
            "Lần đầu Hexer mở mà không kèm tệp, một màn hình chào ngắn sẽ giới thiệu app.",
            "Tìm tất cả liệt kê mọi kết quả trong ngăn kết quả.",
        ])
    }

    @Test func fallsBackToEnglishThenToNothing() {
        let english = "### What’s New\n- Faster search.\n### Fixed\n- Nothing."
        #expect(ReleaseNotes.items(in: english, vietnamese: true) == ["Faster search."])
        #expect(ReleaseNotes.items(in: "Just text.\n- A list without a heading.", vietnamese: false).isEmpty)
    }
}

@Suite struct UpdateSignatureTests {
    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hexer-update-\(UUID().uuidString).dmg")
        try Data(bytes).write(to: url)
        return url
    }

    @Test func messageNamesVersionAndDigest() {
        let message = UpdateSignature.message(version: "0.3.0", sha256: [0x00, 0xAB, 0x10])
        #expect(String(decoding: message, as: UTF8.self) == "hexer-update-v1\n0.3.0\n00ab10\n")
    }

    @Test func digestMatchesKnownAnswer() throws {
        // More than one 1 MiB block; `shasum -a 256` of 3 MiB + 5 bytes of 0x61.
        let url = try tempFile([UInt8](repeating: 0x61, count: 3 << 20 | 5))
        defer { try? FileManager.default.removeItem(at: url) }
        let hex = try UpdateSignature.sha256(ofFileAt: url).map { String(format: "%02x", $0) }.joined()
        #expect(hex == "aff2c7498aae939dfb2fb1dc6c0c83fa3708b069428e51338801af7f5dc2bf0f")
        let empty = try tempFile([])
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(try UpdateSignature.sha256(ofFileAt: empty).map { String(format: "%02x", $0) }.joined()
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func signThenVerify() throws {
        let url = try tempFile((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = UpdateSignature.makeKeyPair()
        #expect(try UpdateSignature.publicKey(forPrivateKey: keys.privateKey) == keys.publicKey)
        let signature = try UpdateSignature.sign(fileAt: url, version: "0.3.0", privateKey: keys.privateKey)
        try UpdateSignature.verify(fileAt: url, version: "0.3.0", signature: signature + "\n", publicKey: keys.publicKey)

        // Another version, another key, a changed byte or a malformed signature all fail.
        #expect(throws: UpdateError.badSignature) {
            try UpdateSignature.verify(fileAt: url, version: "0.3.1", signature: signature, publicKey: keys.publicKey)
        }
        #expect(throws: UpdateError.badSignature) {
            try UpdateSignature.verify(fileAt: url, version: "0.3.0", signature: signature,
                                       publicKey: UpdateSignature.makeKeyPair().publicKey)
        }
        #expect(throws: UpdateError.badSignature) {
            try UpdateSignature.verify(fileAt: url, version: "0.3.0", signature: "c2lnbmF0dXJl", publicKey: keys.publicKey)
        }
        #expect(throws: UpdateError.invalidPublicKey) {
            try UpdateSignature.verify(fileAt: url, version: "0.3.0", signature: signature, publicKey: "")
        }
        #expect(throws: UpdateError.invalidPrivateKey) {
            try UpdateSignature.sign(fileAt: url, version: "0.3.0", privateKey: "short")
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 69_999)
        try handle.write(contentsOf: [0xFF])
        try handle.close()
        #expect(throws: UpdateError.badSignature) {
            try UpdateSignature.verify(fileAt: url, version: "0.3.0", signature: signature, publicKey: keys.publicKey)
        }
    }

    /// A signature made by OpenSSL 4 (`openssl pkeyutl -sign -rawin`) over the message for an
    /// empty file, so the format stays what other Ed25519 implementations produce.
    @Test func verifiesAnOpenSSLSignature() throws {
        let empty = try tempFile([])
        defer { try? FileManager.default.removeItem(at: empty) }
        try UpdateSignature.verify(fileAt: empty, version: "1.0.0", signature: Self.openSSLSignature,
                                   publicKey: Self.openSSLPublicKey)
    }

    static let openSSLPublicKey = "VD38wD3TSLnaQ5xyDifGXIPxNtOcmWN4oMnunxBSiz4="
    static let openSSLSignature = "7Ee6DF1ZdqhULT1blJQVSU/QNo1dRgMuBRpeo8hzB69kmJUKmbLiNk0x7G3soRir8lKFLGzuBDh55h0vinn3Ag=="
}

@Suite struct AppBundleInstallerTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hexer-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeBundle(at url: URL, identifier: String = "com.example.app", version: String = "1.0.0",
                            minimumSystem: String? = "15.0", marker: String = "") throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version]
        if let minimumSystem { info["LSMinimumSystemVersion"] = minimumSystem }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data(marker.utf8).write(to: contents.appendingPathComponent("MacOS/marker"))
    }

    private let sequoia = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)

    @Test func validatesIdentifierVersionAndSystem() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("A.app")
        try makeBundle(at: app, version: "0.3.0", minimumSystem: "15.4")
        let newer = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        try AppBundleInstaller.validate(app, bundleIdentifier: "com.example.app", version: "0.3.0", system: newer)
        try AppBundleInstaller.validate(app, bundleIdentifier: "com.example.app", version: "0.3.0",
                                        system: OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0))
        #expect(throws: UpdateError.requiresNewerSystem("15.4")) {
            try AppBundleInstaller.validate(app, bundleIdentifier: "com.example.app", version: "0.3.0", system: sequoia)
        }
        #expect(throws: UpdateError.notHexer) {
            try AppBundleInstaller.validate(app, bundleIdentifier: "com.example.other", version: "0.3.0", system: newer)
        }
        #expect(throws: UpdateError.versionMismatch(expected: "0.3.1", found: "0.3.0")) {
            try AppBundleInstaller.validate(app, bundleIdentifier: "com.example.app", version: "0.3.1", system: newer)
        }
        #expect(throws: UpdateError.notHexer) {
            try AppBundleInstaller.validate(dir.appendingPathComponent("Missing.app"), bundleIdentifier: "com.example.app",
                                            version: "0.3.0", system: newer)
        }
    }

    @Test func replaceSwapsTheBundles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let installed = dir.appendingPathComponent("Applications/Hexer.app")
        let staged = dir.appendingPathComponent("Staging/Hexer.app")
        try makeBundle(at: installed, marker: "old")
        try makeBundle(at: staged, marker: "new")
        try AppBundleInstaller.checkReplaceable(installed)
        try AppBundleInstaller.replace(installed, with: staged)
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/MacOS/marker"), encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Staging").path).isEmpty)
    }

    @Test func replaceLeavesTheAppWhenTheUpdateIsMissing() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let installed = dir.appendingPathComponent("Hexer.app")
        try makeBundle(at: installed, marker: "old")
        #expect(throws: UpdateError.replaceFailed(path: installed.path, code: ENOENT)) {
            try AppBundleInstaller.replace(installed, with: dir.appendingPathComponent("Missing/Hexer.app"))
        }
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/MacOS/marker"), encoding: .utf8) == "old")
    }

    @Test func refusesTranslocatedAndReadOnlyLocations() throws {
        #expect(throws: UpdateError.translocated) {
            try AppBundleInstaller.checkReplaceable(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Hexer.app"))
        }
        let dir = try tempDir()
        defer {
            chmod(dir.path, 0o755)
            try? FileManager.default.removeItem(at: dir)
        }
        let app = dir.appendingPathComponent("Hexer.app")
        try makeBundle(at: app)
        chmod(dir.path, 0o555)
        #expect(throws: UpdateError.notWritable(path: dir.path)) { try AppBundleInstaller.checkReplaceable(app) }
    }
}

@Suite struct UpdateManifestTests {
    static func entry(_ version: String, urls: [String] = ["https://cdn.example.com/Hexer-0.3.2.dmg", "https://github.com/x/Hexer-0.3.2.dmg"],
                      signature: String = "c2ln", prerelease: Bool = false) -> UpdateManifest.Entry {
        UpdateManifest.Entry(version: version, prerelease: prerelease, page: "https://github.com/letrucdev/hexer/releases/tag/v\(version)",
                             notes: "## \(version)", size: 6_782_206, sha256: "ab", signature: signature, urls: urls)
    }

    static func manifest(_ entries: [UpdateManifest.Entry]) throws -> Data {
        try UpdateManifest(releases: entries).encoded()
    }

    @Test func readsMirrorsAndSignature() throws {
        let releases = try UpdateManifest.releases(from: Self.manifest([Self.entry("0.3.2")]))
        let r = try #require(releases.first)
        #expect(releases.count == 1 && r.version.description == "0.3.2")
        #expect(r.diskImageURLs.map(\.host) == ["cdn.example.com", "github.com"])
        #expect(r.diskImageURL.host == "cdn.example.com")
        #expect(r.signature == "c2ln" && r.diskImageSize == 6_782_206 && !r.isPrerelease)
        #expect(r.pageURL.absoluteString == "https://github.com/letrucdev/hexer/releases/tag/v0.3.2")
    }

    @Test func leavesOutReleasesThatCantBeInstalled() throws {
        let releases = try UpdateManifest.releases(from: Self.manifest([
            Self.entry("0.4.0", signature: ""),
            Self.entry("0.3.9", urls: ["http://cdn.example.com/a.dmg"]),
            Self.entry("not-a-version"),
            Self.entry("0.3.5", urls: ["http://cdn.example.com/a.dmg", "https://cdn.example.com/a.dmg"]),
            Self.entry("0.3.4-beta.1"),
            Self.entry("0.3.3", prerelease: true),
        ]))
        #expect(releases.map(\.version.description) == ["0.3.5", "0.3.4-beta.1", "0.3.3"])
        #expect(releases[0].diskImageURLs.count == 1 && releases[1].isPrerelease && releases[2].isPrerelease)
    }

    @Test func fileURLsOnlyWhenAllowed() throws {
        let data = try Self.manifest([Self.entry("1.0.0", urls: ["file:///tmp/feed/Hexer-1.0.0.dmg"])])
        #expect(try UpdateManifest.releases(from: data).isEmpty)
        #expect(try UpdateManifest.releases(from: data, allowingFileURLs: true).count == 1)
    }

    @Test func rejectsWhatIsNotAManifest() {
        for text in ["", "{}", #"{"format":2,"releases":[]}"#, "<html>", "[]", #"{"message": "API rate limit exceeded"}"#] {
            #expect(throws: UpdateError.invalidFeed) { try UpdateManifest.releases(from: Data(text.utf8)) }
        }
    }

    @Test func picksTheNewestUpdate() throws {
        let releases = try UpdateManifest.releases(from: Self.manifest([
            Self.entry("0.2.0"), Self.entry("0.3.0-beta.2"), Self.entry("0.2.1"), Self.entry("0.1.1"),
        ]))
        func newest(_ current: String, betas: Bool = false, skipping: String? = nil) -> String? {
            UpdateFeed.newest(in: releases, after: AppVersion(current)!, includingPrereleases: betas,
                              skipping: skipping.flatMap(AppVersion.init))?.version.description
        }
        #expect(newest("0.1.1") == "0.2.1")
        #expect(newest("0.1.1", betas: true) == "0.3.0-beta.2")
        #expect(newest("0.2.1") == nil)
        #expect(newest("0.3.0-beta.1", betas: true) == "0.3.0-beta.2")
        #expect(newest("0.3.0") == nil && newest("0.3.0", betas: true) == nil)
        // Skipping the newest offers nothing; a newer release than the skipped one comes back.
        #expect(newest("0.1.1", skipping: "0.2.1") == nil)
        #expect(newest("0.1.1", betas: true, skipping: "0.2.1") == "0.3.0-beta.2")
    }

    @Test func addingKeepsTheNewestAndReplacesTheSameVersion() throws {
        var data: Data?
        for version in ["0.3.0", "0.3.2", "0.3.1", "0.3.2"] {
            data = try UpdateManifest.adding(Self.entry(version, signature: "sig-\(version)-\(data?.count ?? 0)"), to: data).encoded()
        }
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: #require(data))
        #expect(manifest.releases.map(\.version) == ["0.3.2", "0.3.1", "0.3.0"])
        #expect(manifest.releases[0].signature.hasPrefix("sig-0.3.2-"))

        var many: Data?
        for minor in 0..<15 { many = try UpdateManifest.adding(Self.entry("0.\(minor).0"), to: many).encoded() }
        let kept = try JSONDecoder().decode(UpdateManifest.self, from: #require(many)).releases.map(\.version)
        #expect(kept.count == UpdateManifest.maxReleases && kept.first == "0.14.0" && kept.last == "0.5.0")
    }

    @Test func addingToUnreadableManifestStartsOver() {
        let manifest = UpdateManifest.adding(Self.entry("0.3.2"), to: Data("garbage".utf8))
        #expect(manifest.releases.map(\.version) == ["0.3.2"])
    }

    @Test func encodesStablyWithPlainSlashes() throws {
        let text = String(decoding: try Self.manifest([Self.entry("0.3.2")]), as: UTF8.self)
        #expect(text.hasPrefix("{\n  \"format\" : 1,\n  \"releases\" : [") && text.hasSuffix("}\n"))
        #expect(text.contains("https://cdn.example.com/Hexer-0.3.2.dmg") && !text.contains("\\/"))
    }
}

@Suite struct AWSSignatureV4Tests {
    /// The examples of the S3 developer guide, "Signature Calculations in the Authorization Header".
    static let credentials = AWSSignatureV4.Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE",
                                                        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    static let date = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z

    @Test func signsAGetLikeAmazonsExample() throws {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        try AWSSignatureV4.sign(&request, payloadSHA256: AWSSignatureV4.emptyPayloadSHA256, credentials: Self.credentials,
                                region: "us-east-1", date: Self.date)
        #expect(request.value(forHTTPHeaderField: "x-amz-date") == "20130524T000000Z")
        #expect(request.value(forHTTPHeaderField: "x-amz-content-sha256") == AWSSignatureV4.emptyPayloadSHA256)
        #expect(request.value(forHTTPHeaderField: "Authorization") == """
            AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, \
            SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, \
            Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41
            """)
    }

    @Test func signsAPutLikeAmazonsExample() throws {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test$file.text")!)
        request.httpMethod = "PUT"
        request.setValue("Fri, 24 May 2013 00:00:00 GMT", forHTTPHeaderField: "Date")
        request.setValue("REDUCED_REDUNDANCY", forHTTPHeaderField: "x-amz-storage-class")
        let payload = AWSSignatureV4.hex(SHA256.hash(data: Data("Welcome to Amazon S3.".utf8)))
        #expect(payload == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
        try AWSSignatureV4.sign(&request, payloadSHA256: payload, credentials: Self.credentials, region: "us-east-1", date: Self.date)
        #expect(AWSSignatureV4.canonicalPath(request.url!) == "/test%24file.text")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasSuffix(
            "SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, "
            + "Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd") == true)
    }

    @Test func canonicalizesPathsAndQueries() {
        let url = URL(string: "https://host.example/a%20b/c~d.json?z=2&a=x%2Fy&a=1&empty")!
        #expect(AWSSignatureV4.canonicalPath(url) == "/a%20b/c~d.json")
        #expect(AWSSignatureV4.canonicalQuery(url) == "a=1&a=x%2Fy&empty=&z=2")
        #expect(AWSSignatureV4.canonicalPath(URL(string: "https://host.example")!) == "/")
        #expect(AWSSignatureV4.canonicalQuery(URL(string: "https://host.example/k")!) == "")
    }

    @Test func rejectsARequestWithoutAHost() {
        var request = URLRequest(url: URL(string: "file:///tmp/x")!)
        #expect(throws: URLError.self) {
            try AWSSignatureV4.sign(&request, payloadSHA256: AWSSignatureV4.emptyPayloadSHA256, credentials: Self.credentials, region: "auto")
        }
    }
}
