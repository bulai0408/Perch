import Foundation
import Testing
@testable import Perch

private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// A quota window fixture.
private func window(_ name: String = "5h", used: Double, resetIn: TimeInterval?) -> QuotaWindow {
    QuotaWindow(name: name, used: used, remaining: 100 - used, resetsAt: resetIn.map { now.addingTimeInterval($0) },
                unlimited: false, text: false)
}

/// 1.4 run-out estimate.
struct RunOutTests {
    @Test func projectsFromTheLastHour() throws {
        // 40% → 60% over an hour: 20%/h, 40% left → 2 h.
        let history = [UsageSample(time: now.addingTimeInterval(-3600), used: 40)]
        let r = try #require(RunOutEstimate.estimate(window: window(used: 60, resetIn: 4 * 3600), history: history, reads: [], now: now))
        #expect(abs(r.at.timeIntervalSince(now) - 7200) < 1)
        #expect(!r.urgent(now: now))
    }

    @Test func hiddenWhenItLastsPastTheReset() {
        let history = [UsageSample(time: now.addingTimeInterval(-3600), used: 40)]
        #expect(RunOutEstimate.estimate(window: window(used: 60, resetIn: 3600), history: history, reads: [], now: now) == nil)
    }

    @Test func hiddenWithTooLittleDataOrNoPace() {
        let short = [UsageSample(time: now.addingTimeInterval(-5 * 60), used: 50)]
        #expect(RunOutEstimate.estimate(window: window(used: 60, resetIn: 4 * 3600), history: short, reads: [], now: now) == nil)
        let flat = [UsageSample(time: now.addingTimeInterval(-3600), used: 60)]
        #expect(RunOutEstimate.estimate(window: window(used: 60, resetIn: 4 * 3600), history: flat, reads: [], now: now) == nil)
    }

    @Test func hiddenWhenExhausted() {
        let history = [UsageSample(time: now.addingTimeInterval(-3600), used: 40)]
        #expect(RunOutEstimate.estimate(window: window(used: 100, resetIn: 4 * 3600), history: history, reads: [], now: now) == nil)
    }

    @Test func readsNeedTenMinutesApart() {
        let close = [UsageSample(time: now.addingTimeInterval(-5 * 60), used: 50)]
        #expect(RunOutEstimate.estimate(window: window(used: 60, resetIn: 4 * 3600), history: [], reads: close, now: now) == nil)
        let apart = [UsageSample(time: now.addingTimeInterval(-30 * 60), used: 50)]
        #expect(RunOutEstimate.estimate(window: window(used: 60, resetIn: 4 * 3600), history: [], reads: apart, now: now) != nil)
    }

    @Test func urgentWithinAnHour() throws {
        let history = [UsageSample(time: now.addingTimeInterval(-3600), used: 10)]
        let r = try #require(RunOutEstimate.estimate(window: window(used: 90, resetIn: 4 * 3600), history: history, reads: [], now: now))
        #expect(r.urgent(now: now))
        #expect(r.text(now: now).hasPrefix("照现在的速度，大约 "))
        #expect(r.text(now: now).hasSuffix(" 用完"))
    }

    @Test func untilFormats() {
        let cal = Calendar.current
        let today = cal.date(bySettingHour: 15, minute: 40, second: 0, of: now)!
        let base = cal.date(bySettingHour: 9, minute: 0, second: 0, of: now)!
        #expect(QuotaFormat.until(today, now: base) == "15:40")
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.date(bySettingHour: 9, minute: 10, second: 0, of: now)!)!
        #expect(QuotaFormat.until(tomorrow, now: base) == "明天 09:10")
        let later = cal.date(byAdding: .day, value: 3, to: today)!
        #expect(QuotaFormat.until(later, now: base).hasPrefix("周"))
        #expect(QuotaFormat.until(later, now: base).hasSuffix(" 15:40"))
    }
}

/// 1.4 failures in magpie's words.
struct CallFailureTests {
    @Test(arguments: [
        (429, "You have reached your usage limit", "", FailureKind.quota),
        (429, "Too many requests", "rate_limit_error", .rate),
        (402, "Insufficient balance", "", .credit),
        (401, "OAuth token has expired", "authentication_error", .login),
        (500, "internal", "api_error", .upstream),
        (529, "Overloaded", "overloaded_error", .upstream),
        (400, "something odd", "", .other),
    ])
    func categories(status: Int, error: String, type: String, kind: FailureKind) {
        #expect(CallFailure.kind(status: status, error: error, errorType: type.isEmpty ? nil : type, rejected: false) == kind)
    }

