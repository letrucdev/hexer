// Edits the Hexer film from the takes that Scripts/film/record.swift recorded: a 30-second
// commercial in four movements (tease, drop, hero, title) cut to a 96 BPM track, following
// VIDEO.md. Every window is a plane in 3D space seen through a virtual camera (Core Image on the
// GPU: perspective, rim and key lights, a sheen across the glass, floor reflections, depth of
// field, motion blur), and the type is set in SF Pro Heavy. The recordings always play at their
// real speed; only the camera moves fast.
//
//   Scripts/film/make.sh                       (renders, writes the score, muxes)
//   build/film/bin/render                      → build/film/video.mov and build/film/cues.json
//   build/film/bin/render --stills 1,5.2,17    → build/film/stills/*.png only
//   build/film/bin/render --mux                → build/film/hexer-film.mp4 (+ 1080p copy) with score.wav
//   options: --size 1920x1080 (drafts), --range 15-20

import AppKit
import AVFoundation
import CoreImage
import CoreText
import simd

// MARK: - Settings

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let filmDir = root.appendingPathComponent("build/film")
let takesDir = filmDir.appendingPathComponent("takes")

var W = 3840.0, H = 2160.0
let fps = 60.0
let length = 30.0
let beat = 60.0 / 96.0
let bar = 4 * beat

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
if let size = option("--size")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 { (W, H) = (size[0], size[1]) }
/// Every length in pixels below is written for 3840 × 2160.
var k: Double { W / 3840 }

// MARK: - Easing and keyframes

func clamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(b, max(a, x)) }
func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> { a + (b - a) * t }
func progress(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }

enum Ease {
    static func sine(_ x: Double) -> Double { 0.5 - 0.5 * cos(Double.pi * clamp(x)) }
    static func cubic(_ x: Double) -> Double { let x = clamp(x); return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    static func quint(_ x: Double) -> Double { let x = clamp(x); return x * x * x * (x * (x * 6 - 15) + 10) }
    static func expoOut(_ x: Double) -> Double { let x = clamp(x); return x >= 1 ? 1 : 1 - pow(2, -10 * x) }
    static func expoIn(_ x: Double) -> Double { let x = clamp(x); return x <= 0 ? 0 : pow(2, 10 * x - 10) }
}

// MARK: - Takes

struct LoggedEvent: Decodable { var t: Double; var kind: String; var name: String?; var x: Double?; var y: Double?; var rect: [Double]? }
struct CleanShot: Decodable { var file: String; var tag: String; var rect: [Double] }
struct GridInfo: Decodable { var canvas: [Double]; var charWidth: Double; var rowHeight: Double; var bytesPerRow: Int }
struct TakeInfo: Decodable {
    var name: String; var appearance: String; var scale: Double; var sourceRect: [Double]; var windows: [[Double]]
    var duration: Double; var grid: GridInfo?; var cleans: [CleanShot]?; var events: [LoggedEvent]
}

func rect(_ a: [Double]) -> CGRect { CGRect(x: a[0], y: a[1], width: a[2], height: a[3]) }

final class Take {
    let info: TakeInfo
    let url: URL
    let size: CGSize            // texture pixels
    /// Clean traffic lights per tag, already placed in texture (Core Image) coordinates.
    private(set) var patches: [String: [CIImage]] = [:]

    init(_ name: String) {
        url = takesDir.appendingPathComponent("\(name).mov")
        let data = try! Data(contentsOf: takesDir.appendingPathComponent("\(name).json"))
        info = try! JSONDecoder().decode(TakeInfo.self, from: data)
        let track = AVURLAsset(url: url).tracks(withMediaType: .video).first!
        size = track.naturalSize
        for shot in info.cleans ?? [] {
            guard let image = CIImage(contentsOf: takesDir.appendingPathComponent(shot.file)) else { continue }
            // The traffic lights and the indicator over them: 8…96 × 6…44 points from the window's corner.
            let s = info.scale, win = rect(shot.rect)
            let area = CGRect(x: 8 * s, y: image.extent.height - 44 * s, width: 88 * s, height: 38 * s)
            let o = uv(CGPoint(x: win.minX, y: win.minY))
            let patch = image.cropped(to: area)
                .transformed(by: CGAffineTransform(translationX: o.x, y: size.height - o.y - image.extent.height))
            patches[shot.tag, default: []].append(patch)
        }
    }

    /// Global points (top-left origin) → texture pixels (top-left origin).
    func uv(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - info.sourceRect[0]) * info.scale, y: (p.y - info.sourceRect[1]) * info.scale)
    }
    func uv(_ r: CGRect) -> CGRect {
        let o = uv(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * info.scale, height: r.height * info.scale)
    }

    func events(_ kind: String? = nil, named name: String? = nil) -> [LoggedEvent] {
        info.events.filter { (kind == nil || $0.kind == kind) && (name == nil || $0.name == name) }
    }
    func time(_ name: String) -> Double {
        guard let e = info.events.first(where: { $0.name == name }) else { fatalError("\(info.name): no event \(name)") }
        return e.t
    }
    func point(_ name: String) -> CGPoint {
        guard let e = info.events.first(where: { $0.name == name }), let x = e.x, let y = e.y else { fatalError("\(info.name): no point \(name)") }
        return uv(CGPoint(x: x, y: y))
    }
    func area(_ name: String) -> CGRect {
        guard let e = info.events.first(where: { $0.name == name }), let r = e.rect else { fatalError("\(info.name): no rect \(name)") }
        return uv(rect(r))
    }
    var window: CGRect { uv(rect(info.windows.max { $0[2] * $0[3] < $1[2] * $1[3] }!)) }

    /// Rect of `count` bytes from `offset` in the hex column, with the grid scrolled to the top.
    func cells(_ offset: Int, _ count: Int = 1) -> CGRect {
        let g = info.grid!
        let row = offset / g.bytesPerRow, col = offset % g.bytesPerRow
        let x = g.canvas[0] + 14 + 11 * g.charWidth + Double(col * 3) * g.charWidth
        let y = g.canvas[1] + Double(row) * g.rowHeight
        return uv(CGRect(x: x - g.charWidth / 2, y: y, width: Double(count * 3) * g.charWidth, height: g.rowHeight))
    }
    func text(_ offset: Int, _ count: Int = 1) -> CGRect {
        let g = info.grid!
        let row = offset / g.bytesPerRow, col = offset % g.bytesPerRow
        let start = 14 + 11 * g.charWidth + Double(g.bytesPerRow * 3 - 1) * g.charWidth + 3 * g.charWidth
        return uv(CGRect(x: g.canvas[0] + start + Double(col) * g.charWidth, y: g.canvas[1] + Double(row) * g.rowHeight,
                         width: Double(count) * g.charWidth, height: g.rowHeight))
    }
}

var takeCache: [String: Take] = [:]
func take(_ name: String) -> Take {
    if let t = takeCache[name] { return t }
    let t = Take(name)
    takeCache[name] = t
    return t
}

/// Plays a take forward from a start time, one frame at a time (the takes have a variable frame rate).
final class Reader {
    let take: Take
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var current: (t: Double, image: CIImage)?
    private var pending: (t: Double, buffer: CVPixelBuffer)?
    private var ended = false
    var patchTag: (Double) -> String = { _ in "clean" }

