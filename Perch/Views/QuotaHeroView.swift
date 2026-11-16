import SwiftUI

/// 额度's hero card: the tightest enabled window, big.
/// Replaces the 1.4 three summary tiles. One VoiceOver element.
struct QuotaHeroView: View {
    let hero: QuotaHero
    let now: Date

    @ScaledMetric(relativeTo: .largeTitle) private var scale: CGFloat = 1
    @Environment(\.verticalSizeClass) private var vertical
    /// The app's sky: tight when any window is low or any run-out line shows.
    @Environment(\.skyMood) private var mood
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown: Double = 0
    @State private var width: CGFloat = 361

    private var heroSize: CGFloat {
        PerchType.heroSize(scale: scale, screenWidth: width + 32, compactHeight: vertical == .compact)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("现在最紧")
                .font(.footnote)
                .foregroundStyle(.ink2)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    CountingText(value: shown) { "\(Int($0.rounded()))" }
                        .font(.system(size: heroSize, design: .serif).monospacedDigit())
                        .tracking(-1.5)
                    Text(verbatim: "%")
                        .font(.system(size: PerchType.heroPercentSize(heroSize), design: .serif))
                }
                .foregroundStyle(hero.tone.numberColor)
                .lineLimit(1)
                .fixedSize()
                Text("剩下")
                    .font(.system(size: 15))
                    .foregroundStyle(.ink2)
            }
            .padding(.top, 2)
            Text(verbatim: hero.source(now: now))
                .font(.system(size: 15).monospacedDigit())
                .foregroundStyle(.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Horizon(used: hero.used, tight: hero.tight || mood.health == .tight)
                .padding(.top, 18)
            if let runOut = hero.runOut {
                Label {
                    Text(verbatim: runOut.text(now: now))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hourglass").font(.system(size: 12))
                }
                .labelStyle(TightLabelStyle())
                .font(.system(size: 14).monospacedDigit())
                .foregroundStyle(.warn)
                .padding(.top, 12)
                .accessibilityIdentifier("hero-run-out")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .perchCard()
        .contentShape(.rect(cornerRadius: 22))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: hero.spoken(now: now)))
        .accessibilityHint(Text("打开详情"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("quota-hero")
        .onAppear {
            // Count up once, from 0, over 0.9 s; no count under Reduce Motion.
            guard shown == 0 else { return }
            if let grow = Motion.grow(reduce) {
                withAnimation(grow) { shown = hero.left.rounded() }
            } else {
                shown = hero.left.rounded()
            }
        }
        .onChange(of: hero.left) { _, left in
            withAnimation(reduce ? nil : Motion.calm) { shown = left.rounded() }
        }
    }
}

/// The horizon: a 1 pt track line, a 12 pt dot at x = used % with a
/// 6 pt halo, 「开始」/「重置」 6 pt below.
private struct Horizon: View {
    let used: Double
    let tight: Bool

    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var grown = false

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { g in
                let x = g.size.width * min(max(used, 0), 100) / 100 * (grown ? 1 : 0)
                let color: Color = tight ? .bad : .accentColor
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.track).frame(height: 1)
                    Circle()
                        .fill(color.opacity(0.14))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().fill(color).frame(width: 12, height: 12))
                        .offset(x: min(max(x - 12, -6), g.size.width - 18))
                }
                .frame(height: 24)
                .animation(Motion.calm(reduce), value: tight)
            }
            .frame(height: 24)
            HStack {
                Text("开始")
                Spacer()
                Text("重置")
            }
            .font(.system(size: 11))
            .foregroundStyle(.ink2)
        }
        .onAppear {
            if let grow = Motion.grow(reduce) { withAnimation(grow) { grown = true } } else { grown = true }
        }
        .animation(Motion.calm(reduce), value: used)
    }
}
