import Foundation
import Observation

/// The Agent tab's state: which agent, which period, and what magpie's
/// usage routes said. The 路由组 tab reads `agent` and `latest` from here.
@MainActor
@Observable
final class UsageStore {
    /// Where the latest read stands.
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(MagpieAPIError)
    }

    /// UserDefaults key for the chosen agent.
    private static let agentKey = "perch.agent"
    /// Stored for 所有 Agent.
    private static let allAgents = "*"

    /// The agent shown; nil = 所有 Agent. Remembered; default Claude Code.
    var agent: String? {
        didSet { defaults.set(agent ?? Self.allAgents, forKey: Self.agentKey) }
    }
    /// The period shown (not remembered).
    var period: UsagePeriod = .today

    /// `/usage?period=` of the period shown (every agent).
    private(set) var summary: UsageSummary?
    /// Agents of the last 7 days, for the title menu, most calls first.
    private(set) var agents: [UsageBucket] = []
    /// First page of `/usage/requests` for the agent and period.
    private(set) var page: UsageRequestsPage?
    /// Per-account totals for the agent and period (one filtered read
    /// each, as magpie has no `by.account` split).
    private(set) var accounts: [UsageBucket] = []
    /// The latest read's state; drives loading/error screens.
    private(set) var phase: Phase = .idle
    /// 1.5: when the page was read, whether a load runs, how it ended.
    private(set) var freshness = Freshness()
    var lastRead: Date? { freshness.lastRead }
    /// What's shown came from the disk cache; no fresh answer yet.
    private(set) var fromCache = false
    /// 按账号 didn't read this time: when the rows shown were read.
    private(set) var accountsStale: Date?
    /// The agent's newest call ever (`period=all`, one row), for 路由组.
    private(set) var latest: UsageRow?
    /// The agent `latest` belongs to.
    private(set) var latestAgent: String?
    /// The newest call didn't read this time: when the one shown was read.
    private(set) var latestStale: Date?
    private(set) var latestRead: Date?
    private(set) var computerID: String?
    /// Set by an account's 「在 Agent 页看」: the tab opens its calls.
    var pendingAccount: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cache: SnapshotCache
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var inflight: Task<Void, Never>?
    @ObservationIgnored private var inflightFilter: UsageFilter?
    /// `/usage?period=7d`, for the title menu's agents.
    @ObservationIgnored private var week: UsageSummary?

    init(defaults: UserDefaults = .standard, cache: SnapshotCache = .shared) {
        self.defaults = defaults
        self.cache = cache
        let stored = defaults.string(forKey: Self.agentKey)
        agent = stored == Self.allAgents ? nil : (stored ?? ClaudeCode.agentID)
    }

    /// Data has been read at least once.
    var hasData: Bool { lastRead != nil }
    /// The key is held: magpie refuses `/usage`.
    var isHeld: Bool { phase == .failed(.held) }
    /// The computer didn't answer (连不上): OfflineCard, data dimmed.
    var isOffline: Bool { freshness.isUnreachable }
    /// 按账号's and the newest call's footers: hidden while 连不上
    ///.
    var accountsFooter: Date? { isOffline ? nil : accountsStale }
    var latestFooter: Date? { isOffline ? nil : latestStale }
    /// The computer answered but the page didn't come: the banner.
    var isStale: Bool { freshness.isStale && hasData }

    /// 「Claude Code」: magpie's `agentName`, else a known name, else the id.
    func name(of agent: String?) -> String {
        guard let agent else { return String(localized: "所有 Agent") }
        if let n = (agents + (summary?.agents ?? [])).first(where: { $0.id == agent })?.name, n != agent, !n.isEmpty { return n }
        if let n = page?.rows.first(where: { $0.agent == agent })?.agentName { return n }
        return Self.knownNames[agent] ?? agent
    }

    /// Names for agent ids magpie may send without an `agentName`.
    static let knownNames = ["claude": "Claude Code", "codex": "Codex", "opencode": "OpenCode", "gemini": "Gemini CLI"]

    /// The selected agent's name.
    var agentName: String { name(of: agent) }

    /// The filter for the selected agent and period.
    var filter: UsageFilter {
        UsageFilter(period: period, agent: agent)
    }

    /// Calls of no subscription account (an API key served them).
    var otherAccountTotals: UsageTotals? {
        guard let page else { return nil }
        var rest = page.totals
        for a in accounts {
            rest.calls -= a.totals.calls
            rest.input -= a.totals.input
            rest.output -= a.totals.output
            rest.cacheRead -= a.totals.cacheRead
            rest.cacheWrite -= a.totals.cacheWrite
            rest.cost -= a.totals.cost
        }
        return rest.calls > 0 ? rest : nil
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
        restore(filter)
        restoreLatest()
    }

    /// First load, pull, foreground and agent/period changes. One load per
    /// filter at a time; a new filter's load replaces the old one's.
    func load(_ client: MagpieClient?, computer: String? = nil) async {
        #if DEBUG
        if DemoData.isOn {
            generation += 1
            loadDemo()
            return
        }
        #endif
        if let computer { use(computer) }
        guard let client else { return }
        let filter = self.filter
        if let inflight, inflightFilter == filter {
            await inflight.value
            return
        }
        inflight?.cancel()
        generation += 1
        let mine = generation
        // Another agent or period: its saved page, if any, at once; else the
        // old page stays (marked refreshing) until the new one lands.
        if page != nil, inflightFilter != nil || lastFilter != filter { restore(filter) }
        let task = Task { await self.run(client, filter: filter, mine: mine) }
        inflight = task
        inflightFilter = filter
        await task.value
        if mine == generation {
            inflight = nil
            inflightFilter = nil
        }
    }

    /// The filter of the page shown.
    @ObservationIgnored private var lastFilter: UsageFilter?

    private enum Part: Sendable {
        case summary(Result<Fetched<UsageSummary>, MagpieAPIError>)
        case week(Result<Fetched<UsageSummary>, MagpieAPIError>)
        case page(Result<Fetched<UsageRequestsPage>, MagpieAPIError>)
        case account(String, Result<Fetched<UsageRequestsPage>, MagpieAPIError>)
    }

    /// Usage, requests and 7 days together, each applied as it lands; then
    /// the per-account split. 12 s at most.
    private func run(_ client: MagpieClient, filter: UsageFilter, mine: Int) async {
        freshness.begin()
        if !hasData || phase != .loaded { phase = .loading }
        let watch = LoadWatch(probe: client) { [weak self] stage in
            guard let self, self.generation == mine else { return false }
            return self.freshness.mark(stage)
        }
        defer { watch.stop() }
        var answered = false
        var mainError: MagpieAPIError?
        var denied: MagpieAPIError?
        var split: [UsageBucket] = []
        var splitFailed = false

        let land: (Part) -> Void = { [self] part in
            guard mine == generation else { return }
            switch part {
            case .summary(.success(let f)):
                answered = true
                summary = f.value
                if filter.period == .sevenDays { week = f.value }
                agents = Self.menuAgents(week: (week ?? f.value).agents, period: f.value.agents)
                save(f.data, "usage-" + filter.period.rawValue, "/v1/magpie/usage?period=" + filter.period.rawValue)
            case .week(.success(let f)):
                answered = true
                week = f.value
                agents = Self.menuAgents(week: f.value.agents, period: summary?.agents ?? [])
                save(f.data, "usage-7d", "/v1/magpie/usage?period=7d")
            case .page(.success(let f)):
                answered = true
                applyPage(f.value, filter: filter)
                save(f.data, Self.pageName(filter), "/v1/magpie/usage/requests")
            case .account(let name, .success(let f)):
                answered = true
                if f.value.totals.calls > 0 { split.append(UsageBucket(id: name, name: name, totals: f.value.totals)) }
            case .summary(.failure(let e)), .page(.failure(let e)):
                if ReadTrouble(e) == .denied { denied = denied ?? e }
                if case .page = part { mainError = e }
            case .account(_, .failure):
                splitFailed = true
            case .week(.failure):
                break
            }
        }

        var jobs: [@Sendable () async -> Part] = [
            { .page(await Fetch.run { try await client.requestsWithData(filter, limit: 100) }) },
            { .summary(await Fetch.run { try await client.usageWithData(filter.period) }) },
        ]
        if filter.period != .sevenDays {
            jobs.append { .week(await Fetch.run { try await client.usageWithData(.sevenDays) }) }
        }
        if await Together.run(until: watch.deadline, jobs, land: land), page == nil || lastFilter != filter || mainError == nil, mine == generation {
            if lastRead.map({ Date.now.timeIntervalSince($0) > 1 }) ?? true { mainError = mainError ?? .timeout }
        }
        guard mine == generation else { return }

        if let denied {
            // A permission state: what this key may not see goes (as before).
            if denied == .held || denied == .unauthorized {
                summary = nil; page = nil; accounts = []; freshness = Freshness(); fromCache = false
            }
            phase = .failed(denied)
            return
        }

        if mainError == nil, let page, lastFilter == filter {
            let names = Array(page.accountNames.prefix(12))
            let cut = await Together.run(until: watch.deadline, names.map { name in
                { () async -> Part in
                    var f = filter
                    f.account = name
                    return .account(name, await Fetch.run { try await client.requestsWithData(f, limit: 1) })
                }
            }, land: land)
            guard mine == generation else { return }
            if cut || splitFailed, !accounts.isEmpty {
                accountsStale = accountsStale ?? lastRead
            } else {
                if split.isEmpty { split = UsageAggregation.accounts(page) }
                accounts = Self.sortedAccounts(split)
                accountsStale = nil
            }
        }

        guard let mainError else {
            phase = .loaded
            freshness.end(nil)
            return
        }
        let failure = await watch.failure(trouble: ReadTrouble(mainError), answered: answered)
        guard mine == generation else { return }
        phase = hasData && page != nil ? .loaded : .failed(mainError)
        freshness.end(failure)
    }

    static func sortedAccounts(_ split: [UsageBucket]) -> [UsageBucket] {
        split.sorted { $0.totals.cost == $1.totals.cost ? $0.totals.tokens > $1.totals.tokens : $0.totals.cost > $1.totals.cost }
    }

    /// `requests-<agent>-<period>`.
    static func pageName(_ filter: UsageFilter) -> String {
        "requests-\(filter.agent ?? "all")-\(filter.period.rawValue)"
    }

    #if DEBUG
    private func loadDemo() {
        if DemoData.state == "empty" {
            // 1.5 screenshots: no agent has called yet (「还没有 Agent 来过」).
            let summary = UsageSummary(period: period.rawValue, since: nil, totals: UsageTotals(), agents: [], models: [], accounts: [], sessionCount: 0)
            let page = UsageRequestsPage(period: period.rawValue, offset: 0, total: 0, rows: [], totals: UsageTotals(),
                                         byModel: [], byModelAt: [], byProvider: [], byAccount: [], accountNames: [])
            apply(summary: summary, page: page, accounts: [], agents: [])
            latest = nil
            return
        }
        apply(summary: DemoData.usageSummary(period), page: DemoData.requestsPage(filter), accounts: DemoData.accountSplit(filter), agents: DemoData.usageSummary(.sevenDays).agents)
        latest = DemoData.requestsPage(UsageFilter(period: .all, agent: agent)).rows.first
        latestAgent = agent
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
            accountsStale = earlier
            latestRead = earlier
            latestStale = earlier
        default: break
        }
    }
    #endif

    /// The saved page (and usage) of `filter`, decoded like live ones.
    private func restore(_ filter: UsageFilter) {
        #if DEBUG
        if DemoData.isOn { return }
        #endif
        guard let id = computerID, let e = cache.load(computer: id, name: Self.pageName(filter)),
              let page = UsageDecoding.requestsPage(from: e.body) else { return }
        if let w = cache.load(computer: id, name: "usage-7d") { week = UsageDecoding.summary(from: w.body) }
        if let s = cache.load(computer: id, name: "usage-" + filter.period.rawValue), let summary = UsageDecoding.summary(from: s.body) {
            self.summary = summary
            agents = Self.menuAgents(week: (week ?? summary).agents, period: summary.agents)
        }
        applyPage(page, filter: filter, at: e.savedAt)
        accounts = Self.sortedAccounts(UsageAggregation.accounts(page))
        fromCache = true
        if phase == .idle || phase == .loading { phase = .loaded }
    }

    private func restoreLatest() {
        guard let id = computerID, let agent, let e = cache.load(computer: id, name: "latest-" + agent),
              let page = UsageDecoding.requestsPage(from: e.body) else { return }
        latest = page.rows.first
        latestAgent = agent
        latestRead = e.savedAt
    }

    private func save(_ data: Data, _ name: String, _ endpoint: String) {
        guard let computerID else { return }
        cache.save(data, computer: computerID, name: name, endpoint: endpoint)
    }

    private func applyPage(_ page: UsageRequestsPage, filter: UsageFilter, at date: Date = .now) {
        if lastFilter != filter { accounts = []; accountsStale = nil }
        self.page = page
        lastFilter = filter
        freshness.succeed(at: date)
        fromCache = false
        phase = .loaded
    }

    /// One page of calls for the full list (its own filters).
    func page(_ filter: UsageFilter, offset: Int, client: MagpieClient?) async -> Result<UsageRequestsPage, MagpieAPIError> {
        #if DEBUG
        if DemoData.isOn { return .success(DemoData.requestsPage(filter, offset: offset, limit: 50)) }
        #endif
        guard let client else { return .failure(.unauthorized) }
        do { return .success(try await client.requests(filter, offset: offset, limit: 50)) } catch { return .failure(error) }
    }

    /// The agent's newest call, for 路由组's 「%agent 刚刚在用」.
    func loadLatest(_ client: MagpieClient?) async {
        #if DEBUG
        if DemoData.isOn {
            latest = DemoData.requestsPage(UsageFilter(period: .all, agent: agent)).rows.first
            latestAgent = agent
            return
        }
        #endif
        guard let client, let agent else { latest = nil; latestAgent = nil; return }
        if latestAgent != agent { restoreLatest() }
        let result: Result<Fetched<UsageRequestsPage>, MagpieAPIError>? = await withTaskGroup(of: Result<Fetched<UsageRequestsPage>, MagpieAPIError>?.self) { group in
            group.addTask { await Fetch.run { try await client.requestsWithData(UsageFilter(period: .all, agent: agent), limit: 1) } }
            group.addTask { try? await Task.sleep(for: LoadBudget.total); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard agent == self.agent else { return }
        switch result {
        case .success(let f)?:
            latest = f.value.rows.first
            latestAgent = agent
            latestRead = .now
            latestStale = nil
            save(f.data, "latest-" + agent, "/v1/magpie/usage/requests?period=all&limit=1")
        default:
            // Keep the one shown; its card says it didn't read.
            if latestAgent == agent, latest != nil { latestStale = latestRead ?? .now }
        }
    }

    /// What the 路由组 block shows for the selected agent, if anything.
    func target(groups: [RoutingGroup]) -> AgentTarget? {
        guard let agent, latestAgent == agent, let latest else { return nil }
        return AgentTarget.latest([latest], agent: agent, groups: groups)
    }

    /// Memory only (disconnect, 换一台电脑); the disk cache stays.
    func reset() {
        inflight?.cancel()
        inflight = nil
        inflightFilter = nil
        generation += 1
        computerID = nil
        summary = nil
        page = nil
        accounts = []
        agents = []
        week = nil
        lastFilter = nil
        phase = .idle
        freshness = Freshness()
        fromCache = false
        accountsStale = nil
        latest = nil
        latestAgent = nil
        latestStale = nil
        latestRead = nil
        pendingAccount = nil
    }

    /// 1.4: the title menu's 「N 次调用」 follow the period shown.
    /// The agents are those of the last 7 days (and of the period), each
    /// with its calls in the period, most first.
    nonisolated static func menuAgents(week: [UsageBucket], period: [UsageBucket]) -> [UsageBucket] {
        var out: [UsageBucket] = []
        for a in week where a.totals.calls > 0 {
            var b = period.first { $0.id == a.id } ?? UsageBucket(id: a.id, name: a.name, provider: a.provider, last: a.last, totals: UsageTotals())
            if b.name.isEmpty || b.name == b.id { b.name = a.name }
            out.append(b)
        }
        for b in period where b.totals.calls > 0 && !out.contains(where: { $0.id == b.id }) { out.append(b) }
        return out.sorted { $0.totals.calls != $1.totals.calls ? $0.totals.calls > $1.totals.calls : $0.name < $1.name }
    }

    /// The title menu: agents with calls, most calls first (ties by name).
    nonisolated static func menuOrder(_ agents: [UsageBucket]) -> [UsageBucket] {
        agents.filter { $0.totals.calls > 0 }.sorted {
            $0.totals.calls != $1.totals.calls ? $0.totals.calls > $1.totals.calls : $0.name < $1.name
        }
    }

    /// Adopts a full successful read.
    private func apply(summary: UsageSummary, page: UsageRequestsPage, accounts: [UsageBucket], agents: [UsageBucket]) {
        self.summary = summary
        self.page = page
        self.accounts = accounts
        self.agents = Self.menuAgents(week: agents, period: summary.agents)
        lastFilter = filter
        freshness.succeed()
        phase = .loaded
    }
}
