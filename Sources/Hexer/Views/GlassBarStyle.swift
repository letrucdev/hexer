import SwiftUI

/// Metrics shared by the floating Liquid Glass bars over the grid (find bar, compare and sector
/// capsules), so text fields, button groups and buttons line up at one height.
enum GlassBar {
    static let height: CGFloat = 36
    /// Hit area of an icon button inside a bar.
    static let iconSize: CGFloat = 28
}

/// Liquid Glass needs macOS 26. On macOS 15 the same floating controls sit on the standard material
/// with a hairline border and a soft shadow; tinted ones (prominent buttons, the mode chip) get a
/// solid fill. Layout and sizes are the same on both.
enum GlassSupport {
    /// `-HexerNoGlass 1` shows the macOS 15 look on newer systems, to check it without a VM.
    static let isAvailable: Bool = {
        guard #available(macOS 26, *) else { return false }
        return !UserDefaults.standard.bool(forKey: "HexerNoGlass")
    }()
}

extension View {
    /// The capsule behind a floating control: glass, optionally tinted, on macOS 26 and later.
    @ViewBuilder
    func barGlass(tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(macOS 26, *), GlassSupport.isAvailable {
            let glass = tint.map { Glass.regular.tint($0) } ?? .regular
            glassEffect(interactive ? glass.interactive() : glass, in: .capsule)
        } else if let tint {
            background(tint, in: .capsule)
        } else {
            background(.regularMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
    }

    /// Lets the capsule morph with its neighbours in a `GlassGroup` (macOS 26 and later).
    @ViewBuilder
    func barGlassID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26, *), GlassSupport.isAvailable {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }
}

/// `GlassEffectContainer` on macOS 26 and later, plain content before.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26, *), GlassSupport.isAvailable {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
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
            .barGlass(tint: prominent ? .accentColor : nil)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
    }
}

extension ButtonStyle where Self == GlassCapsuleButtonStyle {
    static var glassCapsule: GlassCapsuleButtonStyle { GlassCapsuleButtonStyle() }
    static var glassCapsuleProminent: GlassCapsuleButtonStyle { GlassCapsuleButtonStyle(prominent: true) }
}
