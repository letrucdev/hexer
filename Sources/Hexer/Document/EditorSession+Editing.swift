import AppKit
import HexerCore

extension NSPasteboard.PasteboardType {
    /// Raw bytes copied from Hexer, so pasting back is exact.
    static let hexerBytes = NSPasteboard.PasteboardType("com.nongdandev.hexer.bytes")
}

extension EditorSession {
    var isEditable: Bool { mode != .readOnly && !buffer.isReadOnly }

    /// Asks once per document before the first edit that changes the file size.
    func confirmSizeChange() -> Bool {
        if buffer.isFixedSize {
            NSSound.beep()
            document?.showMessage(L("The size of this data cannot change."),
                                  info: L("Disks and other fixed-size data can only be overwritten."))
            return false
        }
        guard !sizeChangeConfirmed, AppSettings.shared.confirmSizeChange else { return true }
        let alert = NSAlert()
        alert.messageText = L("Change the file size?")
        alert.informativeText = L("This edit inserts or removes bytes, so everything after it moves to a different offset.")
        alert.addButton(withTitle: L("Change Size"))
        alert.addButton(withTitle: L("Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("Don't ask again")
        let ok = alert.runModal() == .alertFirstButtonReturn
        if ok {
            sizeChangeConfirmed = true
            if alert.suppressionButton?.state == .on { AppSettings.shared.confirmSizeChange = false }
        }
        return ok
    }

    private func perform(_ body: () throws -> Void) {
        do {
            try body()
        } catch EditError.readOnly {
            NSSound.beep()
        } catch EditError.sizeChangeNotAllowed {
            NSSound.beep()
        } catch {
            document?.presentError(error)
        }
    }

    private func byte(at offset: UInt64) -> UInt8 {
        offset < buffer.length ? buffer.snapshot().bytes(offset..<offset + 1).first ?? 0 : 0
    }

    // MARK: Typing

    func typeHexDigit(_ value: UInt8) {
        guard isEditable else { NSSound.beep(); return }
        let before = selection
        let p = caretByte
        overwrittenByTyping.removeAll()
        perform {
            if mode == .insert && nibble == 0 {
                guard confirmSizeChange() else { return }
                let after = Selection(caret: p)
                try buffer.apply(L("Typing"), replacing: before.range.isEmpty ? p..<p : before.range,
                                 with: buffer.addPieces([value << 4]), selectionBefore: before,
                                 selectionAfter: after, coalesceKey: "typing")
                selection = after
                nibble = 1
            } else {
                if p >= buffer.length {
                    guard !buffer.isFixedSize else { NSSound.beep(); return }
                    guard confirmSizeChange() else { return }
                }
                let current = byte(at: p)
                let new = nibble == 0 ? (value << 4 | current & 0x0F) : (current & 0xF0 | value)
                let after = Selection(caret: nibble == 0 ? p : p + 1)
                if !before.isEmpty && mode == .insert {
                    try buffer.apply(L("Typing"), replacing: before.range, with: buffer.addPieces([new]),
                                     selectionBefore: before, selectionAfter: after, coalesceKey: "typing")
                } else {
                    try buffer.overwrite([new], at: p, name: L("Typing"), selectionBefore: before,
                                         selectionAfter: after, coalesceKey: "typing")
                }
                selection = after
                nibble = nibble == 0 ? 1 : 0
            }
        }
        editorView?.scrollToVisible(offset: selection.caret)
    }

    func typeText(_ text: String) {
        guard isEditable else { NSSound.beep(); return }
        guard let bytes = encoding.table.encode(text), !bytes.isEmpty else { NSSound.beep(); return }
        let before = selection
        let p = caretByte
        perform {
            let after = Selection(caret: p + UInt64(bytes.count))
            if mode == .insert {
                guard confirmSizeChange() else { return }
                try buffer.apply(L("Typing"), replacing: before.isEmpty ? p..<p : before.range, with: buffer.addPieces(bytes),
                                 selectionBefore: before, selectionAfter: after, coalesceKey: "typing")
            } else {
                if p + UInt64(bytes.count) > buffer.length {
                    guard !buffer.isFixedSize || p < buffer.length else { NSSound.beep(); return }
                    if !buffer.isFixedSize { guard confirmSizeChange() else { return } }
                }
                let replaced = buffer.snapshot().bytes(p..<min(p + UInt64(bytes.count), buffer.length))
                try buffer.overwrite(bytes, at: p, name: L("Typing"), selectionBefore: before,
                                     selectionAfter: Selection(caret: min(p + UInt64(bytes.count), buffer.isFixedSize ? buffer.length : .max)),
                                     coalesceKey: "typing")
                if before.isEmpty {
                    let typed = buffer.isFixedSize ? replaced.count : bytes.count
                    overwrittenByTyping.append((p, typed, replaced))
                }
            }
            selection = after.clamped(to: buffer.length)
            nibble = 0
        }
        editorView?.scrollToVisible(offset: selection.caret)
    }

    /// In Overwrite mode, Backspace during a typing run puts back what the last typed text
    /// replaced and steps back onto it, instead of deleting a byte. Vietnamese input methods
    /// (Telex: "a" + "s" → "á") retype a character by sending Backspace and the new one, so
    /// without this each accent would ask to change the file size.
    private func untypeLast() -> Bool {
        guard mode == .overwrite, selection.isEmpty, let last = overwrittenByTyping.last,
              buffer.undoStack.last?.coalesceKey == "typing",
              last.offset + UInt64(last.typed) == selection.caret else { return false }
        let before = selection
        let after = Selection(caret: last.offset)
        perform {
            try buffer.apply(L("Typing"), replacing: last.offset..<last.offset + UInt64(last.typed), with: buffer.addPieces(last.original),
                             selectionBefore: before, selectionAfter: after, coalesceKey: "typing")
            selection = after
            nibble = 0
            overwrittenByTyping.removeLast()
        }
        editorView?.scrollToVisible(offset: selection.caret)
        return true
    }

    // MARK: Deleting

    func deleteSelection(name: String = L("Delete")) {
        guard isEditable else { NSSound.beep(); return }
        let before = selection
        guard !before.isEmpty, confirmSizeChange() else { return }
        perform { try buffer.delete(before.range, name: name, selectionBefore: before) }
        selection = Selection(caret: before.range.lowerBound)
        nibble = 0
    }

    func deleteBackward() {
        guard selection.isEmpty else { deleteSelection(); return }
        if untypeLast() { return }
        let p = selection.caret
        guard p > 0 else { NSSound.beep(); return }
        guard isEditable, confirmSizeChange() else { if !isEditable { NSSound.beep() }; return }
        let before = selection
        perform { try buffer.delete(p - 1..<p, name: L("Delete"), selectionBefore: before) }
        selection = Selection(caret: p - 1)
        nibble = 0
        editorView?.scrollToVisible(offset: selection.caret)
    }

    func deleteForward() {
        guard selection.isEmpty else { deleteSelection(); return }
        let p = selection.caret
        guard p < buffer.length else { NSSound.beep(); return }
        guard isEditable, confirmSizeChange() else { if !isEditable { NSSound.beep() }; return }
        let before = selection
        perform { try buffer.delete(p..<p + 1, name: L("Delete"), selectionBefore: before) }
        selection = Selection(caret: p)
        nibble = 0
    }

    // MARK: Clipboard

    static let maxClipboardBytes: UInt64 = 256 << 20

    func copySelection(to pasteboard: NSPasteboard = .general) {
        let range = selection.range
        guard !range.isEmpty else { NSSound.beep(); return }
        guard range.upperBound - range.lowerBound <= Self.maxClipboardBytes else {
            document?.showMessage(L("The selection is too large to copy."),
                                  info: L("Use File ▸ Save Selection As… to write large selections to a file."))
            return
        }
        let bytes = buffer.snapshot().bytes(range)
        pasteboard.clearContents()
        pasteboard.declareTypes([.hexerBytes, .string], owner: nil)
        pasteboard.setData(Data(bytes), forType: .hexerBytes)
        if activeColumn == .hex {
            let digits = lowercaseHex ? "%02x" : "%02X"
            pasteboard.setString(bytes.map { String(format: digits, $0) }.joined(separator: " "), forType: .string)
        } else {
            let table = encoding.table
            let text = table.decode(bytes)
            pasteboard.setString(text, forType: .string)
            if AppSettings.shared.warnFilteredClipboard, bytes.contains(where: { !table.isPrintable($0) }) {
                document?.showMessage(L("Some characters were replaced by dots."),
                                      info: L("Control characters and bytes without a character in %@ cannot be copied as text. Copy from the hex column to keep every byte.", encoding.shortName))
            }
        }
    }

    func cutSelection() {
        guard isEditable else { NSSound.beep(); return }
        copySelection()
        deleteSelection(name: L("Cut"))
    }

    /// The bytes on the pasteboard: Hexer's own data, else hex digits (hex column) or text.
    func pasteboardBytes(_ pasteboard: NSPasteboard = .general) -> [UInt8]? {
        if let data = pasteboard.data(forType: .hexerBytes) { return [UInt8](data) }
        guard let string = pasteboard.string(forType: .string) else { return nil }
        if activeColumn == .hex {
            guard let bytes = Self.parseHex(string) else {
                document?.showMessage(L("The clipboard does not contain valid hex values."),
                                      info: L("To paste text, click in the text column first."))
                return nil
            }
            return bytes
        }
        guard let bytes = encoding.table.encode(string) else {
            document?.showMessage(L("The clipboard contains characters that %@ cannot represent.", encoding.shortName), info: "")
            return nil
        }
        return bytes
    }

    /// Parses "4D 5A 90", "4d5a90" or "0x4D, 0x5A" into bytes.
    static func parseHex(_ string: String) -> [UInt8]? {
        var digits: [UInt8] = []
        var cleaned = string.replacingOccurrences(of: "0x", with: " ").replacingOccurrences(of: "0X", with: " ")
        cleaned = cleaned.replacingOccurrences(of: ",", with: " ")
        for c in cleaned.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(c) { continue }
            guard let v = UInt8(String(c), radix: 16) else { return nil }
            digits.append(v)
        }
        guard !digits.isEmpty, digits.count % 2 == 0 else { return nil }
        return stride(from: 0, to: digits.count, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }
    }

    func paste(overwrite: Bool) {
        guard isEditable else { NSSound.beep(); return }
        guard let bytes = pasteboardBytes(), !bytes.isEmpty else { return }
        let before = selection
        perform {
            if overwrite {
                let p = before.isEmpty ? before.caret : before.range.lowerBound
                if p + UInt64(bytes.count) > buffer.length && !buffer.isFixedSize {
                    guard confirmSizeChange() else { return }
                }
                let end = min(p + UInt64(bytes.count), buffer.isFixedSize ? buffer.length : .max)
                try buffer.overwrite(bytes, at: p, name: L("Paste Overwrite"), selectionBefore: before,
                                     selectionAfter: Selection(anchor: p, caret: end))
                selection = Selection(anchor: p, caret: end)
            } else {
                guard confirmSizeChange() else { return }
                let r = before.isEmpty ? before.caret..<before.caret : before.range
                let after = Selection(anchor: r.lowerBound, caret: r.lowerBound + UInt64(bytes.count))
                try buffer.apply(L("Paste"), replacing: r, with: buffer.addPieces(bytes), selectionBefore: before, selectionAfter: after)
                selection = after
            }
            nibble = 0
        }
        editorView?.scrollToVisible(offset: selection.caret)
    }

    // MARK: Undo

    func undo() {
        guard let s = buffer.undo() else { NSSound.beep(); return }
        setSelection(s.clamped(to: buffer.length))
    }

    func redo() {
        guard let s = buffer.redo() else { NSSound.beep(); return }
        setSelection(s.clamped(to: buffer.length))
    }
}
