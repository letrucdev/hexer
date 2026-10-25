// The score for the Hexer film: a 30-second electronic track at 96 BPM in D minor, synthesized
// from scratch (no samples), with the sound design placed on the cues that render.swift writes
// (build/film/cues.json): whooshes into cuts, bass drops on the drop, the hero and the title,
// snaps under the type, and mechanical clicks under every real click and key press in the takes.
//
//   build/film/bin/score        → build/film/score.wav (48 kHz, stereo, 24-bit) and a level report
//
// Form (bars of 2.5 s): 1–2 tease (drone, ticks, a riser), 3–6 the drop (four on the floor,
// pumping bass, a sixteenth-note arpeggio; Dm B♭ F C), 7–10 the hero (supersaw chords and a hook;
// bar 9 thins out for the light shot), 11–12 the title (one chord left ringing).

import AVFoundation
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let filmDir = root.appendingPathComponent("build/film")

let sr = 48_000.0
let length = 30.0
let count = Int(length * sr)
let beat = 60.0 / 96.0
let bar = 4 * beat
let sixteenth = beat / 4

// MARK: - Cues

struct Cue: Decodable { var t: Double; var kind: String; var size: Double; var length: Double }
struct CueDoc: Decodable { var cues: [Cue] }
let cues = (try? JSONDecoder().decode(CueDoc.self, from: Data(contentsOf: filmDir.appendingPathComponent("cues.json"))))?.cues ?? []

// MARK: - Buffers and helpers

struct Stereo {
    var l: [Double]
    var r: [Double]
    init(_ n: Int = count) { l = [Double](repeating: 0, count: n); r = l }
    var n: Int { l.count }

    /// Adds a mono signal at `t` seconds with constant-power panning (-1 left … 1 right).
    mutating func add(_ s: [Double], at t: Double, gain: Double = 1, pan: Double = 0) {
        let start = Int((t * sr).rounded())
        let a = (pan + 1) * .pi / 4
        let gl = cos(a) * gain * 1.4142, gr = sin(a) * gain * 1.4142
        for (i, v) in s.enumerated() {
            let j = start + i
            if j < 0 { continue }
            if j >= n { break }
            l[j] += v * gl
            r[j] += v * gr
        }
    }
    mutating func add(_ s: Stereo, at t: Double, gain: Double = 1) {
        let start = Int((t * sr).rounded())
        for i in 0..<s.n {
            let j = start + i
            if j < 0 { continue }
            if j >= n { break }
            l[j] += s.l[i] * gain
            r[j] += s.r[i] * gain
        }
    }
    mutating func mix(_ o: Stereo, gain: Double = 1) {
        for i in 0..<min(n, o.n) { l[i] += o.l[i] * gain; r[i] += o.r[i] * gain }
    }
    mutating func scale(by g: (Int) -> Double) {
        for i in 0..<n { let k = g(i); l[i] *= k; r[i] *= k }
    }
}

