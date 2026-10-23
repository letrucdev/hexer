import AppKit
import HexerCore
import HexerPlatform
import SwiftUI

extension DiskInfo {
    /// "Internal · PCI-Express", "Disk image", "MS-DOS FAT16", … for the Type column.
    var typeDescription: String {
        if isWhole {
            if isDiskImage { return L("Disk image") }
            return [isInternal ? L("Internal") : L("External"), busProtocol].compactMap { $0 }.joined(separator: " · ")
        }
        return volumeKind?.uppercased() ?? contentDescription ?? content ?? "—"
    }

    var displayTitle: String {
        volumeName.map { "\(bsdName) — \($0)" } ?? bsdName
    }

    var sizeDescription: String { ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file) }

    /// Writing anywhere on the startup disk is refused.
    var isProtected: Bool { isOnBootDisk || holdsBootVolume }
}

enum DiskOpening {
    /// Opens `info` as a document, read-only or for writing (after unmounting its volumes).
    static func open(_ info: DiskInfo, readOnly: Bool) async throws {
        var writable = !readOnly
        if writable && info.isProtected {
            let alert = NSAlert()
            alert.messageText = L("The startup disk can't be written.")
            alert.informativeText = L("%@ will open read-only.", info.bsdName)
            alert.runModal()
            writable = false
        }
        if writable && AppSettings.shared.warnDiskWriteAccess {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("Open %@ with write access?", info.displayTitle)
            alert.informativeText = info.isMounted
                ? L("Its volumes will be unmounted. Changes are written only when you save, but a mistake can destroy the data on the disk.")
                : L("Changes are written only when you save, but a mistake can destroy the data on the disk.")
            // Return keeps the safe choice; writing needs a click on the destructive button.
            alert.addButton(withTitle: L("Open Read-only"))
            alert.addDestructiveButton(withTitle: L("Open for Writing"))
            alert.addButton(withTitle: L("Cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: writable = false
            case .alertSecondButtonReturn: break
            default: throw CancellationError()
            }
        }
        // A mounted disk can't be opened for writing; its volumes have to go first.
        if writable && info.isMounted { try await DiskArbitrationSession.shared.unmount(bsdName: info.bsdName) }
        let fd = try await RawDeviceOpener.open(bsdName: info.bsdName, writable: writable)
        let document = try HexDocument(disk: info, descriptor: fd, writable: writable)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
    }
}

// MARK: Open Disk

@Observable
final class OpenDiskModel {
    var disks: [DiskInfo] = []
    var selection: DiskInfo.ID?
    var readOnly = AppSettings.shared.diskReadOnlyByDefault

    init() { refresh() }

    func refresh() {
        disks = DiskEnumerator.disks().filter { !$0.isSynthesized || !$0.isWhole }
    }

    var physical: [DiskInfo] { disks.filter(\.isWhole) }
    var logical: [DiskInfo] { disks.filter { !$0.isWhole } }
    var selected: DiskInfo? { disks.first { $0.id == selection } }
}

/// HxD's "Open disk": physical disks and logical volumes, opened read-only by default.
struct OpenDiskView: View {
    @Bindable var model: OpenDiskModel
    let controller: ToolWindowController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Table(of: DiskInfo.self, selection: $model.selection) {
                TableColumn("Name") { disk in
                    Label {
                        Text(verbatim: disk.displayTitle)
                    } icon: {
                        Image(systemName: disk.isProtected ? "lock.fill" : disk.isWhole ? "internaldrive" : "square.stack.3d.up")
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 140, ideal: 200)
                TableColumn("Type") { Text(verbatim: $0.typeDescription) }.width(min: 90, ideal: 140)
                TableColumn("Size") { Text(verbatim: $0.sizeDescription).monospacedDigit() }.width(min: 60, ideal: 80)
                TableColumn("Hardware") { Text(verbatim: $0.model ?? $0.mediaName ?? "") }.width(min: 90, ideal: 180)
            } rows: {
                Section(L("Physical disks")) { ForEach(model.physical) { TableRow($0) } }
                Section(L("Logical volumes")) { ForEach(model.logical) { TableRow($0) } }
            }
            .frame(height: 300)
            .contextMenu(forSelectionType: DiskInfo.ID.self) { _ in } primaryAction: { _ in open() }
            HStack {
                Toggle("Open as read-only", isOn: $model.readOnly)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise", action: model.refresh)
            }
            Text("Raw access may ask for an administrator password. The startup disk can't be written.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ToolFooter(controller: controller, confirmTitle: "Open", canConfirm: model.selected != nil, confirm: open)
        }
        .padding(20)
        .frame(width: 680)
    }

