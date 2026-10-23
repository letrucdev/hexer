// Turns the recorded tour (Scripts/record_demo.swift) into the promotional video
// build/promo/hexer-tour.mp4 (1920×1080, H.264): the app as recorded, with a pointer, click ripples,
// key badges, captions and camera moves drawn from the app's timeline, between a title card and a
// closing card. The video stays local; build/ is not committed.
//
//   Scripts/bundle.sh && swift Scripts/record_demo.swift && swift Scripts/make_promo.swift
import AppKit
import AVFoundation
import CoreText
import ImageIO

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let promo = root.appendingPathComponent("build/promo")
let videoURL = promo.appendingPathComponent("hexer-tour.mp4")

let width = 1920, height = 1080, fps = 30
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func loadImage(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("cannot read \(url.path)") }
    return image
}

func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp01(x), 3) }
func easeInOut(_ x: Double) -> Double { let t = clamp01(x); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double { easeOut((t - a) / (b - a)) }
func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

// MARK: Inputs

struct Event {
    var type: String
    var t: Double
    var fields: [String: Any]
    func number(_ key: String) -> Double { (fields[key] as? NSNumber)?.doubleValue ?? 0 }
    func text(_ key: String) -> String { fields[key] as? String ?? "" }
}

let captureInfo = try JSONSerialization.jsonObject(with: Data(contentsOf: promo.appendingPathComponent("capture.json"))) as! [String: Any]
let timelineInfo = try JSONSerialization.jsonObject(with: Data(contentsOf: promo.appendingPathComponent("timeline.json"))) as! [String: Any]
func rect(_ any: Any?) -> CGRect {
    let d = any as! [String: NSNumber]
    return CGRect(x: d["x"]!.doubleValue, y: d["y"]!.doubleValue, width: d["width"]!.doubleValue, height: d["height"]!.doubleValue)
}
let firstFrame = (captureInfo["firstFrame"] as! NSNumber).doubleValue
let recScale = (captureInfo["scale"] as! NSNumber).doubleValue
let source = rect(captureInfo["source"]), windowFrame = rect(captureInfo["window"])
/// Where the window's top-left corner lies in the recording, in points.
let windowOrigin = CGPoint(x: windowFrame.minX - source.minX, y: windowFrame.minY - source.minY)
// Event times on the recording's clock.
let events: [Event] = (timelineInfo["events"] as! [[String: Any]]).map {
    Event(type: $0["type"] as! String, t: ($0["t"] as! NSNumber).doubleValue - firstFrame, fields: $0)
}
let begin = events.first { $0.type == "begin" }!.t
let end = events.first { $0.type == "end" }!.t

// MARK: Recording frames

final class Frames {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    var current: (time: Double, image: CGImage)?
    var pending: (time: Double, image: CGImage)?
    var finished = false

    init(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
    }

    private func next() -> (time: Double, image: CGImage)? {
        guard !finished, let sample = output.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) else {
            finished = true
            return nil
        }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels), row = CVPixelBufferGetBytesPerRow(pixels)
        let data = Data(bytes: CVPixelBufferGetBaseAddress(pixels)!, count: row * h)
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row, space: sRGB,
                            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: CGDataProvider(data: data as CFData)!,
                            decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return (CMSampleBufferGetPresentationTimeStamp(sample).seconds, image)
    }

    /// The last frame shown at or before `time` (times only increase).
    func image(at time: Double) -> CGImage? {
        if current == nil { current = next() }
        while true {
            if pending == nil { pending = next() }
            guard let p = pending, p.time <= time else { break }
            current = p
            pending = nil
        }
        return current?.image
    }
}

let frames = try await Frames(promo.appendingPathComponent("recording.mov"))
let recordingSize = CGSize(width: source.width * recScale, height: source.height * recScale)

// MARK: Patch over the sharing indicator