func samples(_ seconds: Double) -> Int { max(1, Int(seconds * sr)) }
func midi(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
func db(_ d: Double) -> Double { pow(10, d / 20) }

struct Noise {
    var s: UInt64 = 0x9E3779B97F4A7C15
    mutating func next() -> Double {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return Double(s >> 11) / Double(1 << 53) * 2 - 1
    }
}
var noise = Noise()

/// Band-limited sawtooth (polyBLEP).
struct Saw {
    var phase = 0.0
    init(phase: Double = 0) { self.phase = phase }
    mutating func next(_ f: Double) -> Double {
        let dt = f / sr
        phase += dt
        if phase >= 1 { phase -= 1 }
        var v = 2 * phase - 1
        if phase < dt { let x = phase / dt; v -= x + x - x * x - 1 }
        else if phase > 1 - dt { let x = (phase - 1) / dt; v -= x * x + x + x + 1 }
        return v
    }
}

/// Topology-preserving state-variable filter (low, band and high pass at once).
struct SVF {
    var ic1 = 0.0, ic2 = 0.0
    mutating func run(_ x: Double, cutoff: Double, q: Double) -> (lp: Double, bp: Double, hp: Double) {
        let g = tan(.pi * min(cutoff, sr * 0.45) / sr), k = 1 / q
        let a1 = 1 / (1 + g * (g + k)), a2 = g * a1, a3 = g * a2
        let v3 = x - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return (v2, v1, x - k * v1 - v2)
    }
}

struct OnePole {
    var z = 0.0
    mutating func lp(_ x: Double, _ cutoff: Double) -> Double {
        let a = exp(-2 * .pi * cutoff / sr)
        z = x * (1 - a) + z * a
        return z
    }
    mutating func hp(_ x: Double, _ cutoff: Double) -> Double { x - lp(x, cutoff) }
}

// MARK: - Effects

/// Freeverb: eight damped combs and four allpasses per channel.
final class Reverb {
    private var combs: [[Double]], idx: [Int], store: [Double]
    private var aps: [[Double]], apIdx: [Int]
    let room: Double, damp: Double
    init(room: Double = 0.86, damp: Double = 0.32) {
        self.room = room; self.damp = damp
        let scale = sr / 44_100
        let cl = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617], al = [556, 441, 341, 225]
        combs = (cl.map { Int(Double($0) * scale) } + cl.map { Int(Double($0 + 23) * scale) }).map { [Double](repeating: 0, count: $0) }
        idx = [Int](repeating: 0, count: 16); store = [Double](repeating: 0, count: 16)
        aps = (al.map { Int(Double($0) * scale) } + al.map { Int(Double($0 + 23) * scale) }).map { [Double](repeating: 0, count: $0) }
        apIdx = [Int](repeating: 0, count: 8)
    }
    func process(_ input: Stereo) -> Stereo {
        var out = Stereo(input.n)
        for i in 0..<input.n {
            let x = (input.l[i] + input.r[i]) * 0.015
            for ch in 0..<2 {
                var acc = 0.0
                for c in 0..<8 {
                    let k = ch * 8 + c
                    let y = combs[k][idx[k]]
                    store[k] = y * (1 - damp) + store[k] * damp
                    combs[k][idx[k]] = x + store[k] * room
                    idx[k] += 1; if idx[k] == combs[k].count { idx[k] = 0 }
                    acc += y
                }
                for a in 0..<4 {
                    let k = ch * 4 + a
                    let b = aps[k][apIdx[k]]
                    aps[k][apIdx[k]] = acc + b * 0.5
                    acc = b - acc
                    apIdx[k] += 1; if apIdx[k] == aps[k].count { apIdx[k] = 0 }
                }
                if ch == 0 { out.l[i] = acc } else { out.r[i] = acc }
            }
        }
        return out
    }
}

/// Ping-pong echo with a darkening feedback path.
func pingPong(_ input: Stereo, time: Double, feedback: Double, tone: Double = 3500) -> Stereo {
    let d = samples(time)
    var out = Stereo(input.n)
    var bl = [Double](repeating: 0, count: d), br = bl
    var p = 0
    var fl = OnePole(), fr = OnePole()
    for i in 0..<input.n {
        let yl = bl[p], yr = br[p]
        out.l[i] = yl; out.r[i] = yr
        bl[p] = fl.lp((input.l[i] + input.r[i]) * 0.5 + yr * feedback, tone)
        br[p] = fr.lp(yl * feedback, tone)
        p += 1; if p == d { p = 0 }
    }
    return out
}

// MARK: - Instruments

func kick(_ vel: Double = 1, long: Bool = false) -> [Double] {
    let n = samples(long ? 1.6 : 0.5)
    var out = [Double](repeating: 0, count: n)
    var ph = 0.0
    for i in 0..<n {
        let t = Double(i) / sr
        let f = (long ? 36 : 52) + (long ? 90 : 125) * exp(-t / 0.032)
        ph += 2 * .pi * f / sr
        let amp = min(1, t / 0.002) * exp(-t / (long ? 0.7 : 0.21))
        var v = sin(ph) * amp
        if t < 0.008 { v += noise.next() * 0.9 * (1 - t / 0.008) }
        out[i] = tanh(v * 1.8) * vel
    }
    return out
}

func clap(_ vel: Double = 1) -> [Double] {
    let n = samples(0.35)
    var out = [Double](repeating: 0, count: n)
    var f = SVF()
    for i in 0..<n {
        let t = Double(i) / sr
        var env = exp(-t / 0.11) * 0.55
        for b in 0..<3 { let tb = t - Double(b) * 0.009; if tb >= 0 { env += exp(-tb / 0.006) } }
        out[i] = f.run(noise.next(), cutoff: 1700, q: 1.0).bp * env * vel * 1.4
    }
    return out
}

let hatFreqs = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0].map { $0 * 1.62 }
func hat(_ vel: Double = 1, open: Bool = false) -> [Double] {
    let n = samples(open ? 0.32 : 0.07)
    var out = [Double](repeating: 0, count: n)
    var ph = [Double](repeating: 0, count: 6)
    var hp = SVF()
    for i in 0..<n {
        let t = Double(i) / sr
        var m = 0.0
        for k in 0..<6 { ph[k] += hatFreqs[k] / sr; m += ph[k].truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : -1 }
        let x = m / 6 * 0.6 + noise.next() * 0.7
        let env = exp(-t / (open ? 0.12 : 0.022)) * min(1, t / 0.0008)
        out[i] = hp.run(x, cutoff: 7600, q: 0.8).hp * env * vel
    }
    return out
}

