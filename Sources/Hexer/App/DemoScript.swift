import AppKit
import HexerCore
import SwiftUI

/// Frames of a few SwiftUI controls, recorded only while the demo runs so its pointer can aim at
/// them: points from the top-left corner of the SwiftUI root of the control's own window.
@MainActor
enum DemoAnchors {
    /// On from launch, so controls laid out before the tour starts are anchored too.
    static var isRecording = UserDefaults.standard.string(forKey: "HexerDemo") != nil
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
/// other apps are left alone. What a viewer should see — chapters, pointer moves and clicks, keys,
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

        await chapter("inspect", "Inspect every byte", "Click a byte and the inspector decodes it as thirty data types.")
        await click(byte: 0x10) { self.session.setSelection(Selection(caret: 0x10)) }
        await pause(1.2)
        await click(byte: 0x48) { self.session.setSelection(Selection(caret: 0x48)) }
        await pause(1.4)
        await focus(CGRect(x: window.frame.width - 340, y: 40, width: 340, height: window.frame.height * 0.6), zoom: 1.6)
        await click(anchor: "Byte order", x: 0.75) { UserDefaults.standard.set(false, forKey: "InspectorLittleEndian") }
        await pause(2.0)
        await click(anchor: "Byte order", x: 0.25) { UserDefaults.standard.set(true, forKey: "InspectorLittleEndian") }
        await pause(1.3)
        await focus(nil)

        await chapter("edit", "Edit in place", "Type over bytes in hex. Changes stay red until saved, and undo is unlimited.")
        await focus(CGRect(x: 0, y: 40, width: window.frame.width * 0.62, height: window.frame.height * 0.45), zoom: 1.45)
        await click(byte: 0x20) { self.session.setSelection(Selection(caret: 0x20)) }
        await pause(0.6)
        var typed = ""
        for (i, digit) in "486578657221".enumerated() {
            typed += String(digit) + (i % 2 == 1 ? " " : "")
            keys(typed.trimmingCharacters(in: .whitespaces), duration: 0.9, style: "typing")
            session.typeHexDigit(UInt8(digit.hexDigitValue!))
            redraw()
            await pause(0.22)
        }
        await pause(1.6)
        keys("⌘Z", duration: 1.4)
        session.undo()
        redraw()
        await pause(1.8)
        await focus(nil)

        await chapter("find", "Find anything", "Text, hex, integers and floats. Find All lists every match.")
        keys("⌘F", duration: 1.3)
        session.find.query.dataType = .text
        session.find.query.pattern = ""
        session.showFind(replace: false)
        await pause(1.0)
        for ch in "Hexer" {
            session.find.query.pattern.append(ch)
            await pause(0.22)
        }
        await pause(0.5)
        await click(anchor: "Find All") { self.session.findAll() }
        await idle()
        await pause(1.8)
        for _ in 0..<2 {
            await click(anchor: "Find navigation", x: 0.72) { self.session.findNext() }
            await pause(1.2)
        }
        await pause(0.5)

        await disassemblyTour()

        await chapter("checksums", "Verify integrity", "CRC-32, MD5, SHA-1, SHA-256 and more, computed in the background.")
        session.hideFind()
        await click(anchor: "Drawer tabs", x: 0.5) { self.session.drawerPane = .checksums }
        await pause(0.6)
        session.computeChecksums([.crc32, .crc32C, .md5, .sha1, .sha256, .sha512], range: 0..<session.length)
        await idle()
        await pause(2.8)

        await statisticsTour()

        if let firmware { await firmwareTour(firmware) }