    @Test func rejectedIsModelNotFound() {
        #expect(CallFailure.kind(status: 400, error: "unknown model", errorType: nil, rejected: true) == .modelNotFound)
    }

    @Test func routeCategories() {
        #expect(CallFailure.kind(category: "quota") == .quota)
        #expect(CallFailure.kind(category: "rate") == .rate)
        #expect(CallFailure.kind(category: "auth") == .login)
        #expect(CallFailure.kind(category: "overloaded") == .upstream)
        #expect(CallFailure.shortReason(category: "quota") == "额度用完")
        #expect(CallFailure.shortReason(category: "rate") == "限流")
        #expect(CallFailure.shortReason(category: "credit") == "余额不足")
        #expect(CallFailure.shortReason(category: "slow") == "出错")
        #expect(CallFailure.shortReason(category: "whatever") == nil)
    }

    @Test func lines() {
        #expect(CallFailure.line(.credit, account: "工作号", provider: "Claude", model: "m", resetsAt: nil, now: now)
                == "工作号 余额不足，充值后才能再用。")
        #expect(CallFailure.line(.login, account: "工作号", provider: "Claude", model: "m", resetsAt: nil, now: now)
                == "工作号 登录已失效，要在电脑上的 magpie 里重新登录。")
        #expect(CallFailure.line(.modelNotFound, account: "a", provider: "p", model: "gpt-9", resetsAt: nil, now: now)
                == "magpie 找不到模型 gpt-9。看看 Agent 里填的模型名对不对。")
        #expect(CallFailure.line(.upstream, account: "a", provider: "Kimi", model: "m", resetsAt: nil, now: now)
                == "Kimi 那边出错了，不是你的问题，等一会儿再试。")
        #expect(CallFailure.line(.other, account: "a", provider: "p", model: "m", resetsAt: nil, now: now) == "这次没成功。")
        let quota = CallFailure.line(.quota, account: "工作号", provider: "Claude", model: "m",
                                     resetsAt: now.addingTimeInterval(600), switchedTo: "个人号", now: now)
        #expect(quota.hasPrefix("工作号 额度用完了，"))
        #expect(quota.hasSuffix("重置。magpie 换到了 个人号。"))
    }

    @Test func rateLimitLine() {
        // A real recovery time reads as a wait, not a clock time.
        #expect(CallFailure.line(.rate, account: "工作号", provider: "Claude", model: "m", resetsAt: nil,
                                 recoversAt: now.addingTimeInterval(180), now: now) == "工作号 被限流了，过 3 分钟恢复。")
        #expect(CallFailure.line(.rate, account: "工作号", provider: "Claude", model: "m", resetsAt: nil,
                                 recoversAt: now.addingTimeInterval(2 * 3600 + 600), now: now) == "工作号 被限流了，过 2 小时恢复。")
        // No recovery time known: a quota window's reset must not stand in for it.
        #expect(CallFailure.line(.rate, account: "工作号", provider: "Claude", model: "m",
                                 resetsAt: now.addingTimeInterval(3600), now: now) == "工作号 被限流了，过一会儿就好。")
        #expect(CallFailure.line(.rate, account: "工作号", provider: "Claude", model: "m", resetsAt: nil,
                                 recoversAt: now.addingTimeInterval(-60), now: now) == "工作号 被限流了，过一会儿就好。")
        #expect(QuotaFormat.duration(until: now.addingTimeInterval(20), now: now) == "1 分钟")
        #expect(QuotaFormat.duration(until: now.addingTimeInterval(59 * 60), now: now) == "59 分钟")
        #expect(CallFailure.resetTime(nil, kind: .rate, now: now) == nil)
    }

    @Test func loginExpiredCard() {
        var card = QuotaCard(provider: "claude", name: "Claude", kind: "subscription", plan: nil, user: "a", alias: nil,
                             seat: nil, from: nil, windows: [], balance: nil, error: nil, asOf: nil, readAt: nil, last: false)
        #expect(!card.loginExpired)
        card.error = "OAuth token expired, please sign in again"
        #expect(card.loginExpired)
        card.error = "timeout reading usage"
        #expect(!card.loginExpired)
    }
}

/// 1.4 magpie versions.
struct VersionTests {
    @Test func comparesNumerically() throws {
        let a = try #require(MagpieVersion("0.1.999"))
        let b = try #require(MagpieVersion("v0.1.4283"))
        #expect(a < b)
        #expect(MagpieVersion("0.1") == MagpieVersion("0.1.0"))
        #expect(MagpieVersion("0.1.x") == nil)
        #expect(MagpieVersion("") == nil)
    }