func snare(_ vel: Double = 1) -> [Double] {
    let n = samples(0.22)
    var out = [Double](repeating: 0, count: n)
    var ph = 0.0
    var f = SVF()
    for i in 0..<n {
        let t = Double(i) / sr
        ph += 2 * .pi * (185 + 60 * exp(-t / 0.02)) / sr
        let tone = sin(ph) * exp(-t / 0.05) * 0.6
        let body = f.run(noise.next(), cutoff: 3200, q: 0.7).bp * exp(-t / 0.085)
        out[i] = (tone + body * 1.3) * vel
    }
    return out
}

func crash(_ vel: Double = 1) -> [Double] {
    let n = samples(2.6)
    var out = [Double](repeating: 0, count: n)
    var f = SVF(), g = SVF()
    var ph = [Double](repeating: 0, count: 6)
    for i in 0..<n {
        let t = Double(i) / sr
        var m = 0.0
        for k in 0..<6 { ph[k] += hatFreqs[k] * 2.3 / sr; m += ph[k].truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : -1 }
        let x = noise.next() + m / 6 * 0.4
        let y = g.run(f.run(x, cutoff: 4200, q: 0.6).hp, cutoff: 14000, q: 0.6).lp
        out[i] = y * exp(-t / 0.75) * min(1, t / 0.003) * vel
    }
    return out
}

/// A plucked chord tone: two detuned saws through a fast-closing low-pass.
func pluck(_ note: Double, _ vel: Double = 1, decay: Double = 0.2, bright: Double = 1) -> [Double] {
    let n = samples(decay * 4)
    var out = [Double](repeating: 0, count: n)
    var a = Saw(phase: 0.1), b = Saw(phase: 0.6)
    var f = SVF()
    let fr = midi(note)
    for i in 0..<n {
        let t = Double(i) / sr
        let x = a.next(fr * 1.004) + b.next(fr * 0.996)
        let cutoff = 500 + 5200 * bright * exp(-t / (decay * 0.55))
        out[i] = f.run(x, cutoff: cutoff, q: 1.3).lp * exp(-t / decay) * min(1, t / 0.002) * vel * 0.5
    }
    return out
}

/// Seven detuned saws (a supersaw) for chords and pads.
func supersaw(_ notes: [Double], length: Double, attack: Double = 0.03, release: Double = 0.4, cutoff: Double = 3200) -> Stereo {
    let n = samples(length + release)
    var out = Stereo(n)
    let detune = [-0.11, -0.065, -0.03, 0, 0.03, 0.065, 0.11]
    for (j, note) in notes.enumerated() {
        var saws = detune.indices.map { Saw(phase: Double(($0 * 37 + j * 11) % 100) / 100) }
        var fl = SVF(), fr = SVF()
        let f = midi(note)
        for i in 0..<n {
            let t = Double(i) / sr
            let env = min(1, t / attack) * (t > length ? exp(-(t - length) / (release / 3)) : 1)
            var l = 0.0, r = 0.0
            for (k, d) in detune.enumerated() {
                let v = saws[k].next(f * pow(2, d / 12))
                let p = Double(k) / 6
                l += v * (1 - p); r += v * p
            }
            out.l[i] += fl.run(l, cutoff: cutoff, q: 0.7).lp * env * 0.12
            out.r[i] += fr.run(r, cutoff: cutoff, q: 0.7).lp * env * 0.12
        }
    }
    return out
}

func bassNote(_ note: Double, length: Double, vel: Double = 1) -> [Double] {
    let n = samples(length + 0.05)
    var out = [Double](repeating: 0, count: n)
    var s = Saw()
    var f = SVF()
    var sub = 0.0
    let fr = midi(note)
    for i in 0..<n {
        let t = Double(i) / sr
        sub += 2 * .pi * fr / sr
        let env = min(1, t / 0.004) * (t > length ? exp(-(t - length) / 0.012) : 1)
        let cutoff = 320 + 1400 * exp(-t / 0.07)
        let v = f.run(s.next(fr), cutoff: cutoff, q: 1.1).lp * 0.8 + sin(sub) * 0.45
        out[i] = tanh(v * 1.3) * env * vel
    }
    return out
}

func lead(_ note: Double, length: Double, vel: Double = 1) -> [Double] {
    let n = samples(length + 0.25)
    var out = [Double](repeating: 0, count: n)
    var a = Saw(), b = Saw(phase: 0.5)
    var f = SVF()
    let fr = midi(note)
    for i in 0..<n {
        let t = Double(i) / sr
        let vib = 1 + 0.004 * sin(2 * .pi * 5.2 * t) * min(1, t / 0.3)
        let env = min(1, t / 0.012) * (t > length ? exp(-(t - length) / 0.08) : 1) * (0.8 + 0.2 * exp(-t / 0.15))
        let x = a.next(fr * vib) * 0.6 + b.next(fr * 2 * vib * 1.002) * 0.25
        out[i] = f.run(x, cutoff: 2600 + 1800 * exp(-t / 0.2), q: 0.9).lp * env * vel * 0.5
    }
    return out
}

