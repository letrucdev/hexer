// Records the takes for the Hexer film: launches a filming copy of Hexer, drives it with real mouse
// and keyboard events at a relaxed human pace, and records Hexer's windows (and the real cursor)
// with ScreenCaptureKit. Each take writes build/film/takes/<name>.mov (HEVC with alpha) and
// <name>.json (capture geometry plus every click, key, scroll and marker on the movie's clock).
//
//   Scripts/film/make.sh record [take…]      (or: build/film/bin/record [probe] [take…])
//
// The mouse really moves while a take runs, so nobody may touch the mouse or keyboard. The driver
// stops as soon as the cursor is not where it left it, when a click would land outside Hexer, or
// when Hexer stops being the frontmost app. Keys go to Hexer's process, except typing into the hex
// grid, which has to come from the HID tap (see `Driver.Route`).
//
// Two takes are checks, not film: `keys` sends shortcuts and typing without touching the mouse,
// and `idle` records a few still seconds.

import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import CoreMedia
@preconcurrency import ScreenCaptureKit

// MARK: - Paths

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let filmDir = root.appendingPathComponent("build/film")
let takesDir = filmDir.appendingPathComponent("takes")
let samplesDir = filmDir.appendingPathComponent("samples")
let sourceApp = root.appendingPathComponent("build/Hexer.app")
let filmApp = filmDir.appendingPathComponent("Hexer.app")
let filmBundleID = "com.nongdandev.hexer.film"

struct Abort: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
func wait(_ seconds: Double) { if seconds > 0 { Thread.sleep(forTimeInterval: seconds) } }
func sleep(until t: Double) { wait(t - now()) }

@discardableResult
func shell(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Deterministic jitter, so a take is the same every time it is recorded.
struct Jitter {
    var state: UInt64 = 0x2545F4914F6CDD1D
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state % 10_000) / 10_000
    }
    mutating func around(_ x: Double, _ spread: Double) -> Double { x + (next() * 2 - 1) * spread }
}

// MARK: - Event log

struct LoggedEvent: Codable {
    var t: Double
    var kind: String            // click, key, scroll, mark
    var name: String?
    var x: Double?
    var y: Double?
    var rect: [Double]?         // global points, top-left origin
}

/// A screenshot of one of Hexer's windows taken while nothing records: during a capture macOS draws
/// a purple recording indicator over the traffic lights, and the edit covers it from these.
struct CleanShot: Codable {
    var file: String
    var tag: String
    var rect: [Double]          // global points
}

struct GridInfo: Codable {
    var canvas: [Double]        // global points
    var charWidth: Double
    var rowHeight: Double
    var bytesPerRow: Int
}

struct TakeInfo: Codable {
    var name: String
    var appearance: String
    var scale: Double
    var sourceRect: [Double]    // global points captured into the movie
    var windows: [[Double]]     // Hexer's windows when the capture started
    var duration: Double
    var frames: Int
    var dropped: Int
    var grid: GridInfo?
    var cleans: [CleanShot]
    var events: [LoggedEvent]
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [LoggedEvent] = []
    var origin: Double?
    func add(_ kind: String, _ name: String? = nil, at p: CGPoint? = nil, rect: CGRect? = nil) {
        let t = now()
        lock.lock(); defer { lock.unlock() }
        events.append(LoggedEvent(t: t, kind: kind, name: name, x: p.map { Double($0.x) }, y: p.map { Double($0.y) },
                                  rect: rect.map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) }))
    }
    func relative() -> [LoggedEvent] {
        lock.lock(); defer { lock.unlock() }
        let o = origin ?? 0
        return events.map { var e = $0; e.t = (e.t - o).rounded(toPlaces: 4); return e }
    }
}

extension Double {
    func rounded(toPlaces n: Int) -> Double { let m = pow(10, Double(n)); return (self * m).rounded() / m }
}

// MARK: - Accessibility

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}

func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

func label(_ e: AXUIElement) -> String {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { attr(e, $0) as? String }
        .first { !$0.isEmpty } ?? ""
}

func role(_ e: AXUIElement) -> String { attr(e, kAXRoleAttribute) as? String ?? "" }

func children(_ e: AXUIElement) -> [AXUIElement] {
    (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [])
}

/// Breadth-first search below `e` for an element with this role whose title, description or value is `name`.
func find(_ e: AXUIElement, role wanted: String? = nil, _ name: String? = nil, depth: Int = 18) -> AXUIElement? {
    var queue: [(AXUIElement, Int)] = [(e, 0)]
    while !queue.isEmpty {
        let (x, d) = queue.removeFirst()
        if (wanted == nil || role(x) == wanted) && (name == nil || label(x) == name) && d > 0 { return x }
        if d < depth { queue += children(x).map { ($0, d + 1) } }
    }
    return nil
}

func dumpTree(_ e: AXUIElement, depth: Int = 0, maxDepth: Int = 16) {
    guard depth <= maxDepth else { return }
    let f = frame(e).map { String(format: "(%.0f,%.0f %.0fx%.0f)", $0.minX, $0.minY, $0.width, $0.height) } ?? ""
    print(String(repeating: "  ", count: depth) + "\(role(e)) “\(label(e).prefix(48))” \(f)")
    for c in children(e) { dumpTree(c, depth: depth + 1, maxDepth: maxDepth) }
}

// MARK: - Input