/// While a window is captured, macOS draws an indicator over its traffic lights. Cover that corner
/// with the same corner of a clean snapshot (taken by the app just before recording), feathered.
func cornerPatch(_ name: String) -> CGImage {
    let clean = loadImage(promo.appendingPathComponent(name))
    let s = Double(clean.width) / windowFrame.width
    let crop = CGRect(x: 4 * s, y: 4 * s, width: 110 * s, height: 46 * s).integral
    let piece = clean.cropping(to: crop)!
    let w = piece.width, h = piece.height, feather = 6 * s
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: bitmapInfo)!
    ctx.draw(piece, in: CGRect(x: 0, y: 0, width: w, height: h))
    // Fade towards the right and bottom edges, which lie inside the window.
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let row = ctx.bytesPerRow
    for y in 0..<h {
        for x in 0..<w {
            let a = clamp01(Double(w - 1 - x) / feather) * clamp01(Double(h - 1 - y) / feather)
            guard a < 1 else { continue }
            for c in 0..<4 { data[y * row + x * 4 + c] = UInt8(Double(data[y * row + x * 4 + c]) * a) }
        }
    }
    return ctx.makeImage()!
}
let patches = ["dark": cornerPatch("clean-dark.png"), "light": cornerPatch("clean-light.png")]
let patchOrigin = CGPoint(x: (windowOrigin.x + 4) * recScale, y: (windowOrigin.y + 4) * recScale)

// MARK: Timeline state at a recording time

func appearance(at r: Double) -> String {
    events.last { $0.type == "appearance" && $0.t <= r }?.text("value") ?? "dark"
}

/// The pointer in window points, and how long ago it clicked (nil when not clicking).
func pointer(at r: Double) -> (point: CGPoint, press: Double?)? {
    var position: CGPoint?
    for e in events where e.type == "move" && e.t <= r {
        let target = CGPoint(x: e.number("x"), y: e.number("y"))
        let d = e.number("duration")
        if let from = position, d > 0 {
            let k = easeInOut((r - e.t) / d)
            position = CGPoint(x: mix(from.x, target.x, k), y: mix(from.y, target.y, k))
        } else {
            position = target
        }
    }
    guard let position else { return nil }
    let click = events.last { $0.type == "click" && $0.t <= r && r - $0.t < 0.6 }
    return (position, click.map { r - $0.t })
}

/// Camera: center in window points and zoom, easing between focus events.
func camera(at r: Double) -> (center: CGPoint, zoom: Double) {
    var center = CGPoint(x: windowFrame.width / 2, y: windowFrame.height / 2), zoom = 1.0
    for e in events where e.type == "focus" && e.t <= r {
        let k = easeInOut((r - e.t) / 0.9)
        center = CGPoint(x: mix(center.x, e.number("x"), k), y: mix(center.y, e.number("y"), k))
        zoom = mix(zoom, e.number("zoom"), k)
    }
    return (center, zoom)
}

let captions = events.filter { $0.type == "caption" }

// MARK: Drawing (CoreGraphics coordinates: origin at the bottom left)

func drawBackground(_ ctx: CGContext) {
    ctx.setFillColor(color(0x080C16))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let glow = CGGradient(colorsSpace: sRGB, colors: [color(0x0A64D8, 0.30), color(0x0A64D8, 0)] as CFArray, locations: [0, 1])!
    let c = CGPoint(x: Double(width) / 2, y: Double(height) * 1.05)
    ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: Double(width) * 0.62, options: [])
}

func textLine(_ string: String, size: CGFloat, weight: NSFont.Weight, color textColor: CGColor) -> CTLine {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): NSFont.systemFont(ofSize: size, weight: weight),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor,
    ]
    return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
}

func drawText(_ ctx: CGContext, _ string: String, size: CGFloat, weight: NSFont.Weight, color textColor: CGColor, centerX: Double, y: Double) {
    let line = textLine(string, size: size, weight: weight, color: textColor)
    ctx.textPosition = CGPoint(x: centerX - Double(CTLineGetBoundsWithOptions(line, []).width) / 2, y: y)
    CTLineDraw(line, ctx)
}

let icon = loadImage(root.appendingPathComponent("Resources/Icon/AppIcon.iconset/icon_512x512.png"))

