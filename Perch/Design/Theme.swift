import SwiftUI
import UIKit

// MARK: - Colour

extension Color {
    static let paper = Color("paper")
    static let card = Color("card")
    static let ink = Color("ink")
    static let ink2 = Color("ink2")
    static let hairline = Color("hairline")
    static let track = Color("track")
    static let warn = Color("warn")
    static let bad = Color("bad")
    static let good = Color("good")
    static let skyCalmA = Color("skyCalmA")
    static let skyCalmB = Color("skyCalmB")
    static let skyTightA = Color("skyTightA")
    static let skyTightB = Color("skyTightB")
}

extension ShapeStyle where Self == Color {
    static var paper: Color { .paper }
    static var card: Color { .card }
    static var ink: Color { .ink }
    static var ink2: Color { .ink2 }
    static var hairline: Color { .hairline }
    static var track: Color { .track }
    static var warn: Color { .warn }
    static var bad: Color { .bad }
    static var good: Color { .good }
}

/// Bar and big-number colour band, by **used**: < 70 % ink,
/// 70–89 % warn, ≥ 90 % bad.
enum BarTone: Equatable, Sendable {
    case ink, warn, bad

    /// The tone for a window that is `used` percent used.
    static func of(used: Double) -> BarTone {
        switch QuotaFormat.level(used: used) {
        case 0: .ink
        case 1: .warn
        default: .bad
        }
    }

    var color: Color {
        switch self {
        case .ink: .ink
        case .warn: .warn
        case .bad: .bad
        }
    }

    /// The window value and the hero number turn bad only at ≥ 90 %.
    var numberColor: Color { self == .bad ? .bad : .ink }
}

// MARK: - Type

/// The app's type ramp: serif display faces and system text styles.
enum PerchType {
    /// Serif (New York; Chinese falls back to PingFang).
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Hero number size: 68 pt at Large (56 pt on a 375-wide or
    /// compact-height phone), scaled with Dynamic Type, capped at 96.
    /// `scale` is the Dynamic Type ratio (@ScaledMetric value / base).
    static func heroSize(scale: CGFloat, screenWidth: CGFloat, compactHeight: Bool) -> CGFloat {
        let base: CGFloat = (screenWidth <= 375 || compactHeight) ? 56 : 68
        return min(96, (base * scale).rounded())
    }

    /// The 「%」 after the hero number keeps the 68:30 ratio.
    static func heroPercentSize(_ hero: CGFloat) -> CGFloat { (hero * 30 / 68).rounded() }

    /// Serif large titles everywhere (navigation bars are UIKit).
    @MainActor static func installNavigationTitles() {
        let metrics = UIFontMetrics(forTextStyle: .largeTitle)
        let base = UIFont.systemFont(ofSize: 34, weight: .semibold)
        let serif = base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: 34) } ?? base
        let large = metrics.scaledFont(for: serif)
        let ink = UIColor(named: "ink") ?? .label
        let appearance = UINavigationBar.appearance()
        appearance.largeTitleTextAttributes = [.font: large, .kern: 0.5, .foregroundColor: ink]
        let inlineBase = UIFont.systemFont(ofSize: 17, weight: .semibold)
        let inline = inlineBase.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: 17) } ?? inlineBase
        appearance.titleTextAttributes = [.font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: inline), .foregroundColor: ink]
    }
}

// MARK: - Motion. Reduce Motion fallbacks live here only.

/// The app's springs, each with its Reduce Motion fallback.
enum Motion {
    static let calm = Animation.spring(duration: 0.5, bounce: 0)
    static let settle = Animation.spring(duration: 0.35, bounce: 0.08)
    static let lift = Animation.spring(duration: 0.6, bounce: 0)
    /// Numbers counting, bars growing, chart line drawing.
    static let grow = Animation.spring(duration: 0.9, bounce: 0)
    /// Every move or scale under Reduce Motion.
    static let fade = Animation.easeInOut(duration: 0.2)

    /// `calm`, or a short fade under Reduce Motion.
    static func calm(_ reduce: Bool) -> Animation { reduce ? fade : calm }

    /// The offline card or the page banner going away: height and
    /// opacity to 0 together in 0.3 s. Under Reduce Motion it just goes
    /// (no collapse, no content moving).
    static let collapse = Animation.easeInOut(duration: 0.3)
    /// The page banner: in with opacity + move 0.3 s, out collapsing.
    static func banner(_ reduce: Bool, showing: Bool) -> Animation? {
        showing ? (reduce ? fade : .easeOut(duration: 0.3)) : (reduce ? nil : collapse)
    }
    /// The offline card: fade to unreachable 0.4 s, out collapsing.
    static func offline(_ reduce: Bool, showing: Bool) -> Animation? {
        showing ? (reduce ? fade : .easeOut(duration: 0.4)) : (reduce ? nil : collapse)
    }
    /// `settle`, or a short fade under Reduce Motion.
    static func settle(_ reduce: Bool) -> Animation { reduce ? fade : settle }
    /// `lift`, staggered 50 ms per `index` (up to 6), or a fade.
    static func lift(_ reduce: Bool, index: Int = 0) -> Animation {
        reduce ? fade : lift.delay(Double(min(index, 6)) * 0.05)
    }
    /// Grow animations under Reduce Motion: none (appear at value).
    static func grow(_ reduce: Bool) -> Animation? { reduce ? nil : grow }

