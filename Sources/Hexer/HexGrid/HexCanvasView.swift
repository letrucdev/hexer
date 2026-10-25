import AppKit
import HexerCore

/// Draws the visible rows and handles mouse and keyboard input for the grid.
final class HexCanvasView: NSView {
    weak var editor: HexEditorView?
    /// Byte where the current mouse drag started.
    private var dragOriginByte: UInt64?
    private var autoscrollTimer: Timer?
    private var lastDragPoint: NSPoint = .zero
    /// IME composition in progress in the text column.
    var markedText: NSAttributedString?
    /// The column to keep while moving with ↑/↓ and Page Up/Down, with the caret it was set for.
    var rowMoveColumn: (caret: UInt64, column: UInt64)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    var session: EditorSession? { editor?.session }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let editor, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let session = editor.session
        let layout = editor.layoutInfo
        let map = editor.rowMap
        let m = editor.metrics
        let bpr = layout.bytesPerRow
        let length = session.length

        HexTheme.background.setFill()
        dirtyRect.fill()

        let topRow = editor.topRow
        let firstRow = UInt64(max(0, floor(topRow)))
        let yOffset = (Double(firstRow) - topRow) * m.rowHeight
        let rowCount = Int(ceil(bounds.height / m.rowHeight)) + 1
        let snapshot = session.snapshot()
        let dx = -editor.scrollX
        let table = session.encoding.table
        let filter = session.characterFilter
        let display: [Character] = filter.isAll ? table.display : (0..<256).map { filter.allows(UInt8($0)) ? table.display[$0] : "." }
        let hexDigits: [Character] = Array(session.lowercaseHex ? "0123456789abcdef" : "0123456789ABCDEF")
        let digitEntries = hexDigits.map { editor.glyphs.entry(for: $0) }
        let questionEntry = editor.glyphs.entry(for: "?")
        let sel = session.selection.range
        let focused = window?.firstResponder === self && window?.isKeyWindow == true
        let activeSel = focused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor
        let inactiveSel = activeSel.withAlphaComponent(0.45)
        let hexActive = session.activeColumn == .hex
        var batch = GlyphBatcher()
        let cw = layout.charWidth

        func drawOffset(_ offset: UInt64, baseline: Double) {
            var x = layout.leftInset + dx
            for c in session.formatOffset(offset, minDigits: layout.offsetDigits) {
                batch.add(editor.glyphs.entry(for: c), at: CGPoint(x: x, y: baseline), color: HexTheme.offset)
                x += cw
            }
        }

