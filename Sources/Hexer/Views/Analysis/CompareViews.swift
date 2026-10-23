import AppKit
import HexerCore
import SwiftUI

/// State of the Compare sheet.
@Observable
final class CompareModel {
    var partner: ObjectIdentifier?
    var vertical = UserDefaults.standard.object(forKey: "CompareTileVertically") as? Bool ?? true
    var selectedDataOnly = false
}

/// HxD's Compare dialog: the second data source, window arrangement and scope.
struct CompareSheet: View {
    @Bindable var model: CompareModel
    let session: EditorSession

    private var others: [HexDocument] {
        NSDocumentController.shared.documents.compactMap { $0 as? HexDocument }.filter { $0 !== session.document }
    }

    var body: some View {
        SheetScaffold(title: "Compare", confirmTitle: "Compare", canConfirm: partnerSession != nil,
                      onCancel: session.closeSheet, onConfirm: compare) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    Text("1. Data source:").gridColumnAlignment(.trailing)
                    Text(verbatim: session.document?.displayName ?? "").fontWeight(.semibold)
                }
                GridRow {
                    Text("2. Data source:")
                    HStack {
                        Picker("Second data source", selection: $model.partner) {
                            Text("Choose…").tag(ObjectIdentifier?.none)
                            ForEach(others, id: \.self) { doc in
                                Text(verbatim: doc.displayName).tag(Optional(ObjectIdentifier(doc)))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                        Button("Open File…", action: openFile)
                    }
                }
                GridRow(alignment: .top) {
                    Text("Windows:")
                    Picker("Window arrangement", selection: $model.vertical) {
                        Text("Side by side").tag(true)
                        Text("One above the other").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                GridRow(alignment: .top) {
                    Text("Scope:")
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Scope", selection: $model.selectedDataOnly) {
                            Text("Whole files").tag(false)
                            Text("Selected data").tag(true)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        Text("Selected data compares each window's selection (or from its caret to the end), aligned at their starts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 300, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var partnerSession: EditorSession? {
        others.first { ObjectIdentifier($0) == model.partner }?.session
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.message = L("Choose the file to compare with “%@”.", session.document?.displayName ?? "")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let (doc, _) = try? await NSDocumentController.shared.openDocument(withContentsOf: url, display: true),
                  let hex = doc as? HexDocument else { return }
            model.partner = ObjectIdentifier(hex)
        }
    }

    private func compare() {
        guard let other = partnerSession else { return }
        UserDefaults.standard.set(model.vertical, forKey: "CompareTileVertically")
        func scope(_ s: EditorSession) -> Range<UInt64> {
            guard model.selectedDataOnly else { return 0..<s.length }
            return s.selection.isEmpty ? s.selection.caret..<s.length : s.selection.range
        }
        session.closeSheet()
        CompareSession.start(session, scope(session), other, scope(other), vertical: model.vertical)
    }
}

/// The floating glass capsule of a compared window: the current difference, previous/next, stop.
struct CompareCapsule: View {
    let session: EditorSession
    let compare: CompareSession

    var body: some View {
        HStack(spacing: 2) {
            if compare.isSearching {
                ProgressView().controlSize(.small).padding(.horizontal, 6)
            }
            Text(verbatim: compare.status ?? "")
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 8)
            GlassBarIconButton("chevron.up", "Previous Difference (⇧F6)") { compare.step(from: session, backward: true) }
            GlassBarIconButton("chevron.down", "Next Difference (F6)") { compare.step(from: session, backward: false) }
            GlassBarIconButton("xmark", "Stop Comparing") { compare.stop() }
        }
        .padding(.horizontal, 6)
        .frame(height: GlassBar.height)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// One row of the Compare pane.
struct DifferenceRow: Identifiable, Hashable {
    let range: Range<UInt64>
    var id: UInt64 { range.lowerBound }
}

/// The Compare pane: every differing run of the compared windows.
struct ComparePane: View {
    @Bindable var session: EditorSession

    var body: some View {
        if let compare = session.compare {
            if let runs = compare.allDifferences {
                Table(runs.map(DifferenceRow.init), selection: $session.compareSelection) {
                    TableColumn("Offset") { row in
                        Text(verbatim: session.formatOffset(row.range.lowerBound, minDigits: 8))
                            .font(.body.monospaced())
                            .foregroundStyle(Color(nsColor: HexTheme.offset))
                    }
                    .width(min: 90, ideal: 110)
                    TableColumn("Length") { row in Text(verbatim: (row.range.upperBound - row.range.lowerBound).formatted()) }
                        .width(min: 60, ideal: 80)
                    TableColumn(Text(verbatim: compare.left?.document?.displayName ?? "1")) { row in
                        Text(verbatim: hex(compare.bytes(of: row.range, left: true))).font(.body.monospaced())
                    }
                    TableColumn(Text(verbatim: compare.right?.document?.displayName ?? "2")) { row in
                        Text(verbatim: hex(compare.bytes(of: row.range, left: false))).font(.body.monospaced())
                    }
                }
                .onChange(of: session.compareSelection) { _, id in
                    guard let id, let run = runs.first(where: { $0.lowerBound == id }) else { return }
                    compare.select(run)
                }
                .overlay {
                    if runs.isEmpty {
                        ContentUnavailableView("No Differences", systemImage: "equal.circle",
                                               description: Text("The compared data is identical."))
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Compare", systemImage: "rectangle.split.2x1")
                } description: {
                    Text("List every difference between the two windows.")
                } actions: {
                    Button("List Differences") { compare.listDifferences(using: session) }
                        .disabled(compare.isSearching)
                }
            }
        } else {
            ContentUnavailableView {
                Label("Not Comparing", systemImage: "rectangle.split.2x1")
            } description: {
                Text("Choose Analysis ▸ Compare… (⌘K) to compare this window with another file.")
            }
        }
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
