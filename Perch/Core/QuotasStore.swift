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
    /// 1.5: when the cards were read, whether a load runs, how it ended.
    private(set) var freshness = Freshness()
    /// When the cards shown were last read successfully.
    var lastRead: Date? { freshness.lastRead }
    /// What's shown came from the disk cache; no fresh answer yet.
    private(set) var fromCache = false
    /// Cards whose own refresh failed: when their shown data was read.
    private(set) var cardStale: [String: Date] = [:]
    /// The computer whose data this is (the disk cache's folder).
    private(set) var computerID: String?
    private(set) var refreshing: Set<String> = []
    /// Bumped when a manual refresh ends: the sky's brightness breath.
    var breath = 0
    /// When each card was last refreshed (for the 30 s cooldown).
    private var lastCardRefresh: [String: Date] = [:]
    /// `/v1/magpie/quotas?kept=1` (for `lastServedAt`); empty when unread.
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

    @ObservationIgnored private let cache: SnapshotCache
    @ObservationIgnored private var inflight: Task<Void, Never>?
    @ObservationIgnored private var loadGen = 0

    init(cache: SnapshotCache = .shared) {
        self.cache = cache
    }

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

    /// The computer didn't answer (连不上): OfflineCard, data dimmed.
    var isOffline: Bool { freshness.isUnreachable }

    /// A card's own 「这张没读到最新的」 footer: hidden while 连不上
    ///.
    func staleFooter(for id: String) -> Date? { isOffline ? nil : cardStale[id] }

    /// The computer answered but the cards didn't come: the banner.
    var isStale: Bool { freshness.isStale && hasData }

    /// Whether this 密钥 may read 额度: nil until magpie has answered.
    var canRead: Bool? {
        switch phase {
        case .loaded: true
        case .failed(.forbidden): false
        default: nil
        }
    }

    /// The computer the data is for: switching clears memory, then shows
    /// that computer's saved answers. Idempotent.
    func use(_ computer: String?) {
        guard computer != computerID else { return }
        #if DEBUG
        // Demo data isn't per computer; a reset here would blank it.
        if DemoData.isOn { computerID = computer; return }
        #endif
        reset()
        computerID = computer
        restore()
    }

    /// Pull to refresh, first load and foreground re-reads. One load at a
    /// time: a second call waits for the one running.
    func load(_ client: QuotaClient?, extras: MagpieClient? = nil, computer: String? = nil) async {
        #if DEBUG
        if DemoData.isOn {
            loadDemo()
            return
        }
        #endif
        if let computer { use(computer) }
        guard let client else { return }
        if let inflight {
            await inflight.value
            return
        }
        loadGen += 1
        let mine = loadGen
        let task = Task { await self.run(client, extras: extras, mine: mine) }
        inflight = task
        await task.value
        if mine == loadGen { inflight = nil }
    }

    private enum Part: Sendable {
        case cards(Result<Fetched<[QuotaCard]>, QuotaError>)
        case served(Result<Fetched<[QuotaCard]>, MagpieAPIError>)
        case history(Result<Fetched<QuotaHistory>, MagpieAPIError>)
        case usage(UsagePeriod, Result<Fetched<UsageSummary>, MagpieAPIError>)
    }

    /// Cards first, applied at once; then history, `/quotas?kept=1` and
    /// both usage reads together, each applied as it lands. 12 s at most.
    private func run(_ client: QuotaClient, extras: MagpieClient?, mine: Int) async {
        freshness.begin()
        if !hasData { phase = .loading }
        let watch = LoadWatch(probe: extras) { [weak self] stage in
            guard let self, self.loadGen == mine else { return false }
            return self.freshness.mark(stage)
        }
        defer { watch.stop() }
        var answered = false
        var mainError: QuotaError?

        let land: (Part) -> Void = { [self] part in
            guard mine == loadGen else { return }
            switch part {
            case .cards(.success(let f)):
                answered = true
                applyCards(f.value)
                save(f.data, "cards", QuotaClient.cardsPath)
            case .cards(.failure(let e)):
                mainError = e
            case .served(.success(let f)):
                answered = true
                served = f.value
                save(f.data, "served", "/v1/magpie/quotas?kept=1")
            case .history(.success(let f)):
                answered = true
                history = f.value
                save(f.data, "history", "/v1/magpie/quotas/history")
            case .history(.failure):
                if history == nil { history = .empty }
            case .usage(let period, .success(let f)):
                answered = true
                if period == .today { usageToday = f.value } else { usageWeek = f.value }
                save(f.data, "usage-" + period.rawValue, "/v1/magpie/usage?period=" + period.rawValue)
            case .served(.failure), .usage(_, .failure):
                // Optional: a held key gets 403 on /usage; old data stays.
                break
            }
        }

        let cut = await Together.run(until: watch.deadline, [{ .cards(await Fetch.run { try await client.cardsWithData() }) }], land: land)
        if cut { mainError = .timeout }
        if let extras, mine == loadGen, mainError.map({ ReadTrouble($0) != .connection && ReadTrouble($0) != .denied }) ?? true {
            _ = await Together.run(until: watch.deadline, [
                { .history(await Fetch.run { try await extras.quotaHistoryWithData() }) },
                { .served(await Fetch.run { try await extras.quotasWithData(kept: true) }) },
                { .usage(.sevenDays, await Fetch.run { try await extras.usageWithData(.sevenDays) }) },
                { .usage(.today, await Fetch.run { try await extras.usageWithData(.today) }) },
            ], land: land)
        }
        guard mine == loadGen else { return }
        guard let mainError else {
            freshness.end(nil)
            return
        }
        let trouble = ReadTrouble(mainError)
        if trouble == .denied {
            // A permission state, not a network one: what this key may not see goes.
            cards = []
            cardStale = [:]
            freshness = Freshness()
            fromCache = false
            phase = .failed(mainError)
            return
        }
        let failure = await watch.failure(trouble: trouble, answered: answered)
        guard mine == loadGen else { return }
        phase = hasData ? .loaded : .failed(mainError)
        freshness.end(failure)
    }

    #if DEBUG
    /// `-perch-demo`: made-up cards; `PERCH_DEMO_STATE` picks the state
    /// (calm, empty, loading, offline, stale, refreshing, slow, partial).
    private func loadDemo() {
        guard let demo = DemoData.quotaCards() else { return }
        switch DemoData.state {
        case "loading":
            phase = .loading
            return
        case "empty":
            applyCards([])
            return
        default: break
        }
        applyCards(demo)
        served = DemoData.servedCards()
        usageWeek = DemoData.usageSummary(.sevenDays)
        usageToday = DemoData.usageSummary(.today)
        history = DemoData.history()
        let earlier = Date.now.addingTimeInterval(-26 * 60)
        switch DemoData.state {
        case "offline":
            freshness.lastRead = earlier
            freshness.end(.unreachable)
        case "stale":
            freshness.lastRead = earlier
            freshness.end(.stale)
        case "refreshing", "slow":
            freshness.lastRead = Date.now.addingTimeInterval(-3 * 60)
            freshness.begin()
            _ = freshness.mark(DemoData.state == "slow" ? .slow : .show)
        case "partial":
            if let card = cards.first(where: { $0.kind == "subscription" }) { cardStale[card.id] = earlier }
        default: break
        }
    }
    #endif

    /// The saved answers of `computerID`, decoded like live ones.
    private func restore() {
        #if DEBUG
        if DemoData.isOn { return }
        #endif
        guard let id = computerID else { return }
        if let e = cache.load(computer: id, name: "cards"), let cards = try? QuotaDecoding.cards(from: e.body) {
            applyCards(cards, at: e.savedAt)
            fromCache = true
        }
        if let e = cache.load(computer: id, name: "served"), let s = try? QuotaDecoding.cards(from: e.body) { served = s }
        if let e = cache.load(computer: id, name: "history") { history = QuotaHistoryDecoding.history(from: e.body) }
        if let e = cache.load(computer: id, name: "usage-7d") { usageWeek = UsageDecoding.summary(from: e.body) }
        if let e = cache.load(computer: id, name: "usage-today") { usageToday = UsageDecoding.summary(from: e.body) }
    }

    private func save(_ data: Data, _ name: String, _ endpoint: String) {
        guard let computerID else { return }
        cache.save(data, computer: computerID, name: name, endpoint: endpoint)
    }

    /// Seconds left before this card may be refreshed again, else nil.
    func cooldownLeft(_ card: QuotaCard, now: Date = .now) -> Int? {
        guard let last = lastCardRefresh[card.id] else { return nil }
        let left = Self.cooldown - now.timeIntervalSince(last)
        return left > 0 ? Int(left.rounded(.up)) : nil
    }

    /// Per-card refresh. Returns false when the card is still cooling down.
    @discardableResult
    /// `force`: the footer's retry after a failed read (no 30 s wait).
    func refresh(_ card: QuotaCard, client: QuotaClient?, force: Bool = false) async -> Bool {
        if !force, cooldownLeft(card) != nil { return false }
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
                let f = try await client.cardsWithData()
                applyCards(f.value)
                save(f.data, "cards", QuotaClient.cardsPath)
            } else {
                applyCards(fresh)
            }
            cardStale[card.id] = nil
        } catch {
            // Only this card: its footer says so; the rest stays as it is.
            cardStale[card.id] = lastRead ?? card.readAt ?? .now
        }
        return true
    }

    /// `/quotas/history`, kept for the session; `.unrecognized` stays.
    func loadHistory(_ client: MagpieClient?) async {
        #if DEBUG
        if DemoData.isOn { history = DemoData.history(); return }
        #endif
        guard let client else { return }
        if let h = try? await client.quotaHistoryWithData() {
            history = h.value
            save(h.data, "history", "/v1/magpie/quotas/history")
        } else if history == nil {
            history = .empty
        }
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
        if let cardClient, let f = try? await cardClient.cardsWithData() {
            applyCards(f.value)
            save(f.data, "cards", QuotaClient.cardsPath)
        }
        return .success(())
    }

    /// Memory only (disconnect, 换一台电脑); the disk cache stays.
    func reset() {
        inflight?.cancel()
        inflight = nil
        loadGen += 1
        computerID = nil
        freshness = Freshness()
        fromCache = false
        cardStale = [:]
        served = []
        usageWeek = nil
        usageToday = nil
        history = nil
        reads = [:]
        switching = nil
        offOverrides = [:]
        cards = []
        phase = .idle
        refreshing = []
        lastCardRefresh = [:]
    }

    /// Adopts freshly read cards, keeping on/off overrides until magpie
    /// agrees, and clears any stale/failed state.
    private func applyCards(_ fresh: [QuotaCard], at date: Date = .now) {
        // magpie's order; the view sorts by the user's 排序 choice.
        var fresh = fresh
        for i in fresh.indices {
            guard let off = offOverrides[fresh[i].id] else { continue }
            if fresh[i].off == off { offOverrides[fresh[i].id] = nil } else { fresh[i].off = off }
        }
        cards = fresh
        record(fresh, at: date)
        freshness.succeed(at: date)
        fromCache = false
        cardStale = [:]
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
