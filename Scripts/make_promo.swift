// Turns the recorded tour (Scripts/record_demo.swift) into the promotional video
// build/promo/hexer-tour.mp4 (1920×1080, 60 fps, H.264 + AAC):
//
// - an animated title: a floor of the app's own bytes, the icon and the wordmark;
// - the window rising from that floor, then the recording with a pointer, click ripples, key
//   badges, camera moves from the app's timeline, and each chapter on a Liquid Glass caption;
// - chapter transitions on the beat (a swing of the window, a light sweep, the caption morphing);
// - a closing grid of features and the download link;
// - a soundtrack made for this cut by Scripts/make_music.py from the cut's cues (cues.json).
//
// Frames are composed with Core Image on the GPU. The video stays local; build/ is not committed.
//
//   Scripts/bundle.sh && swift Scripts/record_demo.swift && swift Scripts/make_promo.swift [--lang vi]
import AppKit
import AVFoundation
import CoreImage
import CoreText
import ImageIO
import Metal

setvbuf(stdout, nil, _IONBF, 0)
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let promo = root.appendingPathComponent("build/promo")
let arguments = CommandLine.arguments
let vietnamese = arguments.firstIndex(of: "--lang").map { $0 + 1 < arguments.count && arguments[$0 + 1] == "vi" } ?? false
let videoURL = promo.appendingPathComponent(vietnamese ? "hexer-tour-vi.mp4" : "hexer-tour.mp4")

let width = 1920, height = 1080, fps = 60
let W = Double(width), H = Double(height)
let frameRect = CGRect(x: 0, y: 0, width: W, height: H)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
/// The soundtrack's tempo: chapters start on its beats.
let beat = 0.75, bar = 3.0

func tr(_ en: String, _ vi: String) -> String { vietnamese ? vi : en }

// MARK: Math

func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp01(x), 3) }
func easeIn(_ x: Double) -> Double { pow(clamp01(x), 3) }
func easeInOut(_ x: Double) -> Double { let t = clamp01(x); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double { easeOut((t - a) / (b - a)) }
func linear(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp01((t - a) / (b - a)) }
func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint { CGPoint(x: mix(a.x, b.x, t), y: mix(a.y, b.y, t)) }

/// A spring from 0 to 1 over `x` seconds-ish (settled by x ≈ 1), overshooting more as `zeta` drops.
func spring(_ x: Double, zeta: Double = 0.55, omega: Double = 12) -> Double {
    guard x > 0 else { return 0 }
    let t = min(x, 2), wd = omega * sqrt(1 - zeta * zeta)
    return 1 - exp(-zeta * omega * t) * (cos(wd * t) + zeta * omega / wd * sin(wd * t))
}

// MARK: Drawing helpers

func cg(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func ci(_ hex: UInt32, _ alpha: Double = 1) -> CIColor { CIColor(cgColor: cg(hex, alpha)) }

let accent: UInt32 = 0x3B82F6, violet: UInt32 = 0x8B5CF6, cyan: UInt32 = 0x22D3EE, mist: UInt32 = 0xA9B4C8

func loadImage(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("cannot read \(url.path)") }
    return image
}

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: bitmapInfo)!
}

func drawing(_ w: Int, _ h: Int, _ body: (CGContext) -> Void) -> CGImage {
    let ctx = makeContext(w, h)
    body(ctx)
    return ctx.makeImage()!
}

func systemFont(_ size: Double, _ weight: NSFont.Weight, mono: Bool = false) -> NSFont {
    mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
}

func textLine(_ string: String, _ font: NSFont, _ color: CGColor, kern: Double = 0) -> CTLine {
    var attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    if kern != 0 { attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = kern }
    return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
}

func lineWidth(_ line: CTLine) -> Double { CTLineGetTypographicBounds(line, nil, nil, nil) }

/// Draws a line with its baseline starting at (x, y).
func draw(_ ctx: CGContext, _ line: CTLine, x: Double, y: Double) {
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

/// A line of text as an image whose origin is the start of its baseline, and its width.
func textImage(_ string: String, size: Double, weight: NSFont.Weight, color: CGColor, kern: Double = 0) -> (image: CIImage, width: Double) {
    let line = textLine(string, systemFont(size, weight), color, kern: kern)
    var ascent: CGFloat = 0, descent: CGFloat = 0
    let w = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
    let pad = 8.0
    let image = drawing(Int(w + pad * 2 + 1), Int(ascent + descent + pad * 2 + 1)) { draw($0, line, x: pad, y: pad + descent) }
    return (CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: -pad, y: -pad - descent)), w)
}

extension CIImage {
    func alpha(_ a: Double) -> CIImage {
        if a >= 0.999 { return self }
        return applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(a, 0))])
    }
    func blurred(_ sigma: Double) -> CIImage { sigma < 0.3 ? self : applyingGaussianBlur(sigma: sigma) }
    func moved(_ x: Double, _ y: Double) -> CIImage { transformed(by: CGAffineTransform(translationX: x, y: y)) }
    /// Scales about a point.
    func scaled(_ s: Double, about p: CGPoint) -> CIImage {
        abs(s - 1) < 1e-4 ? self : transformed(by: CGAffineTransform(translationX: -p.x, y: -p.y)
            .concatenating(CGAffineTransform(scaleX: s, y: s)).concatenating(CGAffineTransform(translationX: p.x, y: p.y)))
    }
}

let clearFrame = CIImage(color: .clear).cropped(to: frameRect)

func radial(_ center: CGPoint, _ radius: Double, _ color: CIColor, cropped: Bool = true) -> CIImage {
    guard color.alpha > 0.001 else { return clearFrame }
    let image = CIFilter(name: "CIRadialGradient", parameters: [
        "inputCenter": CIVector(cgPoint: center), "inputRadius0": 0, "inputRadius1": max(radius, 1),
        "inputColor0": color, "inputColor1": CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 0, colorSpace: sRGB)!,
    ])!.outputImage!
    return cropped ? image.cropped(to: frameRect) : image
}

func roundedRect(_ rect: CGRect, _ radius: Double, _ color: CIColor) -> CIImage {
    CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
        "inputExtent": CIVector(cgRect: rect), "inputRadius": radius, "inputColor": color,
    ])!.outputImage!
}

/// The macOS arrow pointer as a path in points, tip at the origin, y pointing down.
let arrowPath: CGPath = {
    let path = CGMutablePath()
    path.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.6), CGPoint(x: 4.1, y: 12.9), CGPoint(x: 6.9, y: 19.4),
                            CGPoint(x: 9.4, y: 18.3), CGPoint(x: 6.7, y: 12.1), CGPoint(x: 11.9, y: 12.1)])
    path.closeSubpath()
    return path
}()

// MARK: Inputs