func drawCard(_ ctx: CGContext, t: Double, line: String, lineColor: CGColor) {
    drawBackground(ctx)
    let centerY = Double(height) / 2 - 30
    let a = ramp(t, 0, 0.8), size = 200 * (0.88 + 0.12 * a)
    ctx.saveGState(); ctx.setAlpha(a); ctx.interpolationQuality = .high
    ctx.draw(icon, in: CGRect(x: Double(width) / 2 - size / 2, y: centerY + 40, width: size, height: size))
    ctx.restoreGState()
    let b = ramp(t, 0.35, 1.1)
    ctx.saveGState(); ctx.setAlpha(b)
    drawText(ctx, "Hexer", size: 104, weight: .bold, color: color(0xFFFFFF), centerX: Double(width) / 2, y: centerY - 70 + (1 - b) * 16)
    ctx.restoreGState()
    let c = ramp(t, 0.75, 1.5)
    ctx.saveGState(); ctx.setAlpha(c)
    drawText(ctx, line, size: 34, weight: .regular, color: lineColor, centerX: Double(width) / 2, y: centerY - 135 + (1 - c) * 12)
    ctx.restoreGState()
}

/// The macOS arrow pointer as a path in points, tip at the origin, y pointing down.
let arrowPath: CGPath = {
    let path = CGMutablePath()
    path.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.6), CGPoint(x: 4.1, y: 12.9), CGPoint(x: 6.9, y: 19.4),
                            CGPoint(x: 9.4, y: 18.3), CGPoint(x: 6.7, y: 12.1), CGPoint(x: 11.9, y: 12.1)])
    path.closeSubpath()
    return path
}()

/// The area the window is fitted into, below the captions.
let stage = CGRect(x: 90, y: 40, width: Double(width) - 180, height: Double(height) - 230)
let baseScale = min(stage.width / recordingSize.width, stage.height / recordingSize.height)

func drawRecording(_ ctx: CGContext, r: Double) {
    guard let frame = frames.image(at: r) else { return }
    let cam = camera(at: r)
    let scale = baseScale * cam.zoom
    // Recording pixel at the camera center, kept so the view never runs past the recording.
    var focus = CGPoint(x: (windowOrigin.x + cam.center.x) * recScale, y: (windowOrigin.y + cam.center.y) * recScale)
    let halfW = stage.width / 2 / scale, halfH = stage.height / 2 / scale
    focus.x = recordingSize.width > 2 * halfW ? min(max(focus.x, halfW), recordingSize.width - halfW) : recordingSize.width / 2
    focus.y = recordingSize.height > 2 * halfH ? min(max(focus.y, halfH), recordingSize.height - halfH) : recordingSize.height / 2
    // Maps recording pixels (top-left origin) to the video.
    func video(_ p: CGPoint) -> CGPoint {
        CGPoint(x: stage.midX + (p.x - focus.x) * scale, y: stage.midY - (p.y - focus.y) * scale)
    }
    func place(_ image: CGImage, at topLeft: CGPoint) {
        let o = video(topLeft)
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        ctx.draw(image, in: CGRect(x: o.x, y: o.y - h, width: w, height: h))
    }
    ctx.saveGState()
    ctx.interpolationQuality = .high
    place(frame, at: .zero)
    place(patches[appearance(at: r)]!, at: patchOrigin)

    if let p = pointer(at: r) {
        let tip = video(CGPoint(x: (windowOrigin.x + p.point.x) * recScale, y: (windowOrigin.y + p.point.y) * recScale))
        if let press = p.press {
            // Click ripple.
            let k = clamp01(press / 0.5)
            let radius = (8 + 26 * easeOut(k)) * recScale * scale
            let ring = CGRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2)
            ctx.setFillColor(color(0x4AA3FF, 0.22 * (1 - k)))
            ctx.fillEllipse(in: ring)
            ctx.setStrokeColor(color(0xFFFFFF, 0.75 * (1 - k)))
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: ring)
        }
        let squeeze = p.press.map { 1 - 0.12 * sin(.pi * clamp01($0 / 0.18)) } ?? 1
        let k = recScale * scale * 1.25 * squeeze
        ctx.saveGState()
        ctx.translateBy(x: tip.x, y: tip.y)
        ctx.scaleBy(x: k, y: -k)
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: color(0x000000, 0.4))
        ctx.addPath(arrowPath)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(2.2)
        ctx.setStrokeColor(color(0xFFFFFF))
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(arrowPath)
        ctx.setFillColor(color(0x000000))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

