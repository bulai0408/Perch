import Foundation

/// The sky's health: tight when any enabled account window
/// has ≤ 15 % left or any run-out line is showing; else calm.
enum QuotaHealth: Equatable, Sendable {
    case calm, tight

    /// At or below this % left, a window counts as tight.
    static let tightLeft: Double = 15

    /// Cards that count: switched on, read without an error.
    static func counts(_ card: QuotaCard) -> Bool {
        !card.off && !card.loginExpired && (card.error?.trimmed.isEmpty ?? true)
    }

    /// `runOut`: the card's run-out line, as the 额度 card shows it.
    static func of(_ cards: [QuotaCard], runOut: (QuotaCard) -> RunOut? = { _ in nil }) -> QuotaHealth {
        for card in cards where counts(card) {
            for w in card.windows where !w.unlimited {
                if let left = QuotaFormat.remaining(w), left <= tightLeft { return .tight }
            }
            if card.kind == "subscription", runOut(card) != nil { return .tight }
        }
        return .calm
    }
}

/// The hero card's window: the tightest window of any enabled account,
/// with its run-out line when one shows.
struct QuotaHero: Equatable, Sendable {
    /// The account card the window belongs to.
    var card: QuotaCard
    /// The tightest window.
    var window: QuotaWindow
    /// % left and % used.
    var left: Double
    /// % used.
    var used: Double
    /// The run-out projection, only when it is for this same window.
    var runOut: RunOut?

    /// Bar colour band for `used`.
    var tone: BarTone { BarTone.of(used: used) }
    /// Tight: the horizon dot turns bad.
    var tight: Bool { left <= QuotaHealth.tightLeft || runOut != nil }

    /// The window with the least left across every counted card; nil when
    /// no card has a percent window.
    static func pick(_ cards: [QuotaCard], runOut: (QuotaCard) -> RunOut? = { _ in nil }) -> QuotaHero? {
        var best: QuotaHero?
        for card in cards where QuotaHealth.counts(card) {
            guard let least = card.leastLeft else { continue }
            if best == nil || least.left < best!.left {
                let line = runOut(card)
                best = QuotaHero(card: card, window: least.window, left: least.left, used: least.used,
                                 runOut: line?.window == least.window.name ? line : nil)
            }
        }
        return best
    }

    /// 「个人号 · 5 小时 · 42 分后重置」.
    func source(now: Date = .now) -> String {
        [card.title, WindowCell.label(window), QuotaFormat.resets(window.resetsAt, now: now)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// VoiceOver, one element: 「现在最紧：个人号 5 小时，剩 7%，42 分钟后重置。照现在的速度大约 16:05 用完。」
    func spoken(now: Date = .now) -> String {
        var parts = [String(localized: "\(card.title) \(WindowCell.label(window))"), String(localized: "剩 \(QuotaFormat.percent(left))")]
        if let reset = Self.spokenReset(window.resetsAt, now: now) { parts.append(reset) }
        var text = String(localized: "现在最紧：") + parts.joined(separator: "，") + "。"
        if let runOut { text += String(localized: "照现在的速度大约 \(QuotaFormat.until(runOut.at, now: now)) 用完。") }
        return text
    }

    /// 「42 分钟后重置」, 「3 小时后重置」, 「周四 08:00 重置」.
    static func spokenReset(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded()))
        if minutes < 60 { return String(localized: "\(minutes.text) 分钟后重置") }
        if minutes < 1440 { return String(localized: "\((minutes / 60).text) 小时后重置") }
        return String(localized: "\(QuotaFormat.dayAndTime(date, now: now)) 重置")
    }
}
