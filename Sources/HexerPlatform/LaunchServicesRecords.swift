import Foundation

/// Launch Services records an app wherever it sees one, a mounted disk image or a temporary
/// folder included, and keeps the record after the folder is gone. Several records for one bundle
/// identifier at deleted paths can make macOS resolve the app to one of them, which shows a blank
/// icon (in the Dock, Spotlight or Open With). There is no API to drop a record, only `lsregister`.
public enum LaunchServicesRecords {
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

    /// Drops the record of the app at `url`, if Launch Services has one; never fails.
    public static func forget(_ url: URL) {
        guard FileManager.default.isExecutableFile(atPath: lsregister) else { return }
        _ = Subprocess.run(lsregister, ["-u", url.path], timeout: 30)
    }
}
