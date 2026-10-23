import Foundation

/// What Find/Replace looks for, mirroring HxD's dialog: a datatype, the typed pattern, and the options of
/// every datatype frame. All frames' options are kept so switching the datatype preserves them, as in HxD.
public struct SearchQuery: Hashable, Codable, Sendable {
    /// HxD's "Datatype" choices.
    public enum DataType: String, CaseIterable, Codable, Sendable {
        case text, hex, integer, float

        public var displayName: String {
            switch self {
            case .text: "Text-string"
            case .hex: "Hex-values"
            case .integer: "Integer number"
            case .float: "Floating point number"
            }
        }
    }

    /// HxD's "Text encoding" choices.
    public enum TextEncodingChoice: Hashable, Codable, Sendable {
        /// "(Editor encoding)": the 8-bit encoding of the document's text column. The UI fills in the
        /// document's current encoding when it builds the query.
        case editor(TextEncoding)
        /// "Unicode (UTF-16 little endian)".
        case utf16LittleEndian

        public var displayName: String {
            switch self {
            case .editor: "(Editor encoding)"
            case .utf16LittleEndian: "Unicode (UTF-16 little endian)"
            }
        }
    }

    /// HxD's text frame.
    public struct TextOptions: Hashable, Codable, Sendable {
        public var encoding: TextEncodingChoice
        public var caseSensitive: Bool

        public init(encoding: TextEncodingChoice = .editor(.windowsLatin1), caseSensitive: Bool = false) {
            self.encoding = encoding
            self.caseSensitive = caseSensitive
        }
    }

    /// HxD's "Bitwidth" choices.
    public enum IntegerWidth: Int, CaseIterable, Codable, Sendable {
        /// Every width the value fits in.
        case any = 0
        case bits8 = 8, bits16 = 16, bits24 = 24, bits32 = 32, bits64 = 64

        public var displayName: String {
            self == .any ? "(any)" : "(U)Int\(rawValue)"
        }

        /// The widths a search with this setting tries.
        public var candidates: [IntegerWidth] {
            self == .any ? [.bits8, .bits16, .bits24, .bits32, .bits64] : [self]
        }
    }

    /// Which values a width accepts. HxD's "(U)Int" widths accept both, which is `.either`.
    public enum Signedness: String, CaseIterable, Codable, Sendable {
        /// Negative values as two's complement, non-negative values up to the unsigned maximum.
        case either, signed, unsigned
    }

    /// HxD's "Byte order" choices.
    public enum ByteOrder: String, CaseIterable, Codable, Sendable {
        case littleEndian, bigEndian

        public var displayName: String {
            switch self {
            case .littleEndian: "Little endian (Intel, AMD64, ...)"
            case .bigEndian: "Big endian (Motorola, SPARC, ...)"
            }
        }
    }

    /// HxD's integer frame (plus `signedness`, which HxD fixes at `.either`).
    public struct IntegerOptions: Hashable, Codable, Sendable {
        public var width: IntegerWidth
        public var byteOrder: ByteOrder
        public var signedness: Signedness

        public init(width: IntegerWidth = .any, byteOrder: ByteOrder = .littleEndian, signedness: Signedness = .either) {
            self.width = width
            self.byteOrder = byteOrder
            self.signedness = signedness
        }
    }

    /// HxD's "Floating point type" choices. Encoders live in FloatFormats.swift.
    public enum FloatType: String, CaseIterable, Codable, Sendable {
        case single, double
        /// Turbo Pascal's 6-byte `Real` (Real48).
        case real48
        /// x87 80-bit extended precision.
        case extended

        public var displayName: String {
            switch self {
            case .single: "Single (float32), 4 bytes"
            case .double: "Double (float64), 8 bytes"
            case .real48: "Real, 6 bytes"
            case .extended: "Extended (float80), 10 bytes"
            }
        }