    private func open() {
        guard let disk = model.selected else { return }
        let readOnly = model.readOnly
        Task {
            do {
                try await DiskOpening.open(disk, readOnly: readOnly)
                controller.close()
            } catch is CancellationError {
            } catch {
                if let window = controller.window { _ = await NSAlert(error: error.localizedForDisplay).beginSheetModal(for: window) }
            }
        }
    }
}

// MARK: Clone Disk

@Observable
final class CloneDiskModel {
    enum Endpoint: Hashable { case disk(String), file }

    var disks: [DiskInfo] = DiskEnumerator.disks().filter(\.isWhole)
    var source: Endpoint?
    var sourceFile: URL?
    var target: Endpoint?
    var targetFile: URL?

    func disk(_ endpoint: Endpoint?) -> DiskInfo? {
        guard case .disk(let name) = endpoint else { return nil }
        return disks.first { $0.bsdName == name }
    }

    var isValid: Bool {
        let sourceOK = source == .file ? sourceFile != nil : disk(source) != nil
        let targetOK = target == .file ? targetFile != nil : disk(target).map { !$0.isProtected } ?? false
        return sourceOK && targetOK && !(source == target && source != .file)
    }
}

/// HxD's "Clone disk": copy a disk or disk image onto another disk or into an image file.
struct CloneDiskView: View {
    @Bindable var model: CloneDiskModel
    let controller: ToolWindowController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    Text("Source:").gridColumnAlignment(.trailing)
                    endpointPicker($model.source, file: model.sourceFile, protectedAllowed: true) {
                        model.sourceFile = chooseFile(L("Choose the disk image to copy from.")) ?? model.sourceFile
                    }
                }
                GridRow {
                    Text("Target:")
                    endpointPicker($model.target, file: model.targetFile, protectedAllowed: false) {
                        model.targetFile = chooseSaveLocation(L("Save the disk image as:"), name: "disk.img") ?? model.targetFile
                    }
                }
            }
            Label("Everything on the target is overwritten. The startup disk can't be a target.", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
            ToolFooter(controller: controller, confirmTitle: "Clone", canConfirm: model.isValid, confirm: clone)
        }
        .padding(20)
        .frame(width: 600)
    }

    private func endpointPicker(_ selection: Binding<CloneDiskModel.Endpoint?>, file: URL?, protectedAllowed: Bool,
                                chooseFile: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Disk", selection: selection) {
                Text("Choose…").tag(CloneDiskModel.Endpoint?.none)
                ForEach(model.disks) { disk in
                    Text(verbatim: "\(disk.displayTitle) · \(disk.sizeDescription) · \(disk.typeDescription)")
                        .tag(Optional(CloneDiskModel.Endpoint.disk(disk.bsdName)))
                        .disabled(!protectedAllowed && disk.isProtected)
                }
                Divider()
                Text("Disk image file").tag(Optional(CloneDiskModel.Endpoint.file))
            }
            .labelsHidden()
            if selection.wrappedValue == .file {
                FileField(url: file, placeholder: "Choose a file", choose: chooseFile)
            }
        }
    }

    private func clone() {
        guard model.isValid else { return }
        let targetDisk = model.disk(model.target)
        if let targetDisk {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = L("Overwrite %@?", targetDisk.displayTitle)
            alert.informativeText = L("All data on the disk is replaced. This cannot be undone.")
            alert.addDestructiveButton(withTitle: L("Overwrite"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let sourceDisk = model.disk(model.source)
        let sourceFile = model.sourceFile
        let targetFile = model.targetFile
        Task {
            do {
                let source: DiskByteSource
                if let sourceDisk {
                    let fd = try await RawDeviceOpener.open(bsdName: sourceDisk.bsdName, writable: false)
                    source = try DiskByteSource(descriptor: fd, path: sourceDisk.devicePath, sectorSize: sourceDisk.blockSize)
                } else {
                    source = try DiskByteSource(path: sourceFile!.path)
                }
                if let targetDisk {
                    try await DiskArbitrationSession.shared.unmount(bsdName: targetDisk.bsdName)
                    let fd = try await RawDeviceOpener.open(bsdName: targetDisk.bsdName, writable: true)
                    controller.run(L("Cloning")) { job in
                        defer { close(fd) }
                        try DiskCloner.copy(from: source, to: fd, sectorSize: targetDisk.blockSize,
                                            isCancelled: { job.isCancelled }, progress: job.report)
                    }
                } else if let targetFile {
                    controller.run(L("Cloning")) { job in
                        try DiskCloner.copy(from: source, to: targetFile, isCancelled: { job.isCancelled }, progress: job.report)
                    }
                }
            } catch {
                if let window = controller.window { _ = await NSAlert(error: error.localizedForDisplay).beginSheetModal(for: window) }
            }
        }
    }
}