struct Event {
    var type: String
    var t: Double
    var fields: [String: Any]
    func number(_ key: String) -> Double { (fields[key] as? NSNumber)?.doubleValue ?? 0 }
    func text(_ key: String) -> String { fields[key] as? String ?? "" }
    var point: CGPoint { CGPoint(x: number("x"), y: number("y")) }
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
let recW = source.width * recScale, recH = source.height * recScale
// Event times on the recording's clock.
let events: [Event] = (timelineInfo["events"] as! [[String: Any]]).map {
    Event(type: $0["type"] as! String, t: ($0["t"] as! NSNumber).doubleValue - firstFrame, fields: $0)
}
let end = events.first { $0.type == "end" }!.t
let moves = events.filter { $0.type == "move" }, clicks = events.filter { $0.type == "click" }
let keyEvents = events.filter { $0.type == "keys" }, focusEvents = events.filter { $0.type == "focus" }

/// Window points (from the top-left corner) to recording pixels in Core Image space (bottom-up).
func recPoint(_ p: CGPoint) -> CGPoint {
    CGPoint(x: (windowOrigin.x + p.x) * recScale, y: recH - (windowOrigin.y + p.y) * recScale)
}

// MARK: Copy

let chapterCopy: [String: (title: String, subtitle: String)] = [
    "inspect": (tr("Inspect every byte", "Soi từng byte"),
                tr("Click a byte and the inspector decodes it as thirty data types.",
                   "Bấm vào một byte, Data Inspector giải mã nó thành ba mươi kiểu dữ liệu.")),
    "edit": (tr("Edit in place", "Sửa ngay tại chỗ"),
             tr("Type over bytes in hex. Changes stay red until saved, and undo is unlimited.",
                "Gõ đè byte bằng hex. Chỗ sửa hiện màu đỏ đến khi lưu, hoàn tác không giới hạn.")),
    "find": (tr("Find anything", "Tìm mọi thứ"),
             tr("Text, hex, integers and floats. Find All lists every match.",
                "Chuỗi, hex, số nguyên và số thực. Find All liệt kê mọi kết quả.")),
    "disasm": (tr("Read machine code", "Đọc mã máy"),
               tr("Search for a byte pattern, and the inspector disassembles x86 and ARM64.",
                  "Tìm một mẫu byte, Data Inspector dịch ngược thành lệnh x86 và ARM64.")),
    "checksums": (tr("Verify integrity", "Kiểm tra toàn vẹn"),
                  tr("CRC-32, MD5, SHA-1, SHA-256 and more, computed in the background.",
                     "CRC-32, MD5, SHA-1, SHA-256 và nhiều thuật toán khác, tính ngầm phía sau.")),
    "stats": (tr("See the shape of your data", "Nhìn thấy hình dạng dữ liệu"),
              tr("A byte histogram of the file or a selection, with its entropy.",
                 "Biểu đồ tần suất byte của cả tệp hoặc vùng chọn, kèm entropy.")),
    "firmware": (tr("Firmware images", "Ảnh firmware"),
                 tr("Import Intel Hex or S-Record. Gaps between records fold away.",
                    "Nhập Intel Hex hoặc S-Record. Khoảng trống giữa các bản ghi được gập lại.")),
    "appearance": (tr("Light or dark", "Sáng hay tối"),
                   tr("A native macOS app with Liquid Glass, in English and Vietnamese.",
                      "Ứng dụng macOS thuần với Liquid Glass, có tiếng Anh và tiếng Việt.")),
]
let introTagline = tr("A fast, native hex editor for macOS", "Trình sửa hex nhanh, thuần macOS")
let gridHeading = tr("Everything a hex editor should do", "Mọi thứ một trình sửa hex cần có")
let finaleTagline = tr("Native on macOS 15 and later", "Thuần macOS, chạy từ macOS 15 trở lên")
let finaleLink = "github.com/letrucdev/hexer"
let features: [(symbol: String, title: String)] = [
    ("number", tr("30 data types", "30 kiểu dữ liệu")),
    ("arrow.uturn.backward", tr("Unlimited undo", "Hoàn tác vô hạn")),
    ("magnifyingglass", tr("Find & replace", "Tìm và thay thế")),
    ("cpu", tr("x86 & ARM64", "x86 và ARM64")),
    ("checkmark.seal", tr("Checksums", "Checksum")),
    ("chart.bar.xaxis", tr("Byte statistics", "Thống kê byte")),
    ("memorychip", tr("Intel Hex & S-Record", "Intel Hex, S-Record")),
    ("internaldrive", tr("Disks & images", "Ổ đĩa và ảnh đĩa")),
    ("square.split.2x1", tr("File compare", "So sánh tệp")),
    ("bolt", tr("Files of any size", "Tệp mọi kích thước")),
]
func keyText(_ text: String) -> String {
    switch text {
    case "Appearance: Light": tr(text, "Giao diện: Sáng")
    case "Appearance: Dark": tr(text, "Giao diện: Tối")
    default: text
    }
}

// MARK: The cut: title, chapters on the beat, closing

struct Scene {
    let id: String
    let r0: Double, r1: Double  // recording
    let v0: Double, v1: Double  // video
}

let introLength = 6.0, outroLength = 12.0
let scenes: [Scene] = {
    let captions = events.filter { $0.type == "caption" }
    var result: [Scene] = []
    var v = introLength
    for (i, c) in captions.enumerated() {
        let last = i + 1 == captions.count
        // The app quits right after the end, so the recording's last frames are empty.
        let r1 = last ? end - 0.05 : captions[i + 1].t
        let d = r1 - c.t
        // Each chapter lasts whole beats (its recording plays a few percent faster or slower);
        // the last one holds its final frame until the bar ends.
        let length = last ? ((v + d - introLength) / bar).rounded(.up) * bar + introLength - v : max(4 * beat, (d / beat).rounded() * beat)
        result.append(Scene(id: c.text("id"), r0: c.t, r1: r1, v0: v, v1: v + length))
        v += length
    }
    return result
}()
let outroStart = scenes.last!.v1
let total = outroStart + outroLength

/// The recording time shown at a video time.
func recordingTime(_ v: Double) -> Double {
    let first = scenes[0]
    if v < first.v0 { return max(0, first.r0 - (first.v0 - v)) }
    for (i, s) in scenes.enumerated() where v < s.v1 {
        let d = s.r1 - s.r0
        return i == scenes.count - 1 ? s.r0 + min(v - s.v0, d) : s.r0 + (v - s.v0) * d / (s.v1 - s.v0)
    }
    return scenes.last!.r1
}

/// The video time of a recording time (for the soundtrack's cues).
func videoTime(_ r: Double) -> Double {
    let first = scenes[0]
    if r < first.r0 { return first.v0 - (first.r0 - r) }
    for (i, s) in scenes.enumerated() where r < s.r1 || i == scenes.count - 1 {
        let d = s.r1 - s.r0
        return i == scenes.count - 1 ? s.v0 + (r - s.r0) : s.v0 + (r - s.r0) * (s.v1 - s.v0) / d
    }
    return outroStart
}

func sceneIndex(at v: Double) -> Int? { scenes.lastIndex { $0.v0 <= v } }

// MARK: The soundtrack

let intro = (logo: 0.5, wordmark: 1.0, tagline: 1.9, exit: 4.2, rise: 4.4)
let finale = 6.0  // after the outro starts: logo and final chord
/// `--stills 6.5,20` saves those frames as PNGs instead of making the video.
let stills = arguments.firstIndex(of: "--stills").map { arguments[$0 + 1].split(separator: ",").compactMap { Double($0) } }
do {
    let cues: [String: Any] = [
        "bpm": 60 / beat, "duration": total, "drop": introLength, "logo": intro.logo, "rise": intro.rise,
        "scenes": scenes.map(\.v0), "outro": outroStart, "finale": outroStart + finale,
        "clicks": clicks.map { videoTime($0.t) },
        "typing": keyEvents.filter { $0.text("style") == "typing" }.map { videoTime($0.t) },
        "shortcuts": keyEvents.filter { $0.text("style") == "shortcut" }.map { videoTime($0.t) },
        "menus": keyEvents.filter { $0.text("style") == "menu" }.map { videoTime($0.t) },
        "appearance": events.filter { $0.type == "appearance" }.map { videoTime($0.t) },
    ]
    try JSONSerialization.data(withJSONObject: cues, options: [.prettyPrinted, .sortedKeys]).write(to: promo.appendingPathComponent("cues.json"))
}
if stills == nil {
    let music = Process()
    music.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    music.arguments = ["python3", root.appendingPathComponent("Scripts/make_music.py").path,
                       promo.appendingPathComponent("cues.json").path, promo.appendingPathComponent("music.wav").path]
    try music.run()
    music.waitUntilExit()
    guard music.terminationStatus == 0 else { fatalError("Scripts/make_music.py failed") }
}
print(String(format: "cut: %.1f s, %d chapters, outro at %.1f s", total, scenes.count, outroStart))

// MARK: Recording frames

final class Frames {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    var current: (time: Double, pixels: CVPixelBuffer)?
    var pending: (time: Double, pixels: CVPixelBuffer)?
    var finished = false

    init(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
    }

    private func next() -> (time: Double, pixels: CVPixelBuffer)? {
        guard !finished, let sample = output.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) else {
            finished = true
            return nil
        }
        return (CMSampleBufferGetPresentationTimeStamp(sample).seconds, pixels)
    }

    /// The last frame shown at or before `time` (times only increase).
    func frame(at time: Double) -> CVPixelBuffer? {
        if current == nil { current = next() }
        while true {
            if pending == nil { pending = next() }
            guard let p = pending, p.time <= time else { break }
            current = p
            pending = nil
        }
        return current?.pixels
    }
}

let frames = try await Frames(promo.appendingPathComponent("recording.mov"))

// MARK: Patches over the sharing indicator

