import AppKit
import HexerCore

/// The hex editor: a fixed header row above a scroll view whose content is drawn by a canvas
/// that stays put while an empty spacer view provides the scroll range.
///
/// Drawing only what is visible, relative to the current top row, lets the same code show a
/// 100-byte file and a 4 TB disk; see `VirtualScrollMapper` for how very tall documents scroll.
final class HexEditorView: NSView {
    let session: EditorSession
    let header = HexHeaderView()
    let scrollView = HexScrollView()
    let spacer = FlippedView()
    let canvas = HexCanvasView()

    private(set) var metrics = HexMetrics(font: AppSettings.shared.font)
    private(set) var glyphs = GlyphCache(font: AppSettings.shared.font)
    private(set) var layoutInfo = HexLayout()
    /// Visual rows: data rows, with undefined sections folded.
    private(set) var rowMap = RowMap(length: 0, bytesPerRow: 16)
    private(set) var mapper = VirtualScrollMapper(totalRows: 0, rowHeight: 20, viewportHeight: 0)
    /// The undefined sections of `revision`, read again only after an edit.
    private var sections: (revision: Int, ranges: [Range<UInt64>])?
    /// Exact top row kept while wheel-scrolling a scaled document; the clip view can only hold
    /// a rounded position.
    private var preciseTopRow: Double?

