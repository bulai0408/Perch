import Foundation
import Testing
@testable import Perch

private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// A quota window fixture.
private func w(_ name: String, used: Double, resetIn: TimeInterval? = nil, unlimited: Bool = false) -> QuotaWindow {
    QuotaWindow(name: name, used: used, remaining: 100 - used, resetsAt: resetIn.map { now.addingTimeInterval($0) },
                display: nil, unlimited: unlimited, text: false, lane: nil)
}

/// A Claude quota card fixture.
private func card(_ alias: String, _ windows: [QuotaWindow], off: Bool = false, error: String? = nil) -> QuotaCard {
    QuotaCard(provider: "claude", name: "Claude", kind: "subscription", plan: "Max", user: alias + "@example.com",
              alias: alias, seat: nil, from: nil, windows: windows, balance: nil, error: error, asOf: nil,
              readAt: nil, last: false, off: off)
}

/// 1.5 sky health.
struct SkyHealthTests {
    @Test func calmAbove15PercentLeft() {
        #expect(QuotaHealth.of([card("a", [w("5h", used: 84), w("7d", used: 10)])]) == .calm)
    }

    @Test func tightAt15PercentLeftOrLess() {
        #expect(QuotaHealth.of([card("a", [w("5h", used: 85)])]) == .tight)
        #expect(QuotaHealth.of([card("a", [w("5h", used: 10)]), card("b", [w("7d", used: 99)])]) == .tight)
    }

    @Test func stoppedAndFailedAccountsDontCount() {
        #expect(QuotaHealth.of([card("a", [w("5h", used: 95)], off: true)]) == .calm)
        #expect(QuotaHealth.of([card("a", [w("5h", used: 95)], error: "upstream 500")]) == .calm)
        #expect(QuotaHealth.of([card("a", [w("5h", used: 95, unlimited: true)])]) == .calm)
    }

    @Test func aRunOutLineMakesItTight() {
        let c = card("a", [w("5h", used: 40, resetIn: 3 * 3600)])
        let line = RunOut(window: "5h", at: now.addingTimeInterval(3600), pace: 0.01)
        #expect(QuotaHealth.of([c]) { _ in line } == .tight)
        #expect(QuotaHealth.of([c]) { _ in nil } == .calm)
    }
}

/// Bar / number colour by used: < 70 ink, 70–89 warn, ≥ 90 bad.
struct BarToneTests {
    @Test func thresholds() {
        #expect(BarTone.of(used: 0) == .ink)
        #expect(BarTone.of(used: 69.9) == .ink)
        #expect(BarTone.of(used: 70) == .warn)
        #expect(BarTone.of(used: 89.9) == .warn)
        #expect(BarTone.of(used: 90) == .bad)
        #expect(BarTone.of(used: 100) == .bad)
    }

    @Test func numbersTurnBadOnlyAt90() {
        #expect(BarTone.warn.numberColor == .ink)
        #expect(BarTone.bad.numberColor == .bad)
    }
}

/// The hero picks the tightest enabled window.
struct QuotaHeroTests {
    private let cards = [
        card("工作号", [w("5h", used: 62, resetIn: 3 * 3600), w("7d", used: 79, resetIn: 4 * 86400)]),
        card("个人号", [w("5h", used: 93, resetIn: 42 * 60), w("7d", used: 34)]),
        card("备用号", [w("5h", used: 99)], off: true),
    ]

    @Test func picksTheLeastLeftOfEnabledAccounts() throws {
        let hero = try #require(QuotaHero.pick(cards))
        #expect(hero.card.title == "个人号")
        #expect(hero.window.name == "5h")
        #expect(abs(hero.left - 7) < 0.001)
        #expect(hero.tone == .bad)
        #expect(hero.tight)
    }

    @Test func noHeroWithoutCountableWindows() {
        #expect(QuotaHero.pick([]) == nil)
        #expect(QuotaHero.pick([card("a", [w("5h", used: 50)], off: true)]) == nil)
    }

    @Test func runOutOnlyWhenItIsTheHeroWindow() throws {
        let other = RunOut(window: "7d", at: now.addingTimeInterval(600), pace: 0.1)
        #expect(try #require(QuotaHero.pick(cards) { _ in other }).runOut == nil)
        let same = RunOut(window: "5h", at: now.addingTimeInterval(600), pace: 0.1)
        #expect(try #require(QuotaHero.pick(cards) { _ in same }).runOut == same)
    }

    @Test func spokenAsOneSentence() throws {
        let hero = try #require(QuotaHero.pick(cards))
        #expect(hero.spoken(now: now) == "现在最紧：个人号 5 小时，剩 7%，42 分钟后重置。")
        var withLine = hero
        withLine.runOut = RunOut(window: "5h", at: now.addingTimeInterval(1800), pace: 0.1)
        let text = withLine.spoken(now: now)
        #expect(text.hasPrefix("现在最紧：个人号 5 小时，剩 7%，42 分钟后重置。照现在的速度大约 "))
        #expect(text.hasSuffix(" 用完。"))
    }

    @Test func sourceLine() throws {
        let hero = try #require(QuotaHero.pick(cards))
        #expect(hero.source(now: now) == "个人号 · 5 小时 · 42 分后重置")
    }

    @Test func spokenResetRanges() {
        #expect(QuotaHero.spokenReset(now.addingTimeInterval(42 * 60), now: now) == "42 分钟后重置")
        #expect(QuotaHero.spokenReset(now.addingTimeInterval(3 * 3600 + 60), now: now) == "3 小时后重置")
        #expect(QuotaHero.spokenReset(nil, now: now) == nil)
    }
}

/// Hero number size: 68 at Large, 56 on a 375-wide or
/// compact-height phone, scales with Dynamic Type, capped at 96.
struct HeroFontTests {
    @Test func baseSizes() {
        #expect(PerchType.heroSize(scale: 1, screenWidth: 393, compactHeight: false) == 68)
        #expect(PerchType.heroSize(scale: 1, screenWidth: 375, compactHeight: false) == 56)
        #expect(PerchType.heroSize(scale: 1, screenWidth: 430, compactHeight: true) == 56)
    }

    @Test func scalesAndCaps() {
        #expect(PerchType.heroSize(scale: 1.2, screenWidth: 393, compactHeight: false) == 82)
        #expect(PerchType.heroSize(scale: 3, screenWidth: 393, compactHeight: false) == 96)
        #expect(PerchType.heroPercentSize(68) == 30)
    }
}
