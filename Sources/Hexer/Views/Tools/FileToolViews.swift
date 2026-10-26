import AppKit
import HexerCore
import SwiftUI
import UniformTypeIdentifiers

/// A small window for a Tools command that works on files rather than on a document.
final class ToolWindowController: NSWindowController, NSWindowDelegate {
    private static var openWindows: [ToolWindowController] = []
    let jobs = JobCenter()

    private init(title: String) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func show(_ title: String, @ViewBuilder content: (ToolWindowController) -> some View) {
        let controller = ToolWindowController(title: title)
        let host = NSHostingController(rootView: content(controller))
        host.sizingOptions = [.preferredContentSize]
        controller.window?.contentViewController = host
        controller.window?.centerAtContentSize()
        openWindows.append(controller)
        controller.showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        jobs.cancelAll()
        Self.openWindows.removeAll { $0 === self }
    }

    /// Runs a file operation with progress in this window; closes it when done.
    func run(_ title: String, _ work: @escaping @Sendable (JobContext) throws -> Void, cleanup: @escaping () -> Void = {}) {
        Task {
            do {
                if try await jobs.run(title, work) == nil { cleanup() } else { close() }
            } catch is CancellationError {
                cleanup()
            } catch {
                cleanup()
                if let window { _ = await NSAlert(error: error.localizedForDisplay).beginSheetModal(for: window) }
            }
        }
    }
}

/// Buttons and progress at the bottom of a tool window.
struct ToolFooter: View {
    let controller: ToolWindowController
    let confirmTitle: LocalizedStringKey
    let canConfirm: Bool
    let confirm: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let job = controller.jobs.jobs.first {
                ProgressView(value: job.progress).frame(width: 180)
                Text(job.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Stop", action: controller.jobs.cancelAll)
            } else {
                Spacer()
                Button("Cancel", role: .cancel) { controller.close() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
        }
    }
}

/// A path field with a Choose… button.
struct FileField: View {
    let url: URL?
    let placeholder: LocalizedStringKey
    let choose: () -> Void

    var body: some View {
        HStack {
            Text(verbatim: url?.path(percentEncoded: false) ?? "")
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                .overlay(alignment: .leading) {
                    if url == nil { Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 6) }
                }
            Button("Choose…", action: choose)
        }
    }
}

func chooseFile(_ message: String) -> URL? {
    let panel = NSOpenPanel()
    panel.message = message
    return panel.runModal() == .OK ? panel.url : nil
}

func chooseSaveLocation(_ message: String, name: String) -> URL? {
    let panel = NSSavePanel()
    panel.message = message
    panel.nameFieldStringValue = name
    return panel.runModal() == .OK ? panel.url : nil
}

private func fileSize(_ url: URL?) -> UInt64? {
    (url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber })?.uint64Value
}

// MARK: Split

@Observable
final class SplitModel {
    var source: URL? { didSet { if let source { base = source } } }
    /// Parts are named `<base>.001`, `<base>.002`, …
    var base: URL?
    /// Index into `FileTools.splitPresets`, or nil for a custom size.
    var preset: Int? = 1
    let customSize = NumberInput(1 << 20, base: .decimal)
    var askForNames = false

    var partSize: UInt64? { preset.map { FileTools.splitPresets[$0].size } ?? customSize.value }

    var partCount: Int? {
        guard let size = fileSize(source), let part = partSize, part > 0 else { return nil }
        return FileTools.partCount(length: size, partSize: part)
    }
}

struct SplitFileView: View {
    @Bindable var model: SplitModel
    let controller: ToolWindowController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    Text("File:").gridColumnAlignment(.trailing)
                    FileField(url: model.source, placeholder: "Choose the file to split") {
                        model.source = chooseFile(L("Choose the file to split.")) ?? model.source
                    }
                }
                GridRow {
                    Text("Part base name:")
                    FileField(url: model.base, placeholder: "Same as the file") {
                        model.base = chooseSaveLocation(L("Parts are named after this, with .001, .002, … appended."),
                                                        name: model.source?.lastPathComponent ?? "") ?? model.base
                    }
                }
                GridRow {
                    Text("Part size:")
                    HStack {
                        Picker("Part size", selection: $model.preset) {
                            ForEach(FileTools.splitPresets.indices, id: \.self) { i in
                                Text(verbatim: FileTools.splitPresets[i].name).tag(Optional(i))
                            }
                            Divider()
                            Text("Custom").tag(Int?.none)
                        }
                        .labelsHidden()
                        .fixedSize()
                        if model.preset == nil {
                            NumberField(title: "Bytes", input: model.customSize).frame(width: 140)
                            Text("bytes").foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow(alignment: .top) {
                    Text("Naming:")
                    Picker("Naming", selection: $model.askForNames) {
                        Text("Number consecutively (.001, .002…)").tag(false)
                        Text("Ask for each name").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(verbatim: model.partCount.map { L("Creates %lld parts.", $0) } ?? " ")
                        .foregroundStyle(.secondary)
                }
            }
            ToolFooter(controller: controller, confirmTitle: "Split", canConfirm: (model.partCount ?? 0) > 0, confirm: split)
        }
        .padding(20)
        .frame(width: 600)
    }

    private func split() {
        guard let source = model.source, let size = model.partSize, let count = model.partCount else { return }
        var parts = FileTools.partURLs(base: model.base ?? source, count: count)
        if model.askForNames {
            var chosen: [URL] = []
            for (i, url) in parts.enumerated() {
                guard let u = chooseSaveLocation(L("Name of part %lld of %lld", i + 1, count), name: url.lastPathComponent) else { return }
                chosen.append(u)
            }
            parts = chosen
        }
        let partURLs = parts
        controller.run(L("Splitting")) { job in
            try FileTools.split(source, partSize: size, to: partURLs, isCancelled: { job.isCancelled }, progress: job.report)
        }
    }
}

