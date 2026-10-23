/// The rows the editor shows when undefined sections are folded: the whole rows inside a gap
/// collapse into one fold row, while rows that hold any defined byte always show.
///
/// Data row `r` holds bytes `r * bytesPerRow ..< (r + 1) * bytesPerRow`; there are
/// `length / bytesPerRow + 1` of them, the last one partly or wholly past the end (where the caret
/// can append). Visual rows number the rows on screen, each a data row or a fold.
public struct RowMap: Equatable, Sendable {
    public enum Row: Equatable, Sendable {
        case data(UInt64)
        /// Index into `folds`.
        case fold(Int)
    }

    public struct Fold: Equatable, Sendable {
        /// The folded data rows.
        public var rows: Range<UInt64>
        /// The undefined section the fold belongs to; it may start and end inside shown rows.
        public var section: Range<UInt64>
    }

    public let bytesPerRow: UInt64
    public let dataRowCount: UInt64
    public let rowCount: UInt64
    /// Sorted by position.
    public let folds: [Fold]
    /// Visual row of each fold.
    private let foldRows: [UInt64]

    /// The fewest whole rows a section must cover to fold.
    public static let minimumFoldedRows: UInt64 = 2

    /// - Parameters:
    ///   - sections: Undefined sections, sorted and non-overlapping.
    ///   - unfolded: Lower bounds of sections the user opened; they show all their rows.
    public init(length: UInt64, bytesPerRow: Int, sections: [Range<UInt64>] = [], unfolded: Set<UInt64> = []) {
        let bpr = UInt64(max(1, bytesPerRow))
        self.bytesPerRow = bpr
        dataRowCount = length / bpr + 1
        var folds: [Fold] = []
        var foldRows: [UInt64] = []
        var hidden: UInt64 = 0
        for section in sections where !unfolded.contains(section.lowerBound) {
            let first = (section.lowerBound + bpr - 1) / bpr
            let end = section.upperBound / bpr
            guard end > first, end - first >= Self.minimumFoldedRows else { continue }
            folds.append(Fold(rows: first..<end, section: section))
            foldRows.append(first - hidden)
            hidden += end - first - 1
        }
        self.folds = folds
        self.foldRows = foldRows
        rowCount = dataRowCount - hidden
    }

    public var hasFolds: Bool { !folds.isEmpty }

    /// What visual row `visual` shows (clamped to the last row).
    public func row(at visual: UInt64) -> Row {
        let visual = min(visual, rowCount - 1)
        guard let i = lastFold(where: { foldRows[$0] <= visual }) else { return .data(visual) }
        if foldRows[i] == visual { return .fold(i) }
        return .data(folds[i].rows.upperBound + (visual - foldRows[i] - 1))
    }

    /// The visual row showing data row `dataRow` (its fold, if folded).
    public func visualRow(ofDataRow dataRow: UInt64) -> UInt64 {
        guard let i = lastFold(where: { folds[$0].rows.lowerBound <= dataRow }) else { return dataRow }
        if folds[i].rows.contains(dataRow) { return foldRows[i] }
        return foldRows[i] + 1 + (dataRow - folds[i].rows.upperBound)
    }

    public func visualRow(of offset: UInt64) -> UInt64 { visualRow(ofDataRow: offset / bytesPerRow) }

    /// The fold hiding `offset`, if any.
    public func fold(containing offset: UInt64) -> Int? {
        let dataRow = offset / bytesPerRow
        guard let i = lastFold(where: { folds[$0].rows.lowerBound <= dataRow }), folds[i].rows.contains(dataRow) else { return nil }
        return i
    }

    /// The first byte of visual row `visual`: the row's start, or a fold's first hidden byte.
    public func offset(ofVisualRow visual: UInt64) -> UInt64 {
        switch row(at: visual) {
        case .data(let r): r * bytesPerRow
        case .fold(let i): folds[i].rows.lowerBound * bytesPerRow
        }
    }

    /// The bytes a visual row stands for (a fold covers all its hidden rows).
    public func byteRange(ofVisualRow visual: UInt64) -> Range<UInt64> {
        switch row(at: visual) {
        case .data(let r): r * bytesPerRow..<(r + 1) * bytesPerRow
        case .fold(let i): folds[i].rows.lowerBound * bytesPerRow..<folds[i].rows.upperBound * bytesPerRow
        }
    }

    /// The last fold index satisfying a predicate that holds for a prefix of `folds`.
    private func lastFold(where isBefore: (Int) -> Bool) -> Int? {
        var lo = 0, hi = folds.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if isBefore(mid) { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? lo - 1 : nil
    }
}