        await chapter("appearance", "Light or dark", "A native macOS app with Liquid Glass, in English and Vietnamese.")
        keys("Appearance: Light", duration: 2.2, style: "menu")
        NSApp.appearance = NSAppearance(named: .aqua)
        log("appearance", ["value": "light"])
        await pause(2.6)
        keys("Appearance: Dark", duration: 2.0, style: "menu")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        log("appearance", ["value": "dark"])
        await pause(2.2)
        log("end", [:])
    }

    /// Switches the find bar to hex, finds an ARM64 function prologue and scrolls the inspector
    /// down to its disassembly.
    private func disassemblyTour() async {
        await chapter("disasm", "Read machine code", "Search for a byte pattern, and the inspector disassembles x86 and ARM64.")
        await click(anchor: "Find type") { self.session.find.showsOptions = true }
        await pause(1.0)
        if let popover = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.className.contains("Popover") }),
           let p = point(of: "Find data type", in: popover, x: 0.375) {
            await click(at: p) {
                self.session.find.query.dataType = .hex
                self.session.find.query.pattern = ""
            }
        } else {
            session.find.query.dataType = .hex
            session.find.query.pattern = ""
        }
        await pause(0.9)
        await click(anchor: "Find field", x: 0.3) {
            self.session.find.showsOptions = false
            self.session.find.focusRequest &+= 1
        }
        await pause(0.5)
        // stp x29, x30, [sp, #-0x10]!
        for ch in "FD 7B BF A9" {
            session.find.query.pattern.append(ch)
            await pause(ch == " " ? 0.08 : 0.2)
        }
        await pause(0.7)
        keys("↩", duration: 1.1)
        // From the top, so the first prologue in the code is found.
        session.setSelection(Selection(caret: 0), scroll: false)
        session.findNext()
        await idle()
        await pause(1.4)
        let hit = session.selection.range
        if !hit.isEmpty {
            await click(byte: hit.lowerBound) { self.session.setSelection(Selection(caret: hit.lowerBound), scroll: false) }
            await pause(0.8)
        }
        await focus(CGRect(x: window.frame.width - 340, y: window.frame.height * 0.45, width: 340, height: window.frame.height * 0.5), zoom: 1.6)
        await move(to: CGPoint(x: window.frame.width - 150, y: window.frame.height * 0.62))
        await scrollInspectorToEnd()
        await pause(2.8)
        await focus(nil)
    }

    /// Opens the Statistics window over the document, sweeps the pointer over the histogram,
    /// picks a bar and closes the window again.
    private func statisticsTour() async {
        await chapter("stats", "See the shape of your data", "A byte histogram of the file or a selection, with its entropy.")
        keys("Analysis ▸ Statistics", duration: 1.8, style: "menu")
        await pause(0.6)
        let autosave = "NSWindow Frame HexerStatisticsWindow"
        let savedFrame = UserDefaults.standard.string(forKey: autosave)
        let controller = StatisticsWindowController(session: session)
        guard let stats = controller.window else { return }
        session.statisticsWindow = controller
        let size = NSSize(width: 860, height: 500)
        stats.setFrame(NSRect(x: window.frame.midX - size.width / 2, y: window.frame.midY - size.height / 2 - 10,
                              width: size.width, height: size.height), display: false)
        stats.ignoresMouseEvents = true
        controller.showWindow(nil)
        log("window", ["frame": [stats.frame.minX - window.frame.minX, window.frame.maxY - stats.frame.maxY,
                                 stats.frame.width, stats.frame.height]])
        for _ in 0..<80 where controller.model.counts == nil { await pause(0.05) }
        await pause(1.2)
        if let counts = controller.model.counts, let plot = point(of: "Statistics plot", in: stats, x: 0, y: 0.5),
           let end = point(of: "Statistics plot", in: stats, x: 1, y: 0.5) {
            let width = end.x - plot.x
            func x(of value: Int) -> CGFloat { plot.x + width * (CGFloat(value) + 0.5) / 256 }
            // The tallest bar shown: the most frequent value is hidden.
            let hidden: Int? = controller.model.hideMaximum ? controller.model.maximum.map { Int($0.value) } : nil
            let shown: [Int] = counts.indices.filter { $0 != hidden }
            let pick = shown.max { counts[$0] < counts[$1] } ?? 0x41
            let y = plot.y + 30
            await move(to: CGPoint(x: x(of: 6), y: y))
            // Sweeps across, the way a hovering pointer lights the bars up one by one.
            await sweep(from: x(of: 6), to: x(of: 250), y: y, duration: 3.0) { controller.model.hovered = Int(($0 - plot.x) / width * 256) }
            await sweep(from: x(of: 250), to: x(of: pick), y: y, duration: 1.5) { controller.model.hovered = Int(($0 - plot.x) / width * 256) }
            await pause(0.15)
            log("click", ["x": x(of: pick), "y": y])
            await pause(0.15)
            controller.model.selected = pick
            await pause(2.4)
        }
        if let close = stats.standardWindowButton(.closeButton) {
            let frame = close.convert(close.bounds, to: nil)
            await click(at: CGPoint(x: stats.frame.minX - window.frame.minX + frame.midX,
                                    y: window.frame.maxY - stats.frame.minY - frame.midY)) { stats.performClose(nil) }
        }
        await pause(1.2)
        UserDefaults.standard.set(savedFrame, forKey: autosave)
    }

    /// Imports the Intel Hex file into a new tab, opens a folded gap and scrolls through it.
    private func firmwareTour(_ url: URL) async {
        await chapter("firmware", "Firmware images", "Import Intel Hex or S-Record. Gaps between records fold away.")
        keys("File ▸ Import ▸ Intel Hex…", duration: 1.8, style: "menu")
        await pause(0.8)
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
        await pause(1.8)
        if let editor = session.editorView, let fold = editor.rowMap.folds.first {
            let start = fold.rows.lowerBound * editor.rowMap.bytesPerRow
            let row = Double(editor.rowMap.visualRow(of: start))
            let y = (row - editor.topRow + 0.5) * editor.metrics.rowHeight
            let x = editor.layoutInfo.hexStartX + editor.layoutInfo.charWidth * 14
            await click(at: windowPoint(editor.canvas, NSPoint(x: x, y: y))) {
                self.session.setSelection(Selection(caret: start), scroll: false)
                editor.unfold(0)
            }
            await pause(2.4)
            keys("View ▸ Fold Undefined Sections", duration: 1.8, style: "menu")
            session.unfoldedSections = []
            await pause(2.2)
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

    /// Starts a chapter of the video, then leaves the app still while the video moves to it and
    /// the caption is read.
    private func chapter(_ id: String, _ title: String, _ subtitle: String) async {
        log("caption", ["id": id, "title": title, "subtitle": subtitle])
        await pause(1.4)
    }

    /// `style` is "shortcut" (keycaps), "typing" (the digits typed so far) or "menu" (a command).
    private func keys(_ text: String, duration: Double, style: String = "shortcut") {
        log("keys", ["text": text, "duration": duration, "style": style])
    }

    /// Zooms the video onto `rect` (window points), or back to the whole window, and waits while
    /// the camera moves (the video takes 1.5 s in, 1.3 s out).
    private func focus(_ rect: CGRect?, zoom: Double = 1) async {
        if let rect {
            log("focus", ["x": rect.midX, "y": rect.midY, "zoom": zoom])
        } else {
            log("focus", ["x": window.frame.width / 2, "y": window.frame.height / 2, "zoom": 1.0])
        }
        await pause(rect == nil ? 1.3 : 1.5)
    }

    private func place(_ p: CGPoint) {
        pointer = p
        log("move", ["x": p.x, "y": p.y, "duration": 0.0])
    }

    /// The video moves the pointer along a slight arc, with the speed profile of a hand
    /// (minimum jerk), so moves take their time.
    private func move(to p: CGPoint) async {
        let distance = hypot(p.x - pointer.x, p.y - pointer.y)
        let duration = min(1.3, max(0.6, Double(distance) / 600))
        log("move", ["x": p.x, "y": p.y, "duration": duration])
        pointer = p
        await pause(duration + 0.1)
    }

    /// Moves the pointer straight along a row (eased like every other move), calling `step` with its x.
    private func sweep(from x0: CGFloat, to x1: CGFloat, y: CGFloat, duration: Double, _ step: (CGFloat) -> Void) async {
        log("move", ["x": x1, "y": y, "duration": duration, "straight": true])
        let steps = Int(duration * 30)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let k = t * t * t * (t * (t * 6 - 15) + 10)
            step(x0 + (x1 - x0) * k)
            await pause(duration / Double(steps))
        }
        pointer = CGPoint(x: x1, y: y)
    }

    /// Moves, rests a moment like a hand would, then clicks.
    private func click(at p: CGPoint, _ action: () -> Void) async {
        await move(to: p)
        await pause(0.15)
        log("click", ["x": p.x, "y": p.y])
        await pause(0.15)
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
        guard let p = point(of: name, x: x, y: y) else { return action() }
        await click(at: p, action)
    }

    /// A point of an anchored control in the document window's points. Controls in another window
    /// (a popover, the Statistics window) are anchored to that window's SwiftUI root.
    private func point(of name: String, in other: NSWindow? = nil, x: Double = 0.5, y: Double = 0.5) -> CGPoint? {
        guard let frame = DemoAnchors.frames[name] else { return nil }
        let local = CGPoint(x: frame.minX + frame.width * x, y: frame.minY + frame.height * y)
        guard let other, let root = hostingView(in: other.contentView) else { return local }
        let rootFrame = other.convertToScreen(root.convert(root.bounds, to: nil))
        return CGPoint(x: rootFrame.minX + local.x - window.frame.minX, y: window.frame.maxY - (rootFrame.maxY - local.y))
    }

    private func hostingView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if String(describing: type(of: view)).contains("HostingView") { return view }
        for sub in view.subviews { if let found = hostingView(in: sub) { return found } }
        return nil
    }

    /// Scrolls the inspector's list to its end (the disassembly), animated like a trackpad scroll.
    private func scrollInspectorToEnd() async {
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        guard let content = window.contentView,
              let list = scrollViews(content).first(where: {
                  let frame = $0.convert($0.bounds, to: nil)
                  return frame.minX > window.frame.width - 400 && frame.height > 200
              }), let document = list.documentView else { return }
        log("scroll", ["duration": 1.6])
        let end = NSPoint(x: 0, y: max(0, document.frame.height - list.contentView.bounds.height))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 1.6
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                list.contentView.animator().setBoundsOrigin(document.isFlipped ? end : .zero)
            } completionHandler: {
                done.resume()
            }
        }
        list.reflectScrolledClipView(list.contentView)
    }

    private func windowPoint(_ view: NSView, _ p: NSPoint) -> CGPoint {
        let w = view.convert(p, to: nil)
        return CGPoint(x: w.x, y: window.frame.height - w.y)
    }

    private func redraw() {
        session.editorView?.canvas.needsDisplay = true
        session.editorView?.header.needsDisplay = true
    }

    /// Waits for background jobs (a search, checksums) to finish.
    private func idle() async {
        await pause(0.05)
        for _ in 0..<80 where session.jobs.isBusy { await pause(0.05) }
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private func save() {
        let data = try? JSONSerialization.data(withJSONObject: ["events": events], options: [.prettyPrinted])
        try? data?.write(to: dir.appendingPathComponent("timeline.json"))
    }
}