    init(session: EditorSession) {
        self.session = session
        super.init(frame: .zero)
        header.editor = self
        canvas.editor = self
        scrollView.editor = self
        // The canvas draws one partial row past its bottom edge; keep it off the status bar.
        clipsToBounds = true
        canvas.clipsToBounds = true

        scrollView.drawsBackground = true
        scrollView.backgroundColor = HexTheme.background
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = spacer
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.addSubview(canvas, positioned: .above, relativeTo: scrollView.contentView)
        addSubview(scrollView)
        addSubview(header)

        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        session.editorView = self
        sync()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var headerHeight: CGFloat { metrics.rowHeight + 4 }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        scrollView.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: max(0, bounds.height - headerHeight))
        updateGeometry()
    }

    /// Re-reads the session's view options and redraws.
    func sync() {
        let font = AppSettings.shared.font
        if font != metrics.font {
            metrics = HexMetrics(font: font)
            glyphs = GlyphCache(font: font)
        }
        updateGeometry()
        canvas.needsDisplay = true
        header.needsDisplay = true
    }

    private func updateGeometry() {
        var layout = HexLayout(bytesPerRow: session.bytesPerRow, groupSize: session.groupSize, columns: session.columns,
                               offsetDigits: session.offsetBase.digits(forLength: session.length),
                               charWidth: metrics.charWidth)
        if session.fitToWidth {
            layout.bytesPerRow = layout.fittingBytesPerRow(width: scrollView.contentView.bounds.width)
        }
        let anchor = topOffset
        if session.effectiveBytesPerRow != layout.bytesPerRow { session.effectiveBytesPerRow = layout.bytesPerRow }
        layoutInfo = layout
        let map = makeRowMap()
        // Keep the top byte in place when rows are regrouped (bytes per row, folding).
        let regrouped = map.bytesPerRow != rowMap.bytesPerRow || map.folds != rowMap.folds
        rowMap = map
        updateMapper()
        if regrouped { scrollToRow(containing: anchor) }
    }

    private func makeRowMap() -> RowMap {
        guard session.foldsUndefinedSections else { return RowMap(length: session.length, bytesPerRow: layoutInfo.bytesPerRow) }
        if sections?.revision != session.revision {
            sections = (session.revision, session.undefinedSections())
        }
        return RowMap(length: session.length, bytesPerRow: layoutInfo.bytesPerRow, sections: sections?.ranges ?? [],
                      unfolded: session.unfoldedSections)
    }

    private func updateMapper() {
        let m = VirtualScrollMapper(totalRows: rowMap.rowCount, rowHeight: metrics.rowHeight,
                                    viewportHeight: scrollView.contentView.bounds.height)
        let width = max(layoutInfo.totalWidth, scrollView.contentView.bounds.width)
        if m != mapper || spacer.frame.width != width {
            mapper = m
            spacer.frame = NSRect(x: 0, y: 0, width: width, height: max(m.documentHeight, scrollView.contentView.bounds.height))
        }
        canvas.frame = scrollView.contentView.frame
    }

    // MARK: Scrolling

    /// The row at the top of the viewport, fractional while between rows.
    var topRow: Double {
        let y = scrollView.contentView.bounds.origin.y
        if let p = preciseTopRow { return p }
        return mapper.topRow(forScrollY: y)
    }

    var scrollX: CGFloat { scrollView.contentView.bounds.origin.x }

    private var topOffset: UInt64 { rowMap.offset(ofVisualRow: UInt64(max(0, topRow))) }

    /// The byte at the top of the viewport, fractional while between rows (compare windows
    /// scroll together by bytes, as their rows may fold differently).
    var topByte: Double {
        let row = floor(max(0, topRow))
        let bytes = rowMap.byteRange(ofVisualRow: UInt64(row))
        return Double(bytes.lowerBound) + (topRow - row) * Double(bytes.upperBound - bytes.lowerBound)
    }

    func scroll(toTopByte byte: Double) {
        let row = rowMap.visualRow(of: UInt64(max(0, byte)))
        let bytes = rowMap.byteRange(ofVisualRow: row)
        let fraction = (max(0, byte) - Double(bytes.lowerBound)) / Double(max(1, bytes.upperBound - bytes.lowerBound))
        scrollToRow(Double(row) + min(max(fraction, 0), 1))
    }

    /// Scrolls the row showing `offset` to the top.
    func scrollToRow(containing offset: UInt64) { scrollToRow(Double(rowMap.visualRow(of: offset))) }

    @objc private func clipBoundsChanged() {
        if let p = preciseTopRow, abs(mapper.scrollY(forTopRow: p) - scrollView.contentView.bounds.origin.y) > 1.5 {
            preciseTopRow = nil
        }
        canvas.needsDisplay = true
        header.needsDisplay = true
        session.compare?.didScroll(session, topRow: topRow)
    }

    func scrollToRow(_ row: Double) {
        let row = mapper.clampTopRow(row)
        preciseTopRow = mapper.isScaled ? row : nil
        var origin = scrollView.contentView.bounds.origin
        origin.y = mapper.scrollY(forTopRow: row)
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        canvas.needsDisplay = true
    }

    /// Wheel scrolling in row units, used for scaled documents.
    func scroll(byRows delta: Double) {
        scrollToRow(topRow + delta)
        scrollView.flashScrollers()
    }

    func scrollToVisible(offset: UInt64) {
        let bpr = UInt64(layoutInfo.bytesPerRow)
        // Going somewhere inside a folded section opens it; its first byte stays on the fold row.
        if let i = rowMap.fold(containing: offset), offset != rowMap.folds[i].rows.lowerBound * bpr {
            unfold(i)
        }
        let row = Double(rowMap.visualRow(of: offset))
        let visible = floor(mapper.visibleRows)
        if row < topRow {
            scrollToRow(row)
        } else if row > topRow + visible - 1 {
            scrollToRow(row - visible + 1)
        }
        // Horizontal: keep the caret column visible.
        let col = Int(offset % bpr)
        let x = session.activeColumn == .hex ? layoutInfo.hexX(byte: col) : layoutInfo.textX(byte: col)
        let clip = scrollView.contentView.bounds
        if x < clip.minX + layoutInfo.charWidth * 2 || x > clip.maxX - layoutInfo.charWidth * 4 {
            var origin = clip.origin
            origin.x = max(0, min(x - clip.width / 2, spacer.frame.width - clip.width))
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    var visibleRowCount: Int { max(1, Int(mapper.visibleRows)) }

    /// Shows all rows of the section behind fold `index`, keeping the top of the view in place.
    func unfold(_ index: Int) {
        guard rowMap.folds.indices.contains(index) else { return }
        session.unfoldedSections.insert(rowMap.folds[index].section.lowerBound)
        updateGeometry()
        canvas.needsDisplay = true
    }
}

/// A flipped, transparent view used as the scroll view's document.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Routes wheel scrolling of scaled documents through row space.
final class HexScrollView: NSScrollView {
    weak var editor: HexEditorView?

    override func scrollWheel(with event: NSEvent) {
        guard let editor, editor.mapper.isScaled, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else {
            super.scrollWheel(with: event)
            return
        }
        let rowHeight = editor.metrics.rowHeight
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / rowHeight : event.scrollingDeltaY * 3
        editor.scroll(byRows: -dy)
    }

    override func tile() {
        super.tile()
        editor?.canvas.frame = contentView.frame
    }
}

/// The column header: offsets of the bytes within a row, highlighting the caret's column.
final class HexHeaderView: NSView {
    weak var editor: HexEditorView?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let editor, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let session = editor.session
        let layout = editor.layoutInfo
        let m = editor.metrics
        HexTheme.headerBackground.setFill()
        bounds.fill()
        HexTheme.separator.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()

        let dx = -editor.scrollX
        let y = (bounds.height - m.rowHeight) / 2 + m.baseline
        let bpr = layout.bytesPerRow
        let caretCol = Int(session.caretByte % UInt64(bpr))
        var batch = GlyphBatcher()
        func put(_ s: String, x: CGFloat, color: NSColor) {
            var x = x
            for c in s {
                batch.add(editor.glyphs.entry(for: c), at: CGPoint(x: x, y: y), color: color)
                x += layout.charWidth
            }
        }
        let accent = NSColor.controlAccentColor
        put(L("Offset") + " (\(session.offsetBase.suffix))", x: layout.leftInset + dx, color: HexTheme.headerText)
        if layout.columns.showsHex {
            for i in 0..<bpr {
                let label = session.offsetBase.format(UInt64(i % 256), minDigits: 2, uppercase: !session.lowercaseHex)
                put(String(label.suffix(2)), x: layout.hexX(byte: i) + dx, color: i == caretCol ? accent : HexTheme.headerText)
            }
        }
        if layout.columns.showsText {
            put(L("Decoded text"), x: layout.textStartX + dx, color: HexTheme.headerText)
        }
        batch.draw(in: ctx, fonts: editor.glyphs.fonts)
    }
}
