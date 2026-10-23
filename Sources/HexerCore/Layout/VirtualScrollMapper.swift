/// Maps between scroll positions and rows when a document has more rows than a scroll view
/// can represent precisely.
///
/// Up to `maxDocumentHeight` the mapping is 1:1 (row r starts at r × rowHeight). Beyond that the
/// scroll range is fixed and positions map proportionally to rows, while wheel scrolling is done
/// in row space by the editor so it still moves by whole rows.
public struct VirtualScrollMapper: Equatable, Sendable {
    public var totalRows: UInt64
    public var rowHeight: Double
    public var viewportHeight: Double
    public var maxDocumentHeight: Double

    public init(totalRows: UInt64, rowHeight: Double, viewportHeight: Double, maxDocumentHeight: Double = 8_000_000) {
        self.totalRows = totalRows
        self.rowHeight = rowHeight
        self.viewportHeight = viewportHeight
        self.maxDocumentHeight = maxDocumentHeight
    }

    public var exactHeight: Double { Double(totalRows) * rowHeight }
    public var isScaled: Bool { exactHeight > maxDocumentHeight }
    public var documentHeight: Double { isScaled ? maxDocumentHeight : exactHeight }
    public var visibleRows: Double { viewportHeight / rowHeight }
    /// The largest top row (fractional) that still fills the viewport.
    public var maxTopRow: Double { max(0, Double(totalRows) - visibleRows) }
    var scrollRange: Double { max(0, documentHeight - viewportHeight) }

    public func topRow(forScrollY y: Double) -> Double {
        guard isScaled else { return max(0, y) / rowHeight }
        guard scrollRange > 0 else { return 0 }
        return min(max(y, 0), scrollRange) / scrollRange * maxTopRow
    }

    public func scrollY(forTopRow row: Double) -> Double {
        guard isScaled else { return row * rowHeight }
        guard maxTopRow > 0 else { return 0 }
        return min(max(row, 0), maxTopRow) / maxTopRow * scrollRange
    }

    public func clampTopRow(_ row: Double) -> Double { min(max(row, 0), maxTopRow) }
}
