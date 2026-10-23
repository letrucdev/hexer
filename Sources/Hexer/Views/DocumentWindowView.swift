import AppKit
import HexerCore
import SwiftUI

/// The window content: glass sidebar, the grid with the results drawer and status bar, and the
/// data inspector, with a Liquid Glass toolbar.
struct DocumentWindowView: View {
    @Bindable var session: EditorSession

    var body: some View {
        NavigationSplitView(columnVisibility: $session.columnVisibility) {
            // The system sidebar: edge-to-edge glass in macOS 27, sized by the user's sidebar setting.
            SidebarView(session: session)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 340)
        } detail: {
            contentColumn
        }
        // The system inspector pane: edge-to-edge glass alongside the content, resizable.
        .inspector(isPresented: $session.showInspector) {
            InspectorView(session: session)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbar { toolbar }
        .sheet(item: $session.sheet) { $0.content }
        .onReceive(NotificationCenter.default.publisher(for: .toggleHexerSidebar)) { _ in
            withAnimation { session.columnVisibility = session.columnVisibility == .detailOnly ? .all : .detailOnly }
        }
    }

    /// The grid with its overlays, the results drawer and the status bar.
    private var contentColumn: some View {
        VStack(spacing: 0) {
            HexEditorRepresentable(session: session)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .topTrailing) {
                    if session.find.isVisible {
                        FindBar(session: session)
                            .padding(.top, 34)
                            .padding(.horizontal, 16)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                    }
                }
                .animation(.smooth(duration: 0.2), value: session.find.isVisible)
                .overlay(alignment: .bottom) {
                    if let compare = session.compare {
                        CompareCapsule(session: session, compare: compare)
                            .padding(.bottom, 16)
                    } else if let sectorSize = session.sectorSize {
                        SectorNavigator(session: session, sectorSize: sectorSize)
                            .padding(.bottom, 16)
                    }
                }
            if let pane = session.drawerPane {
                Divider()
                ResultsDrawer(session: session, pane: pane)
                    .frame(height: 210)
            }
            Divider()
            StatusBarView(session: session)
        }
    }

    @ToolbarContentBuilder
    /// Three groups, as the HIG recommends: document actions, the edit mode, and find/navigate
    /// with the inspector button on the trailing edge (every item is also in the menu bar).
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { NSDocumentController.shared.openDocument(nil) } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open a file (⌘O)")
            Button { session.document?.save(nil) } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .help("Save (⌘S)")
            .disabled(!session.isDirty)
            Button { session.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .help("Undo (⌘Z)")
                .disabled(!session.canUndo)
            Button { session.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .help("Redo (⇧⌘Z)")
                .disabled(!session.canRedo)
        }
        // Compared windows are narrow; the status bar's mode chip stands in for the picker.
        if session.compare == nil {
            ToolbarItem(placement: .principal) {
                modePicker
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { session.showFind(replace: false) } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            .help("Find (⌘F)")
            Button { NSApp.sendAction(#selector(HexWindowController.goToOffset(_:)), to: nil, from: nil) } label: {
                Label("Go to Offset", systemImage: "arrow.right.to.line")
            }
            .help("Go to Offset (⌘L)")
            Button { withAnimation { session.showInspector.toggle() } } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the data inspector (⌥⌘I)")
        }
    }

    private var modePicker: some View {
        Picker("Edit Mode", selection: modeBinding) {
            ForEach(EditMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .help("Insert inserts typed bytes; Overwrite replaces them; Read-only prevents changes")
    }

    private var modeBinding: Binding<EditMode> {
        Binding {
            session.mode
        } set: { mode in
            if mode != .readOnly && session.buffer.isReadOnly { NSSound.beep(); return }
            session.mode = mode
            session.nibble = 0
        }
    }
}

extension Notification.Name {
    static let toggleHexerSidebar = Notification.Name("HexerToggleSidebar")
}
