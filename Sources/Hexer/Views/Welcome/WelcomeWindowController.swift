import AppKit
import SwiftUI

/// The welcome tour. It takes the Open panel's place the first time Hexer starts without a
/// document, and Help ▸ Welcome to Hexer shows it again.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private static var current: WelcomeWindowController?
    private static let shownKey = "WelcomeShown"

    let model: WelcomeModel
    /// Shown at launch: closing it then carries on to the Open panel, as a launch without it does.
    private let atLaunch: Bool
    private var opensFile = false

    /// Shows the tour unless it was shown before; false then, so the launch goes on as usual.
    static func showIfFirstLaunch() -> Bool {
        guard !UserDefaults.standard.bool(forKey: shownKey) else { return false }
        show(atLaunch: true)
        return true
    }

    /// `marksShown: false` (scripted snapshots) leaves the first-launch tour to come.
    static func show(page: Int = 0, atLaunch: Bool = false, marksShown: Bool = true) {
        if marksShown { UserDefaults.standard.set(true, forKey: shownKey) }
        if let current {
            current.model.go(to: page)
            current.showWindow(nil)
            return
        }
        let controller = WelcomeWindowController(page: page, atLaunch: atLaunch)
        current = controller
        controller.showWindow(nil)
        controller.model.reveal(after: 0.3)
    }

    static var window: NSWindow? { current?.window }
    static var model: WelcomeModel? { current?.model }

    private init(page: Int, atLaunch: Bool) {
        model = WelcomeModel(page: page)
        self.atLaunch = atLaunch
        let window = WelcomeWindow(contentRect: NSRect(origin: .zero, size: WelcomeView.size),
                                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = L("Welcome to Hexer")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // The field of bytes under the SwiftUI view (see WelcomeHexFieldView).
        let field = WelcomeHexFieldView()
        let host = NSHostingView(rootView: WelcomeView(model: model))
        host.sizingOptions = []
        let container = NSView(frame: NSRect(origin: .zero, size: WelcomeView.size))
        for view in [field, host] as [NSView] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        window.contentView = container
        window.setContentSize(WelcomeView.size)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.onArrow = { [model] step in model.go(to: model.page + step) }
        field.show(page: model.page)
        model.onPageChange = { [field] page in field.show(page: page) }
        model.onFinish = { [weak self] openFile in
            self?.opensFile = openFile
            self?.close()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
        let controller = NSDocumentController.shared
        guard opensFile || atLaunch && controller.documents.isEmpty else { return }
        // After the window is gone: the Open panel runs modally.
        DispatchQueue.main.async { controller.openDocument(nil) }
    }
}

/// Arrow keys turn the pages; Escape closes the window when no Skip button takes it.
final class WelcomeWindow: NSWindow {
    var onArrow: (Int) -> Void = { _ in }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onArrow(-1)
        case 124: onArrow(1)
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// Which page of the tour shows, and the clock its animations run on.
@Observable
final class WelcomeModel {
    static let pageCount = 4

    private(set) var page: Int
    /// +1 when the tour moves forward, -1 back: the side the next page slides in from.
    private(set) var direction: CGFloat = 1
    /// The page whose contents have risen into place. It follows `page` a moment later, so they
    /// come in after the page itself.
    private(set) var revealed: Int?
    /// When `page` last changed: the clock of the page's illustration.
    private(set) var changedAt = Date.now

    @ObservationIgnored var onFinish: (_ openFile: Bool) -> Void = { _ in }
    @ObservationIgnored var onPageChange: (Int) -> Void = { _ in }

    init(page: Int) {
        self.page = min(max(page, 0), Self.pageCount - 1)
    }

    var isLast: Bool { page == Self.pageCount - 1 }

    func go(to target: Int) {
        let target = min(max(target, 0), Self.pageCount - 1)
        guard target != page else { return }
        direction = target > page ? 1 : -1
        revealed = nil
        changedAt = .now
        withAnimation(.smooth(duration: 0.55)) { page = target }
        onPageChange(target)
        reveal(after: 0.14)
    }

    /// Raises the current page's contents; each element animates in with its own delay.
    func reveal(after delay: TimeInterval) {
        let target = page
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, page == target else { return }
            revealed = target
        }
    }
}
