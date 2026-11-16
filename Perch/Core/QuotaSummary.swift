import Foundation

/// How the 额度 cards are ordered. Saved
/// across launches by its raw value.
enum QuotaSort: String, CaseIterable, Sendable {
    /// The account with the most calls in the last 7 days first. The
    /// default since 1.3.
    case mostUsed
    /// The card with the least left in any window first.
    case leastLeft
    /// The card whose next window resets soonest first.
    case soonestReset
    /// As magpie lists them.
    case magpie

    /// New key in 1.3, so everyone starts on the new default.
    static let storageKey = "perch.quotaSort.13"

    /// The menu label.
    var label: String {
        switch self {
        case .mostUsed: String(localized: "用得多的在前")
        case .leastLeft: String(localized: "剩得少的在前")
        case .soonestReset: String(localized: "快重置的在前")
        case .magpie: String(localized: "按 magpie 里的顺序")
        }
    }

    /// Cards without the key (no percentages, no reset time) keep
    /// magpie's order after the rest; ties keep magpie's order too.
    /// `calls`: 7-day calls by card id (`QuotaGrouping.calls`).
    func sorted(_ cards: [QuotaCard], now: Date = .now, calls: [String: Int] = [:]) -> [QuotaCard] {
        switch self {
        case .magpie:
            return cards
        case .mostUsed:
            return Self.stable(cards) { card in calls[card.id].flatMap { $0 > 0 ? -Double($0) : nil } }
        case .leastLeft:
            return Self.stable(cards) { $0.leastLeft?.left }
        case .soonestReset:
            return Self.stable(cards) { $0.soonestReset(now: now).map { $0.date.timeIntervalSince1970 } }
        }
    }

    /// Sorts by `key` ascending; nil keys go last; ties keep input order.
    private static func stable(_ cards: [QuotaCard], key: (QuotaCard) -> Double?) -> [QuotaCard] {
        cards.enumerated()
            .map { (offset: $0.offset, card: $0.element, key: key($0.element)) }
            .sorted { a, b in
                switch (a.key, b.key) {
                case let (x?, y?) where x != y: x < y
                case (_?, nil): true
                case (nil, _?): false
                default: a.offset < b.offset
                }
            }
            .map(\.card)
    }
}

/// One window of one card, as a tile quotes it: 「工作号 · 5 小时」.
struct QuotaPick: Equatable, Sendable {
    /// The card's title.
    var card: String
    /// The window's label.
    var window: String
    /// 「工作号 · 5 小时」.
    var source: String { "\(card) · \(window)" }
}

extension QuotaCard {
    /// Cards whose read failed don't count towards the tiles or the sort:
    /// their numbers are old.
    private var countable: Bool { error?.trimmed.isEmpty ?? true }

    /// The window with the smallest share left.
    var leastLeft: (left: Double, used: Double, window: QuotaWindow)? {
        guard countable else { return nil }
        var best: (left: Double, used: Double, window: QuotaWindow)?
        for window in windows where !window.unlimited {
            guard let left = QuotaFormat.remaining(window) else { continue }
            if best == nil || left < best!.left { best = (left, 100 - left, window) }
        }
        return best
    }

    /// The next window to reset, ignoring times already past.
    func soonestReset(now: Date = .now) -> (date: Date, window: QuotaWindow)? {
        guard countable else { return nil }
        var best: (date: Date, window: QuotaWindow)?
        for window in windows {
            guard let date = window.resetsAt, date > now else { continue }
            if best == nil || date < best!.date { best = (date, window) }
        }
        return best
    }
}

/// The three tiles above the 额度 cards.
struct QuotaSummary: Equatable, Sendable {
    /// 剩得最少: percent left, percent used (for the colour), where.
    var leastLeft: Double?
    /// % used of that same window, for the tile colour.
    var leastUsed: Double?
    /// Which card and window that is.
    var leastSource: QuotaPick?
    /// 最快重置.
    var soonest: Date?
    /// Which card and window resets first.
    var soonestSource: QuotaPick?
    /// 账号: cards, and how many are in use.
    var accounts: Int
    /// How many cards are in use right now.
    var inUse: Int
    /// Accounts switched off in magpie (copy 1.3 构建后补充).
    var off: Int = 0

    /// `inUse`: the cards marked 刚刚在用 (`QuotasStore.justUsed`); without
    /// it, the cards magpie flags `last`.
    init(_ cards: [QuotaCard], inUse: Int? = nil, now: Date = .now) {
        accounts = cards.count
        self.inUse = inUse ?? cards.filter(\.last).count
        off = cards.filter(\.off).count
        for card in cards {
            if let least = card.leastLeft, leastLeft == nil || least.left < leastLeft! {
                leastLeft = least.left
                leastUsed = least.used
                leastSource = QuotaPick(card: card.title, window: QuotaFormat.windowLabel(least.window.name))
            }
            if let next = card.soonestReset(now: now), soonest == nil || next.date < soonest! {
                soonest = next.date
                soonestSource = QuotaPick(card: card.title, window: QuotaFormat.windowLabel(next.window.name))
            }
        }
    }

    /// 「7%」; 「—」 when no card has a percentage.
    var leastText: String { leastLeft.map(QuotaFormat.percent) ?? "—" }

    /// 「42 分」, 「3 小时」, 「周四」; 「—」 without a reset time.
    func soonestText(now: Date = .now) -> String {
        soonest.map { QuotaFormat.resetsShort($0, now: now) } ?? "—"
    }

    /// 「2 个正在用」.
    var inUseText: String { String(localized: "\(inUse.text) 个正在用") }
    /// The 账号 tile's line: 「1 个已停用」, else 「都能用」.
    var offText: String { off > 0 ? String(localized: "\(off.text) 个已停用") : String(localized: "都能用") }
}