/// Virtual key codes of the ANSI layout, with whether Shift is held.
let keyCodes: [Character: (CGKeyCode, Bool)] = {
    var m: [Character: (CGKeyCode, Bool)] = [:]
    let letters: [Character: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
                                           "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31,
                                           "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46]
    for (c, k) in letters { m[c] = (k, false); m[Character(c.uppercased())] = (k, true) }
    let digits: [Character: CGKeyCode] = ["1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
                                          "8": 28, "0": 29]
    for (c, k) in digits { m[c] = (k, false) }
    m["-"] = (27, false); m["_"] = (27, true); m[" "] = (49, false); m["."] = (47, false)
    return m
}()

enum Key: CGKeyCode {
    case returnKey = 36, tab = 48, escape = 53, left = 123, right = 124, down = 125, up = 126, f6 = 97
}

final class Driver {
    let pid: pid_t
    let log: EventLog
    let source = CGEventSource(stateID: .hidSystemState)
    private(set) var cursor: CGPoint
    var jitter = Jitter()

    init(pid: pid_t, log: EventLog) {
        self.pid = pid
        self.log = log
        cursor = CGEvent(source: nil)?.location ?? .zero
    }

    var app: AXUIElement { AXUIElementCreateApplication(pid) }

    // Safety

    func checkUntouched() throws {
        let p = CGEvent(source: nil)?.location ?? cursor
        if hypot(p.x - cursor.x, p.y - cursor.y) > 3 {
            throw Abort("Someone moved the mouse (expected \(cursor), found \(p)); stopping the take.")
        }
    }

    func checkFrontmost() throws {
        let front = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        if front != pid { throw Abort("Hexer is no longer the frontmost app; stopping the take.") }
    }

    /// The window that would receive a click at `p` must be Hexer's (or the menu bar, when asked).
    func checkHit(_ p: CGPoint, allowMenuBar: Bool = false) throws {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for w in list {
            guard let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b), rect.contains(p) else { continue }
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            if alpha < 0.01 || layer >= 1000 { continue }
            let owner = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
            if owner == pid { return }
            let name = w[kCGWindowOwnerName as String] as? String ?? "?"
            if allowMenuBar, layer == Int(CGWindowLevelForKey(.mainMenuWindow)) { return }
            throw Abort("A window of \(name) (layer \(layer)) covers \(p); stopping before the click.")
        }
        throw Abort("No Hexer window under \(p); stopping before the click.")
    }

    // Mouse

    private func post(_ type: CGEventType, _ p: CGPoint, clicks: Int64 = 0) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
        else { return }
        if clicks > 0 { e.setIntegerValueField(.mouseEventClickState, value: clicks) }
        e.post(tap: .cghidEventTap)
    }

    /// Probes only look: they never move the mouse.
    var dryRun = false

    /// Places the cursor before a take starts recording.
    func park(_ p: CGPoint) {
        if !dryRun { post(.mouseMoved, p) }
        cursor = p
        wait(0.05)
    }

    /// Moves along a gentle arc with a minimum-jerk speed profile, like a hand on a trackpad.
    func move(to p: CGPoint, duration: Double? = nil, arc: Double = 0.06) throws {
        try checkUntouched()
        let a = cursor
        let d = hypot(p.x - a.x, p.y - a.y)
        guard d > 0.5 else { return }
        let T = duration ?? min(1.15, max(0.6, 0.45 + d / 1100))
        let steps = max(2, Int(T * 120))
        let nx = -(p.y - a.y) / d, ny = (p.x - a.x) / d
        let start = now()
        for i in 1...steps {
            let s = Double(i) / Double(steps)
            let e = s * s * s * (10 - 15 * s + 6 * s * s)
            let bow = sin(Double.pi * e) * arc * d
            let q = CGPoint(x: a.x + (p.x - a.x) * e + nx * bow, y: a.y + (p.y - a.y) * e + ny * bow)
            post(.mouseMoved, q)
            cursor = q
            sleep(until: start + Double(i) / 120)
        }
        cursor = p
    }

    func click(_ name: String? = nil, settle: Double = 0.28, allowMenuBar: Bool = false) throws {
        wait(jitter.around(settle, 0.05))
        try checkUntouched()
        if !allowMenuBar { try checkFrontmost() }
        try checkHit(cursor, allowMenuBar: allowMenuBar)
        post(.leftMouseDown, cursor, clicks: 1)
        log.add("click", name, at: cursor)
        wait(0.085)
        post(.leftMouseUp, cursor, clicks: 1)
    }

    func click(at p: CGPoint, _ name: String? = nil, settle: Double = 0.28, allowMenuBar: Bool = false) throws {
        try move(to: p)
        try click(name, settle: settle, allowMenuBar: allowMenuBar)
    }

    /// Smooth, continuous (trackpad-like) scrolling of `distance` points; positive scrolls down.
    func scroll(_ distance: Double, duration: Double, _ name: String? = nil) throws {
        try checkUntouched()
        try checkFrontmost()
        try checkHit(cursor)
        log.add("scroll", name, at: cursor)
        let steps = max(2, Int(duration * 120))
        var sent = 0.0
        let start = now()
        for i in 1...steps {
            let s = Double(i) / Double(steps)
            let e = s * s * s * (10 - 15 * s + 6 * s * s)
            let target = distance * e
            let delta = (target - sent).rounded()
            if delta != 0, let ev = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                            wheel1: Int32(-delta), wheel2: 0, wheel3: 0) {
                ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                ev.location = cursor
                ev.post(tap: .cghidEventTap)
                sent += delta
            }
            sleep(until: start + Double(i) / 120)
        }
    }

    // Keyboard (posted to Hexer's process only)

    /// How a key reaches Hexer. `.process` posts it to Hexer's process: it cannot reach another app,
    /// and keyboard tools that rewrite typing through an event tap (OpenKey's Telex turns "TEXT" into
    /// "TẼT") never see it. Hexer's own grid reads typing through the text input system, which only
    /// takes keys from the HID tap, so typing into the grid uses `.hid` (and words Telex leaves alone).
    enum Route { case process, hid }

    func key(_ code: CGKeyCode, _ flags: CGEventFlags = [], char: String? = nil, name: String, route: Route = .process) throws {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            // A Unicode string on the event stops AppKit from matching a menu's key equivalent.
            if let char, flags.isDisjoint(with: [.maskCommand, .maskControl]) {
                let u = Array(char.utf16)
                e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
            }
            try checkFrontmost()
            switch route {
            case .process: e.postToPid(pid)
            case .hid: e.post(tap: .cghidEventTap)
            }
            if down { log.add("key", name) }
            wait(down ? 0.07 : 0)
        }
    }

    func press(_ k: Key, _ flags: CGEventFlags = [], name: String? = nil) throws {
        try key(k.rawValue, flags, name: name ?? "\(k)")
    }

    func shortcut(_ c: Character, _ flags: CGEventFlags, name: String) throws {
        guard let (code, _) = keyCodes[c] else { throw Abort("No key for \(c)") }
        try key(code, flags, name: name)
    }

    /// Types at a relaxed pace: `interval` seconds per character with a little human unevenness.
    func type(_ text: String, interval: Double = 0.21, route: Route = .process) throws {
        try requirePlainKeyboard()
        for c in text {
            guard let (code, shift) = keyCodes[c] else { throw Abort("No key for \(c)") }
            try key(code, shift ? .maskShift : [], char: String(c), name: String(c), route: route)
            wait(jitter.around(interval - 0.07, 0.035))
        }
    }

    /// An input method (e.g. Vietnamese Telex) would rewrite what the take types.
    func requirePlainKeyboard() throws {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return }
        let type = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        if type != (kTISTypeKeyboardLayout as String) {
            throw Abort("The current input source is an input method; switch to a plain keyboard layout (ABC).")
        }
    }

    func mark(_ name: String, rect: CGRect? = nil) { log.add("mark", name, at: nil, rect: rect) }

    // Hexer's UI

    /// Hexer's windows, without the small recording indicator macOS adds while capturing.
    var windows: [AXUIElement] {
        (attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter { (frame($0)?.height ?? 0) > 60 }
    }

    func window(titled prefix: String? = nil) -> AXUIElement? {
        windows.first { w in prefix.map { (attr(w, kAXTitleAttribute) as? String ?? "").hasPrefix($0) } ?? true }
    }

    func element(role r: String? = nil, _ name: String, in root: AXUIElement? = nil, timeout: Double = 4) throws -> AXUIElement {
        let end = now() + timeout
        repeat {
            for w in root.map({ [$0] }) ?? windows {
                if let e = find(w, role: r, name), let f = frame(e), f.width > 0 { return e }
            }
            wait(0.1)
        } while now() < end
        throw Abort("Could not find \(r ?? "element") “\(name)” in Hexer's windows.")
    }

    /// Setup only (before recording): presses a control through Accessibility, without the mouse.
    func axPress(role r: String, _ name: String) throws {
        AXUIElementPerformAction(try element(role: r, name), kAXPressAction as CFString)
    }

    func all(role r: String, _ name: String, in root: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var queue = [root]
        while !queue.isEmpty {
            let x = queue.removeFirst()
            if role(x) == r && label(x) == name { out.append(x) }
            queue += children(x)
        }
        return out
    }

    func center(of e: AXUIElement) throws -> CGPoint {
        guard let f = frame(e) else { throw Abort("Element has no frame") }
        return CGPoint(x: f.midX, y: f.midY)
    }

    func menu(_ title: String, _ item: String) throws {
        guard let object = attr(app, kAXMenuBarAttribute),
              let top = find(object as! AXUIElement, role: kAXMenuBarItemRole, title, depth: 1) else {
            throw Abort("No menu \(title)")
        }
        try click(at: try center(of: top), "menu \(title)", allowMenuBar: true)
        wait(0.45)
        let entry = try element(role: kAXMenuItemRole, item, in: top, timeout: 2)
        try move(to: try center(of: entry), duration: 0.55, arc: 0.02)
        try click("menu \(item)", settle: 0.2, allowMenuBar: true)
    }
}

