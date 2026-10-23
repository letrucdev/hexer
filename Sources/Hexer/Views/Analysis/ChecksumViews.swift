import AppKit
import HexerCore
import SwiftUI

/// One row of the Checksums results pane.
struct ChecksumEntry: Identifiable, Hashable {
    let id = UUID()
    let result: ChecksumResult
    let range: Range<UInt64>
    /// "Entire file" or the selection, like HxD's "Usage" column.
    let scope: String

    var name: String { result.algorithm.displayName }
}

extension EditorSession {
    /// Computes `algorithms` over `range` in the background and adds the results to the pane.
    func computeChecksums(_ algorithms: [ChecksumAlgorithm], range: Range<UInt64>) {
        guard !algorithms.isEmpty else { return }
        let snapshot = snapshot()
        let scope = range == 0..<snapshot.length
            ? L("Entire file")
            : L("Selection %@–%@", formatOffset(range.lowerBound), formatOffset(range.upperBound - 1))
        Task {
            do {
                let results = try await jobs.run(L("Calculating checksums")) { job in
                    ChecksumCalculator.compute(algorithms, snapshot: snapshot, range: range,
                                               isCancelled: { job.isCancelled }, progress: job.report)
                }
                guard let results = results ?? nil else { return }
                checksumResults.append(contentsOf: results.map { ChecksumEntry(result: $0, range: range, scope: scope) })
                drawerPane = .checksums
            } catch {
                document?.presentError(error)
            }
        }
    }

    /// Recomputes every listed checksum over the current bytes (HxD's Refresh button).
    func refreshChecksums() {
        let entries = checksumResults
        checksumResults.removeAll()
        checksumSelection.removeAll()
        for range in Set(entries.map(\.range)).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let r = range.clamped(to: 0..<length)
            computeChecksums(entries.filter { $0.range == range }.map(\.result.algorithm), range: r)
        }
    }

    func copyChecksums(_ ids: Set<ChecksumEntry.ID>, detailed: Bool) {
        let rows = checksumResults.filter { ids.contains($0.id) }
        guard !rows.isEmpty else { return }
        let text = rows.map { detailed ? "\($0.name)\t\($0.result.hexString)\t\($0.scope)" : $0.result.hexString }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func deleteChecksums(_ ids: Set<ChecksumEntry.ID>) {
        checksumResults.removeAll { ids.contains($0.id) }
        checksumSelection.subtract(ids)
    }
}

/// State of the Generate Checksums sheet; the chosen algorithms are remembered.
@Observable
final class ChecksumModel {
    var selected: Set<ChecksumAlgorithm>
    var useCustomChecksum = false
    var customChecksum = CustomChecksumParameters(resultWidth: 32)
    var useCustomCRC = false
    var crcWidth = 32
    let crcPolynomial = NumberInput(0x04C1_1DB7, base: .hexadecimal)
    let crcInitial = NumberInput(0xFFFF_FFFF, base: .hexadecimal)
    let crcFinalXOR = NumberInput(0xFFFF_FFFF, base: .hexadecimal)
    var crcReflectInput = true
    var crcReflectOutput = true
    var selectionOnly: Bool
    var compare = false
    var expected = ""

    private static let key = "ChecksumAlgorithms"

    init(hasSelection: Bool) {
        let saved = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? ["CRC-32", "MD5", "SHA-256"])
        selected = Set(ChecksumAlgorithm.standard.filter { saved.contains($0.displayName) })
        selectionOnly = hasSelection
    }

    var customCRC: CRCParameters? {
        guard let poly = crcPolynomial.value, let initial = crcInitial.value, let xor = crcFinalXOR.value else { return nil }
        return CRCParameters(width: crcWidth, polynomial: poly, initialValue: initial, finalXOR: xor,
                             reflectInput: crcReflectInput, reflectOutput: crcReflectOutput)
    }

    /// The algorithms to run, in HxD's order with the custom ones last.
    var algorithms: [ChecksumAlgorithm] {
        var list = ChecksumAlgorithm.standard.filter(selected.contains)
        if useCustomChecksum { list.append(.customChecksum(customChecksum)) }
        if useCustomCRC, let crc = customCRC { list.append(.customCRC(crc)) }
        return list
    }

    func remember() {
        UserDefaults.standard.set(ChecksumAlgorithm.standard.filter(selected.contains).map(\.displayName), forKey: Self.key)
    }
}

/// HxD's "Generate checksums" dialog.
struct ChecksumSheet: View {
    @Bindable var model: ChecksumModel
    let session: EditorSession

