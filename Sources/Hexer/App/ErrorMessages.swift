import DiskArbitration
import Foundation
import HexerCore
import HexerPlatform
import Security

/// HexerCore and HexerPlatform word their errors in English, which hexer-cli prints as is; the app
/// shows the same messages in the UI language. Errors from the system are already localized.
@MainActor extension Error {
    /// The message for an alert or an inline error label.
    var displayMessage: String { uiMessage?.text ?? localizedDescription }

    /// The error with its message in the UI language, for `presentError` and `NSAlert(error:)`.
    var localizedForDisplay: Error {
        guard let message = uiMessage else { return self }
        var info: [String: Any] = [NSLocalizedDescriptionKey: message.text, NSUnderlyingErrorKey: self]
        if let detail = message.detail {
            info[NSLocalizedDescriptionKey] = message.title
            info[NSLocalizedRecoverySuggestionErrorKey] = detail
        }
        return NSError(domain: "Hexer", code: 0, userInfo: info)
    }

    private var uiMessage: UIErrorMessage? {
        switch self {
        case let e as SearchError: UIErrorMessage(e.localizedText)
        case let e as HexImportError:
            UIErrorMessage(title: L("Parse error while importing “%@” in line %lld, column %lld:", e.fileName, e.line, e.column),
                           detail: e.kind.localizedText)
        case let e as ExportError: UIErrorMessage(e.localizedText)
        case let e as FileTools.ToolError: UIErrorMessage(e.localizedText)
        case let e as RawDeviceError: UIErrorMessage(e.localizedText)
        case let e as DiskArbitrationError: UIErrorMessage(e.localizedText)
        case let e as DiskIOError: UIErrorMessage(e.localizedText)
        case let e as UpdateError: UIErrorMessage(e.localizedText)
        case let e as MountedDiskImage.Failure: UIErrorMessage(e.localizedText)
        case let e as CodeSignature.Failure: UIErrorMessage(e.localizedText)
        default: nil
        }
    }
}

/// A message as one line, or as a title with a detail below it in an alert.
private struct UIErrorMessage {
    var title: String
    var detail: String?

    init(_ text: String) { title = text }
    init(title: String, detail: String) { self.title = title; self.detail = detail }

    var text: String { detail.map { title + "\n" + $0 } ?? title }
}

private func systemError(_ code: Int32) -> String { String(cString: strerror(code)) }

private func hexOffset(_ offset: UInt64) -> String { "0x" + String(offset, radix: 16, uppercase: true) }

@MainActor extension SearchError {
    fileprivate var localizedText: String {
        switch self {
        case .emptyPattern: L("Enter a value to search for.")
        case .noHexValues: L("The pattern has to contain at least one hex-value.")
        case .invalidHexValues(let s): L("The pattern '%@' contains invalid hex-values.", s)
        case .unencodableText(let name):
            L("The search- or replace-pattern contains characters that the selected text encoding (%@) cannot represent.", L(name))
        case .invalidInteger(let s): L("“%@” is not a valid integer number.", s)
        case .integerOutOfRange(let s, let bits): L("“%@” is out of range representable with %lld bits.", s, bits)
        case .invalidFloat(let s): L("“%@” is not a valid floating point number.", s)
        case .floatOutOfRange(let s, let type): L("“%@” cannot be represented as %@.", s, type)
        case .sizeMismatch(let a, let b):
            L("The size of the search- and the replace-pattern do not match (%lld <> %lld).", a, b) + "\n\n"
                + L("However this is necessary, since the chosen data stream has a fixed size.")
        }
    }
}

@MainActor extension HexImportError.Kind {
    fileprivate var localizedText: String {
        switch self {
        case .expected(let what, let found): L("“%@” expected, but found “%@”.", what, found)
        case .expectedEndOfLine(let found): L("Expected end of line, but found “%@”.", found)
        case .hexDigits(let lo, let hi, let found):
            L("Two hexadecimal digits in the range of %@-%@ were expected, but found “%@”.",
              String(format: "%02X", lo), String(format: "%02X", hi), found)
        case .checksum(let expected, let found):
            L("Checksum %@ expected, but found %@.", String(format: "%02X", expected), String(format: "%02X", found))
        case .lineAfterEndOfFile: L("No further lines permitted after EOF record.")
        case .sRecordType(let found): L("An S-record type was expected (S1, S2, S3, S5, S7, S8, S9) but found “%@”.", found)
        case .etlRecordType(let found): L("An ETL extended record type was expected (X0 to X9) but found “%@”.", found)
        case .recordCount(let expected, let found):
            L("%lld data records (records of type S1, S2 or S3) were expected, but since the last S5-record or the beginning %lld data records were found.",
              Int64(clamping: expected), Int64(clamping: found))
        case .byteCountTooSmall(let count, let minimum):
            L("The byte count %lld is too small; at least %lld bytes are required for the address and checksum.", count, minimum)
        case .wrongDataLength(let type, let expected, let found):
            L("A record of type %@ must contain %lld data bytes, but %lld were found.", type, expected, found)
        }
    }
}