func bell(_ note: Double, _ vel: Double = 1, decay: Double = 1.6) -> [Double] {
    let n = samples(decay * 3)
    var out = [Double](repeating: 0, count: n)
    let f = midi(note)
    let partials: [(Double, Double, Double)] = [(1, 1, 1), (2.76, 0.4, 0.6), (5.4, 0.22, 0.35), (8.93, 0.1, 0.22)]
    for i in 0..<n {
        let t = Double(i) / sr
        var v = 0.0
        for (m, a, d) in partials { v += sin(2 * .pi * f * m * t) * a * exp(-t / (decay * d)) }
        out[i] = v * min(1, t / 0.002) * vel * 0.4
    }
    return out
}

// Sound design

func whoosh(_ len: Double, size: Double = 1) -> Stereo {
    let n = samples(len + 0.15)
    var out = Stereo(n)
    var f = SVF(), g = SVF()
    for i in 0..<n {
        let t = Double(i) / sr, p = min(1, t / len)
        let env = pow(sin(.pi * min(1, p * 0.85 + 0.0)), 2) * (t > len ? exp(-(t - len) / 0.05) : 1)
        let cutoff = 300 * pow(30, p)
        let x = noise.next()
        let y = f.run(x, cutoff: cutoff, q: 1.6).bp * 0.8 + g.run(x, cutoff: cutoff * 0.5, q: 0.7).lp * 0.3
        let pan = -0.8 + 1.6 * p
        let a = (pan + 1) * .pi / 4
        out.l[i] = y * env * cos(a) * size
        out.r[i] = y * env * sin(a) * size
    }
    return out
}

func riser(_ len: Double, size: Double = 1) -> Stereo {
    let n = samples(len)
    var out = Stereo(n)
    var f = SVF(), saw = Saw(), saw2 = Saw(phase: 0.3)
    for i in 0..<n {
        let t = Double(i) / sr, p = t / len
        let env = pow(p, 2.2) * (1 - pow(max(0, p - 0.97) / 0.03, 2))
        let nz = f.run(noise.next(), cutoff: 400 * pow(25, p), q: 2.2).bp
        let tone = (saw.next(110 * pow(8, p)) + saw2.next(110 * pow(8, p) * 1.01)) * 0.12 * p
        let wide = sin(2 * .pi * 0.9 * t * (1 + p * 6))
        out.l[i] = (nz * 0.7 + tone) * env * (1 + 0.3 * wide) * size
        out.r[i] = (nz * 0.7 + tone) * env * (1 - 0.3 * wide) * size
    }
    return out
}

func impact(_ size: Double) -> [Double] {
    let n = samples(2.2)
    var out = [Double](repeating: 0, count: n)
    var ph = 0.0
    var f = SVF()
    for i in 0..<n {
        let t = Double(i) / sr
        ph += 2 * .pi * (30 + 52 * exp(-t / 0.09)) / sr
        let boom = sin(ph) * exp(-t / (0.35 + 0.2 * size)) * min(1, t / 0.003)
        let crack = f.run(noise.next(), cutoff: 1800, q: 0.6).lp * exp(-t / 0.07)
        out[i] = tanh((boom * 0.6 + crack * 1.0) * 1.5) * size
    }
    return out
}

/// The type landing: a short bright tick on a soft low thud.
func snap(_ size: Double) -> [Double] {
    let n = samples(0.18)
    var out = [Double](repeating: 0, count: n)
    var f = SVF()
    var ph = 0.0
    for i in 0..<n {
        let t = Double(i) / sr
        ph += 2 * .pi * (95 + 60 * exp(-t / 0.01)) / sr
        let tick = f.run(noise.next(), cutoff: 4200, q: 3).bp * exp(-t / 0.006)
        let thud = sin(ph) * exp(-t / 0.045) * 0.6
        out[i] = (tick * 1.6 + thud) * size
    }
    return out
}

/// A mouse button: the press and, 85 ms later, the softer release.
func mouseClick(_ size: Double) -> [Double] {
    let n = samples(0.14)
    var out = [Double](repeating: 0, count: n)
    var f = SVF(), g = SVF()
    for i in 0..<n {
        let t = Double(i) / sr
        let down = exp(-t / 0.0035), tu = t - 0.085
        let up = tu >= 0 ? exp(-tu / 0.0025) * 0.55 : 0
        let x = noise.next()
        let body = f.run(x, cutoff: 3100, q: 4).bp
        let ping = g.run(x, cutoff: 6800, q: 6).bp * 0.5
        out[i] = (body + ping) * (down + up) * size * 1.5
    }
    return out
}

