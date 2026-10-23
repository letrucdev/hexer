import AppKit

extension NSAlert {
    /// Adds the button for an action that can't be undone: drawn as destructive and never the default,
    /// so Return doesn't trigger it and confirming takes a deliberate click. Escape still cancels.
    @discardableResult
    func addDestructiveButton(withTitle title: String) -> NSButton {
        let button = addButton(withTitle: title)
        button.hasDestructiveAction = true
        if button.keyEquivalent == "\r" { button.keyEquivalent = "" }
        return button
    }
}
