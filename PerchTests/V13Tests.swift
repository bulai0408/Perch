import Foundation
import Testing
@testable import Perch

/// 1.3: 额度 grouping and order, 刚刚在用 per provider, the Agent menu,
/// the 路由组 「刚刚在用」 block and the Agent tab's numbers.
struct QuotaGroupingTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A quota card fixture.
    static func card(_ provider: String, _ user: String?, kind: String = "subscription", used: Double? = nil,
                     reset: TimeInterval? = nil, last: Bool = false, served: TimeInterval? = nil, off: Bool = false) -> QuotaCard {
        let windows = used.map { [QuotaWindow(name: "5h", used: $0, remaining: 100 - $0, resetsAt: reset.map { now.addingTimeInterval($0) },
                                              unlimited: false, text: false)] } ?? []
        return QuotaCard(provider: provider, name: provider.capitalized, kind: kind, plan: nil, user: user, alias: nil,
                         seat: nil, from: nil, windows: windows, balance: kind == "balance" ? "¥ 1" : nil, error: nil,
                         asOf: nil, readAt: nil, last: last, lastServedAt: served.map { now.addingTimeInterval(-$0) }, off: off)
    }

    /// A usage bucket fixture.
    static func bucket(_ id: String, calls: Int, cost: Double = 0) -> UsageBucket {
        UsageBucket(id: id, name: id, totals: UsageTotals(calls: calls, cost: cost))
    }

    /// A usage summary fixture.
    static func usage(accounts: [UsageBucket], models: [UsageBucket] = []) -> UsageSummary {
        UsageSummary(period: "7d", since: nil, totals: UsageTotals(), agents: [], models: models, accounts: accounts, sessionCount: 0)
    }

    static let cards = [
        card("deepseek", nil, kind: "balance"),
        card("codex", "c@example.com", used: 10, reset: 600),
        card("claude", "a@example.com", used: 80, reset: 3600),
        card("claude", "b@example.com", used: 20, reset: 60),
        card("kimi", "k@example.com", used: 50, reset: 120),
    ]

    @Test func mostUsedProviderFirstPayAsYouGoLast() {
        let usage = Self.usage(accounts: [Self.bucket("a@example.com", calls: 30), Self.bucket("b@example.com", calls: 90), Self.bucket("c@example.com", calls: 50)])
        let sections = QuotaGrouping.sections(Self.cards, usage: usage, sort: .mostUsed, now: Self.now)
        #expect(sections.map(\.id) == ["claude", "codex", "kimi", QuotaGrouping.payAsYouGoID])
        #expect(sections.map(\.title) == ["Claude", "Codex", "Kimi", "按量付费"])
        #expect(sections[0].isClaude && sections[3].isPayAsYouGo)
        // Inside Claude, the account with more calls first.
        #expect(sections[0].cards.map(\.user) == ["b@example.com", "a@example.com"])
    }

    @Test func providerCallsFallBackToModelsServed() {
        let usage = Self.usage(accounts: [], models: [UsageBucket(id: "kimi/k3", name: "k3", provider: "kimi", totals: UsageTotals(calls: 7))])
        let sections = QuotaGrouping.sections(Self.cards, usage: usage, now: Self.now)
        #expect(sections.first?.id == "kimi")
    }

    @Test func noUsageKeepsMagpieOrderButNewestServedFirst() {
        var cards = Self.cards
        #expect(QuotaGrouping.sections(cards, now: Self.now).map(\.id) == ["codex", "claude", "kimi", QuotaGrouping.payAsYouGoID])
        cards[4].lastServedAt = Self.now
        #expect(QuotaGrouping.sections(cards, now: Self.now).first?.id == "kimi")
    }

    @Test func otherSortsApplyInsideEachGroup() {
        let least = QuotaGrouping.sections(Self.cards, sort: .leastLeft, now: Self.now)
        #expect(least.first { $0.id == "claude" }?.cards.map(\.user) == ["a@example.com", "b@example.com"])
        let soonest = QuotaGrouping.sections(Self.cards, sort: .soonestReset, now: Self.now)
        #expect(soonest.first { $0.id == "claude" }?.cards.map(\.user) == ["b@example.com", "a@example.com"])
        #expect(QuotaSort.allCases.first == .mostUsed)
    }

    @Test func justUsedIsOnePerProvider() {
        let cards = [
            Self.card("claude", "a@example.com", served: 60),
            Self.card("claude", "b@example.com", served: 600),
            Self.card("codex", "c@example.com", served: 5000),
            Self.card("codex", "d@example.com"),
            Self.card("kimi", "k@example.com"),
        ]
        let ids = QuotaGrouping.justUsed(cards, served: [])
        #expect(ids == [cards[0].id, cards[2].id])
    }

    @Test func justUsedReadsQuotasServingTimesAndLastFlag() {
        let cards = [Self.card("claude", "a@example.com"), Self.card("claude", "b@example.com"), Self.card("kimi", "k@example.com")]
        var served = cards
        served[1].lastServedAt = Self.now
        served[2].last = true
        #expect(QuotaGrouping.justUsed(cards, served: served) == [cards[1].id, cards[2].id])
    }

    @Test func matchesUsageAccountsToCards() {
        let card = Self.card("claude", "A@example.com")
        #expect(QuotaGrouping.bucket(for: card, in: [Self.bucket("a@example.com", calls: 3)])?.totals.calls == 3)
        #expect(QuotaGrouping.card(named: "a@example.com", in: [card])?.id == card.id)
        #expect(QuotaGrouping.card(named: "zz", in: [card]) == nil)
    }

    @Test func windowLabelsFollowCopy() {
        func w(_ n: String) -> QuotaWindow { QuotaWindow(name: n, unlimited: false, text: false) }
        #expect(WindowCell.label(w("5h")) == "5 小时")
        #expect(WindowCell.label(w("7d")) == "每周")
        #expect(WindowCell.label(w("7d Opus")) == "Opus 每周")
        #expect(WindowCell.label(w("30d")) == "30 天")
        #expect(QuotaCard.ordered([w("7d Opus"), w("7d"), w("5h")]).map(\.name) == ["5h", "7d", "7d Opus"])
    }
}