func drawCaption(_ ctx: CGContext, r: Double) {
    // A scrim keeps the captions readable over a zoomed window.
    let scrim = CGGradient(colorsSpace: sRGB, colors: [color(0x080C16, 0.96), color(0x080C16, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(scrim, start: CGPoint(x: 0, y: Double(height)), end: CGPoint(x: 0, y: Double(height) - 250), options: [])
    for (i, c) in captions.enumerated() {
        let fadeIn = ramp(r, c.t, c.t + 0.5)
        let fadeOut = i + 1 < captions.count ? clamp01((captions[i + 1].t - r) / 0.3) : 1
        let a = fadeIn * fadeOut
        guard a > 0.001 else { continue }
        ctx.saveGState(); ctx.setAlpha(a)
        drawText(ctx, c.text("title"), size: 56, weight: .bold, color: color(0xFFFFFF), centerX: Double(width) / 2,
                 y: Double(height) - 112 + (1 - fadeIn) * 12)
        drawText(ctx, c.text("subtitle"), size: 26, weight: .regular, color: color(0xA9B4C8), centerX: Double(width) / 2,
                 y: Double(height) - 160 + (1 - fadeIn) * 12)
        ctx.restoreGState()
    }
}

func drawKeys(_ ctx: CGContext, r: Double) {
    let keys = events.filter { $0.type == "keys" && $0.t <= r }
    guard let e = keys.last, r < e.t + e.number("duration") + 0.2 else { return }
    // Keys typed in a row update one badge, which fades in once.
    var start = e.t
    for k in keys.reversed().dropFirst() where k.t + k.number("duration") + 0.2 > start { start = k.t }
    let a = min(clamp01((r - start) / 0.12), clamp01((e.t + e.number("duration") + 0.2 - r) / 0.2))
    let line = textLine(e.text("text"), size: 30, weight: .semibold, color: color(0xFFFFFF))
    let bounds = CTLineGetBoundsWithOptions(line, [])
    let box = CGRect(x: Double(width) / 2 - bounds.width / 2 - 26, y: 64, width: bounds.width + 52, height: 62)
    ctx.saveGState(); ctx.setAlpha(a)
    ctx.addPath(CGPath(roundedRect: box, cornerWidth: 18, cornerHeight: 18, transform: nil))
    ctx.setFillColor(color(0x15181F, 0.88)); ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 18, cornerHeight: 18, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, 0.18)); ctx.setLineWidth(1); ctx.strokePath()
    ctx.textPosition = CGPoint(x: box.midX - bounds.width / 2, y: box.midY - bounds.height / 2 - bounds.minY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// MARK: Sequence: title card, the recording, closing card

let intro = 2.6, outro = 3.4, crossfade = 0.45
let tourStart = begin - 0.3, tourEnd = end + 0.4
let tourLength = tourEnd - tourStart
let total = intro + tourLength + outro

func render(_ ctx: CGContext, at time: Double) {
    let tourTime = time - intro
    if tourTime < 0 {
        drawCard(ctx, t: time, line: "A fast, native hex editor for macOS", lineColor: color(0xA9B4C8))
        return
    }
    if tourTime > tourLength {
        drawCard(ctx, t: tourTime - tourLength, line: "github.com/letrucdev/hexer", lineColor: color(0x4AA3FF))
        return
    }
    let r = tourStart + tourTime
    drawBackground(ctx)
    let a = min(clamp01(tourTime / crossfade), clamp01((tourLength - tourTime) / crossfade))
    ctx.saveGState(); ctx.setAlpha(a)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    drawRecording(ctx, r: r)
    drawCaption(ctx, r: r)
    drawKeys(ctx, r: r)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// MARK: Encoding

try? FileManager.default.removeItem(at: videoURL)
let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                      AVVideoMaxKeyFrameIntervalKey: fps * 2],
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
])
writer.add(input)
guard writer.startWriting() else { fatalError("cannot write: \(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)

let frameCount = Int((total * Double(fps)).rounded())
for frame in 0..<frameCount {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    guard let buffer else { fatalError("no pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: sRGB, bitmapInfo: bitmapInfo)!
    render(ctx, at: Double(frame) / Double(fps))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
}
input.markAsFinished()
await writer.finishWriting()
guard writer.status == .completed else { fatalError("writing failed: \(String(describing: writer.error))") }
print(String(format: "wrote %@ (%.1f s, %d frames)", videoURL.path, total, frameCount))
