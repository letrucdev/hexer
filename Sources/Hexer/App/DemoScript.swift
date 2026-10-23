import AppKit
import HexerCore
import SwiftUI

/// Window frames (points from the top-left corner) of a few SwiftUI controls, recorded only while
/// the demo runs so its pointer can aim at them.
@MainActor
enum DemoAnchors {
    static var isRecording = false
    static var frames: [String: CGRect] = [:]
}

extension View {
    func demoAnchor(_ name: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            if DemoAnchors.isRecording { DemoAnchors.frames[name] = frame }
        }
    }
}

/// The scripted tour recorded for the promotional video (`Scripts/record_demo.swift`, launched as
/// `Hexer FILE -HexerDemo DIR -HexerDemoFirmware HEX`).
///
/// It drives the app through its own APIs, never synthetic system events, so the real pointer and
/// other apps are left alone. What a viewer should see — pointer moves and clicks, keys, captions,
/// camera focus — is logged with host times (`CACurrentMediaTime`, the clock of ScreenCaptureKit
/// frames) to `DIR/timeline.json`, in points from the window's top-left corner. Before starting it
/// saves clean window snapshots (`clean-dark.png`, `clean-light.png`), since a captured window shows
/// a sharing indicator over its traffic lights, then waits for `DIR/go`.
@MainActor
final class DemoScript {
    private let dir: URL
    private var window: NSWindow
    private var session: EditorSession
    private var events: [[String: Any]] = []

    private init(dir: URL, window: NSWindow, session: EditorSession) {
        self.dir = dir
        self.window = window
        self.session = session
    }

    static func run(dir: URL, document: HexDocument, firmware: URL?) async {
        guard let window = document.windowControllers.first?.window, let session = document.session else { return }
        let demo = DemoScript(dir: dir, window: window, session: session)
        await demo.prepare()
        await demo.tour(firmware: firmware)
        demo.save()
        // Quit without asking about the imported, untitled document.
        exit(0)
    }

    // MARK: Preparation

