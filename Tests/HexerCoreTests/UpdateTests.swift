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

@Suite struct UpdateFeedTests {
    /// The shape of GitHub's `GET /repos/letrucdev/hexer/releases`, trimmed to the fields Hexer
    /// reads plus a few it ignores.
    static func feed(_ releases: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: releases)
    }

    static func release(_ tag: String, prerelease: Bool = false, draft: Bool = false, signed: Bool = true,
                        host: String = "https://github.com", body: String = "") -> [String: Any] {
        let version = AppVersion(tag)?.description ?? tag
        let base = "\(host)/letrucdev/hexer/releases/download/\(tag)/Hexer-\(version).dmg"
        var assets: [[String: Any]] = [
            ["name": "Hexer-\(version).dmg", "size": 6_782_206, "content_type": "application/x-apple-diskimage",
             "browser_download_url": base, "digest": "sha256:69c7"],
            ["name": "Hexer-\(version).dmg.sha256", "size": 82, "browser_download_url": base + ".sha256"],
        ]
        if signed { assets.append(["name": "Hexer-\(version).dmg.sig", "size": 89, "browser_download_url": base + ".sig"]) }
        return ["tag_name": tag, "name": "Hexer \(version)", "draft": draft, "prerelease": prerelease, "body": body,
                "html_url": "https://github.com/letrucdev/hexer/releases/tag/\(tag)", "published_at": "2026-10-24T11:51:40Z",
                "assets": assets]
    }

    @Test func readsSignedReleasesOnly() throws {
        let data = Self.feed([
            Self.release("v0.4.0", draft: true),
            Self.release("v0.3.1", signed: false),
            Self.release("v0.3.0-beta.1", prerelease: true),
            Self.release("v0.2.1", host: "http://github.com"),
            Self.release("v0.2.0"),
            Self.release("nightly"),
        ])
        let releases = try UpdateFeed.releases(fromGitHubJSON: data)
        #expect(releases.map(\.version.description) == ["0.3.0-beta.1", "0.2.0"])
        let r = releases[1]
        #expect(r.diskImageURL.absoluteString == "https://github.com/letrucdev/hexer/releases/download/v0.2.0/Hexer-0.2.0.dmg")
        #expect(r.signatureURL.lastPathComponent == "Hexer-0.2.0.dmg.sig")
        #expect(r.pageURL.absoluteString == "https://github.com/letrucdev/hexer/releases/tag/v0.2.0")
        #expect(r.diskImageSize == 6_782_206 && !r.isPrerelease && releases[0].isPrerelease)
    }

    @Test func fileURLsOnlyWhenAllowed() throws {
        let data = Self.feed([Self.release("v1.0.0", host: "file:///tmp/feed")])
        #expect(try UpdateFeed.releases(fromGitHubJSON: data).isEmpty)
        #expect(try UpdateFeed.releases(fromGitHubJSON: data, allowingFileURLs: true).count == 1)
    }

    @Test func rejectsWhatIsNotAReleaseList() {
        for text in ["", "{}", "{\"message\": \"API rate limit exceeded\"}", "[{\"tag\": 1}]"] {
            #expect(throws: UpdateError.invalidFeed) { try UpdateFeed.releases(fromGitHubJSON: Data(text.utf8)) }
        }
    }

    @Test func picksTheNewestUpdate() throws {
        let releases = try UpdateFeed.releases(fromGitHubJSON: Self.feed([
            Self.release("v0.2.0"), Self.release("v0.3.0-beta.2", prerelease: true), Self.release("v0.2.1"), Self.release("v0.1.1"),
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