    init(_ take: Take, from start: Double) {
        self.take = take
        let asset = AVURLAsset(url: take.url)
        reader = try! AVAssetReader(asset: asset)
        let track = asset.tracks(withMediaType: .video).first!
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        output.alwaysCopiesSampleData = false
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start - 4), preferredTimescale: 600), end: .positiveInfinity)
        reader.add(output)
        reader.startReading()
    }

    private func pull() -> (Double, CVPixelBuffer)? {
        while !ended {
            guard let sample = output.copyNextSampleBuffer() else { ended = true; return nil }
            if let buffer = CMSampleBufferGetImageBuffer(sample) { return (sample.presentationTimeStamp.seconds, buffer) }
        }
        return nil
    }

    func frame(at t: Double) -> CIImage {
        if pending == nil, !ended { pending = pull() }
        while let p = pending, p.t <= t + 0.0001 {
            current = (p.t, CIImage(cvPixelBuffer: p.buffer))
            pending = pull()
        }
        guard var image = current?.image ?? pending.map({ CIImage(cvPixelBuffer: $0.buffer) }) else {
            return CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: take.size))
        }
        for patch in take.patches[patchTag(t)] ?? take.patches["clean"] ?? [] { image = patch.composited(over: image) }
        return image
    }
}

// MARK: - Kernels

let spotKernel = CIColorKernel(source: """
kernel vec4 spot(__sample s, vec2 c, vec2 r, float amb) {
    vec2 d = (destCoord() - c) / r;
    float k = amb + (1.0 - amb) * exp(-2.0 * dot(d, d));
    return vec4(s.rgb * k, s.a);
}
""")!
let sheenKernel = CIColorKernel(source: """
kernel vec4 sheen(__sample s, vec2 p, vec2 n, float w, float amt) {
    float d = dot(destCoord() - p, n);
    float g = exp(-d * d / (2.0 * w * w));
    return vec4(s.rgb + s.a * amt * g, s.a);
}
""")!
let rimKernel = CIColorKernel(source: """
kernel vec4 rim(__sample s, __sample e, vec2 c, vec2 l, float amt) {
    float edge = clamp(s.a - e.a, 0.0, 1.0);
    vec2 d = normalize(destCoord() - c);
    float w = clamp(dot(d, l) * 0.5 + 0.5, 0.0, 1.0);
    return vec4(s.rgb + edge * amt * (0.15 + 0.85 * w * w), s.a);
}
""")!
let fadeKernel = CIColorKernel(source: """
kernel vec4 fade(__sample s, float y0, float y1) {
    float t = clamp((destCoord().y - y0) / (y1 - y0), 0.0, 1.0);
    return s * (1.0 - t) * (1.0 - t);
}
""")!
let dofKernel = CIColorKernel(source: """
kernel vec4 dof(vec3 abc, float zf, float gain) {
    vec2 p = destCoord();
    float iz = abc.x * p.x + abc.y * p.y + abc.z;
    float m = clamp(abs(1.0 - zf * iz) * gain, 0.0, 1.0);
    return vec4(m, m, m, 1.0);
}
""")!
let grainKernel = CIColorKernel(source: """
kernel vec4 grain(__sample s, __sample n, float amt) {
    float lum = dot(s.rgb, vec3(0.2126, 0.7152, 0.0722));
    return vec4(s.rgb + (n.r - 0.5) * amt * sqrt(max(lum, 0.0)) * s.a, s.a);
}
""")!

extension CIImage {
    /// Opacity. CIColorMatrix works on unpremultiplied colour, so only alpha is scaled.
    func scaledAlpha(_ a: Double) -> CIImage {
        if a >= 0.999 { return self }
        return applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, a)))])
    }
    func brightness(_ b: Double) -> CIImage {
        let v = CGFloat(b)
        return applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: v, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: v, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: v, w: 0),
        ])
    }
    func added(to background: CIImage) -> CIImage { applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: background]) }
    func softBlurred(_ r: Double) -> CIImage { r < 0.3 ? self : applyingGaussianBlur(sigma: r) }
}

// MARK: - 3D

typealias V3 = SIMD3<Double>

func rotation(yaw: Double, pitch: Double, roll: Double) -> simd_double3x3 {
    let (a, b, c) = (yaw * .pi / 180, pitch * .pi / 180, roll * .pi / 180)
    let ry = simd_double3x3(rows: [V3(cos(a), 0, sin(a)), V3(0, 1, 0), V3(-sin(a), 0, cos(a))])
    let rx = simd_double3x3(rows: [V3(1, 0, 0), V3(0, cos(b), -sin(b)), V3(0, sin(b), cos(b))])
    let rz = simd_double3x3(rows: [V3(cos(c), -sin(c), 0), V3(sin(c), cos(c), 0), V3(0, 0, 1)])
    return ry * rx * rz
}

struct Camera {
    var eye: V3
    var target: V3
    var fov = 30.0
    var roll = 0.0

    /// A camera `distance` away from `target`, `az` degrees around and `el` degrees above it.
    static func orbit(_ target: V3, distance: Double, az: Double, el: Double, fov: Double = 30, roll: Double = 0) -> Camera {
        let a = az * .pi / 180, e = el * .pi / 180
        return Camera(eye: target + distance * V3(sin(a) * cos(e), sin(e), cos(a) * cos(e)), target: target, fov: fov, roll: roll)
    }

    var focal: Double { (H / 2) / tan(fov * .pi / 360) }

    var basis: (r: V3, u: V3, f: V3) {
        let f = simd_normalize(target - eye)
        var r = simd_normalize(simd_cross(f, V3(0, 1, 0)))
        var u = simd_cross(r, f)
        if roll != 0 {
            let c = cos(roll * .pi / 180), s = sin(roll * .pi / 180)
            (r, u) = (r * c + u * s, u * c - r * s)
        }
        return (r, u, f)
    }

    func view(_ p: V3) -> V3 {
        let (r, u, f) = basis
        let d = p - eye
        return V3(simd_dot(d, r), simd_dot(d, u), simd_dot(d, f))
    }

    /// Screen position in Core Image coordinates (origin bottom-left).
    func project(_ c: V3) -> CGPoint {
        CGPoint(x: W / 2 + c.x / c.z * focal, y: H / 2 + c.y / c.z * focal)
    }
}

/// Slides a camera sideways (without turning it) so `subject` lands at a screen position given as
/// fractions of the frame (y up): how the shots leave room for the type.
func compose(_ cam: Camera, _ subject: V3, at fx: Double, _ fy: Double) -> Camera {
    let (r, u, _) = cam.basis
    let c = cam.view(subject)
    let dr = c.x - (fx - 0.5) * W * c.z / cam.focal
    let du = c.y - (fy - 0.5) * H * c.z / cam.focal
    var out = cam
    out.eye += r * dr + u * du
    out.target += r * dr + u * du
    return out
}

/// A camera on a texture point of the plane, placed at a screen position.
func shoot(_ plane: Plane, _ subject: CGPoint, at f: (Double, Double), distance: Double, az: Double, el: Double,
           roll: Double = 0, fov: Double = 30) -> Camera {
    let s = plane.world(subject)
    return compose(Camera.orbit(s, distance: distance, az: az, el: el, fov: fov, roll: roll), s, at: f.0, f.1)
}

func blend(_ a: Camera, _ b: Camera, _ t: Double) -> Camera {
    Camera(eye: mix(a.eye, b.eye, t), target: mix(a.target, b.target, t), fov: mix(a.fov, b.fov, t), roll: mix(a.roll, b.roll, t))
}

struct Light {
    var spot: (u: Double, v: Double, rx: Double, ry: Double, ambient: Double)?
    var sheen: (pos: Double, amount: Double)?   // pos 0…1 across the texture's diagonal
    var rim = 0.0
}

struct Plane {
    var image: CIImage                 // texture, extent at the origin
    var center = V3(0, 0, 0)
    var yaw = 0.0, pitch = 0.0, roll = 0.0
    var crop: CGRect?                  // texture pixels, top-left origin
    var opacity = 1.0
    var light = Light()
    var reflection = 0.0
    var glow = 0.0
    var shadow = 0.0

    var size: CGSize { image.extent.size }

    /// World position of a texture pixel (top-left origin).
    func world(_ u: Double, _ v: Double) -> V3 {
        center + rotation(yaw: yaw, pitch: pitch, roll: roll) * V3(u - size.width / 2, size.height / 2 - v, 0)
    }
    func world(_ p: CGPoint) -> V3 { world(p.x, p.y) }
}

