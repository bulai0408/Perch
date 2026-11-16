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
    /// When data was last read successfully.
    private(set) var lastRead: Date?
    /// Set while offline with older data still shown.
    private(set) var staleSince: Date?
    /// The agent's newest call ever (`period=all`, one row), for 路由组.
    private(set) var latest: UsageRow?
    /// The agent `latest` belongs to.
    private(set) var latestAgent: String?
    /// Set by an account's 「在 Agent 页看」: the tab opens its calls.
    var pendingAccount: String?

    private let defaults: UserDefaults
    /// Bumped per load so a slow, superseded load doesn't overwrite a newer one.
    private var generation = 0

    /// Restores the remembered agent (Claude Code the first time).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.agentKey)
        agent = stored == Self.allAgents ? nil : (stored ?? ClaudeCode.agentID)
    }

    /// Data has been read at least once.
    var hasData: Bool { lastRead != nil }
    /// The key is held: magpie refuses `/usage`.
    var isHeld: Bool { phase == .failed(.held) }
    /// The last read failed for want of a connection.
    var isOffline: Bool {
        if staleSince != nil { return true }
        if case .failed(let e) = phase { return e.isOffline }
        return false
    }

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

    /// Reads the Agent tab for the selected agent and period:
    /// `GET /v1/magpie/usage?period=` (summary), `GET /v1/magpie/usage/requests`
    /// (first 100 rows + splits), the 7-day summary for the agent menu, then one
    /// `limit=1` requests read per account (up to 12) for per-account totals.
    /// Offline with data → stale; held/unauthorized → data dropped and failed.
    func load(_ client: MagpieClient?) async {
        generation += 1
        let mine = generation
        #if DEBUG
        if DemoData.isOn {
            apply(summary: DemoData.usageSummary(period), page: DemoData.requestsPage(filter), accounts: DemoData.accountSplit(filter), agents: DemoData.usageSummary(.sevenDays).agents)
            latest = DemoData.requestsPage(UsageFilter(period: .all, agent: agent)).rows.first
            latestAgent = agent
            return
        }
        #endif
        guard let client else { return }
        if !hasData || phase != .loaded { phase = .loading }
        let filter = self.filter
        do throws(MagpieAPIError) {
            let summary = try await client.usage(filter.period)
            let page = try await client.requests(filter, limit: 100)
            let week = filter.period == .sevenDays ? summary : try? await client.usage(.sevenDays)
            var split: [UsageBucket] = []
            for name in page.accountNames.prefix(12) {
                var f = filter
                f.account = name
                if let p = try? await client.requests(f, limit: 1), p.totals.calls > 0 {
                    split.append(UsageBucket(id: name, name: name, totals: p.totals))
                }
            }
            if split.isEmpty { split = UsageAggregation.accounts(page) }
            guard mine == generation else { return }
            apply(summary: summary, page: page, accounts: split.sorted { $0.totals.cost == $1.totals.cost ? $0.totals.tokens > $1.totals.tokens : $0.totals.cost > $1.totals.cost },
                  agents: (week ?? summary).agents)
        } catch {
            guard mine == generation else { return }
            if error.isOffline, hasData {
                staleSince = lastRead
                phase = .loaded
            } else {
                if error == .held || error == .unauthorized { summary = nil; page = nil; accounts = []; lastRead = nil }
                phase = .failed(error)
            }
        }
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
        if let page = try? await client.requests(UsageFilter(period: .all, agent: agent), limit: 1) {
            latest = page.rows.first
            latestAgent = agent
        }
    }

    /// What the 路由组 block shows for the selected agent, if anything.
    func target(groups: [RoutingGroup]) -> AgentTarget? {
        guard let agent, latestAgent == agent, let latest else { return nil }
        return AgentTarget.latest([latest], agent: agent, groups: groups)
    }

    /// Forgets everything (on disconnect or switching computers).
    func reset() {
        summary = nil
        page = nil
        accounts = []
        agents = []
        phase = .idle
        lastRead = nil
        staleSince = nil
        latest = nil
        latestAgent = nil
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
        lastRead = .now
        staleSince = nil
        phase = .loaded
    }
}