    var body: some View {
        SheetScaffold(title: "Generate Checksums", confirmTitle: "Calculate", canConfirm: !model.algorithms.isEmpty,
                      onCancel: session.closeSheet, onConfirm: run) {
            HStack(alignment: .top, spacing: 28) {
                group("Sums", [.checksum8, .checksum16, .checksum32, .checksum64]) {
                    Toggle("Custom…", isOn: $model.useCustomChecksum)
                }
                group("CRC", [.crc16, .crc16CCITTFalse, .crc32, .crc32C]) {
                    Toggle("Custom CRC…", isOn: $model.useCustomCRC)
                }
                group("Digests", [.md2, .md4, .md5, .sha1, .sha256, .sha384, .sha512]) { EmptyView() }
            }
            if model.useCustomChecksum || model.useCustomCRC {
                HStack(alignment: .top, spacing: 28) {
                    if model.useCustomChecksum { customChecksumOptions }
                    if model.useCustomCRC { customCRCOptions }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Text("Scope")
                Picker("Scope", selection: $model.selectionOnly) {
                    Text("Whole file").tag(false)
                    Text("Selection").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(session.selection.isEmpty)
            }
            HStack(spacing: 8) {
                Toggle("Compare with expected value", isOn: $model.compare)
                TextField("Expected checksum", text: $model.expected)
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .disabled(!model.compare)
            }
        }
    }

    private func group(_ title: LocalizedStringKey, _ algorithms: [ChecksumAlgorithm],
                       @ViewBuilder extra: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            ForEach(algorithms, id: \.self) { algorithm in
                Toggle(algorithm.displayName, isOn: Binding {
                    model.selected.contains(algorithm)
                } set: { on in
                    if on { model.selected.insert(algorithm) } else { model.selected.remove(algorithm) }
                })
            }
            extra()
        }
    }

    private var customChecksumOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Custom checksum").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Result width:")
                    widthPicker($model.customChecksum.resultWidth, CustomChecksumParameters.dialogWidths)
                }
                GridRow {
                    Text("Addend width:")
                    widthPicker($model.customChecksum.addendWidth, CustomChecksumParameters.dialogWidths)
                }
                GridRow {
                    Text("Byte order:")
                    Picker("Byte order", selection: $model.customChecksum.byteOrder) {
                        Text("Little endian").tag(CustomChecksumParameters.ByteOrder.littleEndian)
                        Text("Big endian").tag(CustomChecksumParameters.ByteOrder.bigEndian)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .controlSize(.small)
        }
    }

    private var customCRCOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Custom CRC").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Bit width:")
                    widthPicker($model.crcWidth, CRCParameters.dialogWidths)
                }
                GridRow { Text("Polynomial:"); NumberField(title: "Polynomial", input: model.crcPolynomial) }
                GridRow { Text("Initial value:"); NumberField(title: "Initial value", input: model.crcInitial) }
                GridRow { Text("Output XOR:"); NumberField(title: "Output XOR", input: model.crcFinalXOR) }
                GridRow {
                    Text("Reflection:")
                    HStack {
                        Toggle("Input", isOn: $model.crcReflectInput)
                        Toggle("Output", isOn: $model.crcReflectOutput)
                    }
                }
            }
            .controlSize(.small)
        }
    }

    private func widthPicker(_ selection: Binding<Int>, _ widths: [Int]) -> some View {
        Picker("Width", selection: selection) {
            ForEach(widths, id: \.self) { Text(L("%lld bits", $0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func run() {
        model.remember()
        let range = model.selectionOnly && !session.selection.isEmpty ? session.selection.range : 0..<session.length
        session.expectedChecksum = model.compare ? model.expected : ""
        session.closeSheet()
        session.computeChecksums(model.algorithms, range: range)
    }
}

/// The Checksums pane of the results drawer.
struct ChecksumsPane: View {
    @Bindable var session: EditorSession

    var body: some View {
        Table(session.checksumResults, selection: $session.checksumSelection) {
            TableColumn("") { entry in status(entry) }
                .width(18)
            TableColumn("Algorithm") { entry in Text(verbatim: entry.name) }
                .width(min: 90, ideal: 130)
            TableColumn("Checksum") { entry in
                Text(verbatim: entry.result.hexString)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            .width(min: 120, ideal: 300)
            TableColumn("Usage") { entry in Text(verbatim: entry.scope).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: ChecksumEntry.ID.self) { ids in
            Button("Copy") { session.copyChecksums(ids, detailed: false) }
            Button("Copy with Details") { session.copyChecksums(ids, detailed: true) }
            Divider()
            Button("Delete") { session.deleteChecksums(ids) }
        }
        .onDeleteCommand { session.deleteChecksums(session.checksumSelection) }
        .onCopyCommand {
            session.copyChecksums(session.checksumSelection, detailed: false)
            return []
        }
        .overlay {
            if session.checksumResults.isEmpty {
                ContentUnavailableView {
                    Label("No Checksums", systemImage: "number")
                } description: {
                    Text("Choose Analysis ▸ Checksums… to calculate checksums of the file or the selection.")
                }
            }
        }
    }

    @ViewBuilder
    private func status(_ entry: ChecksumEntry) -> some View {
        if session.expectedChecksum.isEmpty {
            Image(systemName: "number").foregroundStyle(.secondary)
        } else if entry.result.matches(session.expectedChecksum) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Matches the expected result")
        } else {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Differs from the expected result")
        }
    }
}

/// Expected value and Refresh, shown in the drawer header while the Checksums pane is open.
struct ChecksumsPaneAccessory: View {
    @Bindable var session: EditorSession

    var body: some View {
        // A text field counts with its ideal width towards the window's minimum, so pick a
        // width that fits rather than let the field widen the window.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { expected(width: 240); refresh }
            HStack(spacing: 8) { expected(width: 140); refresh }
            refresh
        }
    }

    private func expected(width: CGFloat) -> some View {
        TextField("Expected result", text: $session.expectedChecksum)
            .font(.callout.monospaced())
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .help("Compare every checksum with this value")
    }

    private var refresh: some View {
        Button("Refresh", action: session.refreshChecksums)
            .disabled(session.checksumResults.isEmpty || session.jobs.isBusy)
    }
}