enum Stage { case dark, light, black }

struct Scene {
    var stage = Stage.dark
    var camera: Camera
    var planes: [Plane] = []
    var floor: Double?                 // world y of a glossy floor
    var focus: Double?                 // focus distance along the view axis; nil = all sharp
    var aperture = 0.0                 // blur radius (px at 4K) far from the focus plane
    var exposure = 1.0
    var overlays: [CIImage] = []       // screen-space images (type, flashes)
    var underlays: [CIImage] = []      // screen-space images under the planes
    var bloom = 0.3
}

// MARK: - Typography

struct TypeStyle {
    var size: Double
    var weight: NSFont.Weight = .heavy
    var color = NSColor(white: 0.96, alpha: 1)
    var tracking = -0.022
}

var glyphCache: [String: (image: CIImage, ascent: Double, width: Double)] = [:]

/// One word (or line) set in SF Pro at 4K scale; cached.
func setType(_ s: String, _ style: TypeStyle) -> (image: CIImage, ascent: Double, width: Double) {
    let key = "\(s)|\(style.size)|\(style.weight.rawValue)|\(style.color)|\(W)"
    if let c = glyphCache[key] { return c }
    let size = style.size * k
    let font = NSFont.systemFont(ofSize: size, weight: style.weight)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.color, .kern: style.tracking * size]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    let pad = 8.0 * k
    let w = Int(ceil(width + 2 * pad)), h = Int(ceil(ascent + descent + 2 * pad))
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldSmoothFonts(false)
    ctx.textPosition = CGPoint(x: pad, y: pad + descent)
    CTLineDraw(line, ctx)
    // Origin at the left end of the baseline.
    let image = CIImage(cgImage: ctx.makeImage()!).transformed(by: CGAffineTransform(translationX: -pad, y: -(pad + descent)))
    let entry = (image, Double(ascent), Double(width))
    glyphCache[key] = entry
    return entry
}

enum Motion { case snap, rise, track }

struct Words {
    var words: [String]
    var times: [Double]                // when each word lands
    var style: TypeStyle
    var origin: CGPoint                // 4K pixels, baseline start (Core Image coordinates)
    var align = 0.0                    // 0 left, 0.5 centre, 1 right
    var motion = Motion.snap
    var exit: Double                   // when the line leaves
    var scrim = 0.0                    // darkening behind the line

    func image(at t: Double) -> CIImage? {
        guard t >= times[0] - 0.05, t < exit + 0.2 else { return nil }
        let space = setType(" ", style).width
        let parts = words.map { setType($0, style) }
        let total = parts.map(\.width).reduce(0, +) + space * Double(parts.count - 1)
        var x = origin.x * k - total * align
        let y = origin.y * k
        var out = CIImage.empty()
        let leave = progress(t, exit, exit + 0.16)
        if scrim > 0 {
            let c = CIVector(x: x + total / 2, y: y + parts[0].ascent * 0.35)
            let glow = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": c, "inputRadius0": total * 0.15, "inputRadius1": total * 0.95,
                "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: scrim), "inputColor1": CIColor.clear,
            ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
                .transformed(by: CGAffineTransform(translationX: -(x + total / 2), y: -(y + parts[0].ascent * 0.35))
                    .concatenating(CGAffineTransform(scaleX: 1, y: 0.55))
                    .concatenating(CGAffineTransform(translationX: x + total / 2, y: y + parts[0].ascent * 0.35)))
            let p = progress(t, times[0] - 0.1, times[0] + 0.25)
            out = glow.scaledAlpha(p * (1 - leave)).composited(over: out)
        }
        for (i, part) in parts.enumerated() {
            let p = t - times[i]
            if p >= -0.001 {
                var a = clamp(p / 0.07)
                var m = CGAffineTransform.identity
                var blur = 0.0
                switch motion {
                case .snap:
                    let s = 1 + 0.16 * (1 - Ease.expoOut(p / 0.28))
                    m = CGAffineTransform(translationX: -part.width / 2, y: -part.ascent / 2)
                        .concatenating(CGAffineTransform(scaleX: s, y: s))
                        .concatenating(CGAffineTransform(translationX: part.width / 2, y: part.ascent / 2))
                    blur = 10 * k * (1 - clamp(p / 0.12))
                case .rise:
                    let d = (1 - Ease.expoOut(p / 0.42)) * part.ascent * 0.9
                    m = CGAffineTransform(translationX: 0, y: -d)
                    a = clamp(p / 0.16)
                case .track:
                    let s = 0.94 + 0.06 * Ease.expoOut(p / 0.6)
                    m = CGAffineTransform(scaleX: s, y: s)
                    a = Ease.sine(p / 0.5)
                    blur = 6 * k * (1 - clamp(p / 0.3))
                }
                let lift = 1 + 0.05 * Ease.expoIn(leave)
                var img = part.image.transformed(by: m)
                if motion == .rise {
                    // Rises from behind its own baseline.
                    img = img.cropped(to: CGRect(x: -50 * k, y: -part.ascent * 0.32, width: part.width + 100 * k, height: part.ascent * 2))
                }
                img = img.transformed(by: CGAffineTransform(translationX: -part.width / 2, y: 0)
                    .concatenating(CGAffineTransform(scaleX: lift, y: lift))
                    .concatenating(CGAffineTransform(translationX: x + part.width / 2, y: y)))
                if blur > 0.3 { img = img.softBlurred(blur) }
                a *= 1 - leave
                out = img.scaledAlpha(a).composited(over: out)
            }
            x += part.width + space
        }
        return out
    }
}

// MARK: - Rendering a scene

let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                  .cacheIntermediates: false, .highQualityDownsample: true])
var frameRect: CGRect { CGRect(x: 0, y: 0, width: W, height: H) }

func stageImage(_ stage: Stage) -> CIImage {
    switch stage {
    case .black:
        return CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: frameRect)
    case .dark:
        return CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: W / 2, y: H * 0.56), "inputRadius0": 0, "inputRadius1": W * 0.62,
            "inputColor0": CIColor(red: 0.030, green: 0.034, blue: 0.044), "inputColor1": CIColor(red: 0, green: 0, blue: 0),
        ])!.outputImage!.cropped(to: frameRect)
    case .light:
        return CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: W / 2, y: H * 0.6), "inputRadius0": 0, "inputRadius1": W * 0.75,
            "inputColor0": CIColor(red: 0.985, green: 0.985, blue: 0.99), "inputColor1": CIColor(red: 0.80, green: 0.81, blue: 0.83),
        ])!.outputImage!.cropped(to: frameRect)
    }
}

/// The plane's texture with its lights, cropped; returns the image and its four corners in texture pixels.
func lit(_ plane: Plane) -> (CIImage, [CGPoint]) {
    let full = plane.image
    let h = full.extent.height
    let crop = plane.crop ?? CGRect(origin: .zero, size: full.extent.size)
    var tex = full
    if let s = plane.light.spot {
        tex = spotKernel.apply(extent: tex.extent, arguments: [tex, CIVector(x: s.u, y: h - s.v), CIVector(x: s.rx, y: s.ry), s.ambient])!
    }
    if plane.light.rim > 0 {
        let eroded = full.applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": 3.0]).cropped(to: full.extent)
        let c = CIVector(x: full.extent.midX, y: full.extent.midY)
        tex = rimKernel.apply(extent: tex.extent, arguments: [tex, eroded, c, CIVector(x: -0.55, y: 0.83), plane.light.rim])!
    }
    if let sh = plane.light.sheen, sh.amount > 0 {
        let w = full.extent.width, d = hypot(w, h)
        let n = CIVector(x: 0.62, y: -0.78)       // a streak leaning like light from the top left
        let along = -0.25 * d + sh.pos * 1.5 * d
        let p = CIVector(x: along * 0.62, y: h + along * -0.78)
        tex = sheenKernel.apply(extent: tex.extent, arguments: [tex, p, n, 0.07 * d, sh.amount])!
    }
    let ciCrop = CGRect(x: crop.minX, y: h - crop.maxY, width: crop.width, height: crop.height)
    tex = tex.cropped(to: ciCrop).transformed(by: CGAffineTransform(translationX: -ciCrop.minX, y: -ciCrop.minY))
    // Corners in texture pixels: top-left, top-right, bottom-right, bottom-left.
    let corners = [CGPoint(x: crop.minX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.minY),
                   CGPoint(x: crop.maxX, y: crop.maxY), CGPoint(x: crop.minX, y: crop.maxY)]
    return (tex, corners)
}

