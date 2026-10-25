// Types keys into the frontmost app through the HID event tap, the path that input methods such
// as OpenKey intercept (System Events keystrokes bypass them). For checking Telex in the grid.
//
//   swiftc -O -o build/hid_keys Scripts/hid_keys.swift
//   build/hid_keys tab a s            keys: a–z, tab, bs (Backspace), cmd+<key>
//
// Bring Hexer to the front first (System Events: set frontmost of process "Hexer" to true).
// OpenKey's smart switch remembers Vietnamese/English per bundle identifier; on this Mac
// com.nongdandev.hexer is in English, so use a copy with another identifier to see Telex.
import CoreGraphics
import Foundation

let codes: [String: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
                                  "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
                                  "n": 45, "m": 46, "tab": 48, "bs": 51]
let source = CGEventSource(stateID: .hidSystemState)
for arg in CommandLine.arguments.dropFirst() {
    var name = arg
    var flags: CGEventFlags = []
    if name.hasPrefix("cmd+") { flags.insert(.maskCommand); name = String(name.dropFirst(4)) }
    guard let code = codes[name] else { FileHandle.standardError.write(Data("unknown key \(arg)\n".utf8)); exit(1) }
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
        event.flags = flags
        event.post(tap: .cghidEventTap)
        usleep(40_000)
    }
    usleep(350_000)
}