/// A key: a click, then the thock of the key bottoming out.
func keyPress(_ size: Double) -> [Double] {
    let n = samples(0.09)
    var out = [Double](repeating: 0, count: n)
    var f = SVF(), g = SVF()
    var ph = 0.0
    let pitch = 170 + noise.next() * 20
    for i in 0..<n {
        let t = Double(i) / sr
        ph += 2 * .pi * pitch / sr
        let click = g.run(noise.next(), cutoff: 5200, q: 2.5).bp * exp(-t / 0.003)
        let tb = t - 0.006
        let thock = tb >= 0 ? (f.run(noise.next(), cutoff: 1300, q: 1.8).bp * 1.2 + sin(ph) * 0.5) * exp(-tb / 0.018) : 0
        out[i] = (click * 0.9 + thock) * size
    }
    return out
}

/// The caret stepping in the dark: a small metallic tick with a low knock.
func caretTick(_ size: Double) -> [Double] {
    let n = samples(0.25)
    var out = [Double](repeating: 0, count: n)
    var ph = 0.0
    for i in 0..<n {
        let t = Double(i) / sr
        ph += 2 * .pi * (72 + 40 * exp(-t / 0.008)) / sr
        let metal = sin(2 * .pi * 3150 * t) * exp(-t / 0.018) * 0.5 + sin(2 * .pi * 4870 * t) * exp(-t / 0.01) * 0.3
        let knock = sin(ph) * exp(-t / 0.05)
        let tr = t < 0.002 ? noise.next() * (1 - t / 0.002) : 0
        out[i] = (metal + knock * 0.9 + tr * 0.6) * size
    }
    return out
}

/// Light gliding across glass: a faint rising shimmer.
func sheen(_ len: Double) -> Stereo {
    let n = samples(len + 0.6)
    var out = Stereo(n)
    var f = SVF()
    for i in 0..<n {
        let t = Double(i) / sr, p = min(1, t / len)
        let env = sin(.pi * p) * (t > len ? exp(-(t - len) / 0.2) : 1)
        let base = 1200 * pow(3, p)
        let tone = sin(2 * .pi * base * t) * 0.3 + sin(2 * .pi * base * 1.5 * t) * 0.2 + sin(2 * .pi * base * 2.01 * t) * 0.15
        let air = f.run(noise.next(), cutoff: 5000 + 6000 * p, q: 2).bp
        let pan = sin(2 * .pi * 0.4 * t)
        out.l[i] = (tone * 0.4 + air) * env * (1 - pan * 0.5) * 0.35
        out.r[i] = (tone * 0.4 + air) * env * (1 + pan * 0.5) * 0.35
    }
    return out
}

func reversed(_ s: Stereo) -> Stereo {
    var o = s
    o.l.reverse(); o.r.reverse()
    return o
}

// MARK: - Arrangement

var drums = Stereo(), bass = Stereo(), music = Stereo(), fx = Stereo(), clicks = Stereo()
var reverbSend = Stereo(), delaySend = Stereo()

func barStart(_ k: Int) -> Double { Double(k) * bar }     // bars counted from 0
let chords: [[Double]] = [[50, 53, 57], [46, 50, 53], [53, 57, 60], [48, 52, 55]]   // Dm B♭ F C
let roots: [Double] = [38, 34, 41, 36]
let arpShape = [0, 1, 2, 1, 3, 2, 1, 2, 0, 2, 3, 2, 1, 2, 3, 4]

