import Foundation
import Testing
@testable import Perch

/// UTF-8 bytes of a JSON literal.
private func json(_ text: String) -> Data { Data(text.utf8) }

/// Subscription accounts and their windows.
struct SubscriptionQuotaTests {
    static let cards = json("""
    {"data":[
      {"provider":"claude","name":"Claude","kind":"subscription","plan":"Max","user":"a@example.com",
       "windows":[{"name":"7d Opus","used":30,"resetsAt":"2026-11-20T00:00:00Z"},
                  {"name":"7d","used":41,"resetsAt":"2026-11-20T00:00:00Z"},
                  {"name":"5h","used":62,"remaining":38,"resetsAt":"2026-11-15T20:00:00.123456789Z"}]},
      {"provider":"claude","name":"Claude","kind":"subscription","plan":"Pro","user":"b@example.com","on":false,"windows":[]},
      {"provider":"codex","name":"Codex","kind":"subscription","user":"c@example.com","windows":[{"name":"5h","used":1}]},
      {"provider":"office/~keys","name":"Remote magpie","kind":"plan","user":"sk-m…73a3","windows":[]}
    ],"object":"list"}
    """)

    @Test func picksClaudeAccountsAndSortsWindows() throws {
        let cards = try QuotaDecoding.cards(from: Self.cards)
        let accounts = SubscriptionAccounts.accounts(cards: cards)
        #expect(accounts.map(\.title) == ["a@example.com", "b@example.com", "c@example.com"])
        #expect(accounts.map(\.isClaude) == [true, true, false])
        #expect(accounts[2].loginAgent == "codex")
        let a = try #require(accounts.first)
        #expect(a.plan == "Max")
        #expect(a.windows.map(\.kind) == [.fiveHour, .weekly, .modelWeekly("Opus")])
        #expect(a.fiveHour?.percentLeft == 38)
        #expect(a.weekly?.percentLeft == 59)
        #expect(a.modelWeekly.first?.percentLeft == 70)
        #expect(a.fiveHour?.resetsAt != nil)
        #expect(accounts[1].off)
        #expect(!a.off)
        #expect(SubscriptionAccounts.usableAfterDisabling(a, in: accounts) == 0)
    }

    @Test(arguments: [
        ("5h", WindowKind.fiveHour), ("5 hours", .fiveHour), ("Session", .fiveHour),
        ("7d", .weekly), ("Week", .weekly), ("weekly", .weekly),
        ("7d Opus", .modelWeekly("Opus")), ("Opus week", .modelWeekly("Opus")), ("Sonnet 7d", .modelWeekly("Sonnet")),
        ("credits", .other),
    ])
    func classifiesWindows(name: String, kind: WindowKind) {
        #expect(WindowKind.classify(QuotaWindow(name: name, unlimited: false, text: false)) == kind)
    }

    @Test func providerGroupsMostRecentFirst() throws {
        let cards = try QuotaDecoding.cards(from: Self.cards)
        let served = try QuotaDecoding.cards(from: json("""
        {"data":[{"provider":"codex","name":"Codex","kind":"subscription","user":"c@example.com","last":true,
          "lastServedAt":"2026-11-15T16:00:00Z","windows":[]},
          {"provider":"claude","name":"Claude","kind":"subscription","user":"a@example.com",
          "lastServedAt":"2026-11-15T12:00:00Z","windows":[]}]}
        """))
        let groups = SubscriptionAccounts.groups(SubscriptionAccounts.accounts(cards: cards, served: served))
        #expect(groups.map(\.provider) == ["codex", "claude"])
        #expect(groups[1].name == "Claude")
        #expect(groups[1].accounts.count == 2)
        // No serving times: most tokens in /usage accounts, then magpie's order.
        let plain = SubscriptionAccounts.accounts(cards: cards)
        #expect(SubscriptionAccounts.groups(plain).map(\.provider) == ["claude", "codex"])
        let usage = [UsageBucket(id: "c@example.com", name: "c@example.com", totals: UsageTotals(calls: 1, input: 50))]
        #expect(SubscriptionAccounts.groups(plain, usage: usage).map(\.provider) == ["codex", "claude"])
    }

    @Test func lastServedFromQuotas() throws {
        let cards = try QuotaDecoding.cards(from: Self.cards)
        let served = try QuotaDecoding.cards(from: json("""
        {"data":[{"provider":"claude","name":"Claude","kind":"subscription","plan":"Max","user":"a@example.com",
          "last":true,"lastServedAt":"2026-11-15T16:54:53.180402933Z","windows":[]}]}
        """))
        let accounts = SubscriptionAccounts.accounts(cards: cards, served: served)
        #expect(accounts[0].lastServed)
        #expect(accounts[0].lastServedAt != nil)
        #expect(!accounts[1].lastServed)
    }