// MARK: - Hex grid geometry (mirrors HexLayout and HexMetrics)

struct Grid {
    let canvas: CGRect          // the hex text area, global points
    let charWidth: Double
    let rowHeight: Double
    let bytesPerRow: Int

    init(canvas: CGRect, fontSize: Double, bytesPerRow: Int) {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        var glyph = CGGlyph(0)
        var zero: UniChar = 0x30
        CTFontGetGlyphsForCharacters(font, &zero, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        charWidth = advance.width
        rowHeight = ceil(font.ascender - font.descender + font.leading) + 5
        self.canvas = canvas
        self.bytesPerRow = bytesPerRow
    }

    var hexStartX: Double { 14 + 8 * charWidth + 3 * charWidth }
    func hexX(_ column: Int) -> Double { hexStartX + Double(column * 3) * charWidth }
    var textStartX: Double { hexStartX + Double(bytesPerRow * 3 - 1) * charWidth + 3 * charWidth }

    /// Centre of the first nibble of `offset`, with the grid scrolled to the top.
    func byte(_ offset: Int, nibble: Int = 0) -> CGPoint {
        let row = offset / bytesPerRow, col = offset % bytesPerRow
        return CGPoint(x: canvas.minX + hexX(col) + (Double(nibble) + 0.5) * charWidth,
                       y: canvas.minY + (Double(row) + 0.5) * rowHeight)
    }

    func cell(_ offset: Int, count: Int = 1) -> CGRect {
        let a = byte(offset), b = byte(offset + count - 1, nibble: 1)
        return CGRect(x: a.x - charWidth / 2, y: a.y - rowHeight / 2,
                      width: b.x - a.x + charWidth, height: rowHeight)
    }

    func text(_ offset: Int, count: Int) -> CGRect {
        let row = offset / bytesPerRow, col = offset % bytesPerRow
        return CGRect(x: canvas.minX + textStartX + Double(col) * charWidth, y: canvas.minY + Double(row) * rowHeight,
                      width: Double(count) * charWidth, height: rowHeight)
    }
}

// MARK: - Capture

let clearColor = CGColor(gray: 0, alpha: 0)

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "film.capture")
    private var stream: SCStream?
    private var writer: AVAssetWriter!
    private var input: AVAssetWriterInput!
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor!
    private var first: CMTime?
    private let started = DispatchSemaphore(value: 0)
    private(set) var frames = 0
    private(set) var dropped = 0
    var failure: Error?
    let log: EventLog

    init(log: EventLog) { self.log = log }

    func start(pid: pid_t, rect: CGRect, scale: Double, url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let width = Int(rect.width * scale) & ~1, height = Int(rect.height * scale) & ~1
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.94,
                                              AVVideoExpectedSourceFrameRateKey: 60],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Abort("Cannot write \(url.path)") }

        var thrown: Error?
        let ready = DispatchSemaphore(value: 0)
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            defer { ready.signal() }
            guard let content, let app = content.applications.first(where: { $0.processID == pid }),
                  let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                thrown = error ?? Abort("ScreenCaptureKit does not list Hexer (Screen Recording permission?)")
                return
            }
            let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = rect
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.showsCursor = true
            config.backgroundColor = clearColor
            config.shouldBeOpaque = false
            config.ignoreShadowsDisplay = true
            config.captureResolution = .best
            config.queueDepth = 8
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            } catch { thrown = error; return }
            self.stream = stream
            stream.startCapture { error in
                if let error { thrown = error }
            }
        }
        ready.wait()
        if let thrown { throw thrown }
        guard started.wait(timeout: .now() + 6) == .success else { throw Abort("No frames arrived from ScreenCaptureKit") }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        let pts = sample.presentationTimeStamp
        if first == nil {
            first = pts
            log.origin = pts.seconds
            writer.startSession(atSourceTime: .zero)
            started.signal()
        }
        if input.isReadyForMoreMediaData, adaptor.append(pixels, withPresentationTime: CMTimeSubtract(pts, first!)) {
            frames += 1
        } else {
            dropped += 1
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { failure = error }

    func stop() -> Double {
        let done = DispatchSemaphore(value: 0)
        let end = now()
        stream?.stopCapture { _ in done.signal() }
        _ = done.wait(timeout: .now() + 5)
        let finished = DispatchSemaphore(value: 0)
        queue.sync {
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(seconds: end - (log.origin ?? end), preferredTimescale: 600))
            writer.finishWriting { finished.signal() }
        }
        finished.wait()
        return end - (log.origin ?? end)
    }
}

