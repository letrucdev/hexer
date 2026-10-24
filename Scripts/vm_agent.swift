// Drives Hexer inside the test VM for Scripts/vm_test.sh, which builds it for macOS 15 (arm64) and
// copies it there with `deploy`. It needs the Accessibility permission, which an SSH session gets
// once sshd-keygen-wrapper is allowed in the VM's Privacy & Security ▸ Accessibility.
//
//   vm_agent keys KEY...        presses keys in Hexer: left right up down return escape tab space
//                               delete, a letter or digit, or a key code; with cmd+ shift+ opt+ ctrl+
//   vm_agent press TITLE        presses the first button with this title or accessibility label
//   vm_agent menu MENU ITEM     chooses a menu item, e.g. menu Help "Welcome to Hexer"
//   vm_agent close TITLE        clicks the close button of the window with this title
//   vm_agent windows            lists Hexer's windows, frontmost first: title | subrole | x y w h
//   vm_agent tree [TITLE]       prints the accessibility tree of the windows (or of one window)
//   vm_agent frame [TITLE]      "x y w h" of the frontmost window (or of the one with this title)
//   vm_agent screen             "w h" of the main display
// Frames and the display are in points, origin at the top left of the main display.
import AppKit
import ApplicationServices

let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("vm_agent: \(message)\n".utf8))
    exit(1)
}

func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var result: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}

func string(_ element: AXUIElement, _ name: String) -> String { value(element, name) as? String ?? "" }

func children(_ element: AXUIElement) -> [AXUIElement] { value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

func frame(_ window: AXUIElement) -> CGRect {
    var origin = CGPoint.zero, size = CGSize.zero
    if let v = value(window, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &origin) }
    if let v = value(window, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &size) }
    return CGRect(origin: origin, size: size)
}

func describe(_ element: AXUIElement) -> String {
    let parts = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute].map { string(element, $0) }
        + [value(element, kAXValueAttribute).map { "\($0)" } ?? ""]
    return parts.filter { !$0.isEmpty }.joined(separator: " | ")
}

/// Visits `element` and its descendants until `visit` returns false.
@discardableResult
func walk(_ element: AXUIElement, depth: Int = 0, _ visit: (AXUIElement, Int) -> Bool) -> Bool {
    guard depth < 40, visit(element, depth) else { return false }
    for child in children(element) where !walk(child, depth: depth + 1, visit) { return false }
    return true
}

func press(_ element: AXUIElement) {
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    if result != .success { fail("pressing \(describe(element)) failed (\(result.rawValue))") }
}

/// Key codes of the ANSI layout.
let keyCodes: [String: CGKeyCode] = {
    var codes: [String: CGKeyCode] = ["left": 123, "right": 124, "down": 125, "up": 126, "return": 36, "escape": 53,
                                      "tab": 48, "space": 49, "delete": 51, "forwarddelete": 117, "home": 115,
                                      "end": 119, "pageup": 116, "pagedown": 121]
    for (i, key) in "asdfhgzxcv_bqweryt123465=97-80]ou[ip_lj'k;\\,/nm.".enumerated() where key != "_" {
        codes[String(key)] = CGKeyCode(i)
    }
    codes["`"] = 50
    return codes
}()

func keys(_ names: [String], to pid: pid_t) {
    let modifiers: [String: CGEventFlags] = ["cmd": .maskCommand, "shift": .maskShift, "opt": .maskAlternate, "ctrl": .maskControl]
    for name in names {
        var parts = name.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let key = parts.removeLast()
        var flags = CGEventFlags()
        for part in parts {
            guard let flag = modifiers[part] else { fail("unknown modifier \(part) in \(name)") }
            flags.insert(flag)
        }
        guard let code = keyCodes[key] ?? CGKeyCode(key) else { fail("unknown key \(name)") }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
            event.flags = flags
            event.postToPid(pid)
            usleep(50_000)
        }
        // Long enough for a page of the welcome tour to turn.
        usleep(600_000)
    }
}

guard let command = args.first else { fail("no command; see the top of Scripts/vm_agent.swift") }
if command == "screen" {
    let display = CGMainDisplayID()
    print(CGDisplayPixelsWide(display), CGDisplayPixelsHigh(display))
    exit(0)
}
if !AXIsProcessTrusted() { fail("no Accessibility permission (see the top of Scripts/vm_agent.swift)") }
guard let hexer = NSRunningApplication.runningApplications(withBundleIdentifier: "com.nongdandev.hexer").first else {
    fail("Hexer is not running")
}
let app = AXUIElementCreateApplication(hexer.processIdentifier)
let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []

func window(titled title: String?) -> AXUIElement? {
    guard let title else { return windows.first }
    return windows.first { string($0, kAXTitleAttribute) == title }
}

switch command {
case "keys":
    keys(Array(args.dropFirst()), to: hexer.processIdentifier)
case "press":
    guard args.count == 2 else { fail("usage: press TITLE") }
    var button: AXUIElement?
    for w in windows where button == nil {
        walk(w) { element, _ in
            if string(element, kAXRoleAttribute) == kAXButtonRole,
               string(element, kAXTitleAttribute) == args[1] || string(element, kAXDescriptionAttribute) == args[1] {
                button = element
            }
            return button == nil
        }
    }
    guard let button else { fail("no button \"\(args[1])\"") }
    press(button)
case "menu":
    guard args.count == 3, let bar = value(app, kAXMenuBarAttribute) else { fail("usage: menu MENU ITEM") }
    guard let menu = children(bar as! AXUIElement).first(where: { string($0, kAXTitleAttribute) == args[1] }) else {
        fail("no menu \"\(args[1])\"")
    }
    guard let item = children(menu).flatMap(children).first(where: { string($0, kAXTitleAttribute) == args[2] }) else {
        fail("no item \"\(args[2])\" in \(args[1])")
    }
    press(item)
case "close":
    guard args.count == 2, let w = window(titled: args[1]) else { fail("no window \"\(args.dropFirst().first ?? "")\"") }
    guard let button = value(w, kAXCloseButtonAttribute) else { fail("the window has no close button") }
    press(button as! AXUIElement)
case "windows":
    for w in windows {
        let f = frame(w)
        print(string(w, kAXTitleAttribute), "|", string(w, kAXSubroleAttribute), "|",
              Int(f.minX), Int(f.minY), Int(f.width), Int(f.height))
    }
case "tree":
    let selected = args.count > 1 ? windows.filter { string($0, kAXTitleAttribute) == args[1] } : windows
    for w in selected {
        walk(w) { element, depth in
            print(String(repeating: "  ", count: depth) + describe(element))
            return true
        }
    }
case "frame":
    guard let w = window(titled: args.dropFirst().first) else { fail("no window") }
    let f = frame(w)
    print(Int(f.minX), Int(f.minY), Int(f.width), Int(f.height))
default:
    fail("unknown command \(command)")
}
