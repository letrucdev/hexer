import AppKit
import SwiftUI

/// A segmented control that switches between views (the drawer's tabs), with the `tabs` role
/// macOS 27 draws differently from a value picker; SwiftUI's segmented Picker cannot set it yet.
/// The control gets a fixed frame of its own intrinsic size, measured once per set of titles.
struct SegmentedTabs<Tag: Hashable>: View {
    let titles: [String]
    let tags: [Tag]
    @Binding var selection: Tag

    var body: some View {
        let size = Self.size(for: titles)
        Control(titles: titles, tags: tags, selection: $selection)
            .frame(width: size.width, height: size.height)
    }

    /// The intrinsic size of a control with these titles, measured once.
    private static func size(for titles: [String]) -> CGSize {
        let key = titles.joined(separator: "\u{1F}")
        if let size = cache[key] { return size }
        let size = Control.make(titles: titles, target: nil, action: nil).intrinsicContentSize
        cache[key] = size
        return size
    }

    private struct Control: NSViewRepresentable {
        let titles: [String]
        let tags: [Tag]
        @Binding var selection: Tag

        static func make(titles: [String], target: AnyObject?, action: Selector?) -> NSSegmentedControl {
            let control = NSSegmentedControl(labels: titles, trackingMode: .selectOne, target: target, action: action)
            if #available(macOS 27, *) { control.role = .tabs }
            return control
        }

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeNSView(context: Context) -> NSSegmentedControl {
            Self.make(titles: titles, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        }

        func updateNSView(_ control: NSSegmentedControl, context: Context) {
            context.coordinator.parent = self
            if control.segmentCount == titles.count {
                for (i, title) in titles.enumerated() where control.label(forSegment: i) != title {
                    control.setLabel(title, forSegment: i)
                }
            }
            if let i = tags.firstIndex(of: selection), control.selectedSegment != i { control.selectedSegment = i }
        }

        final class Coordinator: NSObject {
            var parent: Control

            init(_ parent: Control) { self.parent = parent }

            @objc func changed(_ sender: NSSegmentedControl) {
                guard parent.tags.indices.contains(sender.selectedSegment) else { return }
                parent.selection = parent.tags[sender.selectedSegment]
            }
        }
    }
}

/// Measured control sizes by their titles (the same for every tag type).
private var cache: [String: CGSize] = [:]