/// The largest part of the plane around the point the camera looks at whose corners all lie in
/// front of the camera (a perspective warp cannot show points behind it).
func fitCrop(_ plane: Plane, _ cam: Camera) -> CGRect? {
    let full = plane.crop ?? CGRect(origin: .zero, size: plane.size)
    func valid(_ r: CGRect) -> Bool {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            .allSatisfy { cam.view(plane.world($0)).z > 80 }
    }
    if valid(full) { return full }
    let rot = rotation(yaw: plane.yaw, pitch: plane.pitch, roll: plane.roll)
    let n = rot * V3(0, 0, 1), dir = simd_normalize(cam.target - cam.eye)
    let denom = simd_dot(dir, n)
    guard abs(denom) > 1e-6 else { return nil }
    let hit = cam.eye + dir * (simd_dot(plane.center - cam.eye, n) / denom)
    let local = rot.transpose * (hit - plane.center)
    let uv = CGPoint(x: local.x + plane.size.width / 2, y: plane.size.height / 2 - local.y)
    var r = CGRect(x: uv.x - 2, y: uv.y - 2, width: 4, height: 4).intersection(full)
    guard !r.isNull, valid(r) else { return nil }
    let step = max(full.width, full.height) / 60
    for _ in 0..<400 {
        var grew = false
        for side in 0..<4 {
            var c = r
            switch side {
            case 0: c.origin.x -= step; c.size.width += step
            case 1: c.size.width += step
            case 2: c.origin.y -= step; c.size.height += step
            default: c.size.height += step
            }
            c = c.intersection(full)
            if c != r, valid(c) { r = c; grew = true }
        }
        if !grew { break }
    }
    return r
}

func warp(_ image: CIImage, _ q: [CGPoint]) -> CIImage {
    image.applyingFilter("CIPerspectiveTransform", parameters: [
        "inputTopLeft": CIVector(cgPoint: q[0]), "inputTopRight": CIVector(cgPoint: q[1]),
        "inputBottomRight": CIVector(cgPoint: q[2]), "inputBottomLeft": CIVector(cgPoint: q[3]),
    ])
}

func render(_ scene: Scene) -> CIImage {
    var out = stageImage(scene.stage)
    for u in scene.underlays { out = u.composited(over: out) }
    let cam = scene.camera
    let sorted = scene.planes.sorted { cam.view($0.center).z > cam.view($1.center).z }
    for var plane in sorted where plane.opacity > 0.001 {
        guard let crop = fitCrop(plane, cam) else { continue }
        plane.crop = crop
        let (tex, corners) = lit(plane)
        let view = corners.map { cam.view(plane.world($0)) }
        let quad = view.map(cam.project)
        var layer = warp(tex, quad).cropped(to: frameRect.insetBy(dx: -200 * k, dy: -200 * k))

        if let floor = scene.floor, plane.reflection > 0 {
            let th = tex.extent.height
            let faded = fadeKernel.apply(extent: tex.extent, arguments: [tex, 0.0, th * 0.42])!
            let mirrored = corners.map { c -> CGPoint in
                var w = plane.world(c)
                w.y = 2 * floor - w.y
                return cam.project(cam.view(w))
            }
            let reflection = warp(faded, mirrored).cropped(to: frameRect).softBlurred(5 * k)
                .scaledAlpha(plane.reflection * plane.opacity)
            out = reflection.composited(over: out)
        }
        if plane.shadow > 0 {
            let shade = layer.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(plane.shadow)),
            ]).softBlurred(70 * k).transformed(by: CGAffineTransform(translationX: 0, y: -60 * k))
            out = shade.cropped(to: frameRect).composited(over: out)
        }
        if plane.glow > 0 {
            let glow = layer.softBlurred(160 * k).cropped(to: frameRect).scaledAlpha(plane.glow * plane.opacity)
            out = glow.added(to: out)
        }
        if let focus = scene.focus, scene.aperture > 0.5 {
            let c0 = view[0], c1 = view[1], c2 = view[3]
            let n = simd_normalize(simd_cross(c1 - c0, c2 - c0))
            let dval = simd_dot(n, c0)
            let f = cam.focal
            let a = n.x / (f * dval), b = n.y / (f * dval), c = (n.z - n.x * W / (2 * f) - n.y * H / (2 * f)) / dval
            let rmax = scene.aperture * k
            let mask = dofKernel.apply(extent: frameRect, arguments: [CIVector(x: a, y: b, z: c), focus, 1.0])!
            layer = layer.applyingFilter("CIMaskedVariableBlur", parameters: ["inputMask": mask, "inputRadius": rmax])
                .cropped(to: frameRect)
        }
        out = layer.scaledAlpha(plane.opacity).composited(over: out)
    }
    for o in scene.overlays { out = o.composited(over: out) }
    out = out.cropped(to: frameRect)
    if scene.bloom > 0 {
        out = out.applyingFilter("CIBloom", parameters: ["inputRadius": 26 * k, "inputIntensity": scene.bloom]).cropped(to: frameRect)
    }
    if scene.exposure < 0.999 { out = out.brightness(scene.exposure) }
    return out
}

// MARK: - The film

struct Shot {
    var start: Double
    var end: Double
    var readers: () -> [Reader]
    var scene: (Double, [Reader]) -> Scene
    /// Subframes for motion blur at a time (1 = none).
    var shutter: (Double) -> Int = { _ in 1 }
}

struct Cue: Encodable {
    var t: Double
    var kind: String       // impact, whoosh, riser, snap, click, key, sheen, tick, hit
    var size: Double = 1
    var length: Double = 0
}

var cues: [Cue] = []
func cue(_ kind: String, _ t: Double, size: Double = 1, length: Double = 0) { cues.append(Cue(t: t, kind: kind, size: size, length: length)) }

/// The real clicks and keys of a take that the film shows, on the film's clock.
func soundsOf(_ take: Take, from s0: Double, shown a: Double, _ b: Double) {
    for e in take.info.events where e.kind == "click" || e.kind == "key" || e.kind == "scroll" {
        let t = a + (e.t - s0)
        if t >= a && t < b { cue(e.kind, t, size: e.name?.hasPrefix("menu") == true ? 0.7 : 1) }
    }
}

func planeOf(_ image: CIImage, light: Light = Light()) -> Plane {
    var p = Plane(image: image)
    p.light = light
    return p
}

var shots: [Shot] = []