    /// Stagger ends after six items; the rest come in together.
    static func stagger(_ index: Int) -> Double { Double(min(index, 6)) * 0.05 }
}

/// Content entering: rise 14 pt + fade, staggered. Once per view.
struct RiseIn: ViewModifier {
    var index: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.fromCache) private var fromCache
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || fromCache ? 1 : 0)
            .offset(y: shown || reduce || fromCache ? 0 : 14)
            .onAppear {
                guard !shown else { return }
                // Saved data is just there, no entrance.
                if fromCache { shown = true; return }
                withAnimation(Motion.lift(reduce, index: index)) { shown = true }
            }
            .task {
                // Never leave content invisible if the first appear's
                // animation got dropped (seen inside NavigationLink).
                try? await Task.sleep(for: .milliseconds(700))
                if !shown { withAnimation(Motion.fade) { shown = true } }
            }
    }
}

extension EnvironmentValues {
    /// What's on screen came from the disk cache (no rise, no grow).
    @Entry var fromCache = false
}

extension View {
    /// Fades and lifts the view in on first appearance, staggered by `index`.
    func riseIn(_ index: Int = 0) -> some View { modifier(RiseIn(index: index)) }
}

// MARK: - Haptics. Never for automatic refreshes or appearing content.

/// The app's haptics, by meaning.
enum Haptic {
    static let connected = SensoryFeedback.success
    static let failed = SensoryFeedback.error
    static let primary = SensoryFeedback.impact(flexibility: .rigid, intensity: 0.7)
    static let toggled = SensoryFeedback.impact(weight: .medium)
    static let selection = SensoryFeedback.selection
    static let refreshed = SensoryFeedback.impact(flexibility: .soft, intensity: 0.5)
    /// 1.5: a pull to refresh that didn't read.
    static let refreshFailed = SensoryFeedback.warning
    static let runOut = SensoryFeedback.warning
}

// MARK: - Card

/// The card surface: filled rounded rectangle with a faint light-mode shadow.
struct PerchCard: ViewModifier {
    var radius: CGFloat = 22
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape.fill(Color.card)
                    .shadow(color: scheme == .dark ? .clear : Color(red: 0x3C / 255, green: 0x28 / 255, blue: 0x0A / 255).opacity(0.04), radius: 0.5, y: 1)
                    .shadow(color: scheme == .dark ? .clear : Color(red: 0x3C / 255, green: 0x28 / 255, blue: 0x0A / 255).opacity(0.10), radius: 12, y: 10)
            }
            .overlay {
                if scheme == .dark { shape.strokeBorder(Color.hairline, lineWidth: 0.5) }
            }
    }
}

extension View {
    /// Puts the view on a `PerchCard` surface.
    func perchCard(radius: CGFloat = 22) -> some View { modifier(PerchCard(radius: radius)) }
}

/// Chips: 12 pt semibold on 12 % of their colour, radius 10.
struct Chip: View {
    let text: LocalizedStringKey
    var color: Color = .ink2
    var fill: Color? = nil
    var dot = false
    var breathing = false

    var body: some View {
        HStack(spacing: 5) {
            if dot { BreathingDot(color: color, breathing: breathing) }
            Text(text)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(fill ?? color.opacity(0.12), in: .rect(cornerRadius: 10, style: .continuous))
        .fixedSize()
    }
}

/// 「刚刚在用」's dot: breathes 2.4 s (opacity 1→0.35, scale 1→0.7).
struct BreathingDot: View {
    var color: Color = .good
    var breathing = true
    var size: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var low = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(low ? 0.35 : 1)
            .scaleEffect(low ? 0.7 : 1)
            .onAppear {
                guard breathing, !reduce else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { low = true }
            }
            .accessibilityHidden(true)
    }
}

/// A number that counts (hero, Agent summary): animatable, so a spring
/// between two values shows every integer on the way.
struct CountingText: View, Animatable {
    var value: Double
    var format: (Double) -> String

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(verbatim: format(value))
    }
}

// MARK: - Paper screens

/// Paper + ambient sky behind a tab root or a pushed screen. Lists and
/// forms lose their grouped background.
struct PerchScreen: ViewModifier {
    var sky = true
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) { g in g.contentOffset.y + g.contentInsets.top } action: { _, y in
                if sky { offset = y }
            }
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    Color.paper
                    if sky {
                        AmbientSky()
                            .offset(y: reduce ? 0 : -max(0, offset) * 0.5)
                    }
                }
                .ignoresSafeArea()
            }
    }
}

extension View {
    /// The standard screen background, with the scrolling sky when `sky`.
    func perchScreen(sky: Bool = true) -> some View { modifier(PerchScreen(sky: sky)) }
}
