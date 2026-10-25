import AppKit
import HexerCore
import HexerPlatform

/// Launch arguments for scripted testing and screenshots, e.g.
/// `Hexer file.bin -HexerGoTo 0x100 -HexerAction goToOffset: -HexerSnapshot /tmp/shot.png -HexerQuit 1`.
///
/// AppKit reads `-Key value` pairs into the argument defaults domain and opens leftover words as
/// files, so flags must be followed by a value (any, e.g. `1`) unless they come last.
enum DebugLaunchArguments {
    /// Whether any `-Hexer…` flag was given.
    static var isScripted: Bool { ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-Hexer") } }

    /// `-HexerUpdateFeed URL`: the update manifest to check instead of the app's feeds (HTTPS, or a
    /// file whose releases may point at local files). Updates are still verified with the key in
    /// Info.plist.
    static var updateFeed: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-HexerUpdateFeed"), i + 1 < args.count,
              let url = URL(string: args[i + 1]), ["https", "file"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }

    static func apply() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func flag(_ name: String) -> Bool { args.contains(name) }
        // -HexerAppearance light|dark renders the app in one appearance whatever the system uses.
        switch value("-HexerAppearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        keepsShadow = flag("-HexerSnapshotShadow")
        // Positional file arguments when launched directly (not through Launch Services).
        let files = args.dropFirst().enumerated().filter { i, a in
            !a.hasPrefix("-") && (i == 0 || !args[i].hasPrefix("-Hexer") && !args[i].hasPrefix("-Apple"))
        }.map(\.element).filter { FileManager.default.fileExists(atPath: $0) }
        if let shot = value("-HexerAlertSnapshot") { captureNextAlert(to: URL(fileURLWithPath: shot)) }
        if value("-HexerUpdatePreview") != nil || flag("-HexerUpdateCheck") {
            // The Software Update window. -HexerUpdatePreview checking|upToDate|available|downloading|
            // verifying|ready|failed shows that phase with a sample release. -HexerUpdateCheck 1 checks
            // the feed (-HexerUpdateFeed), -HexerUpdateInstall 1 installs what it finds and
            // -HexerUpdateRelaunch 1 relaunches once it's ready. Phases are printed as they change.
            Task { @MainActor in
                let update = SoftwareUpdate.shared
                Task { @MainActor in
                    var last = ""
                    while true {
                        let now = String(describing: update.phase)
                        if now != last { print("HexerUpdatePhase \(now)") }
                        last = now
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                @MainActor func wait(until done: @MainActor () -> Bool) async {
                    for _ in 0..<600 where !done() { try? await Task.sleep(for: .milliseconds(100)) }
                }
                if let name = value("-HexerUpdatePreview") {
                    update.preview(previewPhase(name))
                    SoftwareUpdateWindowController.show()
                } else {
                    update.checkForUpdates()
                    if flag("-HexerUpdateInstall") {
                        await wait { if case .available = update.phase { true } else { false } }
                        update.install()
                        await wait { if case .ready = update.phase { true } else if case .failed = update.phase { true } else { false } }
                        if flag("-HexerUpdateRelaunch"), case .ready = update.phase { update.relaunch() }
                    }
                }
                if let shot = value("-HexerSnapshot"), let window = SoftwareUpdateWindowController.window {
                    try? await Task.sleep(for: .seconds(value("-HexerSnapshotDelay").flatMap(Double.init) ?? 1.5))
                    print("HexerWindowID \(window.windowNumber)")
                    snapshot(window, to: URL(fileURLWithPath: shot))
                }
                if flag("-HexerQuit") { NSApp.terminate(nil) }
            }
            return
        }
        if let page = value("-HexerWelcome").flatMap(Int.init) {
            // The welcome tour at page n (from 0), leaving the first-launch one to come. -HexerWelcomeTour s
            // turns a page every s seconds; -HexerSnapshot captures it once the page has settled.
            // -HexerWelcomeEnd skip|open|close ends it as the buttons or the close button would, as if
            // it had been shown at launch.
            Task { @MainActor in
                let end = value("-HexerWelcomeEnd")
                WelcomeWindowController.show(page: page, atLaunch: end != nil, marksShown: false)
                if let step = value("-HexerWelcomeTour").flatMap(Double.init) {
                    for next in (page + 1)..<WelcomeModel.pageCount {
                        try? await Task.sleep(for: .seconds(step))
                        WelcomeWindowController.show(page: next, marksShown: false)
                    }
                    try? await Task.sleep(for: .seconds(step))
                }
                if let shot = value("-HexerSnapshot"), let window = WelcomeWindowController.window {
                    try? await Task.sleep(for: .seconds(value("-HexerSnapshotDelay").flatMap(Double.init) ?? 2.5))
                    print("HexerWindowID \(window.windowNumber)")
                    snapshot(window, to: URL(fileURLWithPath: shot))
                }
                if let end, let window = WelcomeWindowController.window {
                    try? await Task.sleep(for: .seconds(1.5))
                    switch end {
                    case "skip": WelcomeWindowController.model?.onFinish(false)
                    case "open": WelcomeWindowController.model?.onFinish(true)
                    default: window.performClose(nil)
                    }
                }
                if flag("-HexerQuit") { NSApp.terminate(nil) }
            }
            return
        }
        if let name = value("-HexerOpenDisk") {
            // Opens a raw disk read-only (e.g. an attached test image), then snapshots it.
            // -HexerOpenDiskWritable asks for write access, but only on disk images.
            Task { @MainActor in
                guard let info = DiskEnumerator.disk(bsdName: name) else { return }
                let readOnly = !(flag("-HexerOpenDiskWritable") && info.isDiskImage)
                do { try await DiskOpening.open(info, readOnly: readOnly) } catch { print("open disk failed: \(error)") }
                if let shot = value("-HexerSnapshot"), let window = NSApp.orderedWindows.first(where: \.isVisible) {
                    try? await Task.sleep(for: .milliseconds(1500))
                    snapshot(window, to: URL(fileURLWithPath: shot))
                }
                if flag("-HexerQuit") { NSApp.terminate(nil) }
            }
            return
        }
        if let path = value("-HexerImport") {
            // Imports open as untitled documents; nothing else is scripted for them.
            Task { @MainActor in
                let url = URL(fileURLWithPath: path)
                guard let data = try? Data(contentsOf: url), let format = RecordImporter.detectFormat(data),
                      let image = try? RecordImporter.importRecords(data, format: format) else { return }
                let document = HexDocument(imported: image.makeBuffer(), name: url.deletingPathExtension().lastPathComponent)
                NSDocumentController.shared.addDocument(document)
                document.makeWindowControllers()
                document.showWindows()
                if let size = value("-HexerWindowSize")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                    document.windowControllers.first?.window?.setContentSize(NSSize(width: size[0], height: size[1]))
                }
                try? await Task.sleep(for: .milliseconds(300))
                if let go = value("-HexerGoTo"), let s = document.session {
                    s.setSelection(Selection(caret: NumberBase.hexadecimal.parse(go) ?? 0))
                }
                if let action = value("-HexerAction") { NSApp.sendAction(Selector(action), to: nil, from: nil) }
                if let shot = value("-HexerSnapshot"), let window = document.windowControllers.first?.window {
                    try? await Task.sleep(for: .milliseconds(1200))
                    snapshot(window, to: URL(fileURLWithPath: shot))
                }
                if flag("-HexerQuit") { NSApp.terminate(nil) }
            }
            return
        }
        guard !files.isEmpty || value("-HexerSnapshot") != nil else { return }

        Task { @MainActor in
            // AppKit opens file paths given on the command line by itself; open only files it
            // has not opened by now, so a file never gets two windows.
            let controller = NSDocumentController.shared
            let urls = files.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
            for _ in 0..<20 where urls.contains(where: { controller.document(for: $0) == nil }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            for url in urls where controller.document(for: url) == nil {
                _ = try? await controller.openDocument(withContentsOf: url, display: true)
            }
            try? await Task.sleep(for: .milliseconds(400))
            guard let doc = (urls.last.flatMap { controller.document(for: $0) } ?? controller.documents.last) as? HexDocument
            else { return }
            let s = doc.session!
            if let n = value("-HexerBytesPerRow").flatMap(Int.init) { s.bytesPerRow = n }
            if let n = value("-HexerSectorSize").flatMap(Int.init) { s.sectorSize = n }
            if let size = value("-HexerWindowSize")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
               let window = doc.windowControllers.first?.window {
                window.setContentSize(NSSize(width: size[0], height: size[1]))
            }
            if let e = value("-HexerEncoding").flatMap(TextEncoding.init(rawValue:)) { s.encoding = e }
            if let m = value("-HexerMode").flatMap(EditMode.init(rawValue:)) { s.mode = m }
            if flag("-HexerHideInspector") { s.showInspector = false }
            if let pane = value("-HexerDrawer").flatMap(DrawerPane.init(rawValue:)) { s.drawerPane = pane }
            if let go = value("-HexerGoTo") {
                let offset = go == "end" ? s.length : (NumberBase.hexadecimal.parse(go) ?? 0)
                s.setSelection(Selection(caret: offset))
            }
            if let sel = value("-HexerSelect")?.split(separator: "-"), sel.count == 2,
               let a = NumberBase.hexadecimal.parse(String(sel[0])), let b = NumberBase.hexadecimal.parse(String(sel[1])) {
                s.setSelection(Selection(anchor: a, caret: b))
            }
            if let names = value("-HexerChecksums")?.split(separator: ",").map(String.init) {
                s.expectedChecksum = value("-HexerExpected") ?? ""
                s.computeChecksums(ChecksumAlgorithm.standard.filter { names.contains($0.displayName) }, range: 0..<s.length)
                try? await Task.sleep(for: .milliseconds(200))
                while s.jobs.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
            }
            if let pattern = value("-HexerFind") {
                if let type = value("-HexerFindType").flatMap(SearchQuery.DataType.init(rawValue:)) { s.find.query.dataType = type }
                s.find.query.pattern = pattern
                if let replacement = value("-HexerReplace") {
                    s.find.replacement = replacement
                    s.find.showsReplace = true
                }
                s.showFind(replace: false)
                if flag("-HexerReplaceAll") {
                    s.find.promptOnReplace = false
                    s.sizeChangeConfirmed = true
                    s.replaceAll()
                } else if flag("-HexerFindAll") {
                    s.findAll()
                } else {
                    s.findNext()
                }
                try? await Task.sleep(for: .milliseconds(200))
                while s.jobs.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
                if flag("-HexerFindAll") {
                    let index = value("-HexerFindAllSelect").flatMap(Int.init) ?? 2
                    s.searchResultSelection = s.searchHits.dropFirst(index).first?.id
                }
            }
            if let tag = value("-HexerCopyAs").flatMap(Int.init).flatMap(ExportFormat.init(rawValue:)) {
                s.copyAs(tag)
            }
            if flag("-HexerCompare") {
                let docs = controller.documents.compactMap { $0 as? HexDocument }
                if docs.count >= 2 {
                    let (a, b) = (docs[0].session!, docs[1].session!)
                    CompareSession.start(a, 0..<a.length, b, 0..<b.length, vertical: true)
                    try? await Task.sleep(for: .milliseconds(600))
                    if flag("-HexerCompareList") {
                        a.drawerPane = .compare; b.drawerPane = .compare
                        a.compare?.listDifferences(using: a)
                        try? await Task.sleep(for: .milliseconds(300))
                        while a.jobs.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
                    }
                    for _ in 0..<(value("-HexerCompareSteps").flatMap(Int.init) ?? 1) {
                        a.compare?.step(from: a, backward: false)
                        try? await Task.sleep(for: .milliseconds(300))
                        while a.jobs.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
                    }
                }
            }
            if let pdf = value("-HexerPrintPDF") {
                let settings: [NSPrintInfo.AttributeKey: Any] = [.jobDisposition: NSPrintInfo.JobDisposition.save,
                                                                  .jobSavingURL: URL(fileURLWithPath: pdf)]
                if let operation = try? doc.printOperation(withSettings: settings) {
                    operation.showsPrintPanel = false
                    operation.showsProgressPanel = false
                    operation.run()
                }
            }
            if flag("-HexerSave") {
                s.sizeChangeConfirmed = true
                doc.save(nil)
                try? await Task.sleep(for: .milliseconds(500))
            }
            if flag("-HexerUndoAll") {
                // History must still read the bytes of the file as it was before saving.
                while s.canUndo { s.undo() }
                doc.save(nil)
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let pane = value("-HexerSettingsPane").flatMap(Int.init) {
                AppDelegate.openSettings(pane: pane)
            }
            if let action = value("-HexerAction"), let window = doc.windowControllers.first?.window {
                // The app may not be active yet, so walk this window's responder chain directly.
                window.makeKeyAndOrderFront(nil)
                if window.firstResponder?.tryToPerform(Selector(action), with: nil) != true {
                    NSApp.sendAction(Selector(action), to: nil, from: nil)
                }
            }
            if let path = value("-HexerSnapshot") {
                try? await Task.sleep(for: .milliseconds(800))
                // An action may have opened another window (e.g. Statistics); capture the frontmost.
                let opensWindow = value("-HexerAction") != nil || value("-HexerSettingsPane") != nil
                let front = opensWindow ? NSApp.orderedWindows.first { $0.isVisible && $0.sheetParent == nil } : nil
                if let window = front ?? doc.windowControllers.first?.window {
                    print("HexerWindowID \(window.windowNumber)")
                    snapshot(window, to: URL(fileURLWithPath: path))
                }
            }
            if flag("-HexerQuit") {
                if let window = doc.windowControllers.first?.window, let sheet = window.attachedSheet {
                    window.endSheet(sheet)
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// A phase of the Software Update window with a sample release (version 0.3.0).
    private static func previewPhase(_ name: String) -> SoftwareUpdate.Phase {
        let notes = """
            ## What's new
            - Hexer looks for a new version once a day and installs it when you agree. Choose Hexer ▸ Check for Updates… to look now.
            - The General pane of Settings has a Software Update section: turn off the daily check, or include beta versions.

            ## Có gì mới
            - Hexer tìm phiên bản mới mỗi ngày một lần và cài khi bạn đồng ý. Chọn Hexer ▸ Kiểm tra cập nhật… để tìm ngay.
            - Mục Cài đặt ▸ Chung có thêm phần Cập nhật phần mềm: tắt việc kiểm tra hằng ngày, hoặc nhận cả bản thử nghiệm.
            """
        let release = UpdateRelease(version: AppVersion("0.3.0")!, notes: notes,
                                    pageURL: URL(string: "https://github.com/letrucdev/hexer/releases/tag/v0.3.0")!,
                                    diskImageURLs: [URL(string: "https://github.com/letrucdev/hexer/releases/download/v0.3.0/Hexer-0.3.0.dmg")!],
                                    diskImageSize: 6_900_000, signature: "", isPrerelease: false)
        switch name {
        case "checking": return .checking
        case "upToDate": return .upToDate
        case "downloading": return .downloading(release, received: 2_480_000, expected: 6_900_000)
        case "verifying": return .verifying(release)
        case "ready": return .ready(release)
        case "failed": return .failed(UpdateError.badSignature.displayMessage, release: release)
        case "failedCheck": return .failed(UpdateError.rateLimited.displayMessage, release: nil)
        default: return .available(release)
        }
    }

    /// Captures the next modal alert once it has finished appearing, then dismisses it as if cancelled.
    static func captureNextAlert(to url: URL) {
        nonisolated(unsafe) var ticksVisible = 0
        let timer = Timer(timeInterval: 0.4, repeats: true) { timer in
            let done = MainActor.assumeIsolated {
                guard let window = NSApp.modalWindow, window.isVisible else { return false }
                ticksVisible += 1
                guard ticksVisible > 1 else { return false }
                print("HexerWindowID \(window.windowNumber)")
                // Which button answers Return and which Escape, as the screenshot can't show it. While
                // the alert runs, Return belongs to the window's default button cell, not a key equivalent.
                @MainActor func buttons(in view: NSView) -> [NSButton] {
                    view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) }
                }
                for button in buttons(in: window.contentView ?? NSView()) where !button.title.isEmpty {
                    let key = window.defaultButtonCell === button.cell ? "Return" : button.keyEquivalent == "\u{1b}" ? "Escape" : "none"
                    print("HexerAlertButton \(button.title) key=\(key) destructive=\(button.hasDestructiveAction)")
                }
                snapshot(window, to: url)
                NSApp.abortModal()
                return true
            }
            if done { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// -HexerSnapshotShadow keeps the window's shadow (on a transparent background) in snapshots.
    private static var keepsShadow = false

    /// Captures the window as it appears on screen, glass included. Needs Screen Recording
    /// permission for the app or the terminal that launched it.
    static func snapshot(_ window: NSWindow, to url: URL) {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // A sheet is a window of its own; capture it alone (never a screen area, which could
        // include other apps' windows).
        let target = window.attachedSheet ?? window
        capture.arguments = (keepsShadow ? ["-x"] : ["-x", "-o"]) + ["-l", String(target.windowNumber), url.path]
        do {
            try capture.run()
            capture.waitUntilExit()
        } catch {}
        if capture.terminationStatus != 0 {
            FileHandle.standardError.write(Data("Snapshot failed; grant Screen Recording permission in System Settings.\n".utf8))
        }
    }
}