// Tease: a low drone, wind, soft ticks; the caret steps; a reversed swell into the reveal.
do {
    let n = samples(5.0)
    var drone = Stereo(n)
    var wind = SVF()
    for i in 0..<n {
        let t = Double(i) / sr
        let env = min(1, t / 2.2) * (t > 4.6 ? max(0, 1 - (t - 4.6) / 0.3) : 1)
        let d = sin(2 * .pi * midi(26) * t) * 0.45 + sin(2 * .pi * midi(38) * t * 1.001) * 0.4 + sin(2 * .pi * midi(45) * t * 0.999) * 0.22 + sin(2 * .pi * midi(57) * t * 1.002) * 0.08 * min(1, t / 4)
        let w = wind.run(noise.next(), cutoff: 280 + 220 * sin(2 * .pi * 0.23 * t), q: 1.4).bp * 0.6
        drone.l[i] = (d + w) * env * 0.5
        drone.r[i] = (d * 0.97 + w * 1.1) * env * 0.5
    }
    music.add(drone, at: 0, gain: db(-5))
    // Soft clock ticks on the off-beats of the tease.
    var t = beat / 2
    while t < 4.4 {
        fx.add(hat(0.25), at: t, gain: db(-14), pan: 0.4)
        t += beat
    }
    // A sixteenth-note pluck, filtered and quiet, rising through the second bar.
    for s in 0..<16 {
        let tt = 2.5 + Double(s) * sixteenth
        let chord = chords[0]
        let note = (s % 2 == 0 ? chord[0] : chord[2]) + 12
        let p = Double(s) / 16
        let sig = pluck(note, 0.5 + 0.5 * p, decay: 0.14, bright: 0.25 + 0.6 * p)
        music.add(sig, at: tt, gain: db(-14) * (0.3 + 0.7 * p), pan: s % 2 == 0 ? -0.3 : 0.3)
        delaySend.add(sig, at: tt, gain: 0.25 * p)
    }
    // A reversed swell of the first chord into the window's reveal.
    let swell = Reverb(room: 0.9, damp: 0.2).process(supersaw([50, 57, 62, 65], length: 0.5, attack: 0.01, release: 0.3, cutoff: 2400))
    let rev = reversed(swell)
    music.add(rev, at: 3.125 - Double(rev.n) / sr, gain: db(-4))
    // Snare roll into the drop: eighths, sixteenths, then thirty-seconds.
    var tr = 3.75
    while tr < 4.9 {
        let p = (tr - 3.75) / 1.15
        drums.add(snare(0.25 + 0.6 * p), at: tr, gain: db(-14), pan: 0)
        tr += tr < 4.375 ? beat / 2 : (tr < 4.6875 ? sixteenth : sixteenth / 2)
    }
}

// The groove, bars 3–10 (5.0–25.0 s).
for k in 2..<10 {
    let t0 = barStart(k)
    let chordIndex = (k - 2) % 4
    let chord = chords[chordIndex]
    let hero = k >= 6
    let light = k == 8                 // the white-stage shot: fewer drums
    let build = k == 5 || k == 9       // last bar before a section: snare roll
    // Kick: four on the floor (only one and three in the light bar).
    for b in 0..<4 where !(light && b % 2 == 1) {
        drums.add(kick(1), at: t0 + Double(b) * beat, gain: db(-9))
    }
    // Clap on two and four, doubled with a snare in the hero.
    if !light {
        for b in [1, 3] {
            drums.add(clap(), at: t0 + Double(b) * beat, gain: db(-7))
            reverbSend.add(clap(), at: t0 + Double(b) * beat, gain: 0.35)
            if hero { drums.add(snare(0.6), at: t0 + Double(b) * beat, gain: db(-15)) }
        }
    }
    // Hats: sixteenths with accents; an open hat on each off-beat.
    for s in 0..<16 where !light || s % 4 == 2 {
        let accent = s % 4 == 2 ? 1.0 : (s % 2 == 0 ? 0.55 : 0.38)
        let open = s % 4 == 2 && !light
        drums.add(hat(accent, open: open), at: t0 + Double(s) * sixteenth, gain: db(open ? -14 : -15), pan: s % 2 == 0 ? 0.25 : -0.2)
    }
    if build {
        var tr = t0 + 2 * beat
        while tr < t0 + bar - 0.02 {
            let p = (tr - t0 - 2 * beat) / (2 * beat)
            drums.add(snare(0.3 + 0.6 * p), at: tr, gain: db(-15))
            tr += p < 0.5 ? sixteenth : sixteenth / 2
        }
    }
    // Bass: pumping eighths on the root, an octave jump on the last eighth.
    for e in 0..<8 where !(light && e % 2 == 1) {
        let note = roots[chordIndex] + (e == 7 ? 12 : 0)
        bass.add(bassNote(note, length: beat / 2 - 0.03, vel: e % 2 == 0 ? 1 : 0.8), at: t0 + Double(e) * beat / 2, gain: db(-9))
    }
    // Arpeggio: sixteenths over the chord, two octaves up.
    let tones = chord.map { $0 + 12 } + [chord[0] + 24, chord[1] + 24]
    for s in 0..<16 {
        let note = tones[arpShape[s] % tones.count]
        let sig = pluck(note, s % 4 == 0 ? 1 : 0.7, decay: hero ? 0.16 : 0.18, bright: hero ? 1.0 : 0.9)
        music.add(sig, at: t0 + Double(s) * sixteenth, gain: db(light ? -10 : -11), pan: s % 2 == 0 ? -0.35 : 0.35)
        delaySend.add(sig, at: t0 + Double(s) * sixteenth, gain: 0.2)
    }
    // Hero: wide supersaw chords and a hook.
    if hero {
        let voicing = chord.map { $0 + 12 } + [chord[0] + 24]
        let pad = supersaw(voicing, length: bar - 0.05, attack: light ? 0.25 : 0.02, release: 0.35, cutoff: light ? 2800 : 5200)
        music.add(pad, at: t0, gain: db(light ? -4 : -2))
        reverbSend.add(pad, at: t0, gain: 0.25)
        let hook: [[(Double, Double, Double)]] = [
            [(0, 69, 1.5), (1.5, 72, 0.5), (2, 74, 2)],
            [(0, 77, 1.5), (1.5, 76, 0.5), (2, 74, 2)],
            [(0, 72, 1.5), (1.5, 69, 0.5), (2, 72, 2)],
            [(0, 76, 1), (1, 74, 1), (2, 72, 1), (3, 74, 1)],
        ]
        if !light {
            for (b, note, len) in hook[chordIndex] {
                let sig = lead(note, length: len * beat - 0.04, vel: 0.9)
                music.add(sig, at: t0 + b * beat, gain: db(-10), pan: 0.05)
                delaySend.add(sig, at: t0 + b * beat, gain: 0.3)
                reverbSend.add(sig, at: t0 + b * beat, gain: 0.3)
            }
        }
    }
}

