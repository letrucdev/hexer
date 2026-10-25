import AppKit
import HexerCore

/// Keyboard navigation, typing (including IME composition in the text column) and edit actions.
extension HexCanvasView: NSTextInputClient, NSMenuItemValidation {
    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    /// Hex digits bypass input methods; the text column accepts composed input (e.g. Telex).
    override var inputContext: NSTextInputContext? {
        session?.activeColumn == .text ? super.inputContext : nil
    }

    /// Without an input context, `interpretKeyEvents` sends typed text here (the responder method),
    /// not to the text input client's `insertText(_:replacementRange:)`.
    override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func doCommand(by selector: Selector) {
        if responds(to: selector) { perform(selector, with: nil) } else { super.doCommand(by: selector) }
    }

    // MARK: Caret movement

    private func move(to offset: UInt64, extend: Bool) {
        guard let session else { return }
        let target = min(offset, session.length)
        if extend {
            session.setSelection(Selection(anchor: session.selection.anchor, caret: target))
        } else {
            session.setSelection(Selection(caret: target))
        }
        needsDisplay = true
    }

    private func move(by delta: Int64, extend: Bool) {
        guard let session else { return }
        let sel = session.selection
        if !extend && !sel.isEmpty && abs(delta) == 1 {
            move(to: delta < 0 ? sel.range.lowerBound : sel.range.upperBound, extend: false)
            return
        }
        let caret = Int64(clamping: sel.caret)
        move(to: UInt64(max(0, caret + delta)), extend: extend)
    }

    /// Moves the caret `delta` rows on screen, keeping its column; a fold row takes the caret to
    /// the section's first hidden byte. Past the first or last row it goes to the start or end.
    private func move(rows delta: Int64, extend: Bool) {
        guard let session, let editor else { return }
        let map = editor.rowMap
        let caret = session.selection.caret
        let target = Int64(clamping: map.visualRow(of: caret)) + delta
        guard target >= 0 else { return move(to: 0, extend: extend) }
        guard target < Int64(clamping: map.rowCount) else { return move(to: session.length, extend: extend) }
        switch map.row(at: UInt64(target)) {
        case .data(let row): move(to: row * map.bytesPerRow + caret % map.bytesPerRow, extend: extend)
        case .fold: move(to: map.offset(ofVisualRow: UInt64(target)), extend: extend)
        }
    }

    private var bpr: Int64 { Int64(editor?.layoutInfo.bytesPerRow ?? 16) }
    private var pageRows: Int64 { Int64(max(1, (editor?.visibleRowCount ?? 1) - 1)) }

    @objc override func moveLeft(_ sender: Any?) { move(by: -1, extend: false) }
    @objc override func moveRight(_ sender: Any?) { move(by: 1, extend: false) }
    @objc override func moveUp(_ sender: Any?) { move(rows: -1, extend: false) }
    @objc override func moveDown(_ sender: Any?) { move(rows: 1, extend: false) }
    @objc override func moveLeftAndModifySelection(_ sender: Any?) { move(by: -1, extend: true) }
    @objc override func moveRightAndModifySelection(_ sender: Any?) { move(by: 1, extend: true) }
    @objc override func moveUpAndModifySelection(_ sender: Any?) { move(rows: -1, extend: true) }
    @objc override func moveDownAndModifySelection(_ sender: Any?) { move(rows: 1, extend: true) }

    @objc override func moveWordLeft(_ sender: Any?) { moveByGroup(-1, extend: false) }
    @objc override func moveWordRight(_ sender: Any?) { moveByGroup(1, extend: false) }
    @objc override func moveWordLeftAndModifySelection(_ sender: Any?) { moveByGroup(-1, extend: true) }
    @objc override func moveWordRightAndModifySelection(_ sender: Any?) { moveByGroup(1, extend: true) }

    private func moveByGroup(_ direction: Int64, extend: Bool) {
        guard let session, let editor else { return }
        let g = UInt64(editor.layoutInfo.groupSize == 1 ? 4 : editor.layoutInfo.groupSize)
        let c = session.selection.caret
        let target = direction < 0 ? (c == 0 ? 0 : (c - 1) / g * g) : (c / g + 1) * g
        move(to: target, extend: extend)
    }

    /// Start of the caret's row; nil on a fold row, which has no line to move along.
    private var caretRowStart: UInt64? {
        guard let session, let editor, editor.rowMap.fold(containing: session.selection.caret) == nil else { return nil }
        let caret = session.selection.caret
        return caret - caret % UInt64(bpr)
    }