// MARK: Concatenate

@Observable
final class ConcatenateModel {
    var files: [URL] = []
    var selection: Set<URL> = []
    var output: URL?
}

struct ConcatenateFilesView: View {
    @Bindable var model: ConcatenateModel
    let controller: ToolWindowController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List(selection: $model.selection) {
                ForEach(Array(model.files.enumerated()), id: \.element) { index, url in
                    HStack {
                        Text(verbatim: "\(index + 1)").foregroundStyle(.secondary).monospacedDigit().frame(width: 24, alignment: .trailing)
                        Text(verbatim: url.lastPathComponent)
                        Spacer()
                        Text(verbatim: fileSize(url).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "")
                            .foregroundStyle(.secondary)
                    }
                    .tag(url)
                }
                .onMove { model.files.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered)
            .frame(height: 200)
            HStack {
                Button("Add…", action: add)
                Button("Remove") { model.files.removeAll { model.selection.contains($0) } }
                    .disabled(model.selection.isEmpty)
                Button("Clear") { model.files.removeAll() }
                    .disabled(model.files.isEmpty)
                Spacer()
                Text("Drag to reorder").font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            HStack {
                Text("Output file:")
                FileField(url: model.output, placeholder: "Choose where to save") {
                    model.output = chooseSaveLocation(L("Save the joined file as:"), name: model.files.first?.deletingPathExtension().lastPathComponent ?? "") ?? model.output
                }
            }
            ToolFooter(controller: controller, confirmTitle: "Concatenate",
                       canConfirm: model.files.count >= 2 && model.output != nil, confirm: concatenate)
        }
        .padding(20)
        .frame(width: 600)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.message = L("Choose the files to join, in order.")
        guard panel.runModal() == .OK else { return }
        model.files += panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func concatenate() {
        guard let output = model.output else { return }
        let files = model.files
        controller.run(L("Concatenating")) { job in
            try FileTools.concatenate(files, to: output, isCancelled: { job.isCancelled }, progress: job.report)
        }
    }
}

// MARK: Wipe

@Observable
final class WipeModel {
    enum Method: Hashable { case dod, zero, random }

    var file: URL?
    var method: Method = .dod

    var passes: [Generator] {
        switch method {
        case .dod: [.pattern([0x00]), .pattern([0xFF]), .random(seed: .random(in: 0...UInt64.max), min: 0, max: 255)]
        case .zero: [.pattern([0x00])]
        case .random: [.random(seed: .random(in: 0...UInt64.max), min: 0, max: 255)]
        }
    }
}

struct WipeFileView: View {
    @Bindable var model: WipeModel
    let controller: ToolWindowController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    Text("File:").gridColumnAlignment(.trailing)
                    FileField(url: model.file, placeholder: "Choose the file to wipe") {
                        model.file = chooseFile(L("Choose the file to overwrite and delete.")) ?? model.file
                    }
                }
                GridRow(alignment: .top) {
                    Text("Method:")
                    Picker("Method", selection: $model.method) {
                        Text("DoD 5220.22-M (3 passes)").tag(WipeModel.Method.dod)
                        Text("Zero bytes (1 pass)").tag(WipeModel.Method.zero)
                        Text("Random bytes (1 pass)").tag(WipeModel.Method.random)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }
            Label("On SSDs and APFS, copies of the data may remain (copy-on-write, snapshots, wear levelling). Use FileVault for guaranteed protection.",
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ToolFooter(controller: controller, confirmTitle: "Wipe and Delete", canConfirm: model.file != nil, confirm: wipe)
        }
        .padding(20)
        .frame(width: 600)
    }

    private func wipe() {
        guard let file = model.file else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L("Wipe “%@”?", file.lastPathComponent)
        alert.informativeText = L("The file is overwritten and deleted. It cannot be recovered.")
        alert.addDestructiveButton(withTitle: L("Wipe and Delete"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Close any window showing the file first, so nothing writes it back.
        if let doc = NSDocumentController.shared.document(for: file) { doc.close() }
        // Like HxD, the wiped file leaves the recent disk images. (The system's Open Recent hides
        // files that are gone by itself.)
        RecentDiskImagesMenu.shared.remove(file)
        let passes = model.passes
        controller.run(L("Wiping")) { job in
            try FileTools.wipe(file, passes: passes, isCancelled: { job.isCancelled }, progress: job.report)
        }
    }
}
