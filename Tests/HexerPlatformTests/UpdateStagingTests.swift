import Foundation
import HexerCore
import Synchronization
import Testing
@testable import HexerPlatform

/// Updates end to end, short of the network: a disk image like Scripts/make_dmg.sh makes, holding
/// an app signed ad hoc like Scripts/bundle.sh signs it, checked and copied out by UpdateStaging.
@Suite struct UpdateStagingTests {
    static let identifier = "com.nongdandev.hexer-update-test"

    /// An app bundle signed ad hoc; its executable is a copy of /usr/bin/true.
    static func makeApp(at url: URL, identifier: String = identifier, version: String) throws {
        let macOS = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                                   "CFBundleExecutable": "Hexer", "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "15.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("Hexer").path)
        let resources = url.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("version \(version)".utf8).write(to: resources.appendingPathComponent("notes.txt"))
        #expect(run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier, url.path]).status == 0)
    }

    /// A compressed HFS+ disk image of `folder`, as make_dmg.sh creates.
    static func makeDiskImage(of folder: URL, at image: URL) throws {
        #expect(run("/usr/bin/hdiutil", ["create", "-volname", "Hexer", "-srcfolder", folder.path, "-fs", "HFS+",
                                         "-format", "UDZO", "-ov", "-quiet", image.path]).status == 0)
    }

    struct Fixture {
        let dir: URL
        let running: URL
        let image: URL
        let staging: URL
        let keys: (privateKey: String, publicKey: String)

        func signature(as version: String = "0.3.0", key: String? = nil) throws -> String {
            try UpdateSignature.sign(fileAt: image, version: version, privateKey: key ?? keys.privateKey)
        }

        func stage(signature: String, version: String = "0.3.0") throws -> URL {
            try UpdateStaging.stage(diskImage: image, signature: signature, version: version, publicKey: keys.publicKey,
                                    replacing: running, bundleIdentifier: identifier, in: staging)
        }
    }

    /// The installed app (0.2.0) and a disk image of 0.3.0; `prepare` may change the new app first.
    static func fixture(newIdentifier: String = identifier, prepare: (URL) throws -> Void = { _ in }) throws -> Fixture {
        let dir = Scratch.url("update")
        let running = dir.appendingPathComponent("Applications/Hexer.app")
        try makeApp(at: running, version: "0.2.0")
        let content = dir.appendingPathComponent("dmg")
        let newApp = content.appendingPathComponent("Hexer.app")
        try makeApp(at: newApp, identifier: newIdentifier, version: "0.3.0")
        try prepare(newApp)
        try FileManager.default.createSymbolicLink(atPath: content.appendingPathComponent("Applications").path,
                                                   withDestinationPath: "/Applications")
        let image = dir.appendingPathComponent("Hexer-0.3.0.dmg")
        try makeDiskImage(of: content, at: image)
        let staging = dir.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return Fixture(dir: dir, running: running, image: image, staging: staging, keys: UpdateSignature.makeKeyPair())
    }

    /// No volume of the fixture's images stays attached.
    static func expectNothingMounted(in fixture: Fixture) throws {
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path)
            .filter { $0 != UpdateStaging.appName }
        #expect(leftovers.isEmpty, "mount points left: \(leftovers)")
    }

    @Test func stagesASignedUpdateThenInstallsIt() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let staged = try f.stage(signature: try f.signature())
        #expect(staged.path == f.staging.appendingPathComponent("Hexer.app").path)
        try CodeSignature.verify(staged, requirement: CodeSignature.updateRequirement(for: f.running))
        try Self.expectNothingMounted(in: f)

        try AppBundleInstaller.checkReplaceable(f.running)
        try AppBundleInstaller.replace(f.running, with: staged)
        let notes = f.running.appendingPathComponent("Contents/Resources/notes.txt")
        #expect(try String(contentsOf: notes, encoding: .utf8) == "version 0.3.0")
        try CodeSignature.verify(f.running)
    }

    @Test func refusesABadSignature() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        // Signed as another version, or with another key: nothing is attached or copied.
        for signature in [try f.signature(as: "0.3.1"), try f.signature(key: UpdateSignature.makeKeyPair().privateKey)] {
            #expect(throws: UpdateError.badSignature) { try f.stage(signature: signature) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.staging.path).isEmpty)
    }

    @Test func refusesAnotherVersionOrApp() throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        // A genuine image signed as what it isn't still fails on the app's own version.
        #expect(throws: UpdateError.versionMismatch(expected: "0.4.0", found: "0.3.0")) {
            try f.stage(signature: try f.signature(as: "0.4.0"), version: "0.4.0")
        }
        try Self.expectNothingMounted(in: f)

        let other = try Self.fixture(newIdentifier: "com.example.other")
        defer { try? FileManager.default.removeItem(at: other.dir) }
        #expect(throws: UpdateError.notHexer) { try other.stage(signature: try other.signature()) }
    }

    @Test func refusesAnAppChangedAfterSigning() throws {
        let f = try Self.fixture { app in
            try Data("tampered".utf8).write(to: app.appendingPathComponent("Contents/Resources/notes.txt"))
        }
        defer { try? FileManager.default.removeItem(at: f.dir) }
        #expect(throws: CodeSignature.Failure.self) { try f.stage(signature: try f.signature()) }
        try Self.expectNothingMounted(in: f)
    }

    @Test func adHocAppsRequireTheirIdentifier() throws {
        let dir = Scratch.url("requirement")
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("A.app")
        try Self.makeApp(at: app, version: "1.0")
        #expect(CodeSignature.updateRequirement(for: app) == "identifier \"\(Self.identifier)\"")
        try CodeSignature.verify(app, requirement: "identifier \"\(Self.identifier)\"")
        #expect(throws: CodeSignature.Failure.self) { try CodeSignature.verify(app, requirement: "identifier \"com.example.other\"") }
        #expect(CodeSignature.updateRequirement(for: dir) == nil)
    }

    @Test func downloadsWithProgress() async throws {
        let dir = Scratch.url("download")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.bin")
        let bytes = randomBytes(3 << 20, seed: 7)
        try Data(bytes).write(to: source)
        let destination = dir.appendingPathComponent("copy.bin")
        let last = Mutex<Int64>(0)
        try await Downloads.file(URLRequest(url: source), to: destination, maxBytes: 4 << 20) { received, _ in
            last.withLock { $0 = received }
        }
        #expect(try [UInt8](Data(contentsOf: destination)) == bytes)
        #expect(last.withLock { $0 } == Int64(bytes.count))
        await #expect(throws: UpdateError.tooLarge) {
            try await Downloads.file(URLRequest(url: source), to: destination, maxBytes: 1 << 20) { _, _ in }
        }
        #expect(try await Downloads.data(URLRequest(url: source), maxBytes: 4 << 20).count == bytes.count)
        await #expect(throws: UpdateError.tooLarge) { try await Downloads.data(URLRequest(url: source), maxBytes: 100) }
    }
}