/// While a window is captured, macOS draws an indicator over its traffic lights. The document
/// window's corner is covered with the same corner of a clean snapshot (taken by the app just
/// before recording), feathered towards the inside of the window.
func feathered(_ piece: CGImage, feather: Double, edges: (left: Bool, right: Bool, top: Bool, bottom: Bool)) -> CGImage {
    let w = piece.width, h = piece.height
    let ctx = makeContext(w, h)
    ctx.draw(piece, in: CGRect(x: 0, y: 0, width: w, height: h))
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let row = ctx.bytesPerRow
    for y in 0..<h {  // y counts from the top
        for x in 0..<w {
            var a = 1.0
            if edges.left { a *= clamp01(Double(x) / feather) }
            if edges.right { a *= clamp01(Double(w - 1 - x) / feather) }
            if edges.top { a *= clamp01(Double(y) / feather) }
            if edges.bottom { a *= clamp01(Double(h - 1 - y) / feather) }
            guard a < 1 else { continue }
            for c in 0..<4 { data[y * row + x * 4 + c] = UInt8(Double(data[y * row + x * 4 + c]) * a) }
        }
    }
    return ctx.makeImage()!
}

let cleanImages = ["dark": loadImage(promo.appendingPathComponent("clean-dark.png")), "light": loadImage(promo.appendingPathComponent("clean-light.png"))]
let cleanScale = Double(cleanImages["dark"]!.width) / windowFrame.width
let cornerPatches = cleanImages.mapValues { clean in
    let crop = CGRect(x: 4 * cleanScale, y: 4 * cleanScale, width: 110 * cleanScale, height: 46 * cleanScale).integral
    return CIImage(cgImage: feathered(clean.cropping(to: crop)!, feather: 6 * cleanScale, edges: (false, true, false, true)))
        .transformed(by: CGAffineTransform(scaleX: recScale / cleanScale, y: recScale / cleanScale))
        .moved((windowOrigin.x + 4) * recScale, recH - (windowOrigin.y + 4 + 46) * recScale)
}

/// The Statistics window opens and closes with an animation, so its indicator is found in each
/// frame (a purple capsule in its title bar) and covered with traffic lights from the clean
/// snapshot (whose middle light sits at (49, 26) points).
let statsEvent = events.first { $0.type == "window" }
let statsFrame: CGRect? = statsEvent.map {
    let f = ($0.fields["frame"] as! [NSNumber]).map(\.doubleValue)
    return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
}
/// From the window opening to the end of its chapter (it closes before that).
let statsTimes: ClosedRange<Double>? = statsEvent.map { e in e.t - 0.05...(scenes.first { $0.r0 <= e.t && e.t < $0.r1 }?.r1 ?? end) }
let lightsPiece = feathered(cleanImages["dark"]!.cropping(to: CGRect(x: 14 * cleanScale, y: 14 * cleanScale, width: 70 * cleanScale, height: 24 * cleanScale).integral)!,
                            feather: 3 * cleanScale, edges: (true, true, true, true))

func indicatorPatch(_ pixels: CVPixelBuffer, at r: Double) -> CIImage? {
    guard let stats = statsFrame, statsTimes?.contains(r) == true else { return nil }
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
    let row = CVPixelBufferGetBytesPerRow(pixels)
    let x0 = Int((windowOrigin.x + stats.minX - 6) * recScale), x1 = Int((windowOrigin.x + stats.minX + 96) * recScale)
    let y0 = Int((windowOrigin.y + stats.minY - 6) * recScale), y1 = Int((windowOrigin.y + stats.minY + 34) * recScale)
    var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min, count = 0, blue = 0
    for y in max(0, y0)..<min(Int(recH), y1) {
        for x in stride(from: max(0, x0), to: min(Int(recW), x1), by: 1) {
            let p = base + y * row + x * 4
            let b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
            // The indicator is (117, 117, 223): blue with red and green alike, unlike the
            // app's blue text and controls.
            guard b > 110, b > r + 60, abs(r - g) < 12, r > 40 else { continue }
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            count += 1
            blue += b
        }
    }
    guard count > 200 else { return nil }
    // Fainter while the window fades in or out.
    let opacity = clamp01((Double(blue) / Double(count) - 60) / 160)
    let box = CGRect(x: minX - 3, y: minY - 3, width: maxX - minX + 7, height: maxY - minY + 7)
    let s = box.width / (66 * recScale)
    let lights = CGSize(width: Double(lightsPiece.width) / cleanScale * recScale * s, height: Double(lightsPiece.height) / cleanScale * recScale * s)
    let fill = CIImage(color: ci(0x272729)).cropped(to: CGRect(x: box.minX, y: recH - box.maxY, width: box.width, height: box.height))
    let piece = CIImage(cgImage: lightsPiece)
        .transformed(by: CGAffineTransform(scaleX: lights.width / Double(lightsPiece.width), y: lights.height / Double(lightsPiece.height)))
        .moved(box.midX - lights.width / 2, recH - box.midY - lights.height / 2)
    return piece.composited(over: fill).alpha(opacity)
}

// MARK: Timeline state at a recording time

func appearance(at r: Double) -> String {
    events.last { $0.type == "appearance" && $0.t <= r }?.text("value") ?? "dark"
}

/// Minimum-jerk easing: no sudden change of speed or acceleration at either end, the profile
/// of a hand moving a pointer.
func smooth(_ x: Double) -> Double { let t = clamp01(x); return t * t * t * (t * (t * 6 - 15) + 10) }

/// The pointer in window points. Moves follow a slight arc, except sweeps along a row.
func pointerPosition(at r: Double) -> CGPoint? {
    var position: CGPoint?
    for e in moves where e.t <= r {
        let d = e.number("duration")
        guard let from = position, d > 0 else { position = e.point; continue }
        let u = smooth((r - e.t) / d)
        var p = mix(from, e.point, u)
        let dx = e.point.x - from.x, dy = e.point.y - from.y, length = hypot(dx, dy)
        if length > 40, e.fields["straight"] == nil {
            let bow = min(length * 0.07, 36) * sin(.pi * u)
            p.x += -dy / length * bow
            p.y += dx / length * bow
        }
        position = p
    }
    return position
}

func lastClick(at r: Double) -> Double? {
    clicks.last { $0.t <= r && r - $0.t < 0.9 }.map { r - $0.t }
}

// MARK: Camera

/// The area the window fills when the camera is out, below the captions.
let baseScale = 0.55
let captionHeight = 92.0, captionTop = 34.0
let stageCenter = CGPoint(x: W / 2, y: H - 140 - windowFrame.height * recScale * baseScale / 2)
let windowRect = CGRect(x: windowOrigin.x * recScale, y: recH - (windowOrigin.y + windowFrame.height) * recScale,
                        width: windowFrame.width * recScale, height: windowFrame.height * recScale)

/// Where the camera looks (window points) and how close.
struct CameraView {
    var center: CGPoint
    var zoom: Double
}

/// The camera's center at a zoom, moved so that a zoomed-in window keeps filling the frame below
/// the folded caption, and a zoomed-out one stays inside it.
func clamped(_ view: CameraView) -> CameraView {
    let s = baseScale * view.zoom
    var focus = recPoint(view.center)
    let top = H - 16 - captionHeight * 0.66 - 8
    let ax = windowRect.minX + stageCenter.x / s, bx = windowRect.maxX - (W - stageCenter.x) / s
    let ay = windowRect.minY + stageCenter.y / s, by = windowRect.maxY - (top - stageCenter.y) / s
    focus.x = min(max(focus.x, min(ax, bx)), max(ax, bx))
    focus.y = min(max(focus.y, min(ay, by)), max(ay, by))
    return CameraView(center: CGPoint(x: focus.x / recScale - windowOrigin.x, y: (recH - focus.y) / recScale - windowOrigin.y), zoom: view.zoom)
}

/// The camera's moves, one per focus event: an eased glide (1.6 s in, 1.5 s out) that zooms on a
/// log scale about the one point that stays put on screen, so the picture never slides sideways
/// while it grows or shrinks.
struct CameraMove {
    let start: Double, duration: Double
    let from: CameraView, to: CameraView

    func view(at t: Double) -> CameraView {
        let u = smooth((t - start) / duration)
        let z0 = from.zoom, z1 = to.zoom
        let zoom = exp(mix(log(z0), log(z1), u))
        guard abs(log(z1 / z0)) > 0.02 else { return CameraView(center: mix(from.center, to.center, u), zoom: zoom) }
        func axis(_ c0: Double, _ c1: Double) -> Double {
            let fixed = (z1 * c1 - z0 * c0) / (z1 - z0)
            return fixed - (fixed - c0) * z0 / zoom
        }
        return CameraView(center: CGPoint(x: axis(from.center.x, to.center.x), y: axis(from.center.y, to.center.y)), zoom: zoom)
    }
}