// MARK: - Samples

func prepareSamples() throws {
    let fm = FileManager.default
    try fm.createDirectory(at: samplesDir, withIntermediateDirectories: true)
    let binary = samplesDir.appendingPathComponent("Hexer")
    if !fm.fileExists(atPath: binary.path) {
        try fm.copyItem(at: sourceApp.appendingPathComponent("Contents/MacOS/Hexer"), to: binary)
    }
    let bytes = try Data(contentsOf: binary)

    // A second build with a few patched bytes near the top, for the comparison.
    let other = samplesDir.appendingPathComponent("Hexer-b")
    if !fm.fileExists(atPath: other.path) {
        var b = bytes
        for (offset, patch) in [(0x24, [0x01, 0x02]), (0x5C, [0x7F]), (0xA8, [0x10, 0x20, 0x30]),
                                (0x134, [0xEE]), (0x1F2, [0x42, 0x24])] {
            for (i, v) in patch.enumerated() { b[offset + i] = UInt8(v) }
        }
        try b.write(to: other)
    }

    // Intel Hex with gaps between its records, so the import shows folded undefined sections.
    let firmware = samplesDir.appendingPathComponent("firmware.hex")
    if !fm.fileExists(atPath: firmware.path) {
        var lines: [String] = []
        func record(_ type: UInt8, _ address: Int, _ data: [UInt8]) {
            var sum = Int(data.count) + (address >> 8) + (address & 0xFF) + Int(type)
            var s = String(format: ":%02X%04X%02X", data.count, address & 0xFFFF, type)
            for d in data { s += String(format: "%02X", d); sum += Int(d) }
            s += String(format: "%02X", (0x100 - (sum & 0xFF)) & 0xFF)
            lines.append(s)
        }
        for (address, from, count) in [(0x0000, 0x0000, 0xC0), (0x0800, 0x4000, 0x60), (0x2400, 0x8000, 0x80)] {
            for k in stride(from: 0, to: count, by: 16) {
                record(0, address + k, Array(bytes[(from + k)..<(from + k + 16)]))
            }
        }
        record(1, 0, [])
        try (lines.joined(separator: "\n") + "\n").write(to: firmware, atomically: true, encoding: .ascii)
    }

    // A small FAT16 volume for the disk take, written by hand (4 MB, one sector per cluster).
    let disk = samplesDir.appendingPathComponent("HEXER.img")
    if !fm.fileExists(atPath: disk.path) {
        var image = [UInt8](repeating: 0, count: 8192 * 512)
        func put(_ at: Int, _ bytes: [UInt8]) { for (i, b) in bytes.enumerated() { image[at + i] = b } }
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16) }
        let reserved = 1, fats = 2, fatSectors = 32, rootEntries = 512
        put(0, [0xEB, 0x3C, 0x90] + Array("MSDOS5.0".utf8))
        put(11, le16(512) + [1] + le16(reserved) + [UInt8(fats)] + le16(rootEntries) + le16(8192) + [0xF8]
            + le16(fatSectors) + le16(32) + le16(16) + le32(0) + le32(0))
        put(36, [0x80, 0, 0x29] + le32(0x2026_1025) + Array("HEXER      FAT16   ".utf8))
        put(510, [0x55, 0xAA])
        let note = Array("Hexer, a hex editor for macOS.\r\n".utf8)
        for f in 0..<fats {
            let at = (reserved + f * fatSectors) * 512
            put(at, [0xF8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])    // media, reserved, README.TXT ends at cluster 2
        }
        let root = (reserved + fats * fatSectors) * 512
        put(root, Array("HEXER      ".utf8) + [0x08])
        put(root + 32, Array("README  TXT".utf8) + [0x20])
        put(root + 32 + 26, le16(2) + le32(note.count))
        let data = root + rootEntries * 32
        put(data, note)
        try Data(image).write(to: disk)
    }
}

/// The filming copy has its own bundle ID, so window frames, recent files and settings that the
/// takes touch never reach the user's Hexer.
func prepareApp() throws {
    let fm = FileManager.default
    let built = sourceApp.appendingPathComponent("Contents/MacOS/Hexer")
    let copy = filmApp.appendingPathComponent("Contents/MacOS/Hexer")
    let builtDate = (try? fm.attributesOfItem(atPath: built.path)[.modificationDate] as? Date) ?? .distantPast
    let copyDate = (try? fm.attributesOfItem(atPath: copy.path)[.modificationDate] as? Date) ?? .distantPast
    guard fm.fileExists(atPath: built.path) else { throw Abort("Run Scripts/bundle.sh first.") }
    if copyDate >= builtDate { return }
    try? fm.removeItem(at: filmApp)
    try fm.copyItem(at: sourceApp, to: filmApp)
    let plist = filmApp.appendingPathComponent("Contents/Info.plist").path
    shell("/usr/libexec/PlistBuddy", ["-c", "Set :CFBundleIdentifier \(filmBundleID)", plist])
    let r = shell("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", filmApp.path])
    if r.status != 0 { throw Abort("codesign failed: \(r.out)") }
}