        public var byteCount: Int {
            switch self {
            case .single: 4
            case .double: 8
            case .real48: 6
            case .extended: 10
            }
        }
    }

    /// HxD's float frame (plus `byteOrder`, which HxD fixes at little endian).
    public struct FloatOptions: Hashable, Codable, Sendable {
        public var type: FloatType
        public var byteOrder: ByteOrder

        public init(type: FloatType = .single, byteOrder: ByteOrder = .littleEndian) {
            self.type = type
            self.byteOrder = byteOrder
        }
    }

    public var dataType: DataType
    /// The text typed into "Search for:", interpreted according to `dataType`.
    public var pattern: String
    public var text: TextOptions
    public var integer: IntegerOptions
    public var float: FloatOptions

    public init(_ dataType: DataType = .text, pattern: String = "", text: TextOptions = TextOptions(),
                integer: IntegerOptions = IntegerOptions(), float: FloatOptions = FloatOptions()) {
        self.dataType = dataType
        self.pattern = pattern
        self.text = text
        self.integer = integer
        self.float = float
    }

    public static func text(_ pattern: String, encoding: TextEncodingChoice = .editor(.windowsLatin1),
                            caseSensitive: Bool = false) -> SearchQuery {
        SearchQuery(.text, pattern: pattern, text: TextOptions(encoding: encoding, caseSensitive: caseSensitive))
    }

    public static func hex(_ pattern: String) -> SearchQuery {
        SearchQuery(.hex, pattern: pattern)
    }

    public static func integer(_ pattern: String, width: IntegerWidth = .any, byteOrder: ByteOrder = .littleEndian,
                               signedness: Signedness = .either) -> SearchQuery {
        SearchQuery(.integer, pattern: pattern,
                    integer: IntegerOptions(width: width, byteOrder: byteOrder, signedness: signedness))
    }

    public static func float(_ pattern: String, type: FloatType = .single, byteOrder: ByteOrder = .littleEndian) -> SearchQuery {
        SearchQuery(.float, pattern: pattern, float: FloatOptions(type: type, byteOrder: byteOrder))
    }
}

/// HxD's "Search direction" choices.
public enum SearchDirection: String, CaseIterable, Codable, Sendable {
    /// The whole file: forward from the caret, wrapping around at the end.
    case all
    case forward, backward

    public var displayName: String {
        switch self {
        case .all: "All"
        case .forward: "Forward"
        case .backward: "Backward"
        }
    }
}

/// Invalid search or replace input, with user-facing messages (HxD's wording where it has one).
public enum SearchError: Error, Equatable, Sendable, LocalizedError {
    case emptyPattern
    case noHexValues
    case invalidHexValues(String)
    case unencodableText(encodingName: String)
    case invalidInteger(String)
    case integerOutOfRange(String, bits: Int)
    case invalidFloat(String)
    case floatOutOfRange(String, type: String)
    /// Replace on a fixed-size stream (disk) with a replacement of a different length.
    case sizeMismatch(search: Int, replacement: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyPattern:
            "Enter a value to search for."
        case .noHexValues:
            "The pattern has to contain at least one hex-value."
        case .invalidHexValues(let s):
            "The pattern '\(s)' contains invalid hex-values."
        case .unencodableText(let name):
            "The search- or replace-pattern contains characters that the selected text encoding (\(name)) cannot represent."
        case .invalidInteger(let s):
            "\"\(s)\" is not a valid integer number."
        case .integerOutOfRange(let s, let bits):
            "\"\(s)\" is out of range representable with \(bits) bits."
        case .invalidFloat(let s):
            "\"\(s)\" is not a valid floating point number."
        case .floatOutOfRange(let s, let type):
            "\"\(s)\" cannot be represented as \(type)."
        case .sizeMismatch(let a, let b):
            "The size of the search- and the replace-pattern do not match (\(a) <> \(b)).\n\nHowever this is necessary, since the chosen data stream has a fixed size."
        }
    }
}