let cameraMoves: [CameraMove] = {
    var moves: [CameraMove] = []
    var current = clamped(CameraView(center: CGPoint(x: windowFrame.width / 2, y: windowFrame.height / 2), zoom: 1))
    for e in focusEvents {
        let start = videoTime(e.t)
        if let last = moves.last { current = last.view(at: start) }
        // A little closer than the app asked: the window fills more of the frame than it did on screen.
        let target = clamped(CameraView(center: e.point, zoom: 1 + (e.number("zoom") - 1) * 1.25))
        let duration = target.zoom > current.zoom + 0.01 ? 1.6 : target.zoom < current.zoom - 0.01 ? 1.5 : 1.2
        moves.append(CameraMove(start: start, duration: duration, from: current, to: target))
    }
    return moves
}()

func cameraView(at t: Double) -> CameraView {
    cameraMoves.last { $0.start <= t }?.view(at: t)
        ?? clamped(CameraView(center: CGPoint(x: windowFrame.width / 2, y: windowFrame.height / 2), zoom: 1))
}

/// Maps recording pixels to the video (before any 3D turn).
struct Placement {
    var focus: CGPoint
    var scale: Double
    var center: CGPoint
    func apply(_ p: CGPoint) -> CGPoint { CGPoint(x: center.x + (p.x - focus.x) * scale, y: center.y + (p.y - focus.y) * scale) }
    var transform: CGAffineTransform {
        CGAffineTransform(translationX: -focus.x, y: -focus.y).concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    }
}

func placement(_ view: CameraView, extraScale: Double = 1, offset: CGPoint = .zero) -> Placement {
    Placement(focus: recPoint(view.center), scale: baseScale * view.zoom * extraScale,
              center: CGPoint(x: stageCenter.x + offset.x, y: stageCenter.y + offset.y))
}

/// A 3D turn of the window's plane about `pivot`, seen from `focal` pixels away.
struct Turn {
    var yaw = 0.0, pitch = 0.0  // radians: yaw turns the right side away, pitch tips the top away
    var pivot = stageCenter
    let focal = 2200.0
    var isFlat: Bool { abs(yaw) < 1e-5 && abs(pitch) < 1e-5 }

    func apply(_ p: CGPoint) -> (point: CGPoint, scale: Double) {
        let x = p.x - pivot.x, y = p.y - pivot.y
        let y1 = y * cos(pitch), z1 = y * sin(pitch)
        let x2 = x * cos(yaw), z2 = z1 + x * sin(yaw)
        let k = focal / max(focal + z2, 1)
        return (CGPoint(x: pivot.x + x2 * k, y: pivot.y + y1 * k), k)
    }

    func warp(_ image: CIImage) -> CIImage {
        guard !isFlat else { return image }
        let area = frameRect.insetBy(dx: -320, dy: -320)
        let full = image.composited(over: CIImage(color: .clear).cropped(to: area)).cropped(to: area)
        return full.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: apply(CGPoint(x: area.minX, y: area.maxY)).point),
            "inputTopRight": CIVector(cgPoint: apply(CGPoint(x: area.maxX, y: area.maxY)).point),
            "inputBottomRight": CIVector(cgPoint: apply(CGPoint(x: area.maxX, y: area.minY)).point),
            "inputBottomLeft": CIVector(cgPoint: apply(CGPoint(x: area.minX, y: area.minY)).point),
        ])
    }
}

// MARK: Background

let dotGrid: CIImage = {
    let spacing = 36
    let image = drawing(spacing, spacing) { ctx in
        ctx.setFillColor(cg(0xFFFFFF, 0.07))
        ctx.fillEllipse(in: CGRect(x: Double(spacing) / 2 - 1.1, y: Double(spacing) / 2 - 1.1, width: 2.2, height: 2.2))
    }
    return CIImage(cgImage: image).applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: CGAffineTransform.identity])
}()

func background(_ t: Double, energy: Double) -> CIImage {
    let base = CIFilter(name: "CILinearGradient", parameters: [
        "inputPoint0": CIVector(x: 0, y: H), "inputPoint1": CIVector(x: 0, y: 0),
        "inputColor0": ci(0x060912), "inputColor1": ci(0x0B1124),
    ])!.outputImage!.cropped(to: frameRect)
    let glow = 1 + 0.45 * energy
    let blobs = [
        radial(CGPoint(x: W * 0.2 + 140 * sin(t * 0.21), y: H * 0.86 + 90 * cos(t * 0.17)), 820, ci(0x2563EB, 0.42 * glow)),
        radial(CGPoint(x: W * 0.84 + 150 * sin(t * 0.13 + 1), y: H * 0.22 + 100 * cos(t * 0.19)), 760, ci(0x7C3AED, 0.32 * glow)),
        radial(CGPoint(x: W * 0.52 + 260 * sin(t * 0.09 + 2), y: -40 + 70 * sin(t * 0.23)), 700, ci(0x06B6D4, 0.22 * glow)),
    ]
    var image = base
    for blob in blobs { image = blob.composited(over: image) }
    let drift = (t * 7).truncatingRemainder(dividingBy: 36)
    image = dotGrid.moved(drift, drift * 0.5).cropped(to: frameRect).composited(over: image)
    let vignette = CIFilter(name: "CIRadialGradient", parameters: [
        "inputCenter": CIVector(x: W / 2, y: H / 2), "inputRadius0": 620, "inputRadius1": 1250,
        "inputColor0": ci(0x000000, 0), "inputColor1": ci(0x000000, 0.55),
    ])!.outputImage!.cropped(to: frameRect)
    return vignette.composited(over: image)
}

// MARK: The title: a floor of bytes

let hexFloor: CIImage = {
    let bytes = [UInt8](try! Data(contentsOf: promo.appendingPathComponent("samples/Hexer"), options: .mappedIfSafe).prefix(0x6000))
    let font = systemFont(26, .medium, mono: true)
    let rowHeight = 44.0, rows = 48, columns = 3
    let columnWidth = 1080.0
    return CIImage(cgImage: drawing(Int(columnWidth) * columns, Int(rowHeight) * rows) { ctx in
        for column in 0..<columns {
            for row in 0..<rows {
                let offset = 0x2900 + (column * rows + row) * 16
                let y = Double(rows - 1 - row) * rowHeight + 12
                let x = Double(column) * columnWidth + 40
                draw(ctx, textLine(String(format: "%08X", offset), font, cg(0x5B8DEF, 0.75)), x: x, y: y)
                let hex = bytes[offset..<offset + 16].map { String(format: "%02X", $0) }.joined(separator: " ")
                draw(ctx, textLine(hex, font, cg(0xFFFFFF, 0.9)), x: x + 170, y: y)
            }
        }
    }).applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: CGAffineTransform.identity])
}()

/// The floor scrolls towards the viewer; a bright band sweeps across it once a bar.
func floorLayer(_ t: Double, speedUp: Double) -> CIImage {
    let area = CGRect(x: 0, y: 0, width: 3240, height: 1700)
    let scroll = t * 46 + 900 * speedUp
    let plane = hexFloor.moved(0, -scroll).cropped(to: area)
    let dim = plane.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0.32, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.5, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.34),
    ])
    let band = area.height * (1 - (t / bar).truncatingRemainder(dividingBy: 1)) * 1.3 - 150
    let bandImage = CIFilter(name: "CISmoothLinearGradient", parameters: [
        "inputPoint0": CIVector(x: 0, y: band), "inputPoint1": CIVector(x: 0, y: band + 170),
        "inputColor0": ci(0xFFFFFF, 1), "inputColor1": ci(0xFFFFFF, 0),
    ])!.outputImage!.cropped(to: CGRect(x: 0, y: band, width: area.width, height: 170))
        .composited(over: CIFilter(name: "CISmoothLinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: band), "inputPoint1": CIVector(x: 0, y: band - 170),
            "inputColor0": ci(0xFFFFFF, 1), "inputColor1": ci(0xFFFFFF, 0),
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: band - 170, width: area.width, height: 170)))
    let bright = plane.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0.55, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.9, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.95),
    ]).applyingFilter("CIBlendWithAlphaMask", parameters: [
        kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: area), kCIInputMaskImageKey: bandImage,
    ])
    let floor = bright.composited(over: dim).cropped(to: area)
    let horizon = H * 0.5
    let warped = floor.applyingFilter("CIPerspectiveTransform", parameters: [
        "inputTopLeft": CIVector(x: W / 2 - 620, y: horizon), "inputTopRight": CIVector(x: W / 2 + 620, y: horizon),
        "inputBottomRight": CIVector(x: W + 1100, y: -260), "inputBottomLeft": CIVector(x: -1100, y: -260),
    ]).cropped(to: frameRect)
    // Fades out towards the horizon.
    let fade = CIFilter(name: "CISmoothLinearGradient", parameters: [
        "inputPoint0": CIVector(x: 0, y: horizon), "inputPoint1": CIVector(x: 0, y: H * 0.12),
        "inputColor0": ci(0xFFFFFF, 0), "inputColor1": ci(0xFFFFFF, 1),
    ])!.outputImage!.cropped(to: frameRect)
    let glow = radial(CGPoint(x: W / 2, y: horizon), 900, ci(accent, 0.22), cropped: false)
        .transformed(by: CGAffineTransform(translationX: -W / 2, y: -horizon).concatenating(CGAffineTransform(scaleX: 1, y: 0.28))
            .concatenating(CGAffineTransform(translationX: W / 2, y: horizon))).cropped(to: frameRect)
    return glow.composited(over: warped.applyingFilter("CIBlendWithAlphaMask", parameters: [
        kCIInputBackgroundImageKey: clearFrame, kCIInputMaskImageKey: fade,
    ]))
}