func forgetFilmApp() {
    shell("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
          ["-u", filmApp.path])
}

// MARK: - Takes

struct Launch {
    var files: [String] = []
    var args: [String] = []
    var appearance = "dark"
    var size = CGSize(width: 1280, height: 800)
    var fontSize = 13.0
    var bytesPerRow = 16
    /// Extra windows (e.g. a comparison) are placed by the take itself.
    var placeWindow = true
}

struct Take {
    let name: String
    let launch: Launch
    /// Runs before recording: positions, parks the cursor. Returns the region to capture.
    var prepare: (Driver, Session) throws -> CGRect
    /// The performance, recorded.
    var perform: (Driver, Session) throws -> Void
}

final class Session {
    let take: Take
    var grid: Grid?
    var cleans: [CleanShot] = []
    init(take: Take) { self.take = take }

    /// Screenshots every visible window of Hexer (`screencapture -l`: one window, no shadow).
    func snapshot(_ d: Driver, tag: String) {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == d.pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let id = w[kCGWindowNumber as String] as? CGWindowID, let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b), rect.width > 100, rect.height > 60 else { continue }
            let file = "\(take.name)-\(tag)-\(id).png"
            shell("/usr/sbin/screencapture", ["-x", "-o", "-l", "\(id)", takesDir.appendingPathComponent(file).path])
            cleans.append(CleanShot(file: file, tag: tag, rect: [rect.minX, rect.minY, rect.width, rect.height].map(Double.init)))
        }
    }
}

var screen: CGRect { CGDisplayBounds(CGMainDisplayID()) }
/// NSScreen's visible frame (bottom-left origin) in top-left global points.
var visible: CGRect {
    let s = NSScreen.main!
    let v = s.visibleFrame
    return CGRect(x: v.minX, y: s.frame.maxY - v.maxY, width: v.width, height: v.height)
}

func centered(_ size: CGSize) -> CGPoint {
    CGPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded())
}

func place(_ w: AXUIElement, at origin: CGPoint, size: CGSize? = nil) {
    if let size {
        var s = size
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
    }
    var p = origin
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
}

func canvas(_ d: Driver, in window: AXUIElement? = nil) throws -> CGRect {
    let end = now() + 4
    repeat {
        for w in window.map({ [$0] }) ?? d.windows {
            if let e = find(w, role: kAXTextAreaRole), let f = frame(e), f.width > 50 { return f }
        }
        wait(0.1)
    } while now() < end
    throw Abort("No hex grid")
}

/// Setup for windows opened without -HexerHideInspector (imports, disks): hide it, then resize.
func hideInspector(_ d: Driver, size: CGSize) throws {
    try d.axPress(role: kAXButtonRole, "Inspector")
    wait(0.7)
    if let w = d.windows.first { place(w, at: centered(size), size: size) }
    wait(0.6)
}

func windowsUnion(_ d: Driver, margin: Double = 24) -> CGRect {
    let frames = d.windows.compactMap(frame)
    guard var u = frames.first else { return screen }
    for f in frames.dropFirst() { u = u.union(f) }
    return u.insetBy(dx: -margin, dy: -margin).intersection(screen).integral
}

func offsetOfText(section: String, in data: Data) -> Int? {
    // Mach-O 64: walk LC_SEGMENT_64 commands for __TEXT,<section>.
    func u32(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 | Int(data[o + 2]) << 16 | Int(data[o + 3]) << 24 }
    guard data.count > 32, u32(0) == 0xFEEDFACF else { return nil }
    let ncmds = u32(16)
    var p = 32
    for _ in 0..<ncmds {
        let cmd = u32(p), size = u32(p + 4)
        if cmd == 0x19 {
            let nsects = u32(p + 64)
            for s in 0..<nsects {
                let q = p + 72 + s * 80
                let name = String(decoding: data[q..<q + 16].prefix { $0 != 0 }, as: UTF8.self)
                let seg = String(decoding: data[(q + 16)..<(q + 32)].prefix { $0 != 0 }, as: UTF8.self)
                if name == section && seg == "__TEXT" { return u32(q + 48) }
            }
        }
        p += size
    }
    return nil
}

let binaryPath = samplesDir.appendingPathComponent("Hexer").path

