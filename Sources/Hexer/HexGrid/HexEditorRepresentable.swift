import AppKit
import SwiftUI

/// Hosts the AppKit grid in SwiftUI. Reading the session's view state here makes SwiftUI call
/// `updateNSView` whenever it changes.
struct HexEditorRepresentable: NSViewRepresentable {
    let session: EditorSession

    func makeNSView(context: Context) -> HexEditorView {
        HexEditorView(session: session)
    }

    func updateNSView(_ view: HexEditorView, context: Context) {
        _ = (session.revision, session.selection, session.nibble, session.activeColumn, session.mode,
             session.bytesPerRow, session.fitToWidth, session.groupSize, session.encoding, session.offsetBase,
             session.lowercaseHex, session.columns, session.foldsUndefinedSections, session.unfoldedSections,
             AppSettings.shared.fontSize, AppSettings.shared.fontName)
        view.sync()
    }
}