/// A montage angle: a take seen from a camera that drifts from `a` to `b`.
func angle(_ start: Double, _ end: Double, take name: String, from s0: Double, patch: ((Double) -> String)? = nil,
           camera: @escaping (Plane, Double) -> Camera, light: @escaping (Plane, Double) -> Light = { _, _ in Light() },
           focus: ((Plane, Camera, Double) -> Double?)? = nil, aperture: Double = 0, words: Words? = nil,
           exposure: @escaping (Double) -> Double = { _ in 1 }, shutter: @escaping (Double) -> Int = { _ in 1 },
           stage: Stage = .dark, crop: CGRect? = nil) {
    let t = take(name)
    soundsOf(t, from: s0, shown: start, end)
    shots.append(Shot(start: start, end: end, readers: {
        let r = Reader(t, from: s0)
        if let patch { r.patchTag = patch }
        return [r]
    }, scene: { time, readers in
        let local = time - start
        var plane = planeOf(readers[0].frame(at: s0 + local))
        plane.crop = crop
        let p = (time - start) / (end - start)
        plane.light = light(plane, p)
        let cam = camera(plane, p)
        var s = Scene(stage: stage, camera: cam, planes: [plane])
        if let focus { s.focus = focus(plane, cam, p); s.aperture = aperture }
        if let w = words?.image(at: time) { s.overlays.append(w) }
        s.exposure = exposure(p)
        return s
    }, shutter: shutter))
}

/// Distance from the camera to a texture point along the view axis (for focusing on it).
func depth(_ cam: Camera, _ plane: Plane, _ p: CGPoint) -> Double { cam.view(plane.world(p)).z }