        // Runs of consecutive data rows are read in one piece; folds stand alone.
        var r = 0
        while r < rowCount, firstRow + UInt64(r) < map.rowCount {
            let visual = firstRow + UInt64(r)
            if case .fold(let i) = map.row(at: visual) {
                let y = yOffset + Double(r) * m.rowHeight
                drawOffset(map.offset(ofVisualRow: visual), baseline: y + m.baseline)
                drawFold(map.folds[i], y: y, selected: !sel.isEmpty && sel.overlaps(map.byteRange(ofVisualRow: visual)),
                         selectionColor: hexActive ? activeSel : inactiveSel)
                r += 1
                continue
            }
            var n = 1
            while r + n < rowCount, visual + UInt64(n) < map.rowCount, case .data = map.row(at: visual + UInt64(n)) { n += 1 }
            let startOffset = map.offset(ofVisualRow: visual)
            guard startOffset <= length else { break }
            let endOffset = min(length, startOffset + UInt64(n * bpr))
            let data = snapshot.read(startOffset..<endOffset)
            let highlights = Highlights(session: session, visible: startOffset..<max(endOffset, startOffset + 1))

            for k in 0..<n {
                let rowStart = startOffset + UInt64(k * bpr)
                if rowStart > length { break }
                let y = yOffset + Double(r + k) * m.rowHeight
                let baseline = y + m.baseline
                drawOffset(rowStart, baseline: baseline)

                let rowBytes = Int(min(UInt64(bpr), length - min(rowStart, length)))
                for i in 0..<rowBytes {
                    let offset = rowStart + UInt64(i)
                    let index = Int(offset - startOffset)
                    let byte = data.bytes[index]
                    let state = data.states[index]
                    let selected = sel.contains(offset)
                    let highlight = selected ? nil : highlights.color(at: offset)
                    let color: NSColor
                    switch state {
                    case .modified: color = HexTheme.modified
                    case .undefined, .unreadable: color = HexTheme.undefined
                    case .original: color = (i / layout.groupSize) % 2 == 1 ? HexTheme.oddColumn : HexTheme.text
                    }
                    if layout.columns.showsHex {
                        let hx = layout.hexX(byte: i) + dx
                        if let highlight {
                            let next = i + 1 < rowBytes && highlights.color(at: offset + 1) == highlight && !sel.contains(offset + 1)
                            let w = next ? layout.hexX(byte: i + 1) - layout.hexX(byte: i) : cw * 2
                            highlight.setFill()
                            NSRect(x: hx, y: y + 1, width: w, height: m.rowHeight - 2).fill(using: .sourceOver)
                        }
                        if selected {
                            // Extend the fill over the gap to the next selected byte in the same row.
                            let next = i + 1 < bpr && sel.contains(offset + 1) && i + 1 < rowBytes
                            let w = next ? layout.hexX(byte: i + 1) - layout.hexX(byte: i) : cw * 2
                            (hexActive ? activeSel : inactiveSel).setFill()
                            NSRect(x: hx, y: y + 1, width: w, height: m.rowHeight - 2).fill()
                        }
                        if state == .undefined || state == .unreadable {
                            batch.add(questionEntry, at: CGPoint(x: hx, y: baseline), color: color)
                            batch.add(questionEntry, at: CGPoint(x: hx + cw, y: baseline), color: color)
                        } else {
                            batch.add(digitEntries[Int(byte >> 4)], at: CGPoint(x: hx, y: baseline), color: color)
                            batch.add(digitEntries[Int(byte & 0xF)], at: CGPoint(x: hx + cw, y: baseline), color: color)
                        }
                    }
                    if layout.columns.showsText {
                        let tx = layout.textX(byte: i) + dx
                        if let highlight {
                            highlight.setFill()
                            NSRect(x: tx, y: y + 1, width: cw, height: m.rowHeight - 2).fill(using: .sourceOver)
                        }
                        if selected {
                            (hexActive ? inactiveSel : activeSel).setFill()
                            NSRect(x: tx, y: y + 1, width: cw, height: m.rowHeight - 2).fill()
                        }
                        let ch: Character = (state == .undefined || state == .unreadable) ? "?" : display[Int(byte)]
                        batch.add(editor.glyphs.entry(for: ch), at: CGPoint(x: tx, y: baseline),
                                  color: state == .original ? HexTheme.text : color)
                    }
                }
            }
            r += n
        }
        batch.draw(in: ctx, fonts: editor.glyphs.fonts)
        drawCaret(editor: editor, firstRow: firstRow, yOffset: yOffset, focused: focused)
    }

    /// The box across the hex and text columns that stands for a folded section's hidden rows.
    func foldRect(y: Double) -> NSRect {
        guard let editor else { return .zero }
        let layout = editor.layoutInfo
        let m = editor.metrics
        let minX = (layout.columns.showsHex ? layout.hexStartX : layout.textStartX) - layout.charWidth / 2
        let maxX = layout.columns.showsText ? layout.textStartX + layout.textWidth : layout.hexStartX + layout.hexWidth
        return NSRect(x: minX - editor.scrollX, y: y + 2, width: maxX - minX + layout.charWidth / 2, height: m.rowHeight - 4)
    }

    private func drawFold(_ fold: RowMap.Fold, y: Double, selected: Bool, selectionColor: NSColor) {
        guard let editor else { return }
        let box = foldRect(y: y)
        let shape = NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2)
        (selected ? selectionColor : HexTheme.foldBackground).setFill()
        shape.fill()
        let bytes = (fold.rows.upperBound - fold.rows.lowerBound) * editor.rowMap.bytesPerRow
        let label = "▸  " + L("%@ undefined bytes", bytes.formatted()) + " · " + L("Click to show")
        let font = NSFont.systemFont(ofSize: max(10, editor.metrics.font.pointSize - 2))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: HexTheme.foldText, .paragraphStyle: style]
        let textHeight = ceil(font.ascender - font.descender)
        let textRect = NSRect(x: box.minX + box.height / 2, y: box.midY - textHeight / 2,
                              width: max(0, box.width - box.height), height: textHeight)
        (label as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    private func drawCaret(editor: HexEditorView, firstRow: UInt64, yOffset: Double, focused: Bool) {
        let session = editor.session
        let layout = editor.layoutInfo
        let m = editor.metrics
        let bpr = UInt64(layout.bytesPerRow)
        let caret = session.selection.caret
        let row = editor.rowMap.visualRow(of: caret)
        guard row >= firstRow else { return }
        let y = yOffset + Double(row - firstRow) * m.rowHeight
        guard y < bounds.height else { return }
        let col = Int(caret % bpr)
        let dx = -editor.scrollX
        let cw = layout.charWidth
        let accent = focused ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
        if editor.rowMap.fold(containing: caret) != nil {
            let box = foldRect(y: y).insetBy(dx: -1, dy: -1)
            let outline = NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2)
            outline.lineWidth = 2
            accent.setStroke()
            outline.stroke()
            return
        }
        let hexRect = NSRect(x: layout.hexX(byte: col) + dx, y: y + 1, width: cw * 2, height: m.rowHeight - 2)
        let textRect = NSRect(x: layout.textX(byte: col) + dx, y: y + 1, width: cw, height: m.rowHeight - 2)
        let (active, ghost) = session.activeColumn == .hex ? (hexRect, textRect) : (textRect, hexRect)
        let showsActive = session.activeColumn == .hex ? layout.columns.showsHex : layout.columns.showsText
        let showsGhost = session.activeColumn == .hex ? layout.columns.showsText : layout.columns.showsHex

        if showsActive {
            accent.setFill()
            if session.mode == .insert || !session.selection.isEmpty {
                NSRect(x: active.minX - 1, y: active.minY, width: 2, height: active.height).fill()
            } else if session.activeColumn == .hex {
                // Block under the nibble that the next keystroke replaces.
                let nibbleRect = NSRect(x: active.minX + CGFloat(session.nibble) * cw, y: active.maxY - 2, width: cw, height: 2)
                nibbleRect.fill()
                accent.withAlphaComponent(0.18).setFill()
                active.fill(using: .sourceOver)
            } else {
                NSRect(x: active.minX, y: active.maxY - 2, width: active.width, height: 2).fill()
                accent.withAlphaComponent(0.18).setFill()
                active.fill(using: .sourceOver)
            }
        }
        if showsGhost && session.selection.isEmpty {
            accent.withAlphaComponent(0.7).setStroke()
            let path = NSBezierPath(rect: ghost.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }
    }

    // MARK: Hit testing

    /// The byte offset and column under a point in this view; on a fold row, the first hidden
    /// byte and the fold's index.
    func hit(_ point: NSPoint) -> (offset: UInt64, column: HexColumn, fold: Int?)? {
        guard let editor else { return nil }
        let layout = editor.layoutInfo
        let rowF = editor.topRow + Double(point.y) / editor.metrics.rowHeight
        let visual = UInt64(max(0, floor(rowF)))
        let column = layout.hitTest(x: Double(point.x + editor.scrollX))
        if case .fold(let i) = editor.rowMap.row(at: visual) {
            return (min(editor.rowMap.offset(ofVisualRow: visual), editor.session.length), column, i)
        }
        let byteInRow: Int
        switch column {
        case .offset: byteInRow = 0
        case .hex(let b, _): byteInRow = b
        case .text(let b): byteInRow = b
        }
        let offset = min(editor.rowMap.offset(ofVisualRow: visual) + UInt64(byteInRow), editor.session.length)
        return (offset, column, nil)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let session, let (offset, column, fold) = hit(convert(event.locationInWindow, from: nil)) else { return }
        if let fold, !event.modifierFlags.contains(.shift) {
            // A click on a fold row opens the section.
            session.setSelection(Selection(caret: offset), scroll: false)
            editor?.unfold(fold)
            return
        }
        var nibble = 0
        switch column {
        case .hex(_, let n): session.activeColumn = .hex; nibble = n
        case .text: session.activeColumn = .text
        case .offset: break
        }
        if event.clickCount == 2 {
            selectGroup(at: offset)
            return
        }
        if event.modifierFlags.contains(.shift) {
            let anchor = session.selection.anchor
            session.setSelection(Selection(anchor: anchor, caret: offset >= anchor ? min(offset + 1, session.length) : offset), scroll: false)
            dragOriginByte = anchor
        } else {
            session.setSelection(Selection(caret: offset), nibble: session.mode == .insert ? 0 : nibble, scroll: false)
            dragOriginByte = offset
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        lastDragPoint = convert(event.locationInWindow, from: nil)
        extendDrag(to: lastDragPoint)
        if lastDragPoint.y < 0 || lastDragPoint.y > bounds.height {
            if autoscrollTimer == nil {
                autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.autoscrollStep() }
                }
            }
        } else {
            autoscrollTimer?.invalidate()
            autoscrollTimer = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
        dragOriginByte = nil
    }

    private func autoscrollStep() {
        guard let editor else { return }
        let overshoot = lastDragPoint.y < 0 ? lastDragPoint.y : lastDragPoint.y - bounds.height
        editor.scroll(byRows: max(-50, min(50, Double(overshoot) / editor.metrics.rowHeight)))
        extendDrag(to: lastDragPoint)
    }

    private func extendDrag(to point: NSPoint) {
        guard let session, let origin = dragOriginByte,
              let (offset, _, _) = hit(NSPoint(x: point.x, y: min(max(point.y, 0), bounds.height - 1))) else { return }
        let len = session.length
        let s = offset >= origin
            ? Selection(anchor: origin, caret: min(offset + 1, len))
            : Selection(anchor: min(origin + 1, len), caret: offset)
        session.setSelection(s, scroll: false)
        needsDisplay = true
    }

    private func selectGroup(at offset: UInt64) {
        guard let session, let editor else { return }
        let g = UInt64(editor.layoutInfo.groupSize)
        let start = offset - offset % g
        session.setSelection(Selection(anchor: start, caret: min(start + g, session.length)), scroll: false)
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = MainMenu.contextMenu()
        if let start = unfoldedSection(at: convert(event.locationInWindow, from: nil)) {
            let item = NSMenuItem(title: L("Fold Section"), action: #selector(foldSection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: start)
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    /// The first byte of the undefined section under `point`, if it was opened from its fold row.
    private func unfoldedSection(at point: NSPoint) -> UInt64? {
        guard let session, session.foldsUndefinedSections, !session.unfoldedSections.isEmpty,
              let (offset, _, fold) = hit(point), fold == nil else { return nil }
        return session.undefinedSections().first { $0.contains(offset) && session.unfoldedSections.contains($0.lowerBound) }?.lowerBound
    }

    /// Folds an opened section again (the grid's context menu).
    @objc private func foldSection(_ sender: NSMenuItem) {
        guard let start = (sender.representedObject as? NSNumber)?.uint64Value else { return }
        editor?.fold(sectionAt: start)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }
}

/// Search hits and compare differences in the visible rows. `color(at:)` must be asked for
/// offsets in increasing order, apart from peeking one byte ahead.
private final class Highlights {
    private let hits: [Range<UInt64>]
    private let diffs: [Range<UInt64>]
    private var hitIndex = 0
    private var diffIndex = 0

    init(session: EditorSession, visible: Range<UInt64>) {
        hits = session.searchHits(overlapping: visible).map(\.range)
        diffs = session.compare?.differences(for: session, visible: visible) ?? []
    }

    func color(at offset: UInt64) -> NSColor? {
        if Self.contains(diffs, &diffIndex, offset) { return HexTheme.difference }
        if Self.contains(hits, &hitIndex, offset) { return HexTheme.searchHit }
        return nil
    }

    /// Whether sorted, non-overlapping `ranges` contain `offset`, advancing `index` past ranges
    /// that end before it.
    private static func contains(_ ranges: [Range<UInt64>], _ index: inout Int, _ offset: UInt64) -> Bool {
        while index < ranges.count && ranges[index].upperBound <= offset { index += 1 }
        return index < ranges.count && ranges[index].contains(offset)
    }
}