// MARK: Title and closing elements

let iconImage = CIImage(cgImage: loadImage(root.appendingPathComponent("Resources/Icon/AppIcon.iconset/icon_512x512@2x.png")))

/// The icon centered at `center`, `size` pixels wide, with a glow behind it.
func logo(center: CGPoint, size: Double, glow: Double) -> CIImage {
    let s = size / iconImage.extent.width
    let icon = iconImage.transformed(by: CGAffineTransform(scaleX: s, y: s)).moved(center.x - size / 2, center.y - size / 2)
    let halo = radial(center, size * 1.5, ci(accent, 0.55 * glow)).composited(over: radial(center, size * 2.6, ci(violet, 0.22 * glow)))
    return icon.composited(over: halo)
}

/// "Hexer", one image per letter with its pen position, so the letters can arrive one by one.
func wordmark(size: Double) -> [(image: CIImage, x: Double)] {
    let font = systemFont(size, .bold)
    let full = textLine("Hexer", font, cg(0xFFFFFF), kern: -size * 0.02)
    var x = 0.0
    var letters: [(CIImage, Double)] = []
    for (i, ch) in "Hexer".enumerated() {
        letters.append((textImage(String(ch), size: size, weight: .bold, color: cg(0xFFFFFF)).image, x))
        x = CTLineGetOffsetForStringIndex(full, i + 1, nil)
    }
    let width = lineWidth(full)
    return letters.map { ($0.0, $0.1 - width / 2) }
}
let titleLetters = wordmark(size: 150), finaleLetters = wordmark(size: 128)
let titleIcon = CGPoint(x: W / 2, y: H / 2 + 175), finaleIcon = CGPoint(x: W / 2, y: H / 2 + 185)

func letters(_ letters: [(image: CIImage, x: Double)], baseline: CGPoint, start: Double, at t: Double) -> CIImage {
    var image = clearFrame
    for (i, letter) in letters.enumerated() {
        let u = t - (start + 0.07 * Double(i))
        guard u > 0 else { continue }
        let k = spring(u / 0.8, zeta: 0.62)
        image = letter.image.blurred(14 * (1 - clamp01(u / 0.4)))
            .moved(baseline.x + letter.x, baseline.y - 46 * (1 - k)).alpha(clamp01(u / 0.3))
            .composited(over: image)
    }
    return image
}

func symbolImage(_ name: String, size: Double, color: CGColor) -> CGImage? {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
    // At twice the size, for sharp edges; the template symbol is drawn, then filled with the color.
    let w = Int((symbol.size.width * 2).rounded(.up)), h = Int((symbol.size.height * 2).rounded(.up))
    return drawing(w, h) { ctx in
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ctx.scaleBy(x: 2, y: 2)
        symbol.draw(in: CGRect(origin: .zero, size: symbol.size))
        NSGraphicsContext.restoreGraphicsState()
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    }
}

let tileSize = CGSize(width: 300, height: 132)
let tiles: [CIImage] = features.map { feature in
    let scale = 2.0
    let image = drawing(Int(tileSize.width * scale), Int(tileSize.height * scale)) { ctx in
        ctx.scaleBy(x: scale, y: scale)
        let box = CGRect(origin: .zero, size: tileSize).insetBy(dx: 1, dy: 1)
        let shape = CGPath(roundedRect: box, cornerWidth: 24, cornerHeight: 24, transform: nil)
        ctx.addPath(shape); ctx.setFillColor(cg(0x0E1428, 0.72)); ctx.fillPath()
        ctx.saveGState(); ctx.addPath(shape); ctx.clip()
        let sheen = CGGradient(colorsSpace: sRGB, colors: [cg(0xFFFFFF, 0.10), cg(0xFFFFFF, 0.0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.midY), options: [])
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 24, cornerHeight: 24, transform: nil))
        ctx.setStrokeColor(cg(0xFFFFFF, 0.16)); ctx.setLineWidth(1); ctx.strokePath()
        // The icon on a tinted square.
        let well = CGRect(x: 22, y: box.maxY - 22 - 50, width: 50, height: 50)
        ctx.addPath(CGPath(roundedRect: well, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.saveGState(); ctx.clip()
        let tint = CGGradient(colorsSpace: sRGB, colors: [cg(accent, 0.9), cg(violet, 0.9)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(tint, start: CGPoint(x: well.minX, y: well.maxY), end: CGPoint(x: well.maxX, y: well.minY), options: [])
        ctx.restoreGState()
        if let symbol = symbolImage(feature.symbol, size: 24, color: cg(0xFFFFFF)) {
            let w = Double(symbol.width) / 2, h = Double(symbol.height) / 2
            ctx.draw(symbol, in: CGRect(x: well.midX - w / 2, y: well.midY - h / 2, width: w, height: h))
        }
        draw(ctx, textLine(feature.title, systemFont(25, .semibold), cg(0xFFFFFF)), x: 24, y: 28)
    }
    return CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
}

let heading = textImage(gridHeading, size: 56, weight: .bold, color: cg(0xFFFFFF), kern: -0.6)
let finaleLine = textImage(finaleTagline, size: 34, weight: .regular, color: cg(mist))
let linkPill: CIImage = {
    let text = textLine(finaleLink, systemFont(30, .semibold), cg(0xFFFFFF))
    let w = lineWidth(text) + 56 + 46, h = 68.0, scale = 2.0
    let image = drawing(Int(w * scale), Int(h * scale)) { ctx in
        ctx.scaleBy(x: scale, y: scale)
        let box = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        ctx.clip()
        let fill = CGGradient(colorsSpace: sRGB, colors: [cg(0x2F7BF5), cg(0x7C4DFF)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: 0), end: CGPoint(x: w, y: h), options: [])
        if let symbol = symbolImage("arrow.down.circle.fill", size: 26, color: cg(0xFFFFFF)) {
            let sw = Double(symbol.width) / 2, sh = Double(symbol.height) / 2
            ctx.draw(symbol, in: CGRect(x: 26, y: h / 2 - sh / 2, width: sw, height: sh))
        }
        draw(ctx, text, x: 26 + 40, y: h / 2 - 10)
    }
    return CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
}()

// MARK: Overlays drawn with Core Graphics

func ring(_ ctx: CGContext, center: CGPoint, progress u: Double, from r0: Double, to r1: Double, color: UInt32) {
    guard u > 0, u < 1 else { return }
    let r = mix(r0, r1, easeOut(u))
    ctx.setStrokeColor(cg(color, 0.55 * (1 - u)))
    ctx.setLineWidth(3 + 5 * (1 - u))
    ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
}

func drawPointer(_ ctx: CGContext, tip: CGPoint, size: Double, press: Double?, trail: [CGPoint], alpha: Double) {
    guard alpha > 0.01 else { return }
    ctx.saveGState()
    ctx.setAlpha(alpha)
    if let press {
        // Click ripple.
        let k = clamp01(press / 0.75)
        let radius = (6 + 30 * easeOut(k)) * size
        let ring = CGRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2)
        ctx.setFillColor(cg(0x4AA3FF, 0.24 * (1 - k)))
        ctx.fillEllipse(in: ring)
        ctx.setStrokeColor(cg(0xFFFFFF, 0.8 * (1 - k)))
        ctx.setLineWidth(2.5)
        ctx.strokeEllipse(in: ring)
    }
    let squeeze = press.map { 1 - 0.12 * sin(.pi * clamp01($0 / 0.26)) } ?? 1
    func arrow(at p: CGPoint, opacity: Double) {
        let k = size * 1.3 * squeeze
        ctx.saveGState()
        ctx.setAlpha(alpha * opacity)
        ctx.translateBy(x: p.x, y: p.y)
        ctx.scaleBy(x: k, y: -k)
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 7, color: cg(0x000000, 0.45))
        ctx.addPath(arrowPath)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(2.2)
        ctx.setStrokeColor(cg(0xFFFFFF))
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(arrowPath)
        ctx.setFillColor(cg(0x000000))
        ctx.fillPath()
        ctx.restoreGState()
    }
    // A faint trail while moving fast, like motion blur.
    for (i, p) in trail.enumerated() where hypot(p.x - tip.x, p.y - tip.y) > 3 {
        arrow(at: p, opacity: 0.16 * Double(trail.count - i) / Double(trail.count))
    }
    arrow(at: tip, opacity: 1)
    ctx.restoreGState()
}

/// A rounded rectangle of glass: the blurred video behind it (from the mask) and this tint.
struct Glass {
    var rect: CGRect
    var radius: Double
    var alpha: Double
}

func glassTint(_ ctx: CGContext, _ glass: Glass, shadow: Bool = true) {
    let path = CGPath(roundedRect: glass.rect, cornerWidth: glass.radius, cornerHeight: glass.radius, transform: nil)
    ctx.saveGState()
    ctx.setAlpha(glass.alpha)
    if shadow { ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 36, color: cg(0x000000, 0.45)) }
    ctx.addPath(path); ctx.setFillColor(cg(0x0A0F1E, 0.46)); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let sheen = CGGradient(colorsSpace: sRGB, colors: [cg(0xFFFFFF, 0.14), cg(0xFFFFFF, 0.02)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: glass.rect.maxY), end: CGPoint(x: 0, y: glass.rect.minY), options: [])
    ctx.restoreGState()
    let edge = glass.rect.insetBy(dx: 0.5, dy: 0.5)
    ctx.addPath(CGPath(roundedRect: edge, cornerWidth: glass.radius - 0.5, cornerHeight: glass.radius - 0.5, transform: nil))
    ctx.setStrokeColor(cg(0xFFFFFF, 0.24)); ctx.setLineWidth(1); ctx.strokePath()
    ctx.restoreGState()
}