func buildFilm() {
    let macro = take("macro"), main = take("main"), light = take("light")
    let compare = take("compare"), firmware = take("firmware"), disk = take("disk")
    let white = NSColor(white: 0.97, alpha: 1)
    let ink = NSColor(white: 0.08, alpha: 1)
    let display = TypeStyle(size: 230, color: white)

    // ── 1. The tease (0:00–0:05) ────────────────────────────────────────────────────────────
    // T1: darkness; a pool of light finds the Mach-O magic, and the caret walks it on the beat.
    let steps = macro.events("key", named: "right").map(\.t)
    let t1s0 = steps[0] - 2 * beat                       // first step lands on beat 3 (1.25 s)
    let magic = macro.cells(0, 4)
    angle(0, 3.125, take: "macro", from: t1s0,
          camera: { plane, p in
              // Follows the caret byte by byte along the row, low and close, drifting robotically.
              let stepsDone = steps.map { s in Ease.quint(progress(t1s0 + p * 3.125, s, s + 0.45)) }.reduce(0, +)
              let cell = macro.cells(min(3, Int(stepsDone)), 1)
              let next = macro.cells(min(3, Int(stepsDone) + 1), 1)
              let f = stepsDone - floor(stepsDone)
              let u = mix(cell.midX, next.midX, f) - magic.width * 0.05
              let target = plane.world(u, magic.midY)
              return Camera.orbit(target, distance: mix(1500, 1180, Ease.sine(p)), az: mix(-48, -36, p), el: mix(16, 9, p),
                                  fov: 28, roll: mix(-4, -1.5, p))
          },
          light: { _, p in
              Light(spot: (magic.minX + magic.width * mix(0.15, 0.85, Ease.sine(p)), magic.midY,
                           magic.width * 0.55, magic.height * 2.6, 0.015),
                    sheen: (mix(-0.1, 1.05, p), 0.03), rim: 0)
          },
          focus: { plane, cam, _ in depth(cam, plane, CGPoint(x: magic.midX, y: magic.midY)) }, aperture: 46,
          exposure: { p in Ease.sine(p * 3.125 / 1.1) })
    for s in steps { cue("tick", s - t1s0, size: 1) }
    cue("sheen", 0.2, length: 2.8)

    // T2: the window comes out of the dark as an outline of light, then the camera rushes in.
    let w = main.window
    let rushStart = 4.375
    shots.append(Shot(start: 3.125, end: 5.0, readers: { [Reader(main, from: 0.8)] }, scene: { time, readers in
        let local = time - 3.125
        var plane = planeOf(readers[0].frame(at: 0.8 + local))
        let reveal = Ease.cubic(progress(time, 3.125, 4.3))
        let lightsOn = Ease.sine(progress(time, 3.9, 4.5))
        plane.light = Light(spot: (w.minX + w.width * 0.2, w.minY + w.height * 0.15, w.width * mix(0.25, 1.4, lightsOn),
                                   w.height * mix(0.25, 1.4, lightsOn), mix(0.04, 0.9, lightsOn)),
                            sheen: (mix(-0.2, 0.7, reveal), 0.04), rim: mix(1.6, 0.9, lightsOn))
        let corner = plane.world(w.minX + 160, w.minY + 70)
        let middle = plane.world(w.midX, w.midY)
        let close = Camera.orbit(corner, distance: 1500, az: 58, el: 22, fov: 30, roll: 6)
        let wide = Camera.orbit(middle, distance: 4300, az: 24, el: 10, fov: 30, roll: 1.5)
        var cam = blend(close, wide, reveal)
        cam.target = mix(corner, middle, Ease.sine(progress(time, 3.125, 4.2)))
        // The rush: into the grid's decoded text, where the next shot begins.
        let rush = pow(progress(time, rushStart, 5.0), 3)
        let aim = plane.world(w.minX + w.width * 0.47, w.minY + w.height * 0.42)
        if rush > 0 {
            let inside = Camera.orbit(aim, distance: 260, az: 4, el: 2, fov: 30)
            cam = blend(cam, inside, rush)
        }
        var s = Scene(stage: .dark, camera: cam, planes: [plane])
        let flash = Ease.expoIn(progress(time, 4.85, 5.0))
        if flash > 0 { s.overlays.append(CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: flash * 0.55)).cropped(to: frameRect)) }
        return s
    }, shutter: { t in t > rushStart + 0.15 ? 7 : 1 }))
    cue("riser", 2.5, length: 2.5)
    cue("hit", 3.125, size: 0.6)
    cue("whoosh", rushStart, size: 1.2, length: 0.625)

    // ── 2. The drop (0:05–0:15) ─────────────────────────────────────────────────────────────
    cue("impact", 5.0, size: 1.4)
    let left = CGPoint(x: 290, y: 330)

    // D1 "Byte by byte." — typing Hexer into the decoded text, big.
    // The cut to the wider angle falls in the middle of the word; it finishes there.
    let d1s0 = macro.time("type") - 0.5
    let row = macro.info.grid!.bytesPerRow == 6 ? 0x36 : 0x38
    let hexRow = macro.cells(row, 5), textRow = macro.text(row, 5)
    let edit = hexRow.union(textRow)
    let d1 = Words(words: ["Byte", "by", "byte."], times: [5.0, 5.3125, 5.625], style: display, origin: left,
                   motion: .snap, exit: 6.25 - 0.12, scrim: 0.8)
    angle(5.0, 6.25, take: "macro", from: d1s0,
          camera: { plane, p in
              shoot(plane, CGPoint(x: mix(textRow.minX - 300, textRow.midX - 150, p), y: textRow.midY), at: (0.66, 0.6),
                    distance: mix(2000, 1700, Ease.sine(p)), az: mix(22, 16, p), el: mix(-6, -3, p))
          },
          light: { _, p in Light(spot: (textRow.minX, textRow.midY, edit.width * 0.6, edit.height * 3.5, 0.10), sheen: (mix(0.2, 0.6, p), 0.02)) },
          focus: { plane, cam, _ in depth(cam, plane, CGPoint(x: textRow.minX, y: textRow.midY)) }, aperture: 24, words: d1)
    angle(6.25, 7.5, take: "macro", from: d1s0 + 1.25,
          camera: { plane, p in
              shoot(plane, CGPoint(x: edit.midX, y: edit.midY), at: (0.5, 0.36), distance: mix(3300, 3000, Ease.sine(p)),
                    az: mix(-16, -11, p), el: mix(5, 3, p), roll: -1)
          },
          light: { _, p in Light(spot: (edit.midX, edit.midY, edit.width * 0.8, edit.height * 5, 0.28), sheen: (mix(0.4, 0.8, p), 0.02)) },
          focus: { plane, cam, _ in depth(cam, plane, CGPoint(x: edit.midX, y: edit.midY)) }, aperture: 14,
          shutter: { p in p > 0.9 ? 5 : 1 })
    cue("whoosh", 6.25 - 0.08, size: 0.5, length: 0.25)

    // D2 "Find anything." — Find All lights up every match.
    let findClick = main.time("Find All")
    let d2s0 = findClick - 1.40
    let findAll = main.area("findAll")
    let fieldArea = CGRect(x: findAll.minX - 760, y: findAll.minY - 10, width: findAll.maxX - findAll.minX + 760, height: findAll.height + 20)
    let grid = CGPoint(x: w.minX + w.width * 0.40, y: w.minY + w.height * 0.42)
    let d2 = Words(words: ["Find", "anything."], times: [7.5, 7.8125], style: display, origin: left, exit: 8.75 - 0.12, scrim: 0.8)
    angle(7.5, 8.75, take: "main", from: d2s0,
          camera: { plane, p in
              shoot(plane, CGPoint(x: fieldArea.midX + mix(-80, 60, p), y: fieldArea.midY), at: (0.6, 0.6),
                    distance: mix(1750, 1500, Ease.sine(p)), az: mix(-20, -14, p), el: mix(8, 5, p))
          },
          light: { _, p in Light(spot: (fieldArea.midX, fieldArea.midY, fieldArea.width * 0.7, 520, 0.12), sheen: (mix(0.1, 0.5, p), 0.02)) },
          focus: { plane, cam, _ in depth(cam, plane, CGPoint(x: fieldArea.midX + 200, y: fieldArea.midY)) }, aperture: 18, words: d2)
    angle(8.75, 10.0, take: "main", from: d2s0 + 1.25,
          camera: { plane, p in
              shoot(plane, CGPoint(x: grid.x, y: grid.y + mix(0, 120, Ease.sine(p))), at: (0.5, 0.5),
                    distance: mix(3000, 2700, Ease.sine(p)), az: mix(14, 9, p), el: mix(4, 2, p), roll: 1)
          },
          light: { _, p in Light(spot: (w.midX, w.midY, w.width * 0.8, w.height * 0.8, 0.45), sheen: (mix(0.3, 0.9, p), 0.02), rim: 0.5) },
          focus: { plane, cam, _ in depth(cam, plane, grid) }, aperture: 10,
          shutter: { p in p > 0.9 ? 5 : 1 })
    cue("whoosh", 8.75 - 0.08, size: 0.5, length: 0.25)

    // D3 "Decode everything." — click an instruction, then the inspector rolls down to the disassembly.
    let instr = main.time("instruction 1")
    let instrAt = main.point("instruction 1")
    let d3s0 = instr - 0.5
    let scroll = main.time("scrollInspector")
    let disasm = main.info.events.first { $0.name == "disassembly" }?.rect.map { main.uv(rect($0)) }
    let inspectorX = disasm.map { $0.minX + 270 } ?? (w.maxX - 300)
    let inspectorY = disasm.map { $0.midY } ?? (w.maxY - 500)
    let d3 = Words(words: ["Decode", "everything."], times: [10.0, 10.3125], style: display, origin: CGPoint(x: 3550, y: 330),
                   align: 1, exit: 11.25 - 0.12, scrim: 0.8)
    angle(10.0, 11.25, take: "main", from: d3s0,
          camera: { plane, p in
              shoot(plane, CGPoint(x: instrAt.x + mix(60, -40, p), y: instrAt.y), at: (0.34, 0.62),
                    distance: mix(1900, 1650, Ease.sine(p)), az: mix(28, 22, p), el: mix(-6, -3, p))
          },
          light: { _, _ in Light(spot: (instrAt.x, instrAt.y, 820, 380, 0.12), sheen: nil) },
          focus: { plane, cam, _ in depth(cam, plane, instrAt) }, aperture: 22, words: d3)
    angle(11.25, 12.5, take: "main", from: scroll + 0.05,
          camera: { plane, p in
              shoot(plane, CGPoint(x: inspectorX, y: inspectorY - mix(420, 60, Ease.sine(p))), at: (0.6, 0.5),
                    distance: mix(1550, 1350, Ease.sine(p)), az: mix(-24, -18, p), el: mix(-2, 1, p))
          },
          light: { _, p in Light(spot: (inspectorX, inspectorY - 200, 650, 1000, 0.22), sheen: (mix(0.4, 0.9, p), 0.02)) },
          focus: { plane, cam, p in depth(cam, plane, CGPoint(x: inspectorX, y: inspectorY - mix(420, 60, p))) },
          aperture: 16, shutter: { p in p > 0.9 ? 5 : 1 })
    cue("whoosh", 11.25 - 0.08, size: 0.5, length: 0.25)

    // D4 "Entropy, visualized." — the histogram under a sweeping pointer, then a bar picked.
    let statsTag: (Double) -> String = { t in
        t >= main.time("menu Statistics") + 0.1 && t < main.time("close") + 0.1 ? "stats" : "clean"
    }
    let sweep = main.time("sweep")
    let plot = main.area("sweep")
    let stats = main.area("stats")
    let pick = main.time("bar 0x5F")
    let d4 = Words(words: ["Entropy,", "visualized."], times: [12.5, 12.8125], style: display, origin: left, exit: 13.75 - 0.12,
                   scrim: 0.8)
    angle(12.5, 13.75, take: "main", from: sweep + 0.25, patch: statsTag,
          camera: { plane, p in
              shoot(plane, CGPoint(x: plot.minX + plot.width * mix(0.40, 0.62, p), y: plot.midY + 60), at: (0.64, 0.6),
                    distance: mix(1900, 1700, Ease.sine(p)), az: mix(30, 24, p), el: mix(-12, -8, p))
          },
          light: { _, p in Light(spot: (plot.minX + plot.width * mix(0.25, 0.85, p), plot.midY, plot.width * 0.45, plot.height, 0.14), sheen: nil) },
          focus: { plane, cam, p in depth(cam, plane, CGPoint(x: plot.minX + plot.width * mix(0.45, 0.65, p), y: plot.midY)) },
          aperture: 20, words: d4)
    angle(13.75, 15.0, take: "main", from: pick - 0.35, patch: statsTag,
          camera: { plane, p in
              let center = CGPoint(x: stats.midX + 40, y: stats.midY + 30)
              let cam = shoot(plane, center, at: (0.5, 0.5), distance: mix(2700, 2450, Ease.sine(p)), az: mix(-14, -10, p), el: mix(4, 2, p))
              return blend(cam, shoot(plane, center, at: (0.5, 0.5), distance: 900, az: -8, el: 1), Ease.expoIn(progress(p, 0.75, 1)) * 0.6)
          },
          light: { _, p in Light(spot: (stats.midX, stats.midY, stats.width * 0.8, stats.height * 0.8, 0.35), sheen: (mix(0.3, 0.8, p), 0.02), rim: 0.6) },
          focus: { plane, cam, _ in depth(cam, plane, CGPoint(x: stats.midX, y: stats.midY)) }, aperture: 10,
          shutter: { p in p > 0.82 ? 7 : 1 })
    cue("riser", 13.75, size: 0.6, length: 1.25)
    cue("whoosh", 14.6, size: 1.0, length: 0.4)

    // ── 3. The hero (0:15–0:25) ─────────────────────────────────────────────────────────────
    cue("impact", 15.0, size: 1.1)
    // H1: the whole window, dark, standing on black glass; at the end the camera finds the mode picker.
    let insert = main.time("Insert")
    let h1s0 = insert - (19.375 - 15.0)
    let modes = main.area("modes")
    let liquid = Words(words: ["Liquid", "Glass."], times: [17.5, 17.8125], style: TypeStyle(size: 190, color: white),
                       origin: CGPoint(x: 1920, y: 1930), align: 0.5, motion: .rise, exit: 19.9)
    soundsOf(main, from: h1s0, shown: 15.0, 20.0)
    shots.append(Shot(start: 15.0, end: 20.0, readers: { [Reader(main, from: h1s0)] }, scene: { time, readers in
        var plane = planeOf(readers[0].frame(at: h1s0 + time - 15.0))
        let p = (time - 15.0) / 5.0
        plane.light = Light(spot: (w.minX + w.width * mix(0.3, 0.6, p), w.minY + w.height * 0.3, w.width * 1.3, w.height * 1.3, 0.78),
                            sheen: (mix(-0.15, 1.1, progress(time, 15.6, 18.2)), 0.035), rim: 1.0)
        plane.reflection = 0.22
        plane.glow = 0.16
        plane.center = V3(0, 0, 0)
        let floorY = -plane.size.height / 2 + (plane.size.height - w.maxY) - 6
        let middle = plane.world(w.midX, w.midY)
        let orbit = compose(Camera.orbit(middle, distance: mix(4100, 3750, Ease.sine(p)), az: mix(26, 10, Ease.sine(p)), el: mix(9, 5, p), fov: 30),
                            middle, at: 0.5, 0.43)
        let pickerTarget = plane.world(modes.midX + 60, modes.midY + 120)
        let find = Camera.orbit(pickerTarget, distance: 1700, az: 6, el: 4, fov: 30, roll: 0.5)
        let cam = blend(orbit, find, Ease.cubic(progress(time, 18.1, 19.45)))
        var s = Scene(stage: .dark, camera: cam, planes: [plane], floor: floorY)
        s.focus = depth(cam, plane, CGPoint(x: modes.midX, y: mix(w.midY, modes.midY, progress(time, 18.1, 19.4))))
        s.aperture = mix(4, 12, progress(time, 18.1, 19.4))
        if let wd = liquid.image(at: time) { s.overlays.append(wd) }
        return s
    }, shutter: { t in t > 19.85 ? 5 : 1 }))
    cue("sheen", 15.6, length: 2.6)
    cue("snap", 17.5, size: 0.7)
    cue("snap", 17.8125, size: 0.7)
    cue("whoosh", 19.9, size: 0.7, length: 0.3)

    // H2: light appearance on a white stage.
    let readOnly = light.time("Read-only")
    let h2s0 = readOnly - 0.62
    let lw = light.window
    let lightWords = Words(words: ["Light", "and", "dark."], times: [20.0, 20.3125, 20.625], style: TypeStyle(size: 190, color: ink),
                           origin: CGPoint(x: 1920, y: 1930), align: 0.5, motion: .rise, exit: 22.4)
    soundsOf(light, from: h2s0, shown: 20.0, 22.5)
    shots.append(Shot(start: 20.0, end: 22.5, readers: { [Reader(light, from: h2s0)] }, scene: { time, readers in
        var plane = planeOf(readers[0].frame(at: h2s0 + time - 20.0))
        let p = (time - 20.0) / 2.5
        plane.light = Light(spot: nil, sheen: (mix(0.0, 1.0, p), 0.025), rim: 0.0)
        plane.reflection = 0.10
        plane.shadow = 0.32
        let floorY = -plane.size.height / 2 + (plane.size.height - lw.maxY) - 6
        let middle = plane.world(lw.midX, lw.midY)
        let cam = compose(Camera.orbit(middle, distance: mix(4100, 3800, Ease.sine(p)), az: mix(-22, -12, Ease.sine(p)), el: mix(7, 4, p), fov: 30),
                          middle, at: 0.5, 0.43)
        var s = Scene(stage: .light, camera: cam, planes: [plane], floor: floorY)
        s.bloom = 0.08
        if let wd = lightWords.image(at: time) { s.overlays.append(wd) }
        return s
    }, shutter: { t in t > 22.38 ? 5 : 1 }))
    for (i, t) in [20.0, 20.3125, 20.625].enumerated() { cue("snap", t, size: i == 2 ? 0.8 : 0.6) }
    cue("whoosh", 22.38, size: 0.7, length: 0.3)

    // H3: files, disks, firmware — three windows in an arc, each lit as its word lands.
    let cs0 = compare.events("key", named: "F6")[0].t - 0.15
    let ds0 = disk.time("return") - 1.1
    let fs0 = firmware.time("fold") - 1.45
    soundsOf(compare, from: cs0, shown: 22.5, 25.0)
    soundsOf(disk, from: ds0, shown: 22.5, 25.0)
    soundsOf(firmware, from: fs0, shown: 22.5, 25.0)
    let wordsAt = [22.5, 23.125, 23.75]
    let family = Words(words: ["Files.", "Disks.", "Firmware."], times: wordsAt, style: TypeStyle(size: 170, color: white),
                       origin: CGPoint(x: 1920, y: 260), align: 0.5, motion: .snap, exit: 24.95)
    shots.append(Shot(start: 22.5, end: 25.0, readers: {
        [Reader(compare, from: cs0), Reader(disk, from: ds0), Reader(firmware, from: fs0)]
    }, scene: { time, readers in
        let local = time - 22.5
        let p = local / 2.5
        let a = planeOf(readers[0].frame(at: cs0 + local))
        let b = planeOf(readers[1].frame(at: ds0 + local))
        let c = planeOf(readers[2].frame(at: fs0 + local))
        var planes = [a, b, c]
        // An arc in word order, left to right: files (the comparison), the disk, the firmware.
        let placements: [(V3, Double)] = [(V3(-3050, 0, -800), 22), (V3(0, 0, 0), 0), (V3(2900, 0, -800), -22)]
        for (i, idx) in planes.indices.enumerated() {
            planes[idx].center = placements[i].0
            planes[idx].yaw = placements[i].1
            let lit = Ease.sine(progress(time, wordsAt[i] - 0.1, wordsAt[i] + 0.25))
            let all = Ease.sine(progress(time, 24.3, 24.8))
            let on = max(lit, all)
            planes[idx].light = Light(spot: (planes[idx].size.width / 2, planes[idx].size.height / 2, planes[idx].size.width,
                                             planes[idx].size.height, mix(0.16, 0.95, on)), sheen: (mix(-0.2, 1.1, progress(time, wordsAt[i], wordsAt[i] + 1.4)), 0.025 * on),
                                      rim: mix(0.6, 1.0, on))
            planes[idx].reflection = 0.16
            planes[idx].glow = 0.10 * on
        }
        let floorY = -900.0
        let focusX = mix(-3050, 2900, Ease.cubic(progress(time, 22.4, 24.0)))
        let target = V3(mix(focusX, 0, Ease.sine(progress(time, 24.0, 25.0))), 0, -300)
        let cam = compose(Camera.orbit(target, distance: mix(6000, 7600, Ease.sine(p)), az: mix(-6, 6, p), el: mix(6, 9, p), fov: 30),
                          target, at: 0.5, 0.56)
        var s = Scene(stage: .dark, camera: cam, planes: planes, floor: floorY)
        if let wd = family.image(at: time) { s.overlays.append(wd) }
        s.focus = cam.view(V3(focusX, 0, -300)).z
        s.aperture = mix(18, 4, progress(time, 24.0, 24.8))
        return s
    }, shutter: { t in t > 24.88 ? 5 : 1 }))
    for t in wordsAt { cue("snap", t, size: 0.8) }
    cue("riser", 23.75, size: 0.8, length: 1.25)

    // ── 4. The title (0:25–0:30) ────────────────────────────────────────────────────────────
    cue("impact", 25.0, size: 1.6)
    let iconURL = root.appendingPathComponent("Resources/Icon/AppIcon.iconset/icon_512x512@2x.png")
    let icon = CIImage(contentsOf: iconURL)!
    let name = TypeStyle(size: 250, color: white, tracking: -0.03)
    let tagline = TypeStyle(size: 66, weight: .semibold, color: NSColor(white: 0.62, alpha: 1), tracking: -0.005)
    shots.append(Shot(start: 25.0, end: length, readers: { [] }, scene: { time, _ in
        let p = time - 25.0
        var plane = planeOf(icon)
        let appear = Ease.expoOut(progress(p, 0, 0.9))
        plane.opacity = clamp(p / 0.35)
        plane.light = Light(spot: nil, sheen: (mix(-0.1, 1.1, Ease.cubic(progress(p, 0.25, 1.6))), 0.12), rim: 0)
        plane.reflection = 0.12
        plane.center = V3(0, 450, 0)
        plane.yaw = mix(-16, 0, appear)
        plane.pitch = mix(10, 0, appear)
        let size = icon.extent.width
        let cam = Camera.orbit(V3(0, 0, 0), distance: mix(5400, 5900, Ease.sine(p / 5)), az: 0, el: 0, fov: 30)
        var s = Scene(stage: .black, camera: cam, planes: [plane], floor: 450 - size / 2 - 26)
        s.bloom = 0.25
        let title = Words(words: ["Hexer"], times: [25.625], style: name, origin: CGPoint(x: 1920, y: 500), align: 0.5,
                          motion: .track, exit: 99)
        let line = Words(words: ["The hex editor for Mac."], times: [26.25], style: tagline, origin: CGPoint(x: 1920, y: 365),
                         align: 0.5, motion: .track, exit: 99)
        if let t = title.image(at: time) { s.overlays.append(t) }
        if let l = line.image(at: time) { s.overlays.append(l) }
        s.exposure = 1 - Ease.sine(progress(time, 28.9, 29.9))
        return s
    }))
    cue("sheen", 25.25, length: 1.4)
    cue("snap", 25.625, size: 0.9)
    cue("snap", 26.25, size: 0.5)
}

