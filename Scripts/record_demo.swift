// Records the scripted tour of the app (App/DemoScript.swift) for the promotional video.
//
//   Scripts/bundle.sh && swift Scripts/record_demo.swift && swift Scripts/make_promo.swift
//
// Launches build/Hexer.app on sample data made from its own binary, captures only Hexer's windows
// with ScreenCaptureKit (other apps never appear), and writes to build/promo/: recording.mov (HEVC
// with alpha), capture.json (geometry and clock), and the app's timeline.json and clean snapshots.
// Needs Screen Recording permission for the terminal that runs it.
import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

setvbuf(stdout, nil, _IONBF, 0)
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let appBinary = root.appendingPathComponent("build/Hexer.app/Contents/MacOS/Hexer")
let out = root.appendingPathComponent("build/promo")
let samples = out.appendingPathComponent("samples")
let fm = FileManager.default

// MARK: Sample data: the app's own binary, and an Intel Hex image of parts of it with gaps.

try? fm.createDirectory(at: samples, withIntermediateDirectories: true)
for name in ["ready", "go", "timeline.json", "recording.mov", "capture.json"] {
    try? fm.removeItem(at: out.appendingPathComponent(name))
}
let binary = samples.appendingPathComponent("Hexer")
try? fm.removeItem(at: binary)
try fm.copyItem(at: appBinary, to: binary)
let bytes = [UInt8](try Data(contentsOf: binary))
var hex = ""
for (start, count) in [(0x0000, 0xE4), (0x0805, 0x80), (0x4000, 0x100), (0x9000, 0x40)] {
    for i in stride(from: 0, to: count, by: 16) {
        let chunk = Array(bytes[(start + i)..<(start + min(i + 16, count))])
        let record = [UInt8(chunk.count), UInt8((start + i) >> 8 & 0xFF), UInt8((start + i) & 0xFF), 0] + chunk
        let sum = record.reduce(0) { $0 &+ $1 }
        hex += ":" + (record + [0 &- sum]).map { String(format: "%02X", $0) }.joined() + "\n"
    }
}
hex += ":00000001FF\n"
let firmware = samples.appendingPathComponent("firmware.hex")
try hex.write(to: firmware, atomically: true, encoding: .ascii)

// MARK: Launch the app in demo mode

let app = Process()
app.executableURL = appBinary
app.arguments = [binary.path, "-HexerDemo", out.path, "-HexerDemoFirmware", firmware.path,
                 "-HexerWindowSize", "1280x800", "-HexerAppearance", "dark",
                 // No windows restored from earlier runs, no tooltips under the real pointer.
                 "-ApplePersistenceIgnoreState", "YES", "-NSInitialToolTipDelay", "100000000"]
fm.createFile(atPath: out.appendingPathComponent("app.log").path, contents: nil)
let log = try FileHandle(forWritingTo: out.appendingPathComponent("app.log"))
app.standardOutput = log
app.standardError = log
try app.run()
print("launched Hexer (pid \(app.processIdentifier)), waiting for the demo to get ready")

// MARK: Recording

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    var first: CMTime?
    var frames = 0

    init(url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.85],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        // Only complete frames carry new pixels; idle ones repeat the last frame.
        if let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
           let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) != .complete { return }
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        if first == nil { first = time }
        guard input.isReadyForMoreMediaData else { return }
        adaptor.append(pixels, withPresentationTime: time - first!)
        frames += 1
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { print("capture stopped: \(error)") }
}

func json(_ rect: CGRect) -> [String: Double] {
    ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
}

let nsapp = NSApplication.shared
nsapp.setActivationPolicy(.prohibited)

Task.detached {
    do {
        let ready = out.appendingPathComponent("ready").path
        for _ in 0..<300 where !fm.fileExists(atPath: ready) && app.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        guard fm.fileExists(atPath: ready) else { print("the app did not get ready (see build/promo/app.log)"); exit(1) }

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.owningApplication?.processID == app.processIdentifier && $0.frame.width > 400 }),
              let hexer = content.applications.first(where: { $0.processID == app.processIdentifier }) else {
            print("Hexer's window is not on screen"); exit(1)
        }
        let display = content.displays.first { $0.frame.intersects(window.frame) } ?? content.displays[0]
        let scale = CGDisplayCopyDisplayMode(display.displayID).map { Double($0.pixelWidth) / Double($0.width) } ?? 2
        // Only Hexer's windows (the document, its sheets and popovers), with room for the shadow.
        let filter = SCContentFilter(display: display, including: [hexer], exceptingWindows: [])
        let source = window.frame.insetBy(dx: -48, dy: -48).intersection(display.frame)
        let config = SCStreamConfiguration()
        config.sourceRect = source.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Int(source.width * scale)
        config.height = Int(source.height * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 8

        let recorder = try Recorder(url: out.appendingPathComponent("recording.mov"), width: config.width, height: config.height)
        let stream = SCStream(filter: filter, configuration: config, delegate: recorder)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "recording"))
        stream.startCapture { error in if let error { print("capture failed: \(error)"); exit(1) } }
        for _ in 0..<100 where recorder.first == nil { try await Task.sleep(for: .milliseconds(50)) }
        fm.createFile(atPath: out.appendingPathComponent("go").path, contents: nil)
        print("recording \(window.frame.size) at \(scale)x")

        for _ in 0..<3000 where app.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        try await stream.stopCapture()
        recorder.input.markAsFinished()
        await recorder.writer.finishWriting()
        let capture: [String: Any] = ["firstFrame": recorder.first.map(\.seconds) ?? 0, "scale": scale,
                                      "source": json(source), "window": json(window.frame), "frames": recorder.frames]
        try JSONSerialization.data(withJSONObject: capture, options: .prettyPrinted).write(to: out.appendingPathComponent("capture.json"))
        print("wrote \(recorder.frames) frames to build/promo/recording.mov")
        exit(recorder.writer.status == .completed ? 0 : 1)
    } catch {
        print("error: \(error)")
        app.terminate()
        exit(1)
    }
}
nsapp.run()