let takes: [Take] = [
    // Keyboard only (never the mouse): checks that the shortcuts and typing reach Hexer (not part of the film).
    Take(name: "keys",
         launch: Launch(files: [binaryPath]),
         prepare: { d, _ in windowsUnion(d, margin: 40) },
         perform: { d, _ in
             func caret() -> String {
                 d.window().flatMap { find($0, role: kAXTextAreaRole) }.flatMap { attr($0, kAXValueAttribute) as? String } ?? "?"
             }
             try d.shortcut("f", .maskCommand, name: "⌘F"); wait(0.8)
             try d.type("__TEXT", interval: 0.1); wait(0.4)
             let field = d.window().flatMap { find($0, role: kAXTextFieldRole) }.flatMap { attr($0, kAXValueAttribute) as? String }
             print("  find field:", field ?? "none")
             try d.press(.escape); wait(0.6)
             print("  find bar closed:", d.window().flatMap { find($0, role: kAXButtonRole, "Find All") } == nil)
             try d.shortcut("l", .maskCommand, name: "⌘L"); wait(0.9)
             try d.type("1BB8", interval: 0.1); wait(0.3)
             try d.press(.returnKey); wait(0.9)
             print("  after go to:", caret())
             try d.press(.right); wait(0.3)
             print("  after →:", caret())
             if let object = attr(d.app, kAXMenuBarAttribute),
                let top = find(object as! AXUIElement, role: kAXMenuBarItemRole, "Analysis", depth: 1),
                let item = find(top, role: kAXMenuItemRole, "Statistics") {
                 AXUIElementPerformAction(item, kAXPressAction as CFString)
             }
             wait(1.5)
             print("  statistics open:", d.window(titled: "Statistics") != nil)
             try d.shortcut("w", .maskCommand, name: "close"); wait(0.8)
             print("  statistics closed:", d.window(titled: "Statistics") == nil, "windows:", d.windows.count)
         }),
    // A few still seconds, without input: checks the capture pipeline (not part of the film).
    Take(name: "idle",
         launch: Launch(files: [binaryPath]),
         prepare: { d, _ in windowsUnion(d, margin: 40) },
         perform: { d, _ in wait(2.5); d.mark("idleDone") }),

    // Extreme close-ups: a large grid font, six bytes per row, no sidebar or inspector.
    Take(name: "macro",
         launch: Launch(files: [binaryPath], args: ["-HexerHideInspector", "1"],
                        size: CGSize(width: 1440, height: 940), fontSize: 60, bytesPerRow: 6),
         prepare: { d, s in
             try d.axPress(role: kAXButtonRole, "Hide Sidebar")
             wait(1.0)
             let g = Grid(canvas: try canvas(d), fontSize: 60, bytesPerRow: 6)
             s.grid = g
             d.park(CGPoint(x: g.canvas.maxX - 60, y: g.canvas.maxY - 40))
             return windowsUnion(d)
         },
         perform: { d, s in
             let g = s.grid!
             wait(1.0)
             d.mark("magic", rect: g.cell(0, count: 4))
             // The caret walks across the Mach-O magic, one byte per beat (96 BPM).
             for _ in 0..<4 {
                 wait(0.625 - 0.07)
                 try d.press(.right)
             }
             wait(1.4)
             // Write "Patch" over a row of zeros (0x36–0x3B), in the decoded text column.
             let row = 0x36
             let cell = g.text(row, count: 1)
             d.mark("edit", rect: g.cell(row, count: 5).union(g.text(row, count: 5)))
             try d.click(at: CGPoint(x: cell.midX, y: cell.midY), "text \(row)")
             wait(0.55)
             d.mark("type")
             try d.type("Patch", interval: 0.3, route: .hid)
             d.mark("typed", rect: g.text(row, count: 5))
             wait(0.6)
             try d.move(to: CGPoint(x: g.canvas.maxX - 60, y: g.canvas.maxY - 40), duration: 1.1)
             wait(1.4)
         }),

    // The standard window: find, inspect, statistics, then scrolling and the mode picker.
    Take(name: "main",
         launch: Launch(files: [binaryPath], size: CGSize(width: 1280, height: 880)),
         prepare: { d, s in
             let g = Grid(canvas: try canvas(d), fontSize: 13, bytesPerRow: 16)
             s.grid = g
             // Off the captured region: the first move brings the cursor in from the side.
             d.park(CGPoint(x: visible.maxX - 4, y: visible.maxY - 30))
             let region = windowsUnion(d, margin: 40)
             // Clean shots of the Statistics window, and of the main window while it is inactive.
             if let object = attr(d.app, kAXMenuBarAttribute),
                let top = find(object as! AXUIElement, role: kAXMenuBarItemRole, "Analysis", depth: 1),
                let item = find(top, role: kAXMenuItemRole, "Statistics") {
                 AXUIElementPerformAction(item, kAXPressAction as CFString)
                 wait(2.0)
                 s.snapshot(d, tag: "stats")
                 if let st = d.window(titled: statisticsTitle), let close = attr(st, kAXCloseButtonAttribute) {
                     AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
                 }
                 wait(1.0)
             }
             return region
         },
         perform: { d, s in
             let g = s.grid!
             wait(2.6)
             // Find all "__TEXT".
             d.mark("find")
             try d.shortcut("f", .maskCommand, name: "⌘F")
             wait(0.8)
             try d.type("__TEXT", interval: 0.2)
             wait(0.45)
             let findAll = try d.element(role: kAXButtonRole, "Find All")
             d.mark("findAll", rect: frame(findAll))
             try d.click(at: try d.center(of: findAll), "Find All")
             wait(2.6)
             d.mark("found")
             try d.press(.escape, name: "esc")
             wait(0.8)

             // Go to the machine code (off camera): first past it, then back, so its row is the top row.
             let data = try Data(contentsOf: URL(fileURLWithPath: binaryPath))
             let code = (offsetOfText(section: "__text", in: data) ?? 0x4000) + 0x40
             for target in [code + 0x800, code] {
                 try d.shortcut("l", .maskCommand, name: "⌘L")
                 wait(0.9)
                 try d.type(String(target, radix: 16).uppercased(), interval: 0.12)
                 wait(0.35)
                 try d.press(.returnKey, name: "return")
                 wait(0.9)
             }
             // Rows now start at the code's row; instructions are 4-byte aligned.
             let top = code & ~0xF
             func at(_ offset: Int) -> CGPoint { g.byte(offset - top) }
             try d.move(to: CGPoint(x: g.canvas.midX + 40, y: g.canvas.minY + 7 * g.rowHeight), duration: 1.0)
             wait(0.6)
             d.mark("inspect", rect: g.cell(0, count: 16))
             try d.click(at: at(code + 0x10), "instruction 1")
             wait(1.4)
             try d.click(at: at(code + 0x2C), "instruction 2")
             wait(1.2)
             let integers = try d.element(role: kAXStaticTextRole, "Integers")
             let list = frame(integers)!
             try d.move(to: CGPoint(x: list.minX + 140, y: list.minY + 300), duration: 0.9)
             wait(0.3)
             d.mark("scrollInspector")
             try d.scroll(400, duration: 1.6, "inspector")
             let disasm = try? d.element(role: kAXStaticTextRole, "Disassembly", timeout: 0.5)
             d.mark("disassembly", rect: disasm.flatMap(frame))
             wait(0.5)
             // Off the inspector's rows before a tooltip can appear.
             try d.move(to: CGPoint(x: g.canvas.midX + 60, y: g.canvas.minY + 300), duration: 1.1)
             wait(0.9)

             // Byte statistics, opened from the menu bar.
             try d.menu("Analysis", "Statistics")
             wait(1.6)
             guard let stats = d.window(titled: statisticsTitle), let sf = frame(stats) else {
                 throw Abort("No Statistics window")
             }
             // Each bar of the chart is an accessibility element labelled "<value> to <value+1>, 0 to <count>".
             func bar(_ value: Int) -> CGRect? {
                 children(stats).lazy.flatMap(children).flatMap(children)
                     .first { label($0).hasPrefix("\(value) to \(value + 1),") }.flatMap(frame)
             }
             guard let b0 = bar(1), let b255 = bar(255), let tall = bar(0x5F) else { throw Abort("No histogram") }
             let plotY = b0.maxY - 150
             d.mark("stats", rect: sf)
             try d.move(to: CGPoint(x: b0.midX + 4, y: plotY), duration: 1.0)
             wait(0.35)
             d.mark("sweep", rect: CGRect(x: b0.minX, y: b0.maxY - 340, width: b255.maxX - b0.minX, height: 340))
             try d.move(to: CGPoint(x: b255.midX - 4, y: plotY + 8), duration: 2.6, arc: 0)
             wait(0.45)
             try d.move(to: CGPoint(x: tall.midX, y: plotY - 20), duration: 1.0)
             try d.click("bar 0x5F", settle: 0.3)
             d.mark("barPicked", rect: tall)
             wait(1.8)
             d.mark("statsDone")
             // ⌘W: during a capture macOS lays its recording indicator over the traffic lights, and it
             // takes the clicks meant for the close button.
             try d.shortcut("w", .maskCommand, name: "close")
             wait(1.0)

             // Close the search results drawer if it is still open.
             if let clear = try? d.element(role: kAXButtonRole, "Clear", timeout: 0.3) {
                 let cy = try d.center(of: clear).y
                 if let shut = d.all(role: kAXButtonRole, "Close", in: d.window()!)
                     .first(where: { (frame($0).map { abs($0.midY - cy) } ?? 99) < 8 }) {
                     try d.click(at: try d.center(of: shut), "close drawer")
                     wait(1.0)
                 }
             }

             // Hero: scroll the grid, then switch modes on the Liquid Glass picker.
             try d.move(to: CGPoint(x: g.canvas.midX, y: g.canvas.midY + 40), duration: 1.0)
             wait(0.4)
             d.mark("hero")
             try d.scroll(1400, duration: 2.6, "grid")
             wait(0.7)
             let insert = try d.element(role: kAXRadioButtonRole, "Insert")
             d.mark("modes", rect: frame(insert))
             try d.click(at: try d.center(of: insert), "Insert")
             wait(1.1)
             let overwrite = try d.element(role: kAXRadioButtonRole, "Overwrite")
             try d.click(at: try d.center(of: overwrite), "Overwrite")
             wait(1.4)
             d.mark("heroDone")
         }),

    // Light appearance: a byte, then Read-only and back on the mode picker.
    Take(name: "light",
         launch: Launch(files: [binaryPath], appearance: "light"),
         prepare: { d, s in
             let g = Grid(canvas: try canvas(d), fontSize: 13, bytesPerRow: 16)
             s.grid = g
             d.park(CGPoint(x: g.canvas.midX, y: g.canvas.midY + 120))
             return windowsUnion(d, margin: 40)
         },
         perform: { d, s in
             let g = s.grid!
             wait(1.2)
             d.mark("light")
             try d.click(at: g.byte(0x52), "byte")
             wait(1.0)
             let readOnly = try d.element(role: kAXRadioButtonRole, "Read-only")
             try d.click(at: try d.center(of: readOnly), "Read-only")
             wait(1.2)
             let overwrite = try d.element(role: kAXRadioButtonRole, "Overwrite")
             try d.click(at: try d.center(of: overwrite), "Overwrite")
             wait(1.6)
             d.mark("lightDone")
         }),

    // Two builds side by side; F6 walks the differences.
    Take(name: "compare",
         launch: Launch(files: [binaryPath, samplesDir.appendingPathComponent("Hexer-b").path],
                        args: ["-HexerCompare", "1", "-HexerCompareSteps", "0"], placeWindow: false),
         prepare: { d, s in
             wait(1.5)
             let ws = d.windows
             guard ws.count >= 2 else { throw Abort("Compare needs two windows") }
             let size = CGSize(width: 720, height: 760)
             let y = (visible.midY - size.height / 2).rounded()
             place(ws[0], at: CGPoint(x: (visible.midX - size.width - 6).rounded(), y: y), size: size)
             place(ws[1], at: CGPoint(x: (visible.midX + 6).rounded(), y: y), size: size)
             wait(0.8)
             let c = try canvas(d, in: ws[0])
             d.park(CGPoint(x: c.midX + 260, y: c.maxY - 80))
             return windowsUnion(d)
         },
         perform: { d, s in
             wait(1.2)
             d.mark("compare")
             for _ in 0..<4 {
                 try d.press(.f6, name: "F6")
                 wait(0.95)
             }
             wait(0.8)
             d.mark("compareDone")
         }),

    // Intel Hex import with folded gaps; click a fold open.
    Take(name: "firmware",
         launch: Launch(args: ["-HexerImport", samplesDir.appendingPathComponent("firmware.hex").path],
                        size: CGSize(width: 960, height: 720)),
         prepare: { d, s in
             try hideInspector(d, size: s.take.launch.size)
             let g = Grid(canvas: try canvas(d), fontSize: 13, bytesPerRow: 16)
             s.grid = g
             d.park(CGPoint(x: g.canvas.midX + 120, y: g.canvas.maxY - 60))
             return windowsUnion(d)
         },
         perform: { d, s in
             let g = s.grid!
             wait(1.2)
             d.mark("firmware")
             // Records cover 0x000–0x0BF (12 rows); the first fold is the 13th row.
             let fold = CGPoint(x: g.canvas.minX + g.hexX(6), y: g.canvas.minY + 12.5 * g.rowHeight)
             try d.click(at: fold, "fold")
             wait(2.0)
             d.mark("firmwareDone")
         }),

    // A FAT volume, read-only: type a sector number into the navigator to reach the root directory.
    Take(name: "disk",
         launch: Launch(size: CGSize(width: 960, height: 720)),
         prepare: { d, s in
             try hideInspector(d, size: s.take.launch.size)
             let g = Grid(canvas: try canvas(d), fontSize: 13, bytesPerRow: 16)
             s.grid = g
             d.park(CGPoint(x: g.canvas.midX + 120, y: g.canvas.maxY - 140))
             return windowsUnion(d)
         },
         perform: { d, s in
             wait(1.2)
             d.mark("disk")
             let field = try d.element(role: kAXTextFieldRole, "0")
             d.mark("sector", rect: frame(field))
             try d.click(at: try d.center(of: field), "sector field")
             wait(0.4)
             try d.shortcut("a", .maskCommand, name: "⌘A")
             wait(0.3)
             try d.type("65", interval: 0.24)
             wait(0.35)
             try d.press(.returnKey, name: "return")
             wait(1.0)
             try d.move(to: CGPoint(x: s.grid!.canvas.midX + 160, y: s.grid!.canvas.minY + 220), duration: 1.0)
             wait(1.4)
             d.mark("diskDone")
         }),
]