// The title: one ringing chord, a long sub drop and a bell under the name.
do {
    let t0 = 25.0
    let stab = supersaw([50, 57, 62, 64, 65, 69], length: 1.2, attack: 0.005, release: 3.2, cutoff: 3600)
    music.add(stab, at: t0, gain: db(-5))
    reverbSend.add(stab, at: t0, gain: 0.6)
    drums.add(kick(1, long: true), at: t0, gain: db(-9))
    drums.add(crash(0.9), at: t0, gain: db(-10), pan: 0.1)
    let pad = supersaw([62, 69, 74, 76], length: 3.4, attack: 0.6, release: 1.4, cutoff: 1800)
    music.add(pad, at: t0 + 0.4, gain: db(-12))
    reverbSend.add(pad, at: t0 + 0.4, gain: 0.5)
    let b = bell(86, 0.8, decay: 1.8)
    music.add(b, at: 25.625, gain: db(-15), pan: 0.15)
    reverbSend.add(b, at: 25.625, gain: 0.6)
    let b2 = bell(81, 0.6, decay: 1.6)
    music.add(b2, at: 26.25, gain: db(-19), pan: -0.15)
    reverbSend.add(b2, at: 26.25, gain: 0.6)
}

// Crashes at the starts of the sections.
for t in [5.0, 15.0] { drums.add(crash(1), at: t, gain: db(-11), pan: -0.1); reverbSend.add(crash(0.6), at: t, gain: 0.2) }

// The cues from the picture.
for c in cues {
    switch c.kind {
    case "impact":
        fx.add(impact(c.size), at: c.t, gain: db(-5) * min(1.2, c.size))
        reverbSend.add(impact(c.size * 0.6), at: c.t, gain: 0.5)
    case "hit":
        fx.add(impact(c.size * 0.6), at: c.t, gain: db(-10))
        fx.add(snap(0.8), at: c.t, gain: db(-14))
    case "whoosh":
        let w = whoosh(max(0.2, c.length), size: c.size)
        fx.add(w, at: c.t - max(0.2, c.length) * 0.75, gain: db(-9))
        reverbSend.add(w, at: c.t - max(0.2, c.length) * 0.75, gain: 0.25)
    case "riser":
        let r = riser(c.length, size: c.size)
        fx.add(r, at: c.t, gain: db(-11))
        reverbSend.add(r, at: c.t, gain: 0.2)
    case "snap":
        fx.add(snap(c.size), at: c.t, gain: db(-12), pan: 0)
        reverbSend.add(snap(c.size), at: c.t, gain: 0.2)
    case "sheen":
        let s = sheen(c.length)
        fx.add(s, at: c.t, gain: db(-13))
        reverbSend.add(s, at: c.t, gain: 0.4)
    case "tick":
        fx.add(caretTick(c.size), at: c.t, gain: db(-8), pan: -0.1)
        reverbSend.add(caretTick(c.size), at: c.t, gain: 0.5)
    case "click":
        clicks.add(mouseClick(c.size), at: c.t, gain: db(-15), pan: 0.15)
        reverbSend.add(mouseClick(c.size), at: c.t, gain: 0.06)
    case "key":
        clicks.add(keyPress(c.size), at: c.t, gain: db(-15), pan: -0.1)
    case "scroll":
        fx.add(whoosh(0.9, size: 0.25), at: c.t, gain: db(-22))
    default: break
    }
}

// MARK: - Mix

