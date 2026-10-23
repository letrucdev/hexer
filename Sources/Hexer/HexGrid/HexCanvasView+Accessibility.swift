import AppKit
import HexerCore

/// VoiceOver: the grid reads as a text area whose value describes the byte at the caret.
extension HexCanvasView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityRoleDescription() -> String? { L("hex editor") }
    override func accessibilityLabel() -> String? { session?.document?.displayName }

    override func accessibilityValue() -> Any? {
        guard let session else { return nil }
        let caret = session.caretByte
        guard caret < session.length else { return L("End of data, offset %@", session.formatOffset(caret)) }
        let byte = session.snapshot().bytes(caret..<caret + 1).first ?? 0
        let table = session.encoding.table
        let character = table.isPrintable(byte) ? " “\(table.display[Int(byte)])”" : ""
        var text = L("Offset %@: %@%@", session.formatOffset(caret), String(format: "%02X", byte), character)
        if !session.selection.isEmpty {
            text += ", " + L("%@ bytes selected", (session.selection.length).formatted())
        }
        return text
    }

    /// Tells VoiceOver that the caret moved or the bytes changed.
    func announceCaretChange() {
        NSAccessibility.post(element: self, notification: .valueChanged)
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }
}