// MARK: The chapter caption

struct Caption {
    let number: String
    let title: CTLine
    let subtitle: CTLine
    let width: Double, compactWidth: Double
    init(_ index: Int) {
        let copy = chapterCopy[scenes[index].id] ?? (scenes[index].id, "")
        number = String(format: "%02d", index + 1)
        title = textLine(copy.title, systemFont(33, .bold), cg(0xFFFFFF), kern: -0.3)
        subtitle = textLine(copy.subtitle, systemFont(21, .regular), cg(0xFFFFFF, 0.74))
        width = 22 + 50 + 20 + max(lineWidth(title), lineWidth(subtitle)) + 34
        compactWidth = 22 + 50 + 20 + lineWidth(title) + 34
    }
    func width(compact: Double) -> Double { mix(width, compactWidth, compact) }
}
let captions = scenes.indices.map(Caption.init)

struct CaptionState {
    var glass: Glass
    var from: Caption?
    var to: Caption
    var morph: Double
    var compact: Double
}

/// The caption at time t (nil when hidden). While the camera is in close it folds to its title,
/// smaller and higher, leaving the window in view.
func captionState(_ t: Double, zoom: Double) -> CaptionState? {
    guard let k = sceneIndex(at: t) else { return nil }
    let shown = ramp(t, scenes[0].v0 + 0.05, scenes[0].v0 + 0.55) * (1 - ramp(t, outroStart, outroStart + 0.45))
    guard shown > 0.001 else { return nil }
    // It stays open for a while after each chapter starts, long enough to read.
    let compact = easeInOut((zoom - 1.05) / 0.35) * easeInOut((t - scenes[k].v0 - 3.0) / 0.7)
    let morph = k == 0 ? 1 : clamp01((t - scenes[k].v0) / 0.6)
    let from = k == 0 ? nil : captions[k - 1]
    let to = captions[k]
    let local = mix(from?.width(compact: compact) ?? to.width(compact: compact), to.width(compact: compact), spring(morph * 0.8, zeta: 0.78, omega: 11))
    let pop = 0.92 + 0.08 * spring((t - scenes[0].v0) / 0.9, zeta: 0.6)
    let scale = mix(1, 0.66, compact) * pop
    let full = captionHeight * mix(1, 0.66, compact)
    let top = mix(captionTop, 16, compact) + (full - captionHeight * scale) / 2 - (1 - shown) * 18
    let rect = CGRect(x: W / 2 - local * scale / 2, y: H - top - captionHeight * scale, width: local * scale, height: captionHeight * scale)
    return CaptionState(glass: Glass(rect: rect, radius: rect.height / 2, alpha: shown), from: from, to: to, morph: morph, compact: compact)
}

