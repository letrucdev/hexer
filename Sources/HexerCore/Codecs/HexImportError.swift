import Foundation

/// A parse error in an imported record file, located by 1-based line and column of the original
/// line (leading whitespace included) and worded like HxD 2.5's messages.
public struct HexImportError: Error, Equatable, Sendable, LocalizedError {
    public enum Kind: Equatable, Sendable {
        /// HxD: `"%0:s" expected, but found "%1:s".`
        case expected(String, found: String)
        /// HxD: `Expected end of line, but found "%s".`
        case expectedEndOfLine(found: String)
        /// HxD: `Two hexadecimal digits in the range of %0:.2x-%1:.2x were expected, but found "%2:s".`
        case hexDigits(min: UInt8, max: UInt8, found: String)
        /// HxD: `Checksum %0:.2x expected, but found %1:.2x.`
        case checksum(expected: UInt8, found: UInt8)
        /// HxD: `No further lines permitted after EOF record.`
        case lineAfterEndOfFile
        /// HxD: `An S-record type was expected (S1, S2, S3, S5, S7, S8, S9) but found "%s".`
        case sRecordType(found: String)
        /// HxD: `An ETL extended record type was expected (X0 to X9) but found "%s".`
        case etlRecordType(found: String)
        /// HxD: `%0:d data records (records of type S1, S2 or S3) were expected, but since the
        /// last S5-record or the beginning %1:d data records were found.`
        case recordCount(expected: UInt64, found: UInt64)
        /// The byte count is smaller than the record's address and checksum (HxD has no message
        /// for this; the wording is Hexer's).
        case byteCountTooSmall(count: Int, minimum: Int)
        /// A record type needs a fixed amount of data, e.g. 2 bytes for an extended linear
        /// address (HxD fails an assertion here; the wording is Hexer's).
        case wrongDataLength(recordType: String, expected: Int, found: Int)
    }

    public var kind: Kind
    public var line: Int
    public var column: Int
    /// The name shown in the message (HxD shows the imported file's name).
    public var fileName: String

    public init(kind: Kind, line: Int, column: Int, fileName: String) {
        self.kind = kind
        self.line = line
        self.column = column
        self.fileName = fileName
    }

    /// The specific part of the message, without the location header.
    public var message: String {
        switch kind {
        case .expected(let what, let found):
            "\"\(what)\" expected, but found \"\(found)\"."
        case .expectedEndOfLine(let found):
            "Expected end of line, but found \"\(found)\"."
        case .hexDigits(let lo, let hi, let found):
            "Two hexadecimal digits in the range of \(Hex.upper[Int(lo)])-\(Hex.upper[Int(hi)]) were expected, but found \"\(found)\"."
        case .checksum(let expected, let found):
            "Checksum \(Hex.upper[Int(expected)]) expected, but found \(Hex.upper[Int(found)])."
        case .lineAfterEndOfFile:
            "No further lines permitted after EOF record."
        case .sRecordType(let found):
            "An S-record type was expected (S1, S2, S3, S5, S7, S8, S9) but found \"\(found)\"."
        case .etlRecordType(let found):
            "An ETL extended record type was expected (X0 to X9) but found \"\(found)\"."
        case .recordCount(let expected, let found):
            "\(expected) data records (records of type S1, S2 or S3) were expected, but since the last S5-record or the beginning \(found) data records were found."
        case .byteCountTooSmall(let count, let minimum):
            "The byte count \(count) is too small; at least \(minimum) bytes are required for the address and checksum."
        case .wrongDataLength(let type, let expected, let found):
            "A record of type \(type) must contain \(expected) data bytes, but \(found) were found."
        }
    }

    public var errorDescription: String? {
        "Parse error while importing \"\(fileName)\" in line \(line), column \(column):\n\(message)"
    }
}
