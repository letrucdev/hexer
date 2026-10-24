import Foundation
import HexerCore

/// Turns a downloaded update into an app ready to swap in with `AppBundleInstaller.replace`.
public enum UpdateStaging {
    /// The app's name in the disk image (Scripts/make_dmg.sh).
    public static let appName = "Hexer.app"

    /// Checks the disk image's Ed25519 signature, then the app inside it (bundle identifier,
    /// version, minimum macOS, code signature against what `running` requires of updates), and
    /// copies the app into `folder`, which must be on the installed app's volume. Returns the copy.
    public static func stage(diskImage: URL, signature: String, version: String, publicKey: String,
                             replacing running: URL, bundleIdentifier: String,
                             system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                             in folder: URL) throws -> URL {
        try UpdateSignature.verify(fileAt: diskImage, version: version, signature: signature, publicKey: publicKey)
        let mounted = try MountedDiskImage.attach(diskImage, inside: folder)
        defer { mounted.detach() }
        let app = mounted.mountPoint.appendingPathComponent(appName)
        try AppBundleInstaller.validate(app, bundleIdentifier: bundleIdentifier, version: version, system: system)
        let requirement = CodeSignature.updateRequirement(for: running)
        try CodeSignature.verify(app, requirement: requirement)

        let staged = folder.appendingPathComponent(appName)
        try? FileManager.default.removeItem(at: staged)
        guard Subprocess.run("/usr/bin/ditto", [app.path, staged.path]).status == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: staged.path])
        }
        try CodeSignature.verify(staged, requirement: requirement)
        return staged
    }
}
