import Foundation
import Observation

/// The 额度 tab's state: quota cards plus the extras that enrich them.
///
/// Data flow on `load`:
/// 1. `GET /v1/magpie/quotas/history` → `history` (run-out pace, charts)
/// 2. `GET /v1/magpie/quotas` → `served` (`lastServedAt` per card)
/// 3. `GET /v1/magpie/usage?period=7d|today` → `usageWeek`/`usageToday`
/// 4. `GET /v1/magpie/quotas/cards` → `cards` (the one that matters; the
///    others are optional and silently skipped when refused).
/// Each successful card read is also recorded in `reads` for the run-out
/// estimate. In DEBUG demo mode everything comes from `DemoData`.
@MainActor
@Observable
final class QuotasStore {
    /// Where the latest card read stands.
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(QuotaError)
    }

    /// The cards, in magpie's order (views sort them).
    private(set) var cards: [QuotaCard] = []
    /// The latest read's state; drives loading/error screens.
    private(set) var phase: Phase = .idle
    /// When the cards shown were last read successfully.
    private(set) var lastRead: Date?
    /// Set when the latest read failed but older cards are still shown.
    private(set) var staleSince: Date?
    /// Card ids being refreshed one by one right now.
    private(set) var refreshing: Set<String> = []
    /// Bumped when a manual refresh ends: the sky's brightness breath.
    var breath = 0
    /// When each card was last refreshed (for the 30 s cooldown).
    private var lastCardRefresh: [String: Date] = [:]
    /// `/v1/magpie/quotas` (for `lastServedAt`); empty when unread.
    private(set) var served: [QuotaCard] = []
    /// `/usage?period=7d` and `today`, for the order and account details.
    private(set) var usageWeek: UsageSummary?
    /// Today's usage summary, for the account detail.
    private(set) var usageToday: UsageSummary?
    /// `/quotas/history`, read when an account opens.
    private(set) var history: QuotaHistory?
    /// The account (card id) being switched on or off.
    private(set) var switching: String?
    /// What Perch last set an account to. magpie's cards may not say an
    /// account is off (undocumented), so this holds until they agree.
    private var offOverrides: [String: Bool] = [:]
    /// 1.4: each window's % used at each read this session (a day at
    /// most), for the run-out pace when magpie keeps no history.
    private(set) var reads: [String: [UsageSample]] = [:]

    /// Subscription accounts derived from `cards` and `served`.
    var accounts: [SubscriptionAccount] { SubscriptionAccounts.accounts(cards: cards, served: served) }

    /// The account with card id `id`.
    func account(_ id: String) -> SubscriptionAccount? { accounts.first { $0.id == id } }

    /// Accounts of the same provider as `account`, it included.
    func siblings(of account: SubscriptionAccount) -> [SubscriptionAccount] {
        accounts.filter { QuotaGrouping.providerKey($0.card) == QuotaGrouping.providerKey(account.card) }
    }

    /// 额度's sections, ordered and sorted (see `QuotaGrouping.sections`).
    func sections(sort: QuotaSort, now: Date = .now) -> [QuotaSection] {
        QuotaGrouping.sections(cards, served: served, usage: usageWeek, sort: sort, now: now)
    }

    /// Card ids marked 刚刚在用 (one per provider).
    var justUsed: Set<String> { QuotaGrouping.justUsed(cards, served: served) }

    /// magpie allows one per-card refresh every 30 s.
    static let cooldown: TimeInterval = 30

    /// 「照现在的速度，大约 %@ 用完」 of a card, if it runs out before a reset.
    func runOut(_ card: QuotaCard, now: Date = .now) -> RunOut? {
        RunOutEstimate.first(card: card, history: history, reads: reads, now: now)
    }

    /// The run-out of one window (account detail).
    func runOut(_ card: QuotaCard, window: QuotaWindow, now: Date = .now) -> RunOut? {
        RunOutEstimate.estimate(window: window, history: RunOutEstimate.samples(history, card: card, window: window),
                                reads: reads[RunOutEstimate.readKey(card, window)] ?? [], now: now)
    }

    /// Cards have been read at least once.
    var hasData: Bool { lastRead != nil }

    /// The last read failed for want of a connection (shown as 连不上).
    var isOffline: Bool {
        if staleSince != nil { return true }
        if case .failed(let error) = phase { return error != .forbidden && error != .unauthorized }
        return false
    }

    /// Whether this 密钥 may read 额度: nil until magpie has answered.
    var canRead: Bool? {
        switch phase {
        case .loaded: true
        case .failed(.forbidden): false
        default: nil
        }
    }

    /// Pull to refresh, first load and foreground re-reads.
    func load(_ client: QuotaClient?, extras: MagpieClient? = nil) async {
        #if DEBUG
        if let demo = DemoData.quotaCards() {
            switch DemoData.state {
            case "loading":
                phase = .loading
                return
            case "empty":
                apply([])
                return
            default: break
            }
            apply(demo)
            if DemoData.state == "offline" {
                staleSince = lastRead
                phase = .loaded
            }
            served = DemoData.servedCards()
            usageWeek = DemoData.usageSummary(.sevenDays)
            usageToday = DemoData.usageSummary(.today)
            history = DemoData.history()
            return
        }
        #endif
        if let extras {
            // 1.4: history feeds the cards' run-out line too.
            if let h = try? await extras.quotaHistory() { history = h } else if history == nil { history = .empty }
            // Each is optional: a held key gets 403 on /usage, an older
            // magpie may not have /quotas' serving times.
            if let s = try? await extras.quotas() { served = s }
            if let u = try? await extras.usage(.sevenDays) { usageWeek = u }
            if let u = try? await extras.usage(.today) { usageToday = u }
        }
        guard let client else { return }
        if !hasData { phase = .loading }
        do {
            let fresh = try await client.cards()
            apply(fresh)
        } catch {
            if hasData {
                staleSince = lastRead
                phase = .loaded
            } else {
                phase = .failed(error)
            }
        }
    }

    /// Seconds left before this card may be refreshed again, else nil.
    func cooldownLeft(_ card: QuotaCard, now: Date = .now) -> Int? {
        guard let last = lastCardRefresh[card.id] else { return nil }
        let left = Self.cooldown - now.timeIntervalSince(last)
        return left > 0 ? Int(left.rounded(.up)) : nil
    }

    /// Per-card refresh. Returns false when the card is still cooling down.
    @discardableResult
    func refresh(_ card: QuotaCard, client: QuotaClient?) async -> Bool {
        if cooldownLeft(card) != nil { return false }
        #if DEBUG
        if DemoData.isOn {
            lastCardRefresh[card.id] = .now
            return true
        }
        #endif
        guard let client, !refreshing.contains(card.id) else { return true }
        lastCardRefresh[card.id] = .now
        refreshing.insert(card.id)
        defer { refreshing.remove(card.id) }
        do {
            let fresh = try await client.refresh(card)
            if fresh.isEmpty {
                apply(try await client.cards())
            } else {
                apply(fresh)
            }
        } catch {
            staleSince = lastRead
        }
        return true
    }

    /// `/quotas/history`, kept for the session; `.unrecognized` stays.
    func loadHistory(_ client: MagpieClient?) async {
        #if DEBUG
        if DemoData.isOn { history = DemoData.history(); return }
        #endif
        guard let client else { return }
        if let h = try? await client.quotaHistory() { history = h } else if history == nil { history = .empty }
    }

    /// 停用 / 启用 an account. magpie's answer isn't the cards, so they
    /// are read again after.
    func setAccount(_ account: SubscriptionAccount, on: Bool, client: MagpieClient?, cards cardClient: QuotaClient?) async -> Result<Void, MagpieAPIError> {
        guard let user = account.user, switching == nil else { return .failure(.other("busy")) }
        switching = account.id
        defer { switching = nil }
        #if DEBUG
        if DemoData.isOn {
            try? await Task.sleep(for: .milliseconds(400))
            if let i = cards.firstIndex(where: { $0.id == account.id }) { cards[i].off = !on }
            return .success(())
        }
        #endif
        guard let client else { return .failure(.unauthorized) }
        do {
            try await client.setAccount(agent: account.loginAgent, user: user, on: on)
        } catch {
            return .failure(error)
        }
        offOverrides[account.id] = !on
        if let i = cards.firstIndex(where: { $0.id == account.id }) { cards[i].off = !on }
        if let cardClient, let fresh = try? await cardClient.cards() { apply(fresh) }
        return .success(())
    }

    /// Forgets everything (on disconnect or switching computers).
    func reset() {
        served = []
        usageWeek = nil
        usageToday = nil
        history = nil
        reads = [:]
        switching = nil
        offOverrides = [:]
        cards = []
        phase = .idle
        lastRead = nil
        staleSince = nil
        refreshing = []
        lastCardRefresh = [:]
    }

    /// Adopts freshly read cards, keeping on/off overrides until magpie
    /// agrees, and clears any stale/failed state.
    private func apply(_ fresh: [QuotaCard]) {
        // magpie's order; the view sorts by the user's 排序 choice.
        var fresh = fresh
        for i in fresh.indices {
            guard let off = offOverrides[fresh[i].id] else { continue }
            if fresh[i].off == off { offOverrides[fresh[i].id] = nil } else { fresh[i].off = off }
        }
        cards = fresh
        record(fresh, at: .now)
        lastRead = .now
        staleSince = nil
        phase = .loaded
    }

    /// Appends each window's % used to `reads`, keeping the last 24 h.
    private func record(_ cards: [QuotaCard], at now: Date) {
        let since = now.addingTimeInterval(-24 * 3600)
        for card in cards {
            for w in card.windows {
                guard let used = QuotaFormat.used(w) else { continue }
                let key = RunOutEstimate.readKey(card, w)
                var list = (reads[key] ?? []).filter { $0.time >= since }
                list.append(UsageSample(time: now, used: used))
                reads[key] = list
            }
        }
    }
}
