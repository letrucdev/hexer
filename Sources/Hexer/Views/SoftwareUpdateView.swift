import AppKit
import HexerCore
import SwiftUI

/// The Software Update window: one window whose content follows `SoftwareUpdate.phase`, laid
/// out like an alert (app icon, bold message, details, buttons on the right).
final class SoftwareUpdateWindowController: NSWindowController, NSWindowDelegate {
    private static var current: SoftwareUpdateWindowController?

    static var isVisible: Bool { current?.window?.isVisible == true }
    static var window: NSWindow? { current?.window }

    static func show() {
        let controller = current ?? SoftwareUpdateWindowController()
        current = controller
        if controller.window?.isVisible != true { controller.window?.centerAtContentSize() }
        controller.showWindow(nil)
    }

    /// Shows the window for an update found by an automatic check, once no modal panel (such as
    /// the Open panel at launch) is in the way.
    static func present() {
        Task {
            while NSApp.modalWindow != nil { try? await Task.sleep(for: .seconds(1)) }
            show()
        }
    }

    private init() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("Software Update")
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: SoftwareUpdateView(model: SoftwareUpdate.shared) { [weak window] in
            window?.performClose(nil)
        })
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        SoftwareUpdate.shared.dismiss()
    }
}

struct SoftwareUpdateView: View {
    @Bindable var model: SoftwareUpdate
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: 520)
    }

    private var version: String { model.currentVersion?.description ?? "" }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .checking:
            message(L("Checking for updates…"))
            ProgressView().progressViewStyle(.linear)
            buttons { Button("Cancel", action: close).keyboardShortcut(.cancelAction) }
        case .upToDate:
            message(L("Hexer is up to date"), detail: L("Version %@ is the newest version available.", version))
            buttons { Button("OK", action: close).keyboardShortcut(.defaultAction) }
        case .available(let release):
            available(release)
        case .downloading(let release, let received, let expected):
            message(L("Downloading Hexer %@…", release.version.description))
            let total = expected > 0 ? expected : release.diskImageSize
            ProgressView(value: Double(received), total: Double(max(total, max(received, 1))))
            Text(verbatim: L("%@ of %@", bytes(received), bytes(total)))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            buttons { Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction) }
        case .verifying(let release):
            message(L("Verifying Hexer %@…", release.version.description),
                    detail: L("Hexer checks the update’s signature and the app inside it before installing it."))
            ProgressView().progressViewStyle(.linear)
            buttons { Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction) }
        case .ready(let release):
            message(L("Hexer %@ is ready to install", release.version.description),
                    detail: L("Relaunch Hexer to start using it. If you keep working, the update installs when you quit Hexer."))
            if NSDocumentController.shared.hasEditedDocuments {
                Text("Before quitting, Hexer asks whether to save your changes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons {
                Button("Install on Quit", action: close).keyboardShortcut(.cancelAction)
                Button("Relaunch") { model.relaunch() }.keyboardShortcut(.defaultAction)
            }
        case .failed(let text, let release):
            message(release == nil ? L("Couldn’t check for updates") : L("Couldn’t install the update"), detail: text)
            buttons {
                if let release {
                    Button("Open Download Page") {
                        NSWorkspace.shared.open(release.pageURL)
                        close()
                    }
                }
                Button("OK", action: close).keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private func available(_ release: UpdateRelease) -> some View {
        message(L("Hexer %@ is available", release.version.description),
                detail: L("You have version %@. Hexer downloads the update, checks it and installs it when it relaunches.", version))
        let items = ReleaseNotes.items(in: release.notes, vietnamese: Bundle.main.preferredLocalizations.first == "vi")
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("What’s New").font(.callout.weight(.semibold))
                    Spacer()
                    Link("Release Notes on GitHub", destination: release.pageURL).font(.callout)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(verbatim: "•").foregroundStyle(.secondary)
                                Text(markdown(item)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            }
        }
        let problem = model.installProblem
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Button("Skip This Version") {
                model.skipThisVersion()
                close()
            }
            Spacer()
            Button("Remind Me Later", action: close).keyboardShortcut(.cancelAction)
            if problem == nil {
                Button("Install Update") { model.install() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Download…") {
                    NSWorkspace.shared.open(release.pageURL)
                    close()
                }
                .help(L("Opens the release’s page on GitHub"))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.top, 4)
    }

    private func message(_ title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(.headline)
            if let detail {
                Text(verbatim: detail)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack {
            Spacer()
            content()
        }
        .padding(.top, 4)
    }

    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    /// Inline Markdown of a changelog item (bold, code, links); plain text if it doesn't parse.
    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