// MARK: - Output

func grain(_ image: CIImage, frame: Int) -> CIImage {
    let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
        .transformed(by: CGAffineTransform(translationX: CGFloat(frame * 97 % 1024), y: CGFloat(frame * 61 % 1024)))
        .cropped(to: frameRect)
    // Fine grain in the lights and mid-tones keeps gradients from banding; the blacks stay clean.
    return grainKernel.apply(extent: frameRect, arguments: [image, noise, 0.022])!
}

func frameImage(_ t: Double, index: Int, readers: inout [Int: [Reader]]) -> CIImage {
    guard let i = shots.firstIndex(where: { t >= $0.start && t < $0.end }) ?? (t >= length - 0.0001 ? shots.count - 1 : nil)
    else { return stageImage(.black) }
    let shot = shots[i]
    if readers[i] == nil {
        readers = readers.filter { $0.key > i }       // earlier shots are done
        readers[i] = shot.readers()
    }
    let n = shot.shutter(t)
    var image: CIImage
    if n <= 1 {
        image = render(shot.scene(t, readers[i]!))
    } else {
        // 180° shutter: subframes across half a frame, averaged.
        image = CIImage.empty()
        for s in 0..<n {
            let ts = t + (Double(s) / Double(n - 1) - 0.5) * (0.5 / fps)
            let sub = render(shot.scene(min(shot.end - 0.0001, max(shot.start, ts)), readers[i]!)).scaledAlpha(1 / Double(n))
            image = s == 0 ? sub : sub.added(to: image)
        }
    }
    return grain(image, frame: index)
}