    @Test func historyShapes() {
        #expect(QuotaHistoryDecoding.history(from: json(#"{"data":[],"object":"list"}"#)) == .empty)
        #expect(QuotaHistoryDecoding.history(from: json(#"{"data":[{"foo":1}]}"#)) == .unrecognized)
        #expect(QuotaHistoryDecoding.history(from: json("nope")) == .unrecognized)

        let flat = QuotaHistoryDecoding.history(from: json("""
        {"data":[{"provider":"claude","user":"a@example.com","window":"5h","t":"2026-11-15T12:00:00Z","used":20},
                 {"provider":"claude","user":"a@example.com","window":"5h","t":"2026-11-15T11:00:00Z","used":10}]}
        """))
        guard case .series(let s) = flat else { Issue.record("flat not read"); return }
        #expect(s.count == 1)
        #expect(s[0].points.map(\.used) == [10, 20])
        #expect(s[0].kind == .fiveHour)

        let nested = QuotaHistoryDecoding.history(from: json("""
        {"data":[{"provider":"claude","user":"a@example.com",
          "windows":[{"name":"7d","points":[[1763200000,5],{"time":1763203600000,"remaining":90}]}]}]}
        """))
        guard case .series(let n) = nested else { Issue.record("nested not read"); return }
        #expect(n[0].points.map(\.used) == [5, 10])
    }
}

/// `/usage` and `/usage/requests` decoding.
struct UsageDecodingTests {
    /// Rows as the probe magpie (0.1.4266) gave them for Claude Code.
    static let page = json("""
    {"period":"today","offset":0,"total":3,"bucket":"hour",
     "series":[{"label":"01","time":"2026-11-15T01:00:00Z","calls":0,"input":0},{"label":"00","time":"2026-11-15T00:00:00Z","calls":2,"input":3,"output":3}],"calls":2,"errors":1,"input":3,"output":3,"cost":0.5,"unpriced":1,
     "by":{"model":[{"id":"m-alpha","calls":2,"errors":1,"input":3,"output":3,"name":"m-alpha"}],
           "modelAt":[{"id":"alpha/m-alpha","calls":2,"name":"m-alpha · alpha"}],
           "provider":[{"id":"alpha","calls":2}]},
     "accounts":[],
     "rows":[
      {"t":"2026-11-15T16:54:53.180402933Z","agent":"claude","agentName":"Claude Code","provider":"alpha","model":"m-alpha",
       "req":"group/perch-probe","served":"m-alpha","status":200,"session":"perch-probe-sess-2","in":3,"out":3,"cost":0.5,"priced":true,
       "providerAccount":"a@example.com"},
      {"t":"2026-11-15T16:54:53.135141441Z","agent":"claude","agentName":"Claude Code","provider":"","model":"magpie/group/perch-probe",
       "req":"magpie/group/perch-probe","status":404,"session":"perch-probe-sess-2"},
      {"t":"2026-11-15T16:54:25.521291443Z","agent":"claude","provider":"alpha","model":"m-alpha","req":"alpha/m-alpha","status":502}
     ]}
    """)

    @Test func readsRequestsPage() throws {
        let page = try #require(UsageDecoding.requestsPage(from: Self.page))
        #expect(page.total == 3)
        #expect(page.bucket == "hour")
        #expect(page.series.map(\.label) == ["00", "01"])
        #expect(page.series[0].totals.tokens == 6)
        #expect(!page.hasMore)
        #expect(page.totals.calls == 2)
        #expect(page.totals.cost == 0.5)
        #expect(page.byModel.first?.totals.calls == 2)
        #expect(page.rows.count == 3)
        #expect(page.rows[0].requested == "group/perch-probe")
        #expect(page.rows[0].account == "a@example.com")
        #expect(page.rows[1].failed)
        #expect(!page.rows[0].failed)
        #expect(page.rows[2].agentName == nil)
        #expect(UsageAggregation.accounts(page).map(\.id) == ["a@example.com"])
    }

