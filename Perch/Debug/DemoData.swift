#if DEBUG
import Foundation

/// Debug builds only: `-perch-demo` fills every tab with made-up data,
/// for screenshots without real accounts. Release builds don't compile
/// this file's contents, so the hook can't ship. Nothing here talks to
/// magpie: switching an account off only changes the demo card.
enum DemoData {
    static let argument = "-perch-demo"

    /// `-perch-demo`, or `PERCH_DEMO=1` for launchers that only pass environment.
    static var isOn: Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
            || ProcessInfo.processInfo.environment["PERCH_DEMO"] == "1"
    }

    /// 1.5 screenshots: `PERCH_DEMO_STATE` = calm, empty, offline or
    /// loading changes what 额度 reads; unset is the usual (tight) demo.
    static var state: String? { ProcessInfo.processInfo.environment["PERCH_DEMO_STATE"] }

    /// The key that connects on the demo connect screen.
    static let connectKey = "sk-magpie-demo"

    /// A connection that looks real in the status capsule and Settings.
    static let address = URL(string: "http://office-mac.local:3425")!
    static let key = "sk-magpie-demo-not-a-real-key-7f3a"

    /// 1.4: office-mac (selected, connected) and 家里, seen 2 hours ago.
    static func computers(now: Date = .now) -> [(name: String, address: URL, key: String, lastSeen: Date?, reachable: Bool?)] {
        [
            ("office-mac", address, key, now, true),
            ("家里", URL(string: "http://192.168.1.30:3425")!, "sk-magpie-demo-home-0000000000000000000000000000c71e",
             now.addingTimeInterval(-2 * 3600), nil),
        ]
    }

    /// The newest magpie on GitHub; office-mac runs 0.1.4211.
    static let release = MagpieRelease(
        tag: "v0.1.4283",
        notes: """
        ## What's new
        - Usage: `/v1/magpie/usage?period=30d` reports one bucket per day.
        - Routing: a failed try now records why (`quota`, `rate`, `credit`…).
        - `/v1/magpie/me` reports the running version.

        ## Fixes
        - Quota cards refresh after an account signs in again.
        - Fewer duplicate rows when a call is handed on.
        """,
        url: URL(string: "https://github.com/yetone/magpie-releases/releases/tag/v0.1.4283"),
        published: Date(timeIntervalSince1970: 1_794_794_000))

    // MARK: 额度

    /// The demo 额度 cards (nil when the demo is off): Kimi, four Claude
    /// accounts (one switched off, one signed out) and a DeepSeek balance.
    static func quotaCards(now: Date = .now) -> [QuotaCard]? {
        guard isOn else { return nil }
        func w(_ name: String, used: Double, in seconds: TimeInterval?) -> QuotaWindow {
            QuotaWindow(name: name, used: used, remaining: 100 - used,
                        resetsAt: seconds.map { now.addingTimeInterval($0) },
                        display: nil, unlimited: false, text: false, lane: nil)
        }
        func card(_ provider: String, _ name: String, alias: String, user: String?, plan: String?,
                  windows: [QuotaWindow], balance: String? = nil, kind: String = "subscription", off: Bool = false,
                  error: String? = nil) -> QuotaCard {
            QuotaCard(provider: provider, name: name, kind: kind, plan: plan, user: user, alias: alias,
                      seat: nil, from: nil, windows: windows, balance: balance, error: error,
                      asOf: now, readAt: now, last: false, off: off)
        }
        return [
            card("kimi", "Kimi", alias: "Kimi 编程", user: "kimi@example.com", plan: "Allegretto",
                 windows: [w("5h", used: 75, in: 2 * 3600 + 40 * 60), w("7d", used: 18, in: 2 * 86400)]),
            card("claude", "Claude", alias: "工作号", user: "work@example.com", plan: "Max",
                 windows: [w("5h", used: 62, in: 3 * 3600 + 12 * 60), w("7d", used: 41, in: nextThursday(now)),
                           w("7d Opus", used: 79, in: nextThursday(now))]),
            card("claude", "Claude", alias: "个人号", user: "me@example.com", plan: "Pro",
                 windows: [w("5h", used: state == "calm" ? 48 : 93, in: 42 * 60), w("7d", used: 34, in: 4 * 86400 + 5 * 3600)]),
            card("claude", "Claude", alias: "备用号", user: "spare@example.com", plan: "Max",
                 windows: [w("5h", used: 0, in: nil), w("7d", used: 12, in: 5 * 86400)], off: true),
            // 1.4 登录已失效: magpie's own sign-in-required wording.
            card("claude", "Claude", alias: "旧号", user: "old@example.com", plan: "Pro",
                 windows: [w("5h", used: 20, in: 4 * 3600), w("7d", used: 55, in: 6 * 86400)],
                 error: "Claude Code could not authenticate this account; sign in again in magpie"),
            card("deepseek", "DeepSeek", alias: "DeepSeek", user: nil, plan: nil,
                 windows: [], balance: "¥ 86.40", kind: "balance"),
        ]
    }

    /// `/quotas`' serving times: 工作号 served Claude's latest call.
    static func servedCards(now: Date = .now) -> [QuotaCard] {
        var cards = quotaCards(now: now) ?? []
        for i in cards.indices {
            switch cards[i].alias {
            case "工作号": cards[i].lastServedAt = now.addingTimeInterval(-180); cards[i].last = true
            case "个人号": cards[i].lastServedAt = now.addingTimeInterval(-720)
            case "Kimi 编程": cards[i].lastServedAt = now.addingTimeInterval(-3 * 3600)
            default: break
            }
        }
        return cards
    }

    /// The next Thursday 08:00 more than a day out: 「周四 08:00 重置」.
    private static func nextThursday(_ now: Date) -> TimeInterval {
        thursday(now).timeIntervalSince(now)
    }

    /// The next Thursday 08:00 at least a day after `now`.
    private static func thursday(_ now: Date) -> Date {
        Calendar.current.nextDate(after: now.addingTimeInterval(86400),
                                  matching: DateComponents(hour: 8, minute: 0, weekday: 5),
                                  matchingPolicy: .nextTime) ?? now.addingTimeInterval(3 * 86400)
    }

    /// 工作号's 5 小时 and 每周 windows, rising in steps to what the card
    /// says, told the way the latest magpie's `/quotas/history` tells them
    /// (`lines` of `at`/`left`) and read by the real decoder.
    /// `PERCH_DEMO_HISTORY=unrecognized`: a reply Perch can't read.
    static func history(now: Date = .now) -> QuotaHistory {
        if ProcessInfo.processInfo.environment["PERCH_DEMO_HISTORY"] == "unrecognized" { return .unrecognized }
        let weekEnd = thursday(now)
        let weekStart = weekEnd.addingTimeInterval(-7 * 86400)
        let steps: [Double] = [0, 3, 8, 8, 14, 19, 25, 27, 33, 36, 41]
        let span = now.timeIntervalSince(weekStart)
        let week = steps.enumerated().map { i, used in
            (weekStart.addingTimeInterval(span * Double(i) / Double(steps.count - 1)), used, weekStart, weekEnd)
        }
        let fiveEnd = now.addingTimeInterval(3 * 3600 + 12 * 60)
        let fiveStart = fiveEnd.addingTimeInterval(-5 * 3600)
        let fiveSteps: [Double] = [0, 12, 20, 31, 44, 52, 62]
        let fiveSpan = now.timeIntervalSince(fiveStart)
        let five = fiveSteps.enumerated().map { i, used in
            (fiveStart.addingTimeInterval(fiveSpan * Double(i) / Double(fiveSteps.count - 1)), used, fiveStart, fiveEnd)
        }
        let format = ISO8601DateFormatter()
        func points(_ list: [(Date, Double, Date, Date)]) -> [[String: Any]] {
            list.map { at, used, start, reset in
                ["at": format.string(from: at), "left": 100 - used, "start": format.string(from: start), "resetsAt": format.string(from: reset)]
            }
        }
        let reply: [String: Any] = ["object": "list", "data": [
            ["provider": "claude", "user": "work@example.com", "lines": [
                ["name": "5 hours", "points": points(five)],
                ["name": "7 days", "points": points(week)],
            ]],
        ]]
        guard let data = try? JSONSerialization.data(withJSONObject: reply) else { return .empty }
        return QuotaHistoryDecoding.history(from: data)
    }

    // MARK: Agent

    /// One made-up agent/model pairing.
    private struct Spec { var agent: String; var name: String; var model: String; var account: String?; var tokens: Int; var cost: Double }

    /// Made-up calls, newest first: Claude Code on two accounts, Codex,
    /// OpenCode. The same every run (no randomness).
    private static func rows(now: Date, period: UsagePeriod) -> [UsageRow] {
        let models: [(String, Int, Double)] = [("claude-opus-5-5", 23_000, 0.10), ("claude-sonnet-5-5", 11_300, 0.032), ("claude-haiku-5-5", 5_900, 0.017)]
        let count = period == .today ? 184 : (period == .sevenDays ? 1_160 : 4_310)
        let days: Double = period == .thirtyDays ? 30 : 7
        let span: TimeInterval = period == .today ? now.timeIntervalSince(Calendar.current.startOfDay(for: now)) : days * 86400
        var out: [UsageRow] = []
        for i in 0..<count {
            let k = (i * 7 + 3) % 10
            let model = k < 5 ? models[0] : (k < 9 ? models[1] : models[2])
            let account = i % 4 == 3 ? "me@example.com" : "work@example.com"
            // Busier towards now: offsets grow with the square of i.
            let f = Double(i) / Double(count)
            let t = now.addingTimeInterval(-max(60, span * f * f) - Double(i % 5) * 20)
            // 1.4: one failure of each kind magpie's rows can tell, and
            // calls magpie handed on to 个人号 after a failed try.
            var failure: (status: Int, type: String?, error: String, rejected: Bool)?
            switch i {
            case 6: failure = (429, "usage_limit_reached", "This request would exceed your account's 5-hour usage limit", false)
            case 14: failure = (429, "rate_limit_error", "Number of requests has exceeded your rate limit", false)
            case 23: failure = (404, nil, "unknown model", true)
            case _ where i % 61 == 60: failure = (529, "overloaded_error", "Overloaded", false)
            default: break
            }
            let failed = failure != nil
            let switched = i == 2 || i == 9 || i == 31
            let rowAccount = switched ? "me@example.com" : account
            let asked = failure?.rejected == true ? "claude-opsu-5" : (i % 3 == 0 ? "group/coder" : model.0)
            let tokens = failed ? 0 : model.1 + (i * 977) % 9000
            out.append(UsageRow(id: "demo-c-\(i)", time: t, agent: "claude", agentName: "Claude Code", session: "s\(i / 9)",
                                requested: asked, model: failure?.rejected == true ? asked : model.0, served: failure?.rejected == true ? nil : model.0,
                                provider: failure?.rejected == true ? "" : "claude", providerName: failure?.rejected == true ? nil : "Claude",
                                account: failure?.rejected == true ? nil : rowAccount, status: failure?.status ?? 200,
                                input: tokens * 9 / 10, output: tokens / 10, cacheRead: tokens * 3, cacheWrite: tokens / 5, reasoning: 0,
                                cost: failed ? 0 : model.2 * Double(tokens) / 10_000, priced: true, ms: failed ? 300 : 800 + (i * 431) % 6000,
                                error: failure?.error, errorType: failure?.type,
                                tries: switched ? 2 : nil, retriedMs: switched ? 140 : nil, rejected: failure?.rejected ?? false))
        }
        let others = period == .today ? (37, 5) : (period == .sevenDays ? (212, 31) : (790, 120))
        for i in 0..<others.0 {
            out.append(UsageRow(id: "demo-x-\(i)", time: now.addingTimeInterval(-span * Double(i + 1) / Double(others.0 + 1)), agent: "codex", agentName: "Codex",
                                session: nil, requested: "gpt-6", model: "gpt-6", served: "gpt-6", provider: "codex", providerName: "Codex",
                                account: "me@example.com", status: 200, input: 9000, output: 800, cacheRead: 20000, cacheWrite: 0, reasoning: 300,
                                cost: 0.05, priced: true, ms: 2400, error: nil))
        }
        for i in 0..<others.1 {
            out.append(UsageRow(id: "demo-o-\(i)", time: now.addingTimeInterval(-span * Double(i + 1) / Double(others.1 + 1)), agent: "opencode", agentName: "OpenCode",
                                session: nil, requested: "deepseek/deepseek-v4-pro", model: "deepseek-v4-pro", served: "deepseek-v4-pro", provider: "deepseek",
                                providerName: "DeepSeek", account: nil, status: 200, input: 4000, output: 600, cacheRead: 0, cacheWrite: 0, reasoning: 0,
                                cost: i % 9 == 4 ? nil : 0.004, priced: i % 9 == 4 ? false : true, ms: 1900, error: nil))
        }
        return out.sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }
    }

    /// The demo rows the filter keeps (`all` reads as 30 days).
    private static func filtered(_ filter: UsageFilter, now: Date) -> [UsageRow] {
        rows(now: now, period: filter.period == .all ? .thirtyDays : filter.period).filter { r in
            (filter.agent == nil || r.agent == filter.agent)
                && (filter.model == nil || r.shownModel == filter.model)
                && (filter.account == nil || r.account == filter.account)
                && (!filter.failedOnly || r.failed)
                && (!filter.retriedOnly || r.switched)
        }
    }

    /// The totals of `rows`.
    private static func total(_ rows: [UsageRow]) -> UsageTotals {
        var t = UsageTotals()
        rows.forEach { t.add($0) }
        return t
    }

    /// A `/usage` summary built from the demo rows.
    static func usageSummary(_ period: UsagePeriod, now: Date = .now) -> UsageSummary {
        let all = filtered(UsageFilter(period: period, agent: nil), now: now)
        func split(_ key: (UsageRow) -> String?, name: (UsageRow) -> String?) -> [UsageBucket] {
            var b: [String: UsageBucket] = [:]
            for r in all {
                guard let k = key(r) else { continue }
                var x = b[k] ?? UsageBucket(id: k, name: name(r) ?? k, provider: r.provider, last: r.time, totals: UsageTotals())
                x.totals.add(r)
                b[k] = x
            }
            return b.values.sorted { $0.totals.calls > $1.totals.calls }
        }
        return UsageSummary(period: period.rawValue, since: nil, totals: total(all),
                            agents: split({ $0.agent }, name: { $0.agentName }),
                            models: split({ "\($0.provider ?? "")/\($0.shownModel)" }, name: { $0.shownModel }),
                            accounts: split({ $0.account }, name: { $0.account }),
                            sessionCount: 12)
    }

    /// A `/usage/requests` page built from the demo rows, with hourly
    /// (today) or daily chart points.
    static func requestsPage(_ filter: UsageFilter, offset: Int = 0, limit: Int = 100, now: Date = .now) -> UsageRequestsPage {
        let rows = filtered(filter, now: now)
        var byModel: [String: UsageBucket] = [:]
        for r in rows {
            var b = byModel[r.shownModel] ?? UsageBucket(id: r.shownModel, name: r.shownModel, totals: UsageTotals())
            b.totals.add(r)
            byModel[r.shownModel] = b
        }
        let calendar = Calendar.current
        var series: [UsageSeriesPoint] = []
        if filter.period == .today {
            let start = calendar.startOfDay(for: now)
            for h in 0..<24 {
                let t = start.addingTimeInterval(Double(h) * 3600)
                series.append(UsageSeriesPoint(time: t, label: String(format: "%02d", h),
                                               totals: total(rows.filter { ($0.time ?? .distantPast) >= t && ($0.time ?? .distantPast) < t.addingTimeInterval(3600) })))
            }
        } else {
            let today = calendar.startOfDay(for: now)
            for d in (0..<(filter.period == .sevenDays ? 7 : 30)).reversed() {
                let t = calendar.date(byAdding: .day, value: -d, to: today) ?? today
                let end = calendar.date(byAdding: .day, value: 1, to: t) ?? t
                series.append(UsageSeriesPoint(time: t, label: "", totals: total(rows.filter { ($0.time ?? .distantPast) >= t && ($0.time ?? .distantPast) < end })))
            }
        }
        let page = Array(rows.dropFirst(offset).prefix(limit))
        return UsageRequestsPage(period: filter.period.rawValue, offset: offset, total: rows.count, rows: page, totals: total(rows),
                                 byModel: byModel.values.sorted { $0.totals.cost > $1.totals.cost }, byModelAt: [], byProvider: [], byAccount: [],
                                 accountNames: Array(Set(rows.compactMap(\.account))).sorted(),
                                 series: series, bucket: filter.period == .today ? "hour" : "day")
    }

    /// The demo rows split by account, most cost first.
    static func accountSplit(_ filter: UsageFilter, now: Date = .now) -> [UsageBucket] {
        UsageAggregation.byAccount(filtered(filter, now: now)).filter { !$0.id.isEmpty }
            .sorted { $0.totals.cost > $1.totals.cost }
    }

    // MARK: 路由组

    /// Four routing groups, one per mode, read by the real decoder.
    static func routingGroups() -> [RoutingGroup] {
        let json = """
        {"groups":[
          {"id":"coder","name":"Coder","routing":"order","members":["alpha/m-alpha","beta/m-beta","gamma/m-gamma"]},
          {"id":"fast","name":"fast","routing":"manual","pick":"kimi/kimi-k3","members":["kimi/kimi-k3","glm/glm-5.3","deepseek/deepseek-v4-pro"]},
          {"id":"cheap","name":"cheap","routing":"cheap","members":["deepseek/deepseek-v4-pro","glm/glm-5.3"]},
          {"id":"claude-opus-5-5","name":"claude-opus-5-5","routing":"","members":["claude/claude-opus-5-5","copilot/claude-opus-5-5"]}
        ]}
        """
        return (try? RoutingDecoding.groups(from: Data(json.utf8))) ?? []
    }
}
#endif
