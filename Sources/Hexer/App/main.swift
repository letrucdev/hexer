import AppKit

// The first NSDocumentController instantiated becomes the shared one.
_ = HexDocumentController()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = MainMenu.build()
if Bundle.main.bundleIdentifier == nil {
    // Running unbundled (`swift run`): behave like a regular app with a Dock icon.
    app.setActivationPolicy(.regular)
}
app.run()