    @Test func newer() {
        let release = MagpieRelease(tag: "v0.1.4283", notes: "", url: nil, published: nil)
        #expect(VersionStore.newer(current: MagpieVersion("0.1.4211"), latest: release) == release)
        #expect(VersionStore.newer(current: MagpieVersion("0.1.4283"), latest: release) == nil)
        #expect(VersionStore.newer(current: nil, latest: release) == nil)
    }

    @MainActor @Test func dismissedVersionStaysHidden() {
        let defaults = UserDefaults(suiteName: "perch-test-\(UUID().uuidString)")!
        let store = VersionStore(defaults: defaults)
        #expect(!store.showsBanner)
        #expect(MagpieRelease.decode(Data(#"{"tag_name":"v0.1.4283","body":"x"}"#.utf8))?.tag == "v0.1.4283")
        #expect(MagpieRelease.decode(Data(#"{"tag_name":"nightly"}"#.utf8)) == nil)
    }
}

/// In-memory Keychain for the multi-computer store.
private final class MemorySecrets: SecretStore {
    var items: [String: String] = [:]
    func read(_ account: String) -> String? { items[account] }
    func write(_ value: String, _ account: String) { items[account] = value }
    func delete(_ account: String) { items[account] = nil }
}

/// Migrating the 1.3 connection; adding, selecting and removing computers.
@MainActor
struct MultiComputerTests {
    /// A fresh, empty defaults suite.
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "perch-test-\(UUID().uuidString)")! }

    @Test func migratesTheOneConnection() throws {
        let d = defaults()
        let secrets = MemorySecrets()
        d.set("http://office-mac.local:8080", forKey: ConnectionStore.legacyAddressKey)
        secrets.items[Keychain.Account.gatewayKey.rawValue] = "sk-magpie-abcdef123456"
        let store = ConnectionStore(defaults: d, secrets: secrets)
        let c = try #require(store.computers.first)
        #expect(store.computers.count == 1)
        #expect(store.currentID == c.id)
        #expect(c.name == "office-mac")
        #expect(store.gatewayKey() == "sk-magpie-abcdef123456")
        #expect(secrets.items[Keychain.Account.gatewayKey.rawValue] == nil)
        #expect(d.string(forKey: ConnectionStore.legacyAddressKey) == nil)
        // A second launch keeps it.
        let again = ConnectionStore(defaults: d, secrets: secrets)
        #expect(again.computers.map(\.id) == [c.id])
    }

    @Test func savedV1AddressesLoseTheirV1() throws {
        let d = defaults()
        let secrets = MemorySecrets()
        let saved = [
            Computer(id: "a", name: "office-mac", address: URL(string: "http://192.168.1.20:3425/v1")!, lastConnected: nil),
            Computer(id: "b", name: "box", address: URL(string: "https://box.example/magpie/v1/")!, lastConnected: nil),
            Computer(id: "c", name: "home", address: URL(string: "http://home.local:3425")!, lastConnected: nil),
        ]
        d.set(try JSONEncoder().encode(saved), forKey: ConnectionStore.computersKey)
        secrets.items[ConnectionStore.keyAccount("a")] = "k"
        let store = ConnectionStore(defaults: d, secrets: secrets)
        #expect(store.computers.map(\.address.absoluteString)
                == ["http://192.168.1.20:3425", "https://box.example/magpie", "http://home.local:3425"])
        #expect(store.currentID == "a")
        #expect(store.gatewayKey() == "k")
        // Written back, so the next launch reads the fixed address.
        let again = ConnectionStore(defaults: d, secrets: secrets)
        #expect(again.computers.first?.address.absoluteString == "http://192.168.1.20:3425")
        #expect(MagpieAddress.droppingV1(URL(string: "http://office-mac:3425/v10")!).absoluteString == "http://office-mac:3425/v10")
        #expect(MagpieAddress.droppingV1(URL(string: "http://office-mac:3425/")!).absoluteString == "http://office-mac:3425/")
    }

    @Test func addSelectRemove() throws {
        let secrets = MemorySecrets()
        let store = ConnectionStore(defaults: defaults(), secrets: secrets)
        let office = store.add(name: nil, address: URL(string: "http://192.168.1.30:8080")!, key: "k1")
        #expect(office.name == "192.168.1.30")
        let home = store.add(name: "家里", address: URL(string: "http://home.local:8080")!, key: "k2")
        #expect(store.currentID == home.id)
        #expect(store.gatewayKey() == "k2")
        store.select(office.id)
        #expect(store.gatewayKey() == "k1")
        #expect(store.toast == "已换到 192.168.1.30")
        store.remove(office.id)
        #expect(store.currentID == home.id)
        #expect(secrets.items[ConnectionStore.keyAccount(office.id)] == nil)
        // Same address again: no duplicate, new key.
        store.add(name: "", address: URL(string: "http://home.local:8080")!, key: "k3")
        #expect(store.computers.count == 1)
        #expect(store.gatewayKey() == "k3")
    }

    @Test func statusText() throws {
        let store = ConnectionStore(defaults: defaults(), secrets: MemorySecrets())
        let c = store.add(name: "A", address: URL(string: "http://a.local:8080")!, key: "k")
        #expect(ComputerStatusText.menu(store.status(of: c)) == "● 已连接")
        store.markReachable(c.id, false, at: now)
        #expect(ComputerStatusText.menu(.unreachable) == "● 连不上")
        #expect(ComputerStatusText.menu(.unknown) == "")
        #expect(ComputerStatusText.menu(.lastSeen(now.addingTimeInterval(-7200)), now: now) == "上次连上：2 小时前")
    }
}