let statisticsTitle = "Statistics"

// MARK: - Running a take

func attachDisk() throws -> String {
    let r = shell("/usr/bin/hdiutil", ["attach", "-nomount", "-readonly", "-imagekey", "diskimage-class=CRawDiskImage",
                                       samplesDir.appendingPathComponent("HEXER.img").path])
    guard r.status == 0, let dev = r.out.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("/dev/disk") })
    else { throw Abort("hdiutil attach failed: \(r.out)") }
    return String(dev.dropFirst("/dev/".count))
}

func runningFilmApps() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: filmBundleID)
}

func launch(_ take: Take, disk: String?) throws -> pid_t {
    for app in runningFilmApps() { app.forceTerminate() }
    wait(0.5)
    let l = take.launch
    var args = l.files
    args += l.args
    if let disk { args += ["-HexerOpenDisk", disk] }
    args += ["-HexerAppearance", l.appearance,
             "-HexerWindowSize", "\(Int(l.size.width))x\(Int(l.size.height))",
             "-FontSize", "\(l.fontSize)",
             "-ApplePersistenceIgnoreState", "YES",
             "-AppleLanguages", "(en)"]
    if l.bytesPerRow != 16 { args += ["-HexerBytesPerRow", "\(l.bytesPerRow)"] }
    let logPath = takesDir.appendingPathComponent("\(take.name).app.log").path
    let r = shell("/usr/bin/open", ["-n", "-a", filmApp.path, "--stdout", logPath, "--stderr", logPath, "--args"] + args)
    if r.status != 0 { throw Abort("open failed: \(r.out)") }
    let end = now() + 15
    while now() < end {
        if let app = runningFilmApps().first {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            if let ws = attr(ax, kAXWindowsAttribute) as? [AXUIElement], !ws.isEmpty { return app.processIdentifier }
        }
        wait(0.2)
    }
    throw Abort("Hexer did not open a window")
}

