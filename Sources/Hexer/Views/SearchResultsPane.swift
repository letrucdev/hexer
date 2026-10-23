import HexerCore
import SwiftUI

/// The Search Results pane: every Find All match with hex and text excerpts, like HxD's list.
struct SearchResultsPane: View {
    @Bindable var session: EditorSession

    var body: some View {
        let snapshot = session.snapshot()
        Table(session.searchHits, selection: $session.searchResultSelection) {
            TableColumn("Offset") { hit in
                Text(verbatim: session.formatOffset(hit.range.lowerBound, minDigits: 8))
                    .font(.body.monospaced())
                    .foregroundStyle(Color(nsColor: HexTheme.offset))
            }
            .width(min: 90, ideal: 110)
            TableColumn("Excerpt (hex)") { hit in
                Text(verbatim: excerpt(hit, snapshot).map { String(format: "%02X", $0) }.joined(separator: " "))
                    .font(.body.monospaced())
            }
            .width(min: 150, ideal: 420)
            TableColumn("Excerpt (text)") { hit in
                Text(verbatim: session.encoding.table.decode(excerpt(hit, snapshot)))
                    .font(.body.monospaced())
            }
            .width(min: 100, ideal: 220)
        }
        .onChange(of: session.searchResultSelection) { _, id in
            guard let id, let hit = session.searchHits.first(where: { $0.id == id }) else { return }
            session.setSelection(Selection(anchor: hit.range.lowerBound, caret: hit.range.upperBound))
            session.editorView?.canvas.needsDisplay = true
        }
        .overlay {
            if session.searchHits.isEmpty {
                ContentUnavailableView {
                    Label("No Search Results", systemImage: "magnifyingglass")
                } description: {
                    Text("Press Find All in the find bar (⌘F) to list every match here.")
                }
            }
        }
    }

    /// The matched bytes, at most 24.
    private func excerpt(_ hit: SearchHit, _ snapshot: ByteSnapshot) -> [UInt8] {
        snapshot.bytes(hit.range.lowerBound..<min(hit.range.upperBound, hit.range.lowerBound + 24))
    }
}

/// Match count and Clear, shown in the drawer header with the Search Results pane.
struct SearchResultsPaneAccessory: View {
    @Bindable var session: EditorSession

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: L("%lld matches", session.searchHits.count) + (session.searchHitsTruncated ? "+" : ""))
                .foregroundStyle(.secondary)
            Button("Clear", action: session.clearSearchHits)
                .disabled(session.searchHits.isEmpty)
        }
    }
}