    @Test func latestTarget() throws {
        let page = try #require(UsageDecoding.requestsPage(from: Self.page))
        #expect(AgentTarget.latest(page.rows, groups: []) ==
                .group(id: "perch-probe", at: page.rows[0].time))
        #expect(AgentTarget.latest(Array(page.rows.suffix(1)), groups: []) ==
                .direct(model: "alpha/m-alpha", at: page.rows[2].time))
        let groups = try RoutingDecoding.groups(from: json(#"{"groups":[{"id":"code","name":"Code","members":["a/b"],"routing":"order"}]}"#))
        #expect(AgentTarget.groupID("Code", groups: groups) == "code")
        #expect(AgentTarget.groupID("magpie/group/code", groups: groups) == "code")
        #expect(AgentTarget.groupID("a/b", groups: groups) == nil)
        #expect(AgentTarget.latest([], groups: groups) == nil)
    }

    @Test func readsSummary() throws {
        let s = try #require(UsageDecoding.summary(from: json("""
        {"period":"7d","since":"2026-11-08T00:00:00Z","calls":13,"cost":1.25,"unpriced":12,"sessionCount":2,
         "agents":[{"id":"curl","calls":11},{"id":"claude","name":"Claude Code","calls":2,"last":"2026-11-15T16:54:53Z"}],
         "models":[{"id":"beta/m-beta","provider":"beta","model":"m-beta","calls":7}],"accounts":[]}
        """)))
        #expect(s.period == "7d")
        #expect(s.agent("claude")?.totals.calls == 2)
        #expect(s.agent("claude")?.last != nil)
        #expect(s.models.first?.name == "m-beta")
    }

    @Test func filterQuery() {
        var f = UsageFilter.claudeCodeToday
        #expect(f.queryItems.map { "\($0.name)=\($0.value ?? "")" } == ["period=today", "agent=claude"])
        f.period = .sevenDays; f.account = "a@example.com"; f.failedOnly = true
        #expect(f.queryItems.map { "\($0.name)=\($0.value ?? "")" } == ["period=7d", "agent=claude", "account=a@example.com", "failed=1"])
    }

    @Test func totalsFromRows() throws {
        let page = try #require(UsageDecoding.requestsPage(from: Self.page))
        var t = UsageTotals()
        page.rows.forEach { t.add($0) }
        #expect(t.calls == 3)
        #expect(t.errors == 2)
        #expect(t.unpriced == 2)
        #expect(t.tokens == 6)
    }
}

/// magpie permission errors and the key limit.
struct MagpieErrorTests {
    @Test func mapsPermissionErrors() {
        func e(_ status: Int, _ body: String, read: Bool = true) -> MagpieAPIError {
            MagpieAPIError.from(status: status, body: json(body), isRead: read)
        }
        #expect(e(403, #"{"error":{"code":"gateway_key_held","message":"held"}}"#) == .held)
        #expect(e(403, #"{"error":{"code":"gateway_key_read_only","message":"ro"}}"#, read: false) == .readOnly)
        #expect(e(403, #"{"error":{"code":"gateway_key_not_admin","message":"no"}}"#, read: false) == .notAdmin)
        #expect(e(400, #"{"error":"subscription accounts are off in magpie (Settings → Privacy, or `magpie accounts discovery on`)"}"#, read: false) == .accountsOff)
        #expect(e(400, #"{"error":"no account x"}"#, read: false) == .rejected(status: 400, reason: "no account x"))
        #expect(e(404, "404 page not found") == .unsupported)
        #expect(e(404, #"{"error":"no such account"}"#, read: false) == .rejected(status: 404, reason: "no such account"))
        #expect(e(401, "") == .unauthorized)
        #expect(e(500, "") == .other("500"))
    }

    @Test func readsLimit() throws {
        let held = try #require(KeyLimitDecoding.limit(from: json(#"{"heldTo":["models"],"key":"perch-held","limited":false,"models":["alpha/*"],"quotas":false}"#)))
        #expect(held.isHeld)
        #expect(held.models == ["alpha/*"])
        #expect(held.quotas == false)
        let budget = try #require(KeyLimitDecoding.limit(from: json("""
        {"heldTo":["budget"],"key":"b","limited":true,"limits":[{"period":"day","reset":"2026-11-16T00:00:00Z","calls":1,"tokens":6,"cost":0,"tokenLimit":100000,"costLimit":5,"spent":false}]}
        """)))
        #expect(budget.budgets.first?.tokenLimit == 100000)
        #expect(budget.budgets.first?.costLimit == 5)
        let plain = try #require(KeyLimitDecoding.limit(from: json(#"{"key":"perch-plain","limited":false}"#)))
        #expect(!plain.isHeld)
    }
}
