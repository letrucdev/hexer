import Testing
@testable import HexerCore

@Suite struct RowMapTests {
    @Test func withoutSectionsRowsAreDataRows() {
        let map = RowMap(length: 0x1000, bytesPerRow: 16)
        #expect(map.rowCount == 0x101)
        #expect(!map.hasFolds)
        #expect(map.row(at: 5) == .data(5))
        #expect(map.visualRow(of: 0x123) == 0x12)
        #expect(map.offset(ofVisualRow: 0x100) == 0x1000)
        #expect(map.fold(containing: 0x500) == nil)
    }

    @Test func wholeRowsInsideASectionFold() {
        // The section starts and ends inside rows 0x10 and 0x80; those two stay visible.
        let map = RowMap(length: 0x1000, bytesPerRow: 16, sections: [0x105..<0x808])
        #expect(map.folds == [RowMap.Fold(rows: 0x11..<0x80, section: 0x105..<0x808)])
        #expect(map.rowCount == 0x101 - (0x80 - 0x11 - 1))
        #expect(map.row(at: 0x10) == .data(0x10))
        #expect(map.row(at: 0x11) == .fold(0))
        #expect(map.row(at: 0x12) == .data(0x80))
        #expect(map.visualRow(of: 0x10F) == 0x10)
        #expect(map.visualRow(of: 0x110) == 0x11)
        #expect(map.visualRow(of: 0x7FF) == 0x11)
        #expect(map.visualRow(of: 0x800) == 0x12)
        #expect(map.fold(containing: 0x110) == 0)
        #expect(map.fold(containing: 0x10F) == nil)
        #expect(map.fold(containing: 0x800) == nil)
        #expect(map.offset(ofVisualRow: 0x11) == 0x110)
        #expect(map.byteRange(ofVisualRow: 0x11) == 0x110..<0x800)
        #expect(map.offset(ofVisualRow: 0x12) == 0x800)
        #expect(map.offset(ofVisualRow: map.rowCount - 1) == 0x1000)
    }

    @Test func shortAndUnfoldedSectionsStayOpen() {
        // One whole row is not worth a fold.
        #expect(!RowMap(length: 0x100, bytesPerRow: 16, sections: [0x08..<0x28]).hasFolds)
        #expect(RowMap(length: 0x100, bytesPerRow: 16, sections: [0x10..<0x30]).folds.count == 1)
        let open = RowMap(length: 0x1000, bytesPerRow: 16, sections: [0x100..<0x200, 0x400..<0x800], unfolded: [0x100])
        #expect(open.folds.map(\.section) == [0x400..<0x800])
        #expect(open.rowCount == 0x101 - 0x3F)
    }

    @Test func sectionReachingTheEnd() {
        let map = RowMap(length: 0x400, bytesPerRow: 16, sections: [0x100..<0x400])
        #expect(map.folds.first?.rows == 0x10..<0x40)
        // Data rows 0…0x0F, the fold, and the empty row at the end for appending.
        #expect(map.rowCount == 0x12)
        #expect(map.row(at: 0x11) == .data(0x40))
        #expect(map.visualRow(of: 0x400) == 0x11)
        #expect(map.row(at: 1000) == .data(0x40))
    }

    @Test func mappingsAgreeWithANaiveListOfRows() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let bpr = Int.random(in: 1...20, using: &rng)
            let length = UInt64.random(in: 0...3000, using: &rng)
            var sections: [Range<UInt64>] = []
            var at: UInt64 = 0
            while at < length {
                at += UInt64.random(in: 0...200, using: &rng)
                let end = min(length, at + UInt64.random(in: 1...300, using: &rng))
                if at < end { sections.append(at..<end) }
                at = end + 1
            }
            let unfolded = Set(sections.filter { _ in Bool.random(using: &rng) }.map(\.lowerBound))
            let map = RowMap(length: length, bytesPerRow: bpr, sections: sections, unfolded: unfolded)

            // Naive: walk the data rows, merging the whole rows of each folded section.
            var naive: [RowMap.Row] = []
            var dataRow: UInt64 = 0
            while dataRow < length / UInt64(bpr) + 1 {
                if let i = map.folds.firstIndex(where: { $0.rows.lowerBound == dataRow }) {
                    naive.append(.fold(i))
                    dataRow = map.folds[i].rows.upperBound
                } else {
                    naive.append(.data(dataRow))
                    dataRow += 1
                }
            }
            #expect(map.rowCount == UInt64(naive.count))
            for (visual, row) in naive.enumerated() {
                let v = UInt64(visual)
                #expect(map.row(at: v) == row)
                switch row {
                case .data(let r):
                    #expect(map.visualRow(ofDataRow: r) == v)
                case .fold(let i):
                    let fold = map.folds[i]
                    #expect(fold.rows.allSatisfy { map.visualRow(ofDataRow: $0) == v })
                    #expect(!unfolded.contains(fold.section.lowerBound))
                    #expect(fold.rows.count >= Int(RowMap.minimumFoldedRows))
                    #expect(fold.section.lowerBound <= fold.rows.lowerBound * UInt64(bpr))
                    #expect(fold.rows.upperBound * UInt64(bpr) <= fold.section.upperBound)
                }
            }
        }
    }
}