    private func prepare() async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DemoAnchors.isRecording = true
        // The real pointer may rest over the window; keep its hover effects and tooltips out.
        window.ignoresMouseEvents = true
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if let canvas = session.editorView?.canvas { window.makeFirstResponder(canvas) }
        await pause(1.2)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            await pause(0.8)
            DebugLaunchArguments.snapshot(window, to: dir.appendingPathComponent("clean-\(name).png"))
        }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("ready").path, contents: nil)
        let go = dir.appendingPathComponent("go").path
        for _ in 0..<600 where !FileManager.default.fileExists(atPath: go) { await pause(0.05) }
        await pause(0.6)
    }

    // MARK: The tour

    private func tour(firmware: URL?) async {
        log("begin", ["width": window.frame.width, "height": window.frame.height])
        place(CGPoint(x: window.frame.width * 0.58, y: window.frame.height * 0.86))
        await pause(0.4)

        caption("Inspect every byte", "Click a byte and the inspector decodes it as thirty data types.")
        await click(byte: 0x10) { self.session.setSelection(Selection(caret: 0x10)) }
        await pause(0.7)
        await click(byte: 0x48) { self.session.setSelection(Selection(caret: 0x48)) }
        await pause(1.0)

        caption("Edit in place", "Type over bytes in hex. Changes stay red until saved, and undo is unlimited.")
        focus(CGRect(x: 0, y: 40, width: window.frame.width * 0.62, height: window.frame.height * 0.45), zoom: 1.45)
        await click(byte: 0x20) { self.session.setSelection(Selection(caret: 0x20)) }
        await pause(0.3)
        var typed = ""
        for (i, digit) in "486578657221".enumerated() {
            typed += String(digit) + (i % 2 == 1 ? " " : "")
            keys(typed.trimmingCharacters(in: .whitespaces), duration: 0.6)
            session.typeHexDigit(UInt8(digit.hexDigitValue!))
            redraw()
            await pause(0.13)
        }
        await pause(1.1)
        keys("⌘Z", duration: 1.0)
        session.undo()
        redraw()
        await pause(1.2)
        focus(nil)

        caption("Find anything", "Text, hex, integers and floats. Find All lists every match.")
        keys("⌘F", duration: 0.9)
        session.find.query.dataType = .text
        session.find.query.pattern = ""
        session.showFind(replace: false)
        await pause(0.7)
        for ch in "Hexer" {
            session.find.query.pattern.append(ch)
            await pause(0.14)
        }
        await pause(0.3)
        await click(anchor: "Find All") { self.session.findAll() }
        for _ in 0..<60 where session.jobs.isBusy { await pause(0.05) }
        await pause(1.0)
        for _ in 0..<2 {
            await click(anchor: "Find navigation", x: 0.72) { self.session.findNext() }
            await pause(0.8)
        }
        await pause(0.4)

        caption("Decode values", "Switch the byte order and every type updates at once.")
        session.hideFind()
        focus(CGRect(x: window.frame.width - 340, y: 40, width: 340, height: window.frame.height * 0.6), zoom: 1.6)
        await pause(0.4)
        await click(anchor: "Byte order", x: 0.75) { UserDefaults.standard.set(false, forKey: "InspectorLittleEndian") }
        await pause(1.5)
        await click(anchor: "Byte order", x: 0.25) { UserDefaults.standard.set(true, forKey: "InspectorLittleEndian") }
        await pause(0.9)
        focus(nil)

        caption("Verify integrity", "CRC-32, MD5, SHA-1, SHA-256 and more, computed in the background.")
        await click(anchor: "Drawer tabs", x: 0.5) { self.session.drawerPane = .checksums }
        await pause(0.3)
        session.computeChecksums([.crc32, .crc32C, .md5, .sha1, .sha256, .sha512], range: 0..<session.length)
        for _ in 0..<80 where session.jobs.isBusy { await pause(0.05) }
        await pause(2.0)

        if let firmware { await firmwareTour(firmware) }

        caption("Light or dark", "A native macOS app with Liquid Glass, in English and Vietnamese.")
        await pause(0.4)
        keys("Appearance: Light", duration: 1.6)
        NSApp.appearance = NSAppearance(named: .aqua)
        log("appearance", ["value": "light"])
        await pause(2.0)
        keys("Appearance: Dark", duration: 1.4)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        log("appearance", ["value": "dark"])
        await pause(1.6)
        log("end", [:])
    }

    /// Imports the Intel Hex file into a new tab, opens a folded gap and scrolls through it.
    private func firmwareTour(_ url: URL) async {
        caption("Firmware images", "Import Intel Hex or S-Record. Gaps between records fold away.")
        keys("File ▸ Import ▸ Intel Hex…", duration: 1.4)
        await pause(0.5)
        guard let data = try? Data(contentsOf: url), let image = try? RecordImporter.importRecords(data, format: .intelHex) else { return }
        let document = HexDocument(imported: image.makeBuffer(), name: url.deletingPathExtension().lastPathComponent)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        guard let tab = document.windowControllers.first?.window, let tabSession = document.session else { return }
        tab.setFrame(window.frame, display: false)
        tab.ignoresMouseEvents = true
        window.addTabbedWindow(tab, ordered: .above)
        tab.makeKeyAndOrderFront(nil)
        window = tab
        session = tabSession
        if let canvas = session.editorView?.canvas { window.makeFirstResponder(canvas) }
        await pause(1.4)
        if let editor = session.editorView, let fold = editor.rowMap.folds.first {
            let start = fold.rows.lowerBound * editor.rowMap.bytesPerRow
            let row = Double(editor.rowMap.visualRow(of: start))
            let y = (row - editor.topRow + 0.5) * editor.metrics.rowHeight
            let x = editor.layoutInfo.hexStartX + editor.layoutInfo.charWidth * 14
            await click(at: windowPoint(editor.canvas, NSPoint(x: x, y: y))) {
                self.session.setSelection(Selection(caret: start), scroll: false)
                editor.unfold(0)
            }
            await pause(1.6)
            keys("View ▸ Fold Undefined Sections", duration: 1.4)
            session.unfoldedSections = []
            await pause(1.6)
        }
    }

    // MARK: Pointer and log

    private var pointer = CGPoint.zero

    private func log(_ type: String, _ fields: [String: Any]) {
        var event = fields
        event["type"] = type
        event["t"] = CACurrentMediaTime()
        events.append(event)
    }

    private func caption(_ title: String, _ subtitle: String) { log("caption", ["title": title, "subtitle": subtitle]) }

    private func keys(_ text: String, duration: Double) { log("keys", ["text": text, "duration": duration]) }

    /// Zooms the video onto `rect` (window points), or back to the whole window.
    private func focus(_ rect: CGRect?, zoom: Double = 1) {
        if let rect {
            log("focus", ["x": rect.midX, "y": rect.midY, "zoom": zoom])
        } else {
            log("focus", ["x": window.frame.width / 2, "y": window.frame.height / 2, "zoom": 1.0])
        }
    }

    private func place(_ p: CGPoint) {
        pointer = p
        log("move", ["x": p.x, "y": p.y, "duration": 0.0])
    }

    private func move(to p: CGPoint) async {
        let distance = hypot(p.x - pointer.x, p.y - pointer.y)
        let duration = min(0.9, max(0.35, Double(distance) / 900))
        log("move", ["x": p.x, "y": p.y, "duration": duration])
        pointer = p
        await pause(duration + 0.05)
    }

    private func click(at p: CGPoint, _ action: () -> Void) async {
        await move(to: p)
        log("click", ["x": p.x, "y": p.y])
        await pause(0.12)
        action()
        redraw()
    }

    private func click(byte offset: UInt64, _ action: () -> Void) async {
        guard let editor = session.editorView else { return action() }
        let layout = editor.layoutInfo
        let bpr = UInt64(layout.bytesPerRow)
        let row = Double(editor.rowMap.visualRow(of: offset))
        let x = layout.hexX(byte: Int(offset % bpr)) - editor.scrollX + layout.charWidth
        let y = (row - editor.topRow + 0.5) * editor.metrics.rowHeight
        await click(at: windowPoint(editor.canvas, NSPoint(x: x, y: y)), action)
    }

    /// Clicks a point of an anchored control: `x` and `y` are fractions of its frame. Just acts
    /// when the control hasn't been laid out.
    private func click(anchor name: String, x: Double = 0.5, y: Double = 0.5, _ action: () -> Void) async {
        await pause(0.1)
        guard let frame = DemoAnchors.frames[name] else { return action() }
        await click(at: CGPoint(x: frame.minX + frame.width * x, y: frame.minY + frame.height * y), action)
    }

    private func windowPoint(_ view: NSView, _ p: NSPoint) -> CGPoint {
        let w = view.convert(p, to: nil)
        return CGPoint(x: w.x, y: window.frame.height - w.y)
    }

    private func redraw() {
        session.editorView?.canvas.needsDisplay = true
        session.editorView?.header.needsDisplay = true
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private func save() {
        let data = try? JSONSerialization.data(withJSONObject: ["events": events], options: [.prettyPrinted])
        try? data?.write(to: dir.appendingPathComponent("timeline.json"))
    }
}