func drawCaption(_ ctx: CGContext, _ state: CaptionState) {
    glassTint(ctx, state.glass)
    let rect = state.glass.rect
    let s = rect.height / captionHeight
    ctx.saveGState()
    ctx.setAlpha(state.glass.alpha)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
    ctx.clip()
    ctx.translateBy(x: rect.minX, y: rect.minY)
    ctx.scaleBy(x: s, y: s)
    // The number on a gradient disc.
    let disc = CGRect(x: 21, y: captionHeight / 2 - 25, width: 50, height: 50)
    ctx.saveGState()
    ctx.addEllipse(in: disc); ctx.clip()
    let tint = CGGradient(colorsSpace: sRGB, colors: [cg(0x3B82F6), cg(0x8B5CF6)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(tint, start: CGPoint(x: disc.minX, y: disc.maxY), end: CGPoint(x: disc.maxX, y: disc.minY), options: [])
    func number(_ caption: Caption, dy: Double, alpha: Double) {
        guard alpha > 0.01 else { return }
        let line = textLine(caption.number, systemFont(21, .bold, mono: true), cg(0xFFFFFF, alpha))
        draw(ctx, line, x: disc.midX - lineWidth(line) / 2, y: disc.midY - 7.5 + dy)
    }
    let out = easeInOut(state.morph / 0.6), into = easeOut((state.morph - 0.15) / 0.85)
    if let from = state.from { number(from, dy: 30 * out, alpha: 1 - out) }
    number(state.to, dy: -30 * (1 - into), alpha: state.from == nil ? 1 : into)
    ctx.restoreGState()
    // Folded, the title moves to the middle and the subtitle fades.
    let titleY = mix(49, 34, state.compact)
    func texts(_ caption: Caption, dy: Double, alpha: Double) {
        guard alpha > 0.01 else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        draw(ctx, caption.title, x: 92, y: titleY + dy)
        ctx.setAlpha(alpha * (1 - state.compact))
        draw(ctx, caption.subtitle, x: 92, y: 21 - 8 * state.compact + dy)
        ctx.restoreGState()
    }
    if let from = state.from { texts(from, dy: 16 * out, alpha: 1 - out) }
    texts(state.to, dy: -16 * (1 - into), alpha: state.from == nil ? 1 : into)
    ctx.restoreGState()
}

// MARK: Key badges

struct KeyBadge {
    var glasses: [Glass]
    var draw: (CGContext) -> Void
}

func keyBadge(at r: Double) -> KeyBadge? {
    let shown = keyEvents.filter { $0.t <= r }
    guard let e = shown.last, r < e.t + e.number("duration") + 0.25 else { return nil }
    // Keys pressed in a row update one badge, which pops in once.
    var start = e.t
    for k in shown.reversed().dropFirst() where k.t + k.number("duration") + 0.25 > start && k.text("style") == e.text("style") { start = k.t }
    let alpha = min(clamp01((r - start) / 0.12), clamp01((e.t + e.number("duration") + 0.25 - r) / 0.22))
    let pop = 0.8 + 0.2 * spring((r - start) / 0.6, zeta: 0.5)
    let bump = 1 + 0.05 * (1 - clamp01((r - e.t) / 0.15)) * (start == e.t ? 0 : 1)
    let s = pop * bump
    let bottom = 58.0
    let style = e.text("style"), text = keyText(e.text("text"))
    if style == "shortcut" {
        let caps = text.map(String.init)
        let size = 70.0, gap = 12.0
        let total = Double(caps.count) * size + Double(caps.count - 1) * gap
        var glasses: [Glass] = []
        for i in caps.indices {
            let x = W / 2 - total / 2 + Double(i) * (size + gap)
            let rect = CGRect(x: x, y: bottom, width: size, height: size)
            let local = 0.8 + 0.2 * spring((r - start - 0.05 * Double(i)) / 0.6, zeta: 0.45)
            let scaled = CGRect(x: rect.midX - size * local / 2, y: rect.midY - size * local / 2, width: size * local, height: size * local)
            glasses.append(Glass(rect: scaled, radius: 17 * local, alpha: alpha))
        }
        return KeyBadge(glasses: glasses) { ctx in
            for (cap, glass) in zip(caps, glasses) {
                glassTint(ctx, glass)
                let font = systemFont(34 * glass.rect.width / size, .semibold)
                let line = textLine(cap, font, cg(0xFFFFFF, alpha))
                var ascent: CGFloat = 0, descent: CGFloat = 0
                let w = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                draw(ctx, line, x: glass.rect.midX - w / 2, y: glass.rect.midY - (ascent - descent) / 2 + 1)
            }
        }
    }
    let typing = style == "typing"
    let font = typing ? systemFont(32, .semibold, mono: true) : systemFont(27, .medium)
    let parts = text.components(separatedBy: " ▸ ")
    let attributed = NSMutableAttributedString()
    for (i, part) in parts.enumerated() {
        if i > 0 {
            attributed.append(NSAttributedString(string: "  ›  ", attributes: [.font: font, .foregroundColor: NSColor(cgColor: cg(0xFFFFFF, 0.45 * alpha))!]))
        }
        attributed.append(NSAttributedString(string: part, attributes: [.font: font, .foregroundColor: NSColor(cgColor: cg(0xFFFFFF, alpha))!]))
    }
    let line = CTLineCreateWithAttributedString(attributed)
    let textWidth = lineWidth(line) + (typing ? 22 : 0)
    let height = 68.0 * s, w = (textWidth + 60) * s
    let rect = CGRect(x: W / 2 - w / 2, y: bottom + (68 - height) / 2, width: w, height: height)
    let glass = Glass(rect: rect, radius: height / 2, alpha: alpha)
    return KeyBadge(glasses: [glass]) { ctx in
        glassTint(ctx, glass)
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: s, y: s)
        draw(ctx, line, x: -textWidth / 2, y: -10)
        if typing, (r * 2.4).truncatingRemainder(dividingBy: 1) < 0.6 {
            ctx.setFillColor(cg(0x6AA8FF, alpha))
            ctx.fill(CGRect(x: textWidth / 2 - 12, y: -18, width: 3, height: 36))
        }
        ctx.restoreGState()
    }
}

// MARK: One frame

func render(at t: Double) -> CIImage {
    let r = recordingTime(t)
    let camera = cameraView(at: t)
    let k = sceneIndex(at: t)
    let sinceChapter = k.map { t - scenes[$0].v0 } ?? -1
    let chapterBeat = (k ?? 0) > 0 && sinceChapter < 2.2 ? sinceChapter : nil
    let outro = t - outroStart

    // Energy: the background brightens on the drop and each chapter.
    var energy = 0.0
    if t >= introLength { energy = max(energy, 0.7 * exp(-(t - introLength) / 0.8)) }
    if let c = chapterBeat { energy = max(energy, 0.45 * exp(-c / 0.8)) }
    if outro > finale { energy = max(energy, 0.8 * exp(-(outro - finale) / 1.0)) }
    var image = background(t, energy: energy)

    // Title: the floor of bytes, the icon and the wordmark.
    if t < introLength + 0.5 {
        let floorAlpha = ramp(t, 0, 0.9) * (1 - ramp(t, 4.6, 5.7))
        if floorAlpha > 0.01 { image = floorLayer(t, speedUp: easeIn((t - intro.rise) / 1.4)).alpha(floorAlpha).composited(over: image) }
        let exit = easeIn((t - intro.exit) / 0.8)
        if exit < 0.999 {
            let pop = spring((t - intro.logo) / 1.0, zeta: 0.5)
            var group = logo(center: titleIcon, size: 270 * pop, glow: pop * (0.85 + 0.15 * sin(t * 3)))
            group = letters(titleLetters, baseline: CGPoint(x: W / 2, y: H / 2 - 95), start: intro.wordmark, at: t).composited(over: group)
            let u = t - intro.tagline
            if u > 0 {
                let line = textImage(introTagline, size: 40, weight: .regular, color: cg(mist), kern: 14 * (1 - easeOut(u / 1.1)))
                group = line.image.moved(W / 2 - line.width / 2, H / 2 - 172).alpha(clamp01(u / 0.6)).composited(over: group)
            }
            let breathe = 1 + 0.035 * ramp(t, intro.logo, intro.exit)
            group = group.scaled(breathe * (1 + 0.4 * exit), about: CGPoint(x: W / 2, y: H / 2)).blurred(24 * exit).alpha(1 - exit)
            image = group.cropped(to: frameRect).composited(over: image)
        }
    }

    // The window: rising out of the floor, then the recording; leaving at the end.
    var turn = Turn()
    var extraScale = 1.0, offset = CGPoint.zero, windowAlpha = 1.0, windowBlur = 0.0
    if t < introLength + 1 {
        let u = (t - intro.rise) / (introLength - intro.rise)
        let k = spring(u, zeta: 0.8, omega: 5)  // lands on the drop
        turn.pitch = 62 * .pi / 180 * (1 - k)
        offset.y = -640 * (1 - k)
        extraScale = 0.8 + 0.2 * k
        windowAlpha = clamp01(u * 4)
    }
    if let c = chapterBeat {
        let side: Double = (k ?? 0) % 2 == 0 ? 1 : -1
        // A slow, slight sway.
        turn.yaw += side * 6 * .pi / 180 * sin(.pi * c / 0.9) * exp(-1.8 * c)
        extraScale *= 1 - 0.025 * sin(.pi * clamp01(c / 1.1))
    }
    if outro > 0 {
        let u = easeInOut(outro / 1.8)
        extraScale *= 1 - 0.36 * u
        turn.yaw += 14 * .pi / 180 * u
        offset.y += 30 * u
        windowAlpha *= 1 - easeIn(outro / 1.8)
        windowBlur = 10 * u
    }
    let place = placement(camera, extraScale: extraScale, offset: offset)
    turn.pivot = CGPoint(x: place.center.x, y: t < introLength + 1 ? place.apply(CGPoint(x: 0, y: windowRect.minY)).y : place.center.y)
    func project(_ windowPoint: CGPoint) -> (point: CGPoint, scale: Double) {
        let p = turn.apply(place.apply(recPoint(windowPoint)))
        return (p.point, p.scale * place.scale * recScale)
    }

    var windowQuad: [CGPoint] = []
    if windowAlpha > 0.005, t >= intro.rise, let pixels = frames.frame(at: r) {
        var layer = CIImage(cvPixelBuffer: pixels)
        layer = cornerPatches[appearance(at: r)]!.composited(over: layer)
        if let patch = indicatorPatch(pixels, at: r) { layer = patch.composited(over: layer) }
        layer = turn.warp(layer.transformed(by: place.transform)).blurred(windowBlur).alpha(windowAlpha)
        image = layer.cropped(to: frameRect).composited(over: image)
        windowQuad = [CGPoint(x: 0, y: 0), CGPoint(x: windowFrame.width, y: 0),
                      CGPoint(x: windowFrame.width, y: windowFrame.height), CGPoint(x: 0, y: windowFrame.height)].map { project($0).point }
    }

    // Glass: the caption and the key badges blur what lies behind them.
    let caption = captionState(t, zoom: camera.zoom)
    let badge = t >= introLength && outro < 0.3 ? keyBadge(at: r) : nil
    let glasses = (caption.map { [$0.glass] } ?? []) + (badge?.glasses ?? [])
    if !glasses.isEmpty {
        var mask = CIImage(color: .clear).cropped(to: frameRect)
        var area = CGRect.null
        for g in glasses where g.alpha > 0.01 {
            mask = roundedRect(g.rect, g.radius, ci(0xFFFFFF, g.alpha)).composited(over: mask)
            area = area.union(g.rect)
        }
        if !area.isNull {
            let frosted = image.clampedToExtent().applyingGaussianBlur(sigma: 16)
                .applyingFilter("CIColorControls", parameters: ["inputSaturation": 1.6, "inputBrightness": 0.02])
                .cropped(to: area.insetBy(dx: -2, dy: -2))
            image = frosted.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
                .cropped(to: frameRect)
        }
    }

    // Core Graphics overlay: rings, glow, sweep, pointer, caption, keys.
    let ctx = makeContext(width, height)
    if t < intro.exit { ring(ctx, center: titleIcon, progress: (t - intro.logo) / 1.3, from: 110, to: 820, color: 0x6AA8FF) }
    if outro > finale { ring(ctx, center: finaleIcon, progress: (outro - finale) / 1.3, from: 100, to: 900, color: 0x6AA8FF) }
    if windowQuad.count == 4 {
        let path = CGMutablePath()
        path.addLines(between: windowQuad)
        path.closeSubpath()
        // The landing: a glow around the window.
        let land = t - introLength
        if land > -0.05, land < 0.9 {
            let a = 1 - clamp01(land / 0.9)
            let radius = 26 * project(.zero).scale
            let outline = CGPath(roundedRect: path.boundingBox, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 60, color: cg(0x4F8CFF, a))
            ctx.addPath(outline); ctx.setStrokeColor(cg(0x9CC2FF, 0.7 * a)); ctx.setLineWidth(2); ctx.strokePath()
            ctx.restoreGState()
        }
        // A light sweep across the window on each chapter.
        let sweep = chapterBeat ?? (land > 0 && land < 1 ? land : nil)
        if let c = sweep, c > 0.05, c < 1.25 {
            let u = easeInOut((c - 0.05) / 1.2)
            let box = path.boundingBox
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            let center = mix(CGPoint(x: box.minX - 300, y: box.maxY + 200), CGPoint(x: box.maxX + 300, y: box.minY - 200), u)
            let band = CGGradient(colorsSpace: sRGB, colors: [cg(0xFFFFFF, 0), cg(0xFFFFFF, 0.13), cg(0xFFFFFF, 0)] as CFArray, locations: [0, 0.5, 1])!
            ctx.drawLinearGradient(band, start: CGPoint(x: center.x - 150, y: center.y + 150), end: CGPoint(x: center.x + 150, y: center.y - 150), options: [])
            ctx.restoreGState()
        }
        // The pointer.
        if let p = pointerPosition(at: r) {
            let alpha = clamp01((t - introLength) / 0.4) * (1 - clamp01(outro / 0.35)) * windowAlpha
            let tip = project(p)
            let trail = (1...4).compactMap { i in pointerPosition(at: r - 0.012 * Double(i)).map { project($0).point } }
            drawPointer(ctx, tip: tip.point, size: tip.scale, press: lastClick(at: r), trail: trail, alpha: alpha)
        }
    }
    if let caption { drawCaption(ctx, caption) }
    badge?.draw(ctx)
    image = CIImage(cgImage: ctx.makeImage()!).composited(over: image)

    // Closing: the feature grid, then the icon and the link.
    if outro > 0 {
        let gridOut = easeIn((outro - 5.2) / 0.6)
        let u = outro - 0.8
        if u > 0, gridOut < 1 {
            let a = clamp01(u / 0.7) * (1 - gridOut)
            image = heading.image.blurred(12 * (1 - clamp01(u / 0.7))).moved(W / 2 - heading.width / 2, H / 2 + 200 - 24 * (1 - easeOut(u / 0.9)))
                .alpha(a).composited(over: image)
        }
        let gap = 24.0, columns = 5
        let gridWidth = Double(columns) * tileSize.width + Double(columns - 1) * gap
        for (i, tile) in tiles.enumerated() {
            let start = 1.1 + 0.08 * Double(i)
            let u = outro - start
            guard u > 0 else { continue }
            let leave = easeIn((outro - 5.15 - 0.03 * Double(i)) / 0.5)
            guard leave < 0.999 else { continue }
            let k = spring(u / 1.2, zeta: 0.68)
            let column = i % columns, row = i / columns
            let x = W / 2 - gridWidth / 2 + Double(column) * (tileSize.width + gap)
            let y = H / 2 - 30 - Double(row) * (tileSize.height + gap)
            let center = CGPoint(x: x + tileSize.width / 2, y: y + tileSize.height / 2 - 40 * (1 - k))
            image = tile.moved(x, y - 40 * (1 - k)).scaled((0.7 + 0.3 * k) * (1 - 0.08 * leave), about: center)
                .blurred(10 * (1 - clamp01(u / 0.45)) + 8 * leave).alpha(clamp01(u / 0.35) * (1 - leave))
                .composited(over: image)
        }
        let v = outro - finale
        if v > 0 {
            let pop = spring(v / 1.3, zeta: 0.6)
            image = logo(center: finaleIcon, size: 230 * pop, glow: pop).cropped(to: frameRect).composited(over: image)
            image = letters(finaleLetters, baseline: CGPoint(x: W / 2, y: H / 2 - 60), start: finale + 0.4, at: outro).composited(over: image)
            let w = v - 1.1
            if w > 0 {
                image = finaleLine.image.moved(W / 2 - finaleLine.width / 2, H / 2 - 128 - 14 * (1 - easeOut(w / 0.6)))
                    .alpha(clamp01(w / 0.5)).composited(over: image)
            }
            let l = v - 1.7
            if l > 0 {
                let k = spring(l / 0.9, zeta: 0.55)
                let pill = linkPill.extent
                let at = CGPoint(x: W / 2 - pill.width / 2, y: H / 2 - 240)
                image = linkPill.moved(at.x, at.y).scaled(0.85 + 0.15 * k, about: CGPoint(x: W / 2, y: at.y + pill.height / 2))
                    .alpha(clamp01(l / 0.3)).composited(over: image)
            }
        }
    }

    // In from black, out to black.
    let fade = min(clamp01(t / 0.5), clamp01((total - t) / 1.6))
    if fade < 1 { image = CIImage(color: ci(0x000000, 1 - fade)).cropped(to: frameRect).composited(over: image) }
    return image.cropped(to: frameRect)
}

// MARK: Encoding

let context = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [.cacheIntermediates: false, .outputColorSpace: sRGB])
let frameCount = Int((total * Double(fps)).rounded())
let started = Date()

