import AppKit
import SwiftUI

/// The pages of the welcome tour, over a field of drifting hex bytes. Pages slide in the direction
/// of travel and their contents rise in one after another; with Reduce Motion they cross-fade.
struct WelcomeView: View {
    static let size = CGSize(width: 680, height: 560)

    let model: WelcomeModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Each page's color: the glow behind it, its symbols, the ripple that brings it in.
    static func nsTint(_ page: Int) -> NSColor {
        switch page {
        case 1: HexTheme.modified
        case 2: .systemOrange
        case 3: .systemGreen
        default: .controlAccentColor
        }
    }

    static func tint(_ page: Int) -> Color { Color(nsColor: nsTint(page)) }

    var body: some View {
        ZStack {
            // Over the field of bytes the window puts under this view.
            veil
            RadialGradient(colors: [Self.tint(model.page).opacity(0.2), Self.tint(model.page).opacity(0)],
                           center: UnitPoint(x: 0.5, y: 0.12), startRadius: 0, endRadius: 380)
                .animation(.smooth(duration: 0.9), value: model.page)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                ZStack {
                    page(model.page, start: model.changedAt)
                        .id(model.page)
                        .transition(WelcomePageTransition(model: model, reduceMotion: reduceMotion))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomBar
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .ignoresSafeArea()
    }

    /// Keeps the field of bytes out of the way of the page (an ellipse around its contents) and of
    /// the buttons, by laying the window's color over it.
    private var veil: some View {
        let color = Color(nsColor: .windowBackgroundColor)
        return ZStack {
            EllipticalGradient(stops: [.init(color: color.opacity(0.86), location: 0.55),
                                       .init(color: color.opacity(0.4), location: 0.8),
                                       .init(color: color.opacity(0), location: 1)],
                               center: UnitPoint(x: 0.5, y: 0.45), endRadiusFraction: 0.6)
            LinearGradient(stops: [.init(color: color.opacity(0), location: 0.77), .init(color: color.opacity(0.84), location: 0.89)],
                           startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func page(_ index: Int, start: Date) -> some View {
        switch index {
        case 0:
            WelcomeHeroPage(model: model, start: start)
        case 1:
            WelcomeFeaturePage(model: model, index: 1, title: "Edit any file, whatever its size", rows: [
                .init("character.cursor.ibeam", description: "Type over bytes or insert new ones, with unlimited undo."),
                .init("bolt", description: "Files of many gigabytes open at once."),
                .init("arrow.left.arrow.right", description: "Import Intel Hex and S-Record, or export as C, Java, HTML and more."),
            ]) { WelcomeEditIllustration(start: start) }
        case 2:
            WelcomeFeaturePage(model: model, index: 2, title: "Find, inspect and compare", rows: [
                .init("magnifyingglass", description: "Search for text, hex values, integers or floating-point numbers."),
                .init("list.bullet.rectangle", description: "The Data Inspector decodes the bytes at the caret in 30 formats."),
                .init("chart.bar", description: "Calculate checksums and statistics, or compare two files."),
            ]) { WelcomeFindIllustration(start: start) }
        default:
            WelcomeFeaturePage(model: model, index: 3, title: "Disks, safely", rows: [
                .init("externaldrive", description: "Open physical disks, volumes and disk images."),
                .init("lock", description: "Disks open read-only until you choose to write."),
                .init("checkmark.shield", description: "Your startup disk is never written."),
            ]) { WelcomeDiskIllustration(start: start) }
        }
    }

    private var bottomBar: some View {
        ZStack {
            WelcomePageDots(model: model)
            HStack(spacing: 10) {
                if !model.isLast {
                    Button("Skip") { model.onFinish(false) }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.cancelAction)
                        .transition(.opacity)
                }
                Spacer()
                if model.page > 0 {
                    Button("Back") { model.go(to: model.page - 1) }
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                Button {
                    if model.isLast { model.onFinish(true) } else { model.go(to: model.page + 1) }
                } label: {
                    Text(model.isLast ? "Open a File…" : "Continue")
                        .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 22)
    }
}

/// The first page: the icon, the name, and "Hexer" decoding from its bytes.
struct WelcomeHeroPage: View {
    let model: WelcomeModel
    let start: Date

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 136, height: 136)
                .shadow(color: .black.opacity(0.2), radius: 18, y: 10)
                .accessibilityHidden(true)
                .welcomeReveal(model, page: 0, order: 0, scale: 0.55)
            Text("Welcome to Hexer")
                .font(.system(size: 36, weight: .bold))
                .padding(.top, 20)
                .welcomeReveal(model, page: 0, order: 1)
            Text("A fast hex editor for files and disks, modelled on HxD.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .welcomeReveal(model, page: 0, order: 2)
            WelcomeDecodeRow(start: start)
                .padding(.top, 34)
                .welcomeReveal(model, page: 0, order: 3)
        }
        .padding(.horizontal, 40)
        .padding(.top, 20)
    }
}

/// An illustration, a title and three lines on what Hexer does.
struct WelcomeFeaturePage<Illustration: View>: View {
    struct Row {
        let symbol: String
        let description: LocalizedStringKey

        init(_ symbol: String, description: LocalizedStringKey) {
            self.symbol = symbol
            self.description = description
        }
    }

    let model: WelcomeModel
    let index: Int
    let title: LocalizedStringKey
    let rows: [Row]
    @ViewBuilder let illustration: () -> Illustration

    var body: some View {
        VStack(spacing: 0) {
            illustration()
                .frame(width: 520, height: 200)
                .accessibilityHidden(true)
                .welcomeReveal(model, page: index, order: 0, scale: 0.92)
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 24)
                .welcomeReveal(model, page: index, order: 1)
            VStack(alignment: .leading, spacing: 11) {
                ForEach(rows.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: rows[i].symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(WelcomeView.tint(index))
                            .frame(width: 22)
                        Text(rows[i].description)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .welcomeReveal(model, page: index, order: 2 + i)
                }
            }
            .frame(width: 480, alignment: .leading)
            .padding(.top, 16)
        }
        .padding(.top, 34)
    }
}

/// Dots for the pages; the current one stretches into a bar. Each one jumps to its page.
struct WelcomePageDots: View {
    let model: WelcomeModel

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<WelcomeModel.pageCount, id: \.self) { i in
                Button { model.go(to: i) } label: {
                    Capsule()
                        .fill(i == model.page ? AnyShapeStyle(WelcomeView.tint(i)) : AnyShapeStyle(.tertiary))
                        .frame(width: i == model.page ? 22 : 7, height: 7)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Page \(i + 1) of \(WelcomeModel.pageCount)"))
                .accessibilityAddTraits(i == model.page ? .isSelected : [])
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.35), value: model.page)
    }
}

/// Pages slide in from the side the tour is heading to, and out the other way.
struct WelcomePageTransition: Transition {
    let model: WelcomeModel
    let reduceMotion: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        let side: CGFloat = switch phase {
        case .willAppear: 1
        case .didDisappear: -1
        case .identity: 0
        }
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .offset(x: reduceMotion ? 0 : side * 90 * model.direction)
            .scaleEffect(phase.isIdentity || reduceMotion ? 1 : 0.97)
            .blur(radius: phase.isIdentity || reduceMotion ? 0 : 8)
    }
}

extension View {
    /// Fades and lifts the view into place once `page` is revealed, `order` steps after the first.
    func welcomeReveal(_ model: WelcomeModel, page: Int, order: Int, scale: CGFloat = 0.98) -> some View {
        modifier(WelcomeReveal(shown: model.revealed == page, order: order, scale: scale))
    }
}

private struct WelcomeReveal: ViewModifier {
    let shown: Bool
    let order: Int
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let visible = shown || reduceMotion
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 18)
            .scaleEffect(visible ? 1 : scale)
            .blur(radius: visible ? 0 : 6)
            .animation(visible ? .spring(duration: 0.8, bounce: scale < 0.9 ? 0.4 : 0.22).delay(0.08 * Double(order))
                               : .easeOut(duration: 0.2), value: visible)
    }
}
