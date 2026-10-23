import HexerCore
import SwiftUI

/// The pane below the grid with search results, checksums and comparison results.
struct ResultsDrawer: View {
    @Bindable var session: EditorSession
    let pane: DrawerPane

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Results", selection: paneBinding) {
                    ForEach(DrawerPane.allCases) { p in Text(p.title).tag(p) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .demoAnchor("Drawer tabs")
                Spacer()
                if pane == .checksums { ChecksumsPaneAccessory(session: session) }
                if pane == .searchResults { SearchResultsPaneAccessory(session: session) }
                Button { withAnimation { session.drawerPane = nil } } label: {
                    Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Hide results")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            Group {
                switch pane {
                case .checksums:
                    ChecksumsPane(session: session)
                case .searchResults:
                    SearchResultsPane(session: session)
                case .compare:
                    ComparePane(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
    }

    private var paneBinding: Binding<DrawerPane> {
        Binding { pane } set: { session.drawerPane = $0 }
    }
}