    @objc override func moveToBeginningOfLine(_ sender: Any?) { if let s = caretRowStart { move(to: s, extend: false) } }
    @objc override func moveToEndOfLine(_ sender: Any?) { if let s = caretRowStart { move(to: s + UInt64(bpr) - 1, extend: false) } }
    @objc override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) { if let s = caretRowStart { move(to: s, extend: true) } }
    @objc override func moveToEndOfLineAndModifySelection(_ sender: Any?) { if let s = caretRowStart { move(to: s + UInt64(bpr), extend: true) } }
    @objc override func moveToLeftEndOfLine(_ sender: Any?) { moveToBeginningOfLine(sender) }
    @objc override func moveToRightEndOfLine(_ sender: Any?) { moveToEndOfLine(sender) }
    @objc override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { moveToBeginningOfLineAndModifySelection(sender) }
    @objc override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { moveToEndOfLineAndModifySelection(sender) }
    @objc override func moveToBeginningOfDocument(_ sender: Any?) { move(to: 0, extend: false) }
    @objc override func moveToEndOfDocument(_ sender: Any?) { move(to: session?.length ?? 0, extend: false) }
    @objc override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { move(to: 0, extend: true) }
    @objc override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { move(to: session?.length ?? 0, extend: true) }
    @objc override func pageUp(_ sender: Any?) { move(rows: -pageRows, extend: false) }
    @objc override func pageDown(_ sender: Any?) { move(rows: pageRows, extend: false) }
    @objc override func pageUpAndModifySelection(_ sender: Any?) { move(rows: -pageRows, extend: true) }
    @objc override func pageDownAndModifySelection(_ sender: Any?) { move(rows: pageRows, extend: true) }
    @objc override func scrollPageUp(_ sender: Any?) { editor?.scroll(byRows: -Double(pageRows)) }
    @objc override func scrollPageDown(_ sender: Any?) { editor?.scroll(byRows: Double(pageRows)) }
    @objc override func scrollToBeginningOfDocument(_ sender: Any?) { editor?.scrollToRow(0) }
    @objc override func scrollToEndOfDocument(_ sender: Any?) { editor?.scrollToRow(.greatestFiniteMagnitude) }

    @objc override func insertTab(_ sender: Any?) { switchColumn() }
    @objc override func insertBacktab(_ sender: Any?) { switchColumn() }

    private func switchColumn() {
        guard let session, let editor, editor.layoutInfo.columns == .hexAndText else { return }
        session.activeColumn = session.activeColumn == .hex ? .text : .hex
        session.nibble = 0
        needsDisplay = true
    }

    @objc override func deleteBackward(_ sender: Any?) { session?.deleteBackward(); needsDisplay = true }
    @objc override func deleteForward(_ sender: Any?) { session?.deleteForward(); needsDisplay = true }
    @objc override func cancelOperation(_ sender: Any?) {
        if let session, !session.selection.isEmpty { move(to: session.selection.caret, extend: false) }
    }

    // MARK: Edit actions

    @objc func copy(_ sender: Any?) { session?.copySelection() }
    @objc func cut(_ sender: Any?) { session?.cutSelection(); needsDisplay = true }
    @objc func paste(_ sender: Any?) { session?.paste(overwrite: false); needsDisplay = true }
    @objc func pasteOverwrite(_ sender: Any?) { session?.paste(overwrite: true); needsDisplay = true }
    @objc func delete(_ sender: Any?) { session?.deleteSelection(); needsDisplay = true }
    @objc override func selectAll(_ sender: Any?) {
        guard let session else { return }
        session.setSelection(Selection(anchor: 0, caret: session.length), scroll: false)
        needsDisplay = true
    }
    @objc func undo(_ sender: Any?) { session?.undo(); needsDisplay = true }
    @objc func redo(_ sender: Any?) { session?.redo(); needsDisplay = true }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let session else { return false }
        let hasSelection = !session.selection.isEmpty
        switch item.action {
        case #selector(copy(_:)): return hasSelection
        case #selector(cut(_:)), #selector(delete(_:)): return hasSelection && session.isEditable && !session.buffer.isFixedSize
        case #selector(paste(_:)): return session.isEditable && !session.buffer.isFixedSize
        case #selector(pasteOverwrite(_:)): return session.isEditable
        case #selector(undo(_:)):
            item.title = session.buffer.undoName.map { L("Undo %@", $0) } ?? L("Undo")
            return session.buffer.canUndo
        case #selector(redo(_:)):
            item.title = session.buffer.redoName.map { L("Redo %@", $0) } ?? L("Redo")
            return session.buffer.canRedo
        default: return true
        }
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = nil
        guard let session else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if session.activeColumn == .hex {
            for c in text {
                guard let v = c.hexDigitValue else { NSSound.beep(); return }
                session.typeHexDigit(UInt8(v))
            }
        } else {
            session.typeText(text)
        }
        needsDisplay = true
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
        markedText = text.length > 0 ? text : nil
    }

    func unmarkText() { markedText = nil }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange { markedText.map { NSRange(location: 0, length: $0.length) } ?? NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { markedText != nil }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Places IME candidate windows next to the caret.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let editor, let session, let window else { return .zero }
        let layout = editor.layoutInfo
        let bprU = UInt64(layout.bytesPerRow)
        let caret = session.selection.caret
        let y = (Double(editor.rowMap.visualRow(of: caret)) - editor.topRow) * editor.metrics.rowHeight
        let x = layout.textX(byte: Int(caret % bprU)) - editor.scrollX
        let local = NSRect(x: x, y: y, width: layout.charWidth, height: editor.metrics.rowHeight)
        return window.convertToScreen(convert(local, to: nil))
    }
}
