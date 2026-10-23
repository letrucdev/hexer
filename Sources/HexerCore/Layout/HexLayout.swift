/// Which part of the editor a point falls on.
public enum HexColumn: Equatable, Sendable {
    case offset
    /// `byte` is the index within the row, `nibble` 0 = high, 1 = low.
    case hex(byte: Int, nibble: Int)
    case text(byte: Int)
}

/// Which columns are visible.
public enum VisibleColumns: String, CaseIterable, Codable, Sendable {
    case hexAndText, hex, text
    public var showsHex: Bool { self != .text }
    public var showsText: Bool { self != .hex }
}

/// Horizontal geometry of one row of the editor, in points.
///
/// Bytes are printed as two hex digits; a group of `groupSize` bytes has no spaces inside and one
/// space after it, so with group size 1 every byte is separated by a space (as in HxD).
public struct HexLayout: Equatable, Sendable {
    public var bytesPerRow: Int
    public var groupSize: Int
    public var columns: VisibleColumns
    public var offsetDigits: Int
    public var charWidth: Double
    public var leftInset: Double
    /// Space between the offset, hex and text columns, in characters.
    public var columnGapChars: Double

    public init(bytesPerRow: Int = 16, groupSize: Int = 1, columns: VisibleColumns = .hexAndText,
                offsetDigits: Int = 8, charWidth: Double = 7.8, leftInset: Double = 14, columnGapChars: Double = 3) {
        self.bytesPerRow = max(1, bytesPerRow)
        self.groupSize = max(1, groupSize)
        self.columns = columns
        self.offsetDigits = offsetDigits
        self.charWidth = charWidth
        self.leftInset = leftInset
        self.columnGapChars = columnGapChars
    }

    public var offsetColumnWidth: Double { Double(offsetDigits) * charWidth }
    public var hexStartX: Double { leftInset + offsetColumnWidth + columnGapChars * charWidth }

    /// Characters printed before byte `i` of a row in the hex column.
    public func hexCharsBefore(_ i: Int) -> Int { i * 2 + i / groupSize }

    public var hexCharCount: Int {
        bytesPerRow * 2 + (bytesPerRow - 1) / groupSize
    }

    public var hexWidth: Double { columns.showsHex ? Double(hexCharCount) * charWidth : 0 }

    public func hexX(byte i: Int, nibble: Int = 0) -> Double {
        hexStartX + Double(hexCharsBefore(i) + nibble) * charWidth
    }

    public var textStartX: Double {
        columns.showsHex ? hexStartX + hexWidth + columnGapChars * charWidth : hexStartX
    }

    public func textX(byte i: Int) -> Double { textStartX + Double(i) * charWidth }

    public var textWidth: Double { columns.showsText ? Double(bytesPerRow) * charWidth : 0 }

    public var totalWidth: Double {
        (columns.showsText ? textStartX + textWidth : hexStartX + hexWidth) + leftInset
    }

    /// Maps an x position to a column. Points between groups belong to the nearer byte.
    public func hitTest(x: Double) -> HexColumn {
        if x < hexStartX - columnGapChars * charWidth / 2 { return .offset }
        if columns.showsHex && (!columns.showsText || x < textStartX - columnGapChars * charWidth / 2) {
            let c = Int(((x - hexStartX) / charWidth).rounded(.down))
            if c < 0 { return .hex(byte: 0, nibble: 0) }
            let groupChars = groupSize * 2 + 1
            let group = c / groupChars
            let inGroup = c % groupChars
            var byte: Int, nibble: Int
            if inGroup >= groupSize * 2 {
                byte = group * groupSize + groupSize - 1
                nibble = 1
            } else {
                byte = group * groupSize + inGroup / 2
                nibble = inGroup % 2
            }
            if byte >= bytesPerRow { byte = bytesPerRow - 1; nibble = 1 }
            return .hex(byte: byte, nibble: nibble)
        }
        let i = Int(((x - textStartX) / charWidth).rounded(.down))
        return .text(byte: min(max(i, 0), bytesPerRow - 1))
    }

    /// The largest bytes-per-row (a multiple of the group size) whose row fits in `width`.
    public func fittingBytesPerRow(width: Double) -> Int {
        var n = groupSize
        while n + groupSize <= 4096 {
            var l = self
            l.bytesPerRow = n + groupSize
            if l.totalWidth > width { break }
            n += groupSize
        }
        return n
    }
}