/// 1.4 Agent summary, menu and group names.
struct AgentSummaryTests {
    /// A usage bucket fixture.
    private func bucket(_ id: String, calls: Int, cost: Double = 0) -> UsageBucket {
        UsageBucket(id: id, name: id, totals: UsageTotals(calls: calls, cost: cost))
    }

    @Test func tenthsOfOpus() throws {
        let totals = UsageTotals(calls: 184, errors: 3, cost: 12.4)
        let s = try #require(AgentSummary.make(period: .today, agentName: "Claude Code", totals: totals,
                                               models: [bucket("claude-opus-5-5", calls: 150, cost: 10), bucket("claude-haiku-5-5", calls: 34, cost: 2.4)]))
        #expect(s.sentence == "今天 Claude Code 调用 184 次，约 $12.40，八成是 Opus。")
        #expect(s.failures == "失败 3 次。")
    }

    @Test func mostUsedBelowSeventy() throws {
        let s = try #require(AgentSummary.make(period: .thirtyDays, agentName: "Codex", totals: UsageTotals(calls: 10, cost: 2),
                                               models: [bucket("gpt-5", calls: 6, cost: 1.2), bucket("kimi-k3", calls: 4, cost: 0.8)]))
        #expect(s.sentence.hasPrefix("这 30 天 Codex 调用 10 次，约 $2.00，"))
        #expect(s.sentence.hasSuffix(" 用得最多。"))
        #expect(s.failures == nil)
    }

    @Test func unpricedDropsTheDollars() throws {
        let s = try #require(AgentSummary.make(period: .sevenDays, agentName: "Codex", totals: UsageTotals(calls: 4, unpriced: 4),
                                               models: [bucket("kimi-k3", calls: 4)]))
        #expect(!s.sentence.contains("$"))
        #expect(s.sentence.hasPrefix("这 7 天 Codex 调用 4 次，"))
    }

    @Test func noCallsNoSummary() {
        #expect(AgentSummary.make(period: .today, agentName: "x", totals: UsageTotals(), models: []) == nil)
    }

    @Test func menuAgentsFollowThePeriod() {
        let week = [bucket("claude", calls: 50), bucket("codex", calls: 10)]
        let today = [bucket("codex", calls: 5), bucket("gemini", calls: 2)]
        let menu = UsageStore.menuAgents(week: week, period: today)
        #expect(menu.map(\.id) == ["codex", "gemini", "claude"])
        #expect(menu.map(\.totals.calls) == [5, 2, 0])
    }

    @Test func duplicateMemberNamesUseProviders() {
        #expect(RoutingChain.names(["claude/opus", "copilot/opus", "kimi/k3"]) == ["claude", "copilot", "k3"])
    }

    @Test func offText() {
        let on = QuotaCard(provider: "claude", name: "Claude", kind: "subscription", plan: nil, user: "a", alias: nil,
                           seat: nil, from: nil, windows: [], balance: nil, error: nil, asOf: nil, readAt: nil, last: false)
        var off = on
        off.off = true
        #expect(QuotaSummary([on], now: now).offText == "都能用")
        #expect(QuotaSummary([on, off], now: now).offText == "1 个已停用")
    }

    @Test func elapsed() {
        #expect(QuotaFormat.elapsed(since: now.addingTimeInterval(-12), now: now) == "12 秒")
        #expect(QuotaFormat.elapsed(since: now.addingTimeInterval(-128), now: now) == "2 分钟")
        #expect(QuotaFormat.elapsed(since: now.addingTimeInterval(-3900), now: now) == "1 小时 5 分钟")
    }
}
