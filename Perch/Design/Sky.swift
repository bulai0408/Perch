import SwiftUI

/// One sky for the whole app.
struct SkyMood: Equatable, Sendable {
    var health: QuotaHealth = .calm
    var offline = false
    /// Bumped when a manual refresh ends: a 0.6 s brightness breath.
    var breath = 0
}

extension EnvironmentValues {
    @Entry var skyMood = SkyMood()
}

/// The ambient sky: two radial gradients in a 420 pt layer at the top.
/// Colours interpolate over 1.2 s (0.2 s crossfade under Reduce Motion);
/// offline desaturates to 30 % over 0.6 s.
struct AmbientSky: View {
    @Environment(\.skyMood) private var mood
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var bright = false

    private var tight: Bool { mood.health == .tight && !mood.offline }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                layer(a: .skyCalmA, b: .skyCalmB, width: w).opacity(tight ? 0 : 1)
                layer(a: .skyTightA, b: .skyTightB, width: w).opacity(tight ? 1 : 0)
            }
            .animation(reduce ? .easeInOut(duration: 0.2) : .easeInOut(duration: 1.2), value: tight)
        }
        .frame(height: 420)
        .opacity(0.95)
        .saturation(mood.offline ? 0.3 : 1)
        .animation(.easeInOut(duration: 0.6), value: mood.offline)
        .brightness(bright ? 0.06 : 0)
        .onChange(of: mood.breath) { _, _ in
            withAnimation(.easeOut(duration: 0.3)) { bright = true }
            withAnimation(.easeIn(duration: 0.3).delay(0.3)) { bright = false }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Two soft radial glows (top left `a`, top right `b`) sized to `w`.
    private func layer(a: Color, b: Color, width w: CGFloat) -> some View {
        ZStack {
            RadialGradient(gradient: Gradient(stops: [.init(color: a, location: 0), .init(color: a.opacity(0), location: 0.7)]),
                           center: UnitPoint(x: 0.3, y: 0), startRadius: 0, endRadius: w * 0.7)
            RadialGradient(gradient: Gradient(stops: [.init(color: b, location: 0), .init(color: b.opacity(0), location: 0.7)]),
                           center: UnitPoint(x: 0.9, y: 0.1), startRadius: 0, endRadius: w * 0.6)
        }
        .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
    }
}