func record(_ take: Take, probe: Bool) throws {
    print("▶︎ \(take.name)\(probe ? " (probe)" : "")")
    let session = Session(take: take)
    var disk: String?
    if take.name == "disk" { disk = try attachDisk() }
    defer {
        for app in runningFilmApps() { app.forceTerminate() }
        if let disk { shell("/usr/bin/hdiutil", ["detach", "/dev/\(disk)", "-force"]) }
    }
    let pid = try launch(take, disk: disk)
    let log = EventLog()
    let d = Driver(pid: pid, log: log)
    d.dryRun = probe
    wait(1.2)
    if take.launch.placeWindow, let w = d.windows.first {
        let f = frame(w) ?? .zero
        place(w, at: centered(f.size))
        wait(0.6)
    }
    let region = try take.prepare(d, session)
    if probe {
        for w in d.windows { dumpTree(w, maxDepth: 12) }
        if let wid = frontWindowID(pid: pid) {
            shell("/usr/sbin/screencapture", ["-x", "-o", "-l", "\(wid)", takesDir.appendingPathComponent("\(take.name)-probe.png").path])
        }
        print("region \(region)")
        return
    }
    if !["idle", "keys"].contains(take.name) { try d.checkFrontmost() }
    session.snapshot(d, tag: "clean")
    let recorder = Recorder(log: log)
    let url = takesDir.appendingPathComponent("\(take.name).mov")
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    try recorder.start(pid: pid, rect: region, scale: scale, url: url)
    let windows = d.windows.compactMap(frame).filter { $0.height > 60 }
        .map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) }
    wait(0.6)
    var failure: Error?
    do { try take.perform(d, session) } catch { failure = error }
    let duration = recorder.stop()
    let info = TakeInfo(name: take.name, appearance: take.launch.appearance, scale: scale,
                        sourceRect: [region.minX, region.minY, region.width, region.height].map(Double.init),
                        windows: windows, duration: duration.rounded(toPlaces: 4),
                        frames: recorder.frames, dropped: recorder.dropped,
                        grid: session.grid.map { g in
                            GridInfo(canvas: [g.canvas.minX, g.canvas.minY, g.canvas.width, g.canvas.height].map(Double.init),
                                     charWidth: g.charWidth, rowHeight: g.rowHeight, bytesPerRow: g.bytesPerRow)
                        },
                        cleans: session.cleans, events: log.relative())
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(info).write(to: takesDir.appendingPathComponent("\(take.name).json"))
    if let failure { throw failure }
    if let e = recorder.failure { throw e }
    print(String(format: "  %.1f s, %d frames, %d dropped", duration, recorder.frames, recorder.dropped))
}

/// The frontmost of Hexer's normal windows.
func frontWindowID(pid: pid_t) -> CGWindowID? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
        .flatMap { $0[kCGWindowNumber as String] as? CGWindowID }
}

// MARK: - Main

var arguments = Array(CommandLine.arguments.dropFirst())
let probe = arguments.first == "probe"
if probe { arguments.removeFirst() }
let selected = arguments.isEmpty ? takes.filter { !["idle", "keys"].contains($0.name) } : takes.filter { arguments.contains($0.name) }

let nsapp = NSApplication.shared
nsapp.setActivationPolicy(.prohibited)
Thread.detachNewThread {
    var status: Int32 = 0
    do {
        guard AXIsProcessTrusted() else { throw Abort("This terminal needs Accessibility permission.") }
        guard CGPreflightScreenCaptureAccess() else { throw Abort("This terminal needs Screen Recording permission.") }
        try FileManager.default.createDirectory(at: takesDir, withIntermediateDirectories: true)
        try prepareApp()
        try prepareSamples()
        for take in selected { try record(take, probe: probe) }
    } catch {
        print("error: \(error)")
        status = 1
    }
    forgetFilmApp()
    exit(status)
}
nsapp.run()
