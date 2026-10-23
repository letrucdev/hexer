import AppKit
import HexerDisasm
import SwiftUI

/// About panel, third-party licenses, and a help window listing every command.
enum AboutAndHelp {
    static func showAbout() {
        let credits = NSMutableAttributedString(
            string: L("A hex editor for macOS, modelled on HxD.") + "\n" + L("Disassembly by Capstone %@ (BSD license).", Disassembler.version),
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private static var acknowledgements: NSWindowController?

    /// Shows the licenses bundled in Resources/Licenses.
    static func showAcknowledgements() {
        if let existing = acknowledgements { existing.showWindow(nil); return }
        let folder = Bundle.main.resourceURL?.appendingPathComponent("Licenses")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder ?? URL(fileURLWithPath: "/nonexistent"),
                                                                   includingPropertiesForKeys: nil)) ?? []
        var text = ""
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let body = try? String(contentsOf: file, encoding: .utf8) else { continue }
            text += "── \(file.deletingPathExtension().lastPathComponent) ──\n\n\(body)\n\n"
        }
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.string = text.isEmpty ? L("No license files were found in the app bundle.") : text
        view.textContainerInset = NSSize(width: 12, height: 12)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L("Acknowledgements")
        window.contentView = scroll
        window.center()
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        acknowledgements = controller
        controller.showWindow(nil)
    }

    private static var help: NSWindowController?

    /// A searchable list of every menu command and its shortcut, read from the menu bar so it
    /// never goes out of date.
    static func showHelp() {
        if let existing = help { existing.showWindow(nil); return }
        let model = HelpModel(entries: commandList(NSApp.mainMenu))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = L("Hexer Help")
        window.contentViewController = NSHostingController(rootView: HelpView(model: model))
        window.setContentSize(NSSize(width: 560, height: 600))
        window.center()
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        help = controller
        controller.showWindow(nil)
    }

    private static func commandList(_ menu: NSMenu?, path: String = "") -> [HelpModel.Entry] {
        guard let menu else { return [] }
        var out: [HelpModel.Entry] = []
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            let place = path.isEmpty ? item.title : "\(path) ▸ \(item.title)"
            if let sub = item.submenu {
                // The application menu's title is the app name; skip the Services list.
                if sub == NSApp.servicesMenu { continue }
                out += commandList(sub, path: path.isEmpty ? item.title : place)
            } else if item.action != nil {
                out.append(.init(menu: path, title: item.title, shortcut: shortcut(item)))
            }
        }
        return out
    }

    private static func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let m = item.keyEquivalentModifierMask
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        let key: String
        switch item.keyEquivalent.unicodeScalars.first.map({ Int($0.value) }) {
        case NSF6FunctionKey: key = "F6"
        case NSBackspaceCharacter, NSDeleteCharacter: key = "⌫"
        default: key = item.keyEquivalent.uppercased()
        }
        return s + key
    }
}

@Observable
final class HelpModel {
    struct Entry: Identifiable, Hashable {
        let id = UUID()
        let menu: String
        let title: String
        let shortcut: String
    }

    let entries: [Entry]
    var query = ""

    init(entries: [Entry]) { self.entries = entries }

    var filtered: [Entry] {
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.menu.localizedCaseInsensitiveContains(query) }
    }
}

struct HelpView: View {
    @Bindable var model: HelpModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Every command of the menu bar, with its keyboard shortcut. Hexer follows HxD: edit in the hex or text column (Tab switches), Insert/Overwrite with ⌘I, and the inspector decodes the bytes at the caret.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Search commands", text: $model.query)
                .textFieldStyle(.roundedBorder)
            Table(model.filtered) {
                TableColumn("Menu") { Text(verbatim: $0.menu).foregroundStyle(.secondary) }.width(min: 80, ideal: 130)
                TableColumn("Command") { Text(verbatim: $0.title) }.width(min: 120, ideal: 240)
                TableColumn("Shortcut") { Text(verbatim: $0.shortcut).font(.body.monospaced()) }.width(min: 60, ideal: 90)
            }
        }
        .padding(16)
    }
}