if let stills {
    for frame in 0..<frameCount {
        let t = Double(frame) / Double(fps)
        guard stills.contains(where: { abs($0 - t) < 0.5 / Double(fps) }) else { continue }
        autoreleasepool {
            let still = context.createCGImage(render(at: t), from: frameRect, format: .RGBA8, colorSpace: sRGB)!
            let url = promo.appendingPathComponent(String(format: "still-%06.2f.png", t))
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, still, nil)
            CGImageDestinationFinalize(destination)
            print("wrote \(url.lastPathComponent)")
        }
    }
    exit(0)
}

let silentURL = promo.appendingPathComponent("video-only.mov")
try? FileManager.default.removeItem(at: silentURL)
let writer = try AVAssetWriter(outputURL: silentURL, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                      AVVideoMaxKeyFrameIntervalKey: fps * 2, AVVideoExpectedSourceFrameRateKey: fps],
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height, kCVPixelBufferMetalCompatibilityKey as String: true,
])
writer.add(input)
guard writer.startWriting() else { fatalError("cannot write: \(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)

for frame in 0..<frameCount {
    autoreleasepool {
        let t = Double(frame) / Double(fps)
        let image = render(at: t)
        while !input.isReadyForMoreMediaData { usleep(1000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let buffer else { fatalError("no pixel buffer") }
        context.render(image, to: buffer, bounds: frameRect, colorSpace: sRGB)
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        if frame % (fps * 5) == 0 {
            print(String(format: "  %5.1f / %.1f s  (%.0f s elapsed)", t, total, Date().timeIntervalSince(started)))
        }
    }
}
input.markAsFinished()
await writer.finishWriting()
guard writer.status == .completed else { fatalError("writing failed: \(String(describing: writer.error))") }

// MARK: Soundtrack

let musicURL = promo.appendingPathComponent("music.m4a")
try? FileManager.default.removeItem(at: musicURL)
let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
convert.arguments = ["-f", "m4af", "-d", "aac", "-b", "256000", "-q", "127",
                     promo.appendingPathComponent("music.wav").path, musicURL.path]
try convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else { fatalError("afconvert failed") }

let composition = AVMutableComposition()
let videoAsset = AVURLAsset(url: silentURL), audioAsset = AVURLAsset(url: musicURL)
let videoDuration = try await videoAsset.load(.duration), audioDuration = try await audioAsset.load(.duration)
let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration),
                               of: try await videoAsset.loadTracks(withMediaType: .video)[0], at: .zero)
let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(videoDuration, audioDuration)),
                               of: try await audioAsset.loadTracks(withMediaType: .audio)[0], at: .zero)
try? FileManager.default.removeItem(at: videoURL)
let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
try await export.export(to: videoURL, as: .mp4)
try? FileManager.default.removeItem(at: silentURL)
print(String(format: "wrote %@ (%.1f s, %d frames, %.0f s)", videoURL.path, total, frameCount, Date().timeIntervalSince(started)))
