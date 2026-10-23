import SwiftUI

/// Metrics shared by the floating Liquid Glass bars over the grid (find bar, compare and sector
/// capsules), so text fields, button groups and buttons line up at one height.
enum GlassBar {
    static let height: CGFloat = 36
    /// Hit area of an icon button inside a bar.
    static let iconSize: CGFloat = 28
}

/// An SF Symbol button inside a glass bar.
struct GlassBarIconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void

    init(_ symbol: String, _ help: LocalizedStringKey, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: GlassBar.iconSize, height: GlassBar.iconSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// A text button drawn as its own glass capsule at `GlassBar.height`, matching the hand-built
/// capsules beside it (system glass button styles size to the control size instead).
struct GlassCapsuleButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            // One line always: a capsule never grows, so a long (e.g. Vietnamese) title would spill out.
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 16)
            .frame(height: GlassBar.height)
            .contentShape(Capsule())
            .glassEffect(prominent ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
    }
}

extension ButtonStyle where Self == GlassCapsuleButtonStyle {
    static var glassCapsule: GlassCapsuleButtonStyle { GlassCapsuleButtonStyle() }
    static var glassCapsuleProminent: GlassCapsuleButtonStyle { GlassCapsuleButtonStyle(prominent: true) }
}