/// The Agent tab's agent menu and remembered choice.
struct AgentMenuTests {
    @Test func agentsSortedByCallsWithoutIdleOnes() {
        let list = UsageStore.menuOrder([
            QuotaGroupingTests.bucket("curl", calls: 5),
            QuotaGroupingTests.bucket("claude", calls: 600),
            QuotaGroupingTests.bucket("idle", calls: 0),
            QuotaGroupingTests.bucket("codex", calls: 40),
            QuotaGroupingTests.bucket("aider", calls: 40),
        ])
        #expect(list.map(\.id) == ["claude", "aider", "codex", "curl"])
    }

    @MainActor @Test func defaultsToClaudeCodeAndRemembers() throws {
        let defaults = try #require(UserDefaults(suiteName: "perch.test.\(UUID().uuidString)"))
        let store = UsageStore(defaults: defaults)
        #expect(store.agent == "claude")
        #expect(store.agentName == "Claude Code")
        store.agent = "codex"
        #expect(UsageStore(defaults: defaults).agent == "codex")
        store.agent = nil
        #expect(UsageStore(defaults: defaults).agent == nil)
        #expect(UsageStore(defaults: defaults).agentName == "所有 Agent")
    }
}

/// What the agent asked for most recently.
struct LastGroupTests {
    /// A usage row fixture asking for `req`.
    static func row(_ req: String, agent: String = "claude", at: TimeInterval) -> UsageRow {
        UsageRow(id: "\(req)\(at)", time: Date(timeIntervalSince1970: at), agent: agent, agentName: nil, session: nil,
                 requested: req, model: "m", served: "m", provider: nil, providerName: nil, account: nil, status: 200,
                 input: 0, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0, cost: nil, priced: nil, ms: nil, error: nil)
    }

    @Test func newestRowOfTheAgentDecides() {
        let rows = [Self.row("group/old", at: 1), Self.row("group/coder", at: 3), Self.row("group/x", agent: "codex", at: 9)]
        #expect(AgentTarget.latest(rows, agent: "claude", groups: []) == .group(id: "coder", at: Date(timeIntervalSince1970: 3)))
        #expect(AgentTarget.latest(rows, agent: "codex", groups: []) == .group(id: "x", at: Date(timeIntervalSince1970: 9)))
    }

    @Test func magpiePrefixAndDirectModel() {
        #expect(AgentTarget.latest([Self.row("magpie/group/fast", at: 1)], groups: []) == .group(id: "fast", at: Date(timeIntervalSince1970: 1)))
        #expect(AgentTarget.latest([Self.row("claude-opus-5-5", at: 1)], groups: []) == .direct(model: "claude-opus-5-5", at: Date(timeIntervalSince1970: 1)))
        #expect(AgentTarget.latest([Self.row("group/x", agent: "codex", at: 1)], agent: "claude", groups: []) == nil)
    }
}

/// Token, money, duration and mask formatting.
struct UsageFormatTests {
    @Test func tokens() {
        #expect(UsageFormat.tokens(870) == "870")
        #expect(UsageFormat.tokens(48_200) == "48.2k")
        #expect(UsageFormat.tokens(3_100_000) == "3.1M")
        #expect(UsageFormat.tokens(2_000_000) == "2M")
        #expect(UsageFormat.tokens(250_000) == "250k")
    }

    @Test func money() {
        #expect(UsageFormat.dollars(12.4) == "$12.40")
        #expect(UsageFormat.dollars(0.004) == "$0.004")
        #expect(UsageFormat.cost(UsageTotals(calls: 2, cost: 1, unpriced: 2)) == "—")
        #expect(UsageFormat.cost(UsageTotals(calls: 2, cost: 1.5)) == "约 $1.50")
    }

    @Test func durationAndMask() {
        #expect(UsageFormat.duration(ms: 800) == "800 毫秒")
        #expect(UsageFormat.duration(ms: 6100) == "6.1 秒")
        #expect(UsageFormat.masked("work@example.com") == "wo***@example.com")
        #expect(UsageFormat.masked("ab@example.com") == "ab@example.com")
    }
}