/// Ducks on every kick (attack 4 ms, recovery ~150 ms).
let kickTimes: [Double] = {
    var ts: [Double] = []
    for k in 2..<10 { for b in 0..<4 where !(k == 8 && b % 2 == 1) { ts.append(barStart(k) + Double(b) * beat) } }
    return ts + [25.0]
}()
func duck(_ depth: Double) -> (Int) -> Double {
    var curve = [Double](repeating: 1, count: count)
    for kt in kickTimes {
        let s = Int(kt * sr)
        for i in max(0, s - samples(0.004))..<min(count, s + samples(0.45)) {
            let t = Double(i - s) / sr
            let g = t < 0 ? 1 - depth * (1 + t / 0.004) : 1 - depth * exp(-t / 0.11)
            curve[i] = min(curve[i], g)
        }
    }
    return { curve[$0] }
}
bass.scale(by: duck(0.55))
music.scale(by: duck(0.4))

// The "suck" before the drop: everything but the riser pulls back over the last sixteenth.
let suck: (Int) -> Double = { i in
    let t = Double(i) / sr
    return t > 4.85 && t < 5.0 ? max(0.15, 1 - (t - 4.85) / 0.15) : 1
}
music.scale(by: suck); drums.scale(by: suck)

var master = Stereo()
master.mix(drums, gain: db(-1))
master.mix(bass, gain: db(-2))
master.mix(music, gain: db(-3))
master.mix(fx, gain: db(-2))
master.mix(clicks, gain: db(0))
master.mix(pingPong(delaySend, time: beat * 0.75, feedback: 0.38), gain: db(-14))
let wet = Reverb().process(reverbSend)
master.mix(wet, gain: db(-6))

// Master: high-pass, a gentle glue compressor, a soft clipper, then the fade to the end.
let rawPeak = zip(master.l, master.r).map { max(abs($0), abs($1)) }.max() ?? 1
master.scale(by: { _ in 0.8 / rawPeak })
var hpL = OnePole(), hpR = OnePole(), airL = OnePole(), airR = OnePole()
var env = 0.0
for i in 0..<count {
    var l = hpL.hp(master.l[i], 28), r = hpR.hp(master.r[i], 28)
    l += airL.hp(l, 3000) * 0.4      // presence and air on top
    r += airR.hp(r, 3000) * 0.4
    let level = max(abs(l), abs(r))
    env = level > env ? env + (level - env) * 0.01 : env + (level - env) * 0.0002
    let over = max(0, 20 * log10(max(env, 1e-6)) - (-10))
    let g = db(-over * (1 - 1 / 2.2))
    l *= g; r *= g
    let t = Double(i) / sr
    let fade = t > 28.6 ? max(0, 1 - (t - 28.6) / 1.35) : 1
    let start = min(1, t / 0.01)
    master.l[i] = tanh(l * 1.25) / 1.25 * fade * start
    master.r[i] = tanh(r * 1.25) / 1.25 * fade * start
}
let peak = zip(master.l, master.r).map { max(abs($0), abs($1)) }.max() ?? 1
let norm = db(-1.0) / peak
master.scale(by: { _ in norm })

// MARK: - Report and write

func rms(_ a: Double, _ b: Double) -> Double {
    let s = Int(a * sr), e = min(count, Int(b * sr))
    var sum = 0.0
    for i in s..<e { sum += (master.l[i] * master.l[i] + master.r[i] * master.r[i]) / 2 }
    return 10 * log10(max(1e-12, sum / Double(e - s)))
}
print(String(format: "levels (dB RMS): tease %.1f  drop %.1f  hero %.1f  light %.1f  title %.1f",
             rms(0, 5), rms(5, 15), rms(15, 20), rms(20, 22.5), rms(25, 28.5)))

// Spectrum balance by band (one FFT-free pass with filters).
do {
    let bands: [(String, Double, Double)] = [("20–60", 20, 60), ("60–250", 60, 250), ("250–2k", 250, 2000), ("2–6k", 2000, 6000), ("6–20k", 6000, 20000)]
    var total = 0.0
    var energies: [Double] = []
    for (_, lo, hi) in bands {
        var h = OnePole(), l = OnePole()
        var e = 0.0
        for i in stride(from: 0, to: count, by: 1) {
            let x = (master.l[i] + master.r[i]) / 2
            let y = l.lp(h.hp(x, lo), hi)
            e += y * y
        }
        energies.append(e); total += e
    }
    print("bands:", zip(bands, energies).map { String(format: "%@ %.1f dB", $0.0.0, 10 * log10($0.1 / total)) }.joined(separator: ", "))
}

let url = filmDir.appendingPathComponent("score.wav")
try? FileManager.default.removeItem(at: url)
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false)!
let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
                                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false],
                           commonFormat: .pcmFormatFloat32, interleaved: false)
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
buffer.frameLength = AVAudioFrameCount(count)
for i in 0..<count {
    buffer.floatChannelData![0][i] = Float(master.l[i])
    buffer.floatChannelData![1][i] = Float(master.r[i])
}
try file.write(from: buffer)
file.close()       // a global never deinitializes, and the header is only finished on close
print("wrote \(url.path)")