let outputSpace = CGColorSpace(name: CGColorSpace.itur_709)!

func writeStills(_ times: [Double]) {
    let dir = filmDir.appendingPathComponent("stills")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for t in times {
        var readers: [Int: [Reader]] = [:]
        let image = frameImage(t, index: Int(t * fps), readers: &readers)
        let url = dir.appendingPathComponent(String(format: "still-%05.2f.png", t))
        try! context.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        print("still", url.lastPathComponent)
    }
}

func writeMovie(range: ClosedRange<Double>) {
    let url = filmDir.appendingPathComponent("video.mov")
    try? FileManager.default.removeItem(at: url)
    let writer = try! AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(W), AVVideoHeightKey: Int(H),
        AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(45_000_000 * k * k), AVVideoExpectedSourceFrameRateKey: 60,
                                          AVVideoMaxKeyFrameIntervalKey: 60],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(W), kCVPixelBufferHeightKey as String: Int(H),
        kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    var readers: [Int: [Reader]] = [:]
    let first = Int((range.lowerBound * fps).rounded()), last = Int((range.upperBound * fps).rounded()) - 1
    let started = Date()
    for i in first...last {
        autoreleasepool {
            let t = Double(i) / fps
            let image = frameImage(t, index: i, readers: &readers)
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            context.render(image, to: buffer!, bounds: frameRect, colorSpace: outputSpace)
            CVBufferSetAttachment(buffer!, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer!, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer!, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i - first), timescale: 60))
            if i % 60 == 0 {
                let rate = Double(i - first + 1) / Date().timeIntervalSince(started)
                print(String(format: "  %5.2f s  (%.1f frames/s)", t, rate))
            }
        }
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    print("wrote \(url.path)")
}

func writeCues() {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted]
    let sorted = cues.sorted { $0.t < $1.t }
    struct Doc: Encodable { var bpm: Double; var length: Double; var cues: [Cue] }
    try! enc.encode(Doc(bpm: 96, length: length, cues: sorted)).write(to: filmDir.appendingPathComponent("cues.json"))
}

/// Puts the score under the picture: the video is copied as it is, the score becomes AAC.
/// Then a 1080p H.264 copy for sharing.
func mux() {
    let master = filmDir.appendingPathComponent("hexer-film.mp4")
    try? FileManager.default.removeItem(at: master)
    let video = AVURLAsset(url: filmDir.appendingPathComponent("video.mov"))
    let audio = AVURLAsset(url: filmDir.appendingPathComponent("score.wav"))
    let writer = try! AVAssetWriter(outputURL: master, fileType: .mp4)
    let vTrack = video.tracks(withMediaType: .video)[0]
    let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                 sourceFormatHint: (vTrack.formatDescriptions.first as! CMFormatDescription))
    let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 320_000,
    ])
    writer.add(vIn); writer.add(aIn)
    let vReader = try! AVAssetReader(asset: video)
    let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
    vReader.add(vOut)
    let aReader = try! AVAssetReader(asset: audio)
    let aOut = AVAssetReaderTrackOutput(track: audio.tracks(withMediaType: .audio)[0], outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
    ])
    aReader.add(aOut)
    vReader.startReading(); aReader.startReading()
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let group = DispatchGroup()
    for (input, output, label) in [(vIn, vOut, "video"), (aIn, aOut, "audio")] {
        group.enter()
        input.requestMediaDataWhenReady(on: DispatchQueue(label: label)) {
            while input.isReadyForMoreMediaData {
                if let sample = output.copyNextSampleBuffer() { input.append(sample) } else {
                    input.markAsFinished(); group.leave(); return
                }
            }
        }
    }
    group.wait()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    print(writer.status == .completed ? "wrote \(master.path)" : "error: \(writer.error.map { "\($0)" } ?? "mux failed")")

    let small = filmDir.appendingPathComponent("hexer-film-1080p.mp4")
    try? FileManager.default.removeItem(at: small)
    let export = AVAssetExportSession(asset: AVURLAsset(url: master), presetName: AVAssetExportPreset1920x1080)!
    export.outputURL = small
    export.outputFileType = .mp4
    let exported = DispatchSemaphore(value: 0)
    export.exportAsynchronously { exported.signal() }
    exported.wait()
    print(export.status == .completed ? "wrote \(small.path)" : "error: 1080p copy failed")
}

if args.contains("--mux") {
    mux()
    exit(0)
}
buildFilm()
writeCues()
if let list = option("--stills") {
    writeStills(list.split(separator: ",").compactMap { Double($0) })
} else {
    var range = 0.0...length
    if let r = option("--range")?.split(separator: "-").compactMap({ Double($0) }), r.count == 2 { range = r[0]...r[1] }
    writeMovie(range: range)
}