@MainActor extension ExportError {
    fileprivate var localizedText: String {
        switch self {
        case .addressRangeExceeded(let format, let limit):
            L("The maximum supported file size (%@) of the “%@” file format was exceeded.", ExportText.sizeString(limit), format)
                + "\n" + L("Choose another format")
        }
    }
}

@MainActor extension FileTools.ToolError {
    fileprivate var localizedText: String {
        switch self {
        case .cannotOpen(let path, let code): L("Cannot open “%@”: %@.", path, systemError(code))
        case .ioFailed(let path, let code): L("Reading or writing “%@” failed: %@.", path, systemError(code))
        case .invalidPartSize: L("The part size must be at least one byte.")
        }
    }
}

@MainActor extension RawDeviceError {
    fileprivate var localizedText: String {
        switch self {
        case .invalidName(let name): L("“%@” is not a disk identifier such as disk4 or disk4s1.", name)
        case .cancelled(let path): L("Opening %@ was cancelled.", path)
        case .denied(let path):
            L("You are not allowed to open %@. Opening a disk requires an administrator’s name and password.", path)
        case .authorizationFailed(let path, let status):
            L("Could not get authorization to open %@: %@.", path,
              (SecCopyErrorMessageString(status, nil) as String?) ?? L("error %lld", Int64(status)))
        case .openFailed(let path, EBUSY): L("%@ is in use. Unmount its volumes before writing to it.", path)
        case .openFailed(let path, ENOENT): L("%@ does not exist. The disk may have been ejected.", path)
        case .openFailed(let path, let code): L("Could not open %@: %@.", path, systemError(code))
        case .helperFailed(let path, let status, let message):
            message.isEmpty
                ? L("authopen could not open %@ (exit status %lld).", path, Int64(status))
                : L("authopen could not open %@: %@", path, message)
        }
    }
}

@MainActor extension DiskArbitrationError {
    fileprivate var localizedText: String {
        switch self {
        case .notFound(let name): L("The disk %@ was not found. It may have been ejected.", name)
        case .bootDisk(let name): L("%@ is on the startup disk, which cannot be unmounted for writing.", name)
        case .dissented(let name, let status, let message):
            if let message, !message.isEmpty {
                L("%@ could not be unmounted or mounted: %@", name, message)
            } else if status == Int32(bitPattern: UInt32(kDAReturnBusy)) {
                L("%@ is in use by another application.", name)
            } else {
                L("%@ could not be unmounted or mounted (error 0x%@).", name, String(UInt32(bitPattern: status), radix: 16))
            }
        }
    }
}

@MainActor extension DiskIOError {
    fileprivate var localizedText: String {
        switch self {
        case .cancelled: L("The operation was cancelled.")
        case .readFailed(let offset, let code): L("Reading at offset %@ failed: %@.", hexOffset(offset), systemError(code))
        case .writeFailed(let offset, let code): L("Writing at offset %@ failed: %@.", hexOffset(offset), systemError(code))
        case .tooLarge(let required, let available):
            L("The data (%lld bytes) does not fit on the destination (%lld bytes).", Int64(clamping: required), Int64(clamping: available))
        case .invalidSectorSize(let size): L("%lld is not a valid sector size.", size)
        case .cannotCreate(let path, let code): L("Could not create %@: %@.", path, systemError(code))
        case .queryFailed(let code): L("Could not determine the size of the disk: %@.", systemError(code))
        }
    }
}

@MainActor extension UpdateError {
    fileprivate var localizedText: String {
        switch self {
        case .serverStatus(let status): L("The update server answered with status %lld.", status)
        case .rateLimited: L("GitHub has had too many requests from this network. Try again in an hour.")
        case .invalidFeed: L("The list of releases could not be read.")
        case .tooLarge: L("The download is larger than an update of Hexer can be.")
        case .invalidPublicKey: L("This copy of Hexer has no valid key to check updates with.")
        case .invalidPrivateKey: L("The signing key must be 32 bytes, Base64-encoded.")
        case .badSignature: L("The update’s signature is not valid, so it was not installed.")
        case .notHexer: L("The downloaded disk image doesn’t contain Hexer.")
        case .versionMismatch(let expected, let found): L("The downloaded app is version %@, not %@.", found, expected)
        case .requiresNewerSystem(let version): L("This version of Hexer requires macOS %@ or later.", version)
        case .translocated:
            L("macOS runs Hexer from a temporary location because it wasn’t moved after downloading. Move Hexer to the Applications folder, open it from there and try again.")
        case .notWritable(let path):
            L("Hexer can’t replace itself in “%@” because you don’t have permission to change it.",
              FileManager.default.displayName(atPath: path))
        case .replaceFailed(let path, let code): L("Replacing “%@” failed: %@.", path, systemError(code))
        }
    }
}

@MainActor extension MountedDiskImage.Failure {
    fileprivate var localizedText: String {
        switch self {
        case .attachFailed(let message): L("The disk image could not be opened: %@", message)
        }
    }
}

@MainActor extension CodeSignature.Failure {
    fileprivate var localizedText: String {
        switch self {
        case .invalid(let path, let status):
            L("The code signature of “%@” is not valid (%lld).", (path as NSString).lastPathComponent, Int64(status))
        }
    }
}
