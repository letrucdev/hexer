import Foundation

/// Why checking for, verifying or installing an update failed.
public enum UpdateError: Error, Equatable, LocalizedError {
    /// The update server answered with an HTTP status other than 200.
    case serverStatus(Int)
    /// The host refused the request because too many came from this network (HTTP 403 or 429).
    case rateLimited
    /// The list of releases could not be read.
    case invalidFeed
    /// A download was larger than an update can be.
    case tooLarge
    /// The app carries no valid key to check signatures with.
    case invalidPublicKey
    /// A signing key is not 32 bytes of Base64.
    case invalidPrivateKey
    /// The disk image's signature is missing, malformed or doesn't match.
    case badSignature
    /// The disk image has no Hexer.app, or one with another bundle identifier.
    case notHexer
    /// The app in the disk image is another version than the release says.
    case versionMismatch(expected: String, found: String)
    /// The new version needs a newer macOS than this Mac runs.
    case requiresNewerSystem(String)
    /// macOS runs the app from a randomized read-only location (App Translocation).
    case translocated
    /// The user can't replace the app at this path.
    case notWritable(path: String)
    /// Swapping the new app into place failed.
    case replaceFailed(path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .serverStatus(let status): "The update server answered with status \(status)."
        case .rateLimited: "The update server has had too many requests from this network. Try again in an hour."
        case .invalidFeed: "The list of releases could not be read."
        case .tooLarge: "The download is larger than an update of Hexer can be."
        case .invalidPublicKey: "This copy of Hexer has no valid key to check updates with."
        case .invalidPrivateKey: "The signing key must be 32 bytes, Base64-encoded."
        case .badSignature: "The update’s signature is not valid, so it was not installed."
        case .notHexer: "The downloaded disk image doesn’t contain Hexer."
        case .versionMismatch(let expected, let found): "The downloaded app is version \(found), not \(expected)."
        case .requiresNewerSystem(let version): "This version of Hexer requires macOS \(version) or later."
        case .translocated:
            "macOS runs Hexer from a temporary location because it wasn’t moved after downloading. Move Hexer to the Applications folder, open it from there and try again."
        case .notWritable(let path): "Hexer can’t replace itself in “\(path)” because you don’t have permission to change it."
        case .replaceFailed(let path, let code): "Replacing “\(path)” failed: \(String(cString: strerror(code)))."
        }
    }
}
