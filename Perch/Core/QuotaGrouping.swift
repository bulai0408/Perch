import Foundation

/// 额度's sections: subscription cards grouped
/// by provider, the provider with the most calls in the last 7 days first,
/// then 「按量付费」 (balance, plan and key cards) last.
struct QuotaSection: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var cards: [QuotaCard]
    var isClaude: Bool
    var isPayAsYouGo: Bool
}

/// Groups and ranks quota cards for 额度. Pure functions over cards and
/// the 7-day usage summary (`GET /v1/magpie/usage?period=7d`).
enum QuotaGrouping {
    /// The id of the 「按量付费」 section (sorts after any provider key).
    static let payAsYouGoID = "~pay-as-you-go"

    /// The section a subscription card belongs to.
    static func providerKey(_ card: QuotaCard) -> String {
        SubscriptionAccounts.isClaude(card) ? "claude" : SubscriptionAccounts.providerKey(card.provider)
    }

    /// 7-day calls per card id, matched to `/usage`'s `accounts[]` by the
    /// login, alias or title.
    static func calls(_ cards: [QuotaCard], usage: UsageSummary?) -> [String: Int] {
        guard let usage else { return [:] }
        var out: [String: Int] = [:]
        for card in cards {
            if let bucket = bucket(for: card, in: usage.accounts) { out[card.id] = bucket.totals.calls }
        }
        return out
    }

    /// The usage split row (`accounts[]`, or an `account=` read) of a
    /// card: matched by login, alias or title, case aside.
    static func bucket(for card: QuotaCard, in buckets: [UsageBucket]) -> UsageBucket? {
        let names = Set([card.user, card.alias, card.title].compactMap { $0?.lowercased() })
        return buckets.first { names.contains($0.id.lowercased()) || names.contains($0.name.lowercased()) }
    }

    /// The card a usage account name belongs to (subscription cards only).
    static func card(named name: String, in cards: [QuotaCard]) -> QuotaCard? {
        let n = name.lowercased()
        return cards.first { card in
            card.kind == "subscription" && [card.user, card.alias, card.title].compactMap { $0?.lowercased() }.contains(n)
        }
    }

    /// 7-day calls per provider: its accounts' calls, else the calls of
    /// models it served (`models[].provider`).
    static func providerCalls(_ cards: [QuotaCard], usage: UsageSummary?) -> [String: Int] {
        guard let usage else { return [:] }
        var out: [String: Int] = [:]
        let byCard = calls(cards, usage: usage)
        for card in cards where card.kind == "subscription" {
            out[providerKey(card), default: 0] += byCard[card.id] ?? 0
        }
        for model in usage.models {
            guard let provider = model.provider.map(SubscriptionAccounts.providerKey), (out[provider] ?? 0) == 0,
                  cards.contains(where: { providerKey($0) == provider }) else { continue }
            out[provider, default: 0] += model.totals.calls
        }
        return out
    }

    /// Builds 额度's sections.
    /// - Parameters:
    ///   - cards: from `/quotas/cards`.
    ///   - served: from `/quotas` (adds `lastServedAt`), used as a tie-break.
    ///   - usage: 7-day usage, for the per-provider call counts.
    ///   - sort: how cards within a section are ordered.
    static func sections(_ cards: [QuotaCard], served: [QuotaCard] = [], usage: UsageSummary? = nil,
                         sort: QuotaSort = .mostUsed, now: Date = .now) -> [QuotaSection] {
        let servedAt = lastServed(cards, served: served)
        let byCard = calls(cards, usage: usage)
        let byProvider = providerCalls(cards, usage: usage)
        var order: [String] = []
        var groups: [String: [QuotaCard]] = [:]
        var payg: [QuotaCard] = []
        for card in cards {
            guard card.kind == "subscription" else { payg.append(card); continue }
            let key = providerKey(card)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(card)
        }
        let ranked = order.enumerated().sorted { a, b in
            let ca = byProvider[a.element] ?? 0, cb = byProvider[b.element] ?? 0
            if ca != cb { return ca > cb }
            let la = groups[a.element]?.compactMap { servedAt[$0.id] }.max() ?? .distantPast
            let lb = groups[b.element]?.compactMap { servedAt[$0.id] }.max() ?? .distantPast
            if la != lb { return la > lb }
            return a.offset < b.offset
        }.map(\.element)
        var sections = ranked.map { key -> QuotaSection in
            let list = groups[key] ?? []
            let first = list.first
            let title = key == "claude" ? "Claude" : (first.map { $0.name.isEmpty ? $0.provider : $0.name } ?? key)
            return QuotaSection(id: key, title: title, cards: sort.sorted(list, now: now, calls: byCard),
                                isClaude: key == "claude", isPayAsYouGo: false)
        }
        if !payg.isEmpty {
            sections.append(QuotaSection(id: payAsYouGoID, title: String(localized: "按量付费"),
                                         cards: sort.sorted(payg, now: now, calls: byCard), isClaude: false, isPayAsYouGo: true))
        }
        return sections
    }

    /// When each card last served, from `/quotas` (by card id) or the card.
    static func lastServed(_ cards: [QuotaCard], served: [QuotaCard]) -> [String: Date] {
        var out: [String: Date] = [:]
        let byID = Dictionary(served.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for card in cards {
            if let d = byID[card.id]?.lastServedAt ?? card.lastServedAt { out[card.id] = d }
        }
        return out
    }

    /// 刚刚在用, one per provider: the account that served that provider's
    /// latest call. Without serving times, magpie's `last` flag.
    static func justUsed(_ cards: [QuotaCard], served: [QuotaCard]) -> Set<String> {
        let servedAt = lastServed(cards, served: served)
        let lastFlag = Set((served.isEmpty ? cards : served).filter(\.last).map(\.id))
        var newest: [String: (String, Date)] = [:]
        for card in cards {
            guard let d = servedAt[card.id] else { continue }
            let key = providerKey(card)
            if newest[key].map({ d > $0.1 }) ?? true { newest[key] = (card.id, d) }
        }
        var out = Set(newest.values.map(\.0))
        for card in cards where lastFlag.contains(card.id) && newest[providerKey(card)] == nil {
            out.insert(card.id)
        }
        return out
    }
}
