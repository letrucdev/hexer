import AppKit

extension NSWindow {
    /// Centers the window at the size its SwiftUI content gives it. A hosting controller hands its
    /// size to the window only after a layout pass, so a window centered before that is centered
    /// at size zero and then grows to the right and down from the middle of the screen.
    func centerAtContentSize() {
        if let view = contentViewController?.view { setContentSize(view.fittingSize) }
        center()
    }
}
