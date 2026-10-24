import Foundation

/// Checks a downloaded app bundle and swaps it into the place of the installed one.
public enum AppBundleInstaller {
    /// Throws unless the bundle at `url` is the app `bundleIdentifier` at `version` and runs on
    /// `system`. Its code signature is checked separately (HexerPlatform's `CodeSignature`).
    public static func validate(_ url: URL, bundleIdentifier: String, version: String,
                                system: OperatingSystemVersion) throws {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier else { throw UpdateError.notHexer }
        let found = info["CFBundleShortVersionString"] as? String ?? ""
        guard found == version else { throw UpdateError.versionMismatch(expected: version, found: found) }
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            let required = (minimum.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]).prefix(3)
            let running = [system.majorVersion, system.minorVersion, system.patchVersion]
            if running.lexicographicallyPrecedes(required) { throw UpdateError.requiresNewerSystem(minimum) }
        }
    }

    /// Throws unless the current user can replace the app at `url`: it isn't translocated (run
    /// from where it was downloaded, see `UpdateError.translocated`) and both the bundle and its
    /// folder are writable, as moving a folder needs.
    public static func checkReplaceable(_ url: URL) throws {
        if url.path.contains("/AppTranslocation/") { throw UpdateError.translocated }
        let folder = url.deletingLastPathComponent()
        guard access(url.path, W_OK) == 0, access(folder.path, W_OK) == 0 else {
            throw UpdateError.notWritable(path: folder.path)
        }
    }

    /// Moves `newBundle` to `installed`'s path, which must be on the same volume, and deletes the
    /// old bundle. The two trade places in one atomic step where the file system can (APFS,
    /// HFS+); elsewhere the old bundle is moved aside first and put back if the move fails.
    public static func replace(_ installed: URL, with newBundle: URL) throws {
        if renamex_np(newBundle.path, installed.path, UInt32(RENAME_SWAP)) == 0 {
            try? FileManager.default.removeItem(at: newBundle)
            return
        }
        let swapError = errno
        guard swapError == ENOTSUP || swapError == EINVAL else {
            throw UpdateError.replaceFailed(path: installed.path, code: swapError)
        }
        let aside = newBundle.deletingLastPathComponent().appendingPathComponent(".replaced-\(UUID().uuidString)")
        guard rename(installed.path, aside.path) == 0 else {
            throw UpdateError.replaceFailed(path: installed.path, code: errno)
        }
        guard rename(newBundle.path, installed.path) == 0 else {
            let code = errno
            rename(aside.path, installed.path)
            throw UpdateError.replaceFailed(path: installed.path, code: code)
        }
        try? FileManager.default.removeItem(at: aside)
    }
}
