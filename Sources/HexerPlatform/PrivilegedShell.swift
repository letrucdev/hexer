import Foundation

/// Runs a shell script as root after macOS has asked the user for an administrator's name and
/// password (AppleScript's `do shell script … with administrator privileges`, run in-process so
/// the prompt names this app). Used to replace the app where the user can't write, such as an
/// administrator's Applications folder.
public enum PrivilegedShell {
    public enum Failure: Error, Equatable {
        /// The user dismissed the password prompt.
        case cancelled
        /// The script exited with an error (the shell's message) or could not be run.
        case failed(String)
    }

    /// AppleScript's error number when the user cancels an authorization prompt.
    static let userCancelled = -128

    /// `NSAppleScript` must be used from the main thread.
    @MainActor
    public static func run(_ script: String) throws {
        let literal = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        guard let apple = NSAppleScript(source: "do shell script \"\(literal)\" with administrator privileges") else {
            throw Failure.failed("The script could not be compiled.")
        }
        var info: NSDictionary?
        apple.executeAndReturnError(&info)
        guard let info else { return }
        if (info[NSAppleScript.errorNumber] as? Int) == userCancelled { throw Failure.cancelled }
        throw Failure.failed((info[NSAppleScript.errorMessage] as? String) ?? "error \(info[NSAppleScript.errorNumber] ?? "?")")
    }
}
