import HexerCore
import SwiftUI

/// The glass sector navigator floating over disk and disk-image documents.
struct SectorNavigator: View {
    let session: EditorSession
    let sectorSize: Int
    @Bindable private var input: SectorInput

    init(session: EditorSession, sectorSize: Int) {
        self.session = session
        self.sectorSize = sectorSize
        input = session.sectorInput
    }

    private var sectorCount: UInt64 { (session.length + UInt64(sectorSize) - 1) / UInt64(sectorSize) }
    private var current: UInt64 { session.caretByte / UInt64(sectorSize) }

    var body: some View {
        HStack(spacing: 2) {
            button("backward.end", "First sector") { go(0) }
            button("chevron.left", "Previous sector") { go(current == 0 ? 0 : current - 1) }
            Text("Sector")
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            TextField("Sector", text: $input.text)
                .textFieldStyle(.plain)
                .font(.callout.monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(width: 80)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: .capsule)
                .onSubmit { if let n = UInt64(input.text) { go(n) } }
            Text(verbatim: L("of %@", sectorCount.formatted()))
                .foregroundStyle(.secondary)
                .padding(.trailing, 6)
            button("chevron.right", "Next sector") { go(current + 1) }
            button("forward.end", "Last sector") { go(sectorCount == 0 ? 0 : sectorCount - 1) }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .frame(height: GlassBar.height)
        .glassEffect(.regular.interactive(), in: .capsule)
        .onAppear { input.text = "\(current)" }
        .onChange(of: current) { input.text = "\(current)" }
    }

    private func button(_ symbol: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        GlassBarIconButton(symbol, help, action: action)
    }

    private func go(_ sector: UInt64) {
        let target = min(sector, max(sectorCount, 1) - 1) * UInt64(sectorSize)
        session.setSelection(Selection(caret: min(target, session.length)))
        session.editorView?.scrollToRow(containing: target)
        session.editorView?.canvas.needsDisplay = true
        input.text = "\(min(sector, max(sectorCount, 1) - 1))"
    }
}

/// The text of the sector field (SwiftUI's @State is unavailable without Xcode's macro plugin).
@Observable
final class SectorInput {
    var text = ""
}
