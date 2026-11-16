import Foundation
import Testing
@testable import Perch

/// Typed addresses normalise to `http://host:port` (3425 by default).
struct AddressTests {
    @Test(arguments: [
        ("192.168.1.20", "http://192.168.1.20:3425"),
        ("192.168.1.20:3425", "http://192.168.1.20:3425"),
        ("  http://office-mac  ", "http://office-mac:3425"),
        ("http://office-mac:8080/", "http://office-mac:8080"),
        ("HTTP://Office-Mac.tailnet.ts.net", "http://office-mac.tailnet.ts.net:3425"),
        ("https://magpie.example.ts.net", "https://magpie.example.ts.net"),
        ("http://10.0.0.2:3425/?k=abc#x", "http://10.0.0.2:3425"),
    ])
    func normalizes(raw: String, expected: String) {
        #expect(MagpieAddress.normalize(raw)?.absoluteString.lowercased() == expected.lowercased())
    }

    @Test(arguments: ["", "   ", "ftp://host", "http://"])
    func rejects(raw: String) {
        #expect(MagpieAddress.normalize(raw) == nil)
    }

    @Test func hostAndPort() throws {
        let url = try #require(MagpieAddress.normalize("192.168.1.20"))
        #expect(MagpieAddress.hostAndPort(url) == "192.168.1.20:3425")
    }
}

/// One rule for the shown computer name (status capsules, Settings row).
struct ComputerNameTests {
    @Test(arguments: [
        ("office-mac.local", "office-mac"),
        ("Office-Mac.LOCAL", "Office-Mac"),
        ("office-mac.local.", "office-mac"),
        ("office-mac", "office-mac"),
        ("office-mac.tailnet.ts.net", "office-mac.tailnet.ts.net"),
        ("192.168.1.30", "192.168.1.30"),
        ("::1", "::1"),
        ("[fe80::1]", "fe80::1"),
        (".local", ".local"),
    ])
    func display(host: String, shown: String) {
        #expect(ComputerName.display(host: host) == shown)
    }

    @Test func noHost() {
        #expect(ComputerName.display(host: nil) == nil)
        #expect(ComputerName.display(host: "  ") == nil)
    }

    @Test func sharedByTheConnection() throws {
        let defaults = try #require(UserDefaults(suiteName: "perch.test.computer-name"))
        defaults.set("http://office-mac.local:3425", forKey: "perch.address")
        defer { defaults.removePersistentDomain(forName: "perch.test.computer-name") }
        let url = try #require(URL(string: defaults.string(forKey: "perch.address") ?? ""))
        #expect(ComputerName.display(host: url.host()) == "office-mac")
    }
}

/// Keys are never shown in full.
struct KeyMaskTests {
    @Test func masksKeys() {
        #expect(KeyMask.mask("sk-magpie-abcdefghijkl3f9a") == "sk-magpie-••••3f9a")
        #expect(KeyMask.mask("short") == "••••")
        #expect(!KeyMask.mask("sk-magpie-secretsecret").contains("secret"))
    }
}

/// `/quotas/cards` decoding, including odd and partial replies.
struct QuotaDecodingTests {
    static let sample = """
    {"object":"list","data":[
      {"provider":"claude","name":"Claude","kind":"subscription","plan":"Max","user":"me@example.com",
       "windows":[
         {"name":"5h","used":62.4,"remaining":37.6,"resetsAt":"2026-11-15T14:00:00.123456789+08:00"},
         {"name":"7d","used":"12","remaining":88},
         {"used":5},
         "garbage"
       ],
       "last":true,"lastServedAt":"2026-11-15T10:00:00Z","somethingNew":{"x":1}},
      {"provider":"deepseek","name":"DeepSeek","kind":"balance","balance":"¥ 42.10","windows":null},
      {"kind":"plan"},
      42,
      {"provider":"codex","name":"Codex","kind":"subscription","alias":"work","windows":[],"error":"401 from chatgpt.com","asOf":"2026-11-15T02:00:00Z"}
    ]}
    """

    @Test func decodesCardsAndSkipsBadOnes() throws {
        let cards = try QuotaDecoding.cards(from: Data(Self.sample.utf8))
        #expect(cards.count == 3)

        let claude = cards[0]
        #expect(claude.title == "me@example.com")
        #expect(claude.subtitle == "Claude · Max")
        #expect(claude.last)
        #expect(claude.windows.count == 2)
        #expect(claude.windows[0].used == 62.4)
        #expect(claude.windows[1].used == 12)
        let reset = try #require(claude.windows[0].resetsAt)
        #expect(abs(reset.timeIntervalSince1970 - 1_794_722_400.123) < 0.01)

        #expect(cards[1].balance == "¥ 42.10")
        #expect(cards[1].windows.isEmpty)
        #expect(cards[1].title == "DeepSeek")

        #expect(cards[2].title == "work")
        #expect(cards[2].error == "401 from chatgpt.com")
        #expect(cards[2].asOf != nil)
    }

    @Test func acceptsBareArrayAndEmptyData() throws {
        #expect(try QuotaDecoding.cards(from: Data(#"[{"provider":"a","name":"A","windows":[]}]"#.utf8)).count == 1)
        #expect(try QuotaDecoding.cards(from: Data(#"{"data":[],"object":"list"}"#.utf8)).isEmpty)
        #expect(try QuotaDecoding.cards(from: Data(#"{"data":null}"#.utf8)).isEmpty)
    }

    @Test func rejectsOtherShapes() {
        #expect(throws: (any Error).self) { try QuotaDecoding.cards(from: Data(#"{"error":{"code":"x"}}"#.utf8)) }
        #expect(throws: (any Error).self) { try QuotaDecoding.cards(from: Data("<html>".utf8)) }
    }
}

/// Cards for the sort and tile tests: one window per entry (used %, reset in seconds from `now`).
private func card(_ id: String, last: Bool = false, error: String? = nil, _ windows: [(String, Double, TimeInterval?)],
                  now: Date = Date(timeIntervalSince1970: 1_000_000)) -> QuotaCard {
    var c = QuotaCard.placeholder
    c.provider = id
    c.user = id
    c.last = last
    c.error = error
    c.windows = windows.map { name, used, reset in
        QuotaWindow(name: name, used: used, remaining: nil, resetsAt: reset.map { now.addingTimeInterval($0) },
                    display: nil, unlimited: false, text: false, lane: nil)
    }
    return c
}

/// The 额度 sort orders.
struct QuotaSortTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    var cards: [QuotaCard] {
        [
            card("roomy", [("5h", 10, 3600), ("7d", 40, 86400 * 3)]),
            card("tight", [("5h", 93, 7200)]),
            card("nowindows", []),
            card("broken", error: "x", [("5h", 99, 60)]),
            card("middle", last: true, [("5h", 50, 600), ("7d", 70, 86400)]),
        ]
    }

    @Test func leastLeftFirstIsTheDefault() {
        let ids = QuotaSort.leastLeft.sorted(cards, now: now).map(\.provider)
        #expect(ids == ["tight", "middle", "roomy", "nowindows", "broken"])
        #expect(QuotaSort(rawValue: "") == nil)
        #expect(QuotaSort.allCases.first == .mostUsed)
    }

    @Test func soonestResetFirst() {
        let ids = QuotaSort.soonestReset.sorted(cards, now: now).map(\.provider)
        #expect(ids == ["middle", "roomy", "tight", "nowindows", "broken"])
    }

    @Test func magpieOrderIsUntouched() {
        let ids = QuotaSort.magpie.sorted(cards, now: now).map(\.provider)
        #expect(ids == ["roomy", "tight", "nowindows", "broken", "middle"])
    }

    @Test func labels() {
        #expect(QuotaSort.allCases.map(\.label) == ["用得多的在前", "剩得少的在前", "快重置的在前", "按 magpie 里的顺序"])
    }
}

/// The 额度 summary tiles: tightest window and soonest reset.
struct QuotaSummaryTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func tilesPickTheTightestAndTheSoonest() {
        var work = card("claude", last: true, [("5h", 62, 3 * 3600 + 12 * 60), ("7d", 41, 86400 * 3)], now: now)
        work.alias = "工作号"
        var home = card("codex", [("5h", 93, 42 * 60)], now: now)
        home.alias = "个人号"
        let past = card("old", [("5h", 20, -600)], now: now)
        let broken = card("broken", error: "x", [("5h", 100, 60)], now: now)
        let summary = QuotaSummary([work, home, past, broken], now: now)
        #expect(summary.leastText == "7%")
        #expect(summary.leastUsed == 93)
        #expect(summary.leastSource?.source == "个人号 · 5 小时")
        #expect(summary.soonestText(now: now) == "42 分")
        #expect(summary.soonestSource?.source == "个人号 · 5 小时")
        #expect(summary.accounts == 4)
        #expect(summary.inUseText == "1 个正在用")
    }

    @Test func tilesWithoutNumbers() {
        let summary = QuotaSummary([card("x", [])], now: now)
        #expect(summary.leastText == "—")
        #expect(summary.soonestText(now: now) == "—")
        #expect(summary.leastSource == nil)
        #expect(summary.accounts == 1)
        #expect(summary.inUseText == "0 个正在用")
    }

    @Test func soonestTileUnits() {
        let summary = QuotaSummary([card("x", [("5h", 10, 3 * 3600 + 50 * 60)], now: now)], now: now)
        #expect(summary.soonestText(now: now) == "3 小时")
    }
}

/// Window labels, percent left, colour bands, reset and read times.
struct FormatTests {
    @Test(arguments: [("5h", "5 小时"), ("7d", "7 天"), ("month", "本月"), ("weekly", "本周"), ("Opus", "Opus")])
    func windowLabels(name: String, expected: String) {
        #expect(QuotaFormat.windowLabel(name) == expected)
    }

    @Test func leftInWindow() {
        let w = QuotaWindow(name: "5h", used: 62.4, remaining: nil, resetsAt: nil, display: nil, unlimited: false, text: false, lane: nil)
        #expect(QuotaFormat.left(w) == "剩 38%")
        #expect(QuotaFormat.used(w) == 62.4)
        var gone = w
        gone.used = 100
        #expect(QuotaFormat.left(gone) == "已用完")
        let onlyLeft = QuotaWindow(name: "7d", used: nil, remaining: 59, resetsAt: nil, display: nil, unlimited: false, text: false, lane: nil)
        #expect(QuotaFormat.left(onlyLeft) == "剩 59%")
        #expect(QuotaFormat.used(onlyLeft) == 41)
        let text = QuotaWindow(name: "credits", used: nil, remaining: nil, resetsAt: nil, display: "1.2k / 3k", unlimited: false, text: true, lane: nil)
        #expect(QuotaFormat.left(text) == "1.2k / 3k")
        #expect(QuotaFormat.used(text) == nil)
    }

    @Test(arguments: [(69.9, 0), (70, 1), (89, 1), (90, 2), (100, 2)])
    func colourBands(used: Double, level: Int) {
        #expect(QuotaFormat.level(used: used) == level)
    }

    @Test func resetLines() throws {
        let calendar = Calendar.current
        // A Monday 09:30 local time.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 9, minute: 30)))
        #expect(QuotaFormat.resets(now.addingTimeInterval(42 * 60), now: now) == "42 分后重置")
        #expect(QuotaFormat.resets(now.addingTimeInterval(20), now: now) == "1 分后重置")
        #expect(QuotaFormat.resets(now.addingTimeInterval(60 * 60), now: now) == "1 小时后重置")
        // Whole hours only: 3:12 reads as 3 小时.
        #expect(QuotaFormat.resets(now.addingTimeInterval(3 * 3600 + 12 * 60), now: now) == "3 小时后重置")
        #expect(QuotaFormat.resets(now.addingTimeInterval(23 * 3600 + 59 * 60), now: now) == "23 小时后重置")
        let thursday = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 8, minute: 0)))
        #expect(QuotaFormat.resets(thursday, now: now) == "周四 08:00 重置")
        #expect(QuotaFormat.resetsShort(thursday, now: now) == "周四")
        #expect(QuotaFormat.resetsShort(now.addingTimeInterval(42 * 60), now: now) == "42 分")
        // A few seconds of clock skew must not turn 42 into 43.
        #expect(QuotaFormat.resetsShort(now.addingTimeInterval(42 * 60 + 3), now: now) == "42 分")
        // A week or more ahead names the date, not a weekday.
        let later = try #require(calendar.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 8, minute: 0)))
        #expect(QuotaFormat.resets(later, now: now) == "12月1日 08:00 重置")
        #expect(QuotaFormat.resets(nil) == nil)
    }

    @Test func readTimes() {
        let now = Date()
        #expect(QuotaFormat.ago(now.addingTimeInterval(-10), now: now) == "刚刚")
        #expect(QuotaFormat.ago(now.addingTimeInterval(-125), now: now) == "2 分钟前")
    }
}

/// Routing group decoding and the reorder/pick plans.
struct RoutingDecodingTests {
    /// Trimmed from magpie 0.1.4260's `GET /v1/magpie/admin/routing-groups`.
    static let sample = """
    {"groups":[
      {"id":"coder","name":"Coder","members":["alpha/m-alpha","beta/m-beta","gamma/m-gamma"],
       "routing":"order","pick":"gamma/m-gamma","ready":true,"ref":"group/coder",
       "memberInfo":[{"id":"alpha/m-alpha","ready":true,"provider":"alpha","name":"Alpha","model":"m-alpha","on":1},
                     {"id":"beta/m-beta","ready":false,"on":0}]},
      {"id":"fast-lane","name":"Fast","members":["gamma/m-gamma","alpha/m-alpha"],"routing":"manual","pick":"alpha/m-alpha","disabled":true},
      {"id":"auto-m-alpha","name":"m-alpha","members":["alpha/m-alpha","beta/m-alpha"],"auto":true,"ref":"auto/m-alpha"},
      {"name":"no id"},
      "junk"
    ],
    "models":[{"id":"alpha/m-alpha","name":"Model Alpha","providerName":"Alpha"}],
    "gatewayKeys":[{"id":"k1"}]}
    """

    @Test func decodesGroups() throws {
        let groups = try RoutingDecoding.groups(from: Data(Self.sample.utf8))
        #expect(groups.map(\.id) == ["coder", "fast-lane", "auto-m-alpha"])

        let coder = groups[0]
        #expect(coder.mode == .order)
        #expect(coder.ref == "group/coder")
        #expect(coder.members.map(\.id) == ["alpha/m-alpha", "beta/m-beta", "gamma/m-gamma"])
        #expect(coder.members[0].title == "Model Alpha")
        #expect(coder.members[0].providerName == "Alpha")
        #expect(coder.members[1].title == "m-beta")
        #expect(coder.members[1].ready == false)
        // A pick left over from Manual doesn't count under In order.
        #expect(coder.primaryID == "alpha/m-alpha")

        let fast = groups[1]
        #expect(fast.mode == .manual)
        #expect(fast.disabled)
        #expect(fast.primaryID == "alpha/m-alpha")
        #expect(fast.ref == "group/fast-lane")

        let auto = groups[2]
        #expect(auto.auto)
        #expect(auto.mode == .smart)
        #expect(auto.routing == "")
    }

    @Test func acceptsOneGroupAndBareArrays() throws {
        let one = Data(#"{"id":"coder","name":"Coder","members":["a/x"]}"#.utf8)
        #expect(try RoutingDecoding.groups(from: one).map(\.id) == ["coder"])
        #expect(try RoutingDecoding.groups(from: Data("[]".utf8)).isEmpty)
        #expect(throws: RoutingDecoding.Failure.self) { try RoutingDecoding.groups(from: Data(#"{"x":1}"#.utf8)) }
        #expect(throws: (any Error).self) { try RoutingDecoding.groups(from: Data("<html></html>".utf8)) }
    }

    @Test func modelPart() {
        #expect(RoutingDecoding.modelPart(of: "claude/claude-opus-5-5") == "claude-opus-5-5")
        #expect(RoutingDecoding.modelPart(of: "openrouter/anthropic/x") == "anthropic/x")
        #expect(RoutingDecoding.modelPart(of: "alpha/m-alpha#me@example.com") == "m-alpha")
        #expect(RoutingDecoding.modelPart(of: "plain") == "plain")
    }

    @Test func movesMemberToTop() throws {
        let coder = try #require(try RoutingDecoding.groups(from: Data(Self.sample.utf8)).first)
        #expect(coder.membersWithFirst("gamma/m-gamma") == ["gamma/m-gamma", "alpha/m-alpha", "beta/m-beta"])
        #expect(coder.membersWithFirst("nope/x") == coder.members.map(\.id))
    }

    @Test func routingValues() {
        #expect(RoutingMode(raw: "") == .smart)
        #expect(RoutingMode(raw: "Order") == .order)
        #expect(RoutingMode(raw: "plug/mine") == .other("plug/mine"))
        #expect(RoutingMode.smart.raw == "")
        #expect(!RoutingMode.offered.contains(.weight))
        #expect(RoutingMode.offered.count == 11)
        #expect(RoutingMode.offered.first == .smart)
        #expect(RoutingMode.order.label == "按顺序")
        #expect(RoutingMode.rotate.label == "轮换")
        #expect(RoutingMode.other("plug/mine").label == "plug/mine")
        #expect(!RoutingMode.other("plug/mine").isOffered)
    }

    @Test func primaryOnlyWhereTheModeHasOne() {
        let with: [RoutingMode] = [.order, .drain, .rotate, .manual]
        let without: [RoutingMode] = [.smart, .usage, .pace, .free, .fast, .cheap, .expiring, .weight, .other("p/x")]
        let withAll = with.allSatisfy { $0.hasPrimary }
        let withoutAny = without.contains { $0.hasPrimary }
        #expect(withAll)
        #expect(!withoutAny)
        let smart = Self.group(routing: "")
        #expect(smart.shownPrimaryID == nil)
        #expect(Self.group(routing: "order").shownPrimaryID == "a/x")
        #expect(Self.group(routing: "manual", pick: "c/z").shownPrimaryID == "c/z")
        // A pick that left the group: the first model.
        #expect(Self.group(routing: "manual", pick: "gone/q").shownPrimaryID == "a/x")
    }

    @Test func footerSwapsByModeAndIsNeverEmpty() {
        #expect(RoutingMode.order.footer == ["先用首选，用不了会自动往下用。"])
        #expect(RoutingMode.drain.footer == ["先用首选，用不了会自动往下用。"])
        #expect(RoutingMode.manual.footer == ["只用选定的这一个。它用不了时不会换别的，会直接报错。"])
        #expect(RoutingMode.smart.footer == ["额度最先续上的先用；快用完的往后排。"])
        #expect(RoutingMode.weight.footer == ["按电脑上设好的比例分配。", "要在电脑上改"])
        #expect(RoutingMode.other("p/x").footer == ["要在电脑上改"])
        let all: [RoutingMode] = RoutingMode.offered + [.weight, .other("p/x")]
        let neverEmpty = all.allSatisfy { !$0.footer.isEmpty }
        #expect(neverEmpty)
    }

    /// A three-member group in the given mode.
    static func group(routing: String, pick: String? = nil) -> RoutingGroup {
        let members = ["a/x", "b/y", "c/z"].map { RoutingMember(id: $0, title: $0, providerName: nil, ready: true) }
        return RoutingGroup(id: "g", name: "G", members: members, routing: routing, pick: pick,
                            disabled: false, auto: false, ref: "group/g")
    }

    @Test func chainStrings() {
        let order = RoutingChain(Self.group(routing: "order"))
        #expect(order.lead == "x")
        #expect(order.text == "x → y → z")
        #expect(order.spoken == "x，y，z")
        #expect(RoutingChain(Self.group(routing: "drain")).text == "x → y → z")
        let manual = RoutingChain(Self.group(routing: "manual", pick: "c/z"))
        #expect(manual.lead == "z")
        #expect(manual.text == "z · 另有 2 个")
        let smart = RoutingChain(Self.group(routing: ""))
        #expect(smart.lead == nil)
        #expect(smart.text == "x · y · z")
        #expect(RoutingChain(Self.group(routing: "rotate")).text == "x · y · z")
        var alone = Self.group(routing: "manual")
        alone.members = [alone.members[0]]
        #expect(RoutingChain(alone).text == "x")
        var empty = Self.group(routing: "order")
        empty.members = []
        #expect(RoutingChain(empty).text == "")
    }

    @Test func modeMenuSections() {
        #expect(RoutingMode.common == [.order, .smart, .drain, .manual])
        #expect(RoutingMode.more == [.rotate, .usage, .pace, .free, .fast, .cheap, .expiring])
        #expect(Set(RoutingMode.common + RoutingMode.more) == Set(RoutingMode.offered))
        #expect(RoutingMode.order.membersHeader == "组里的模型 · 从上往下用")
        #expect(RoutingMode.drain.membersHeader == "组里的模型 · 从上往下用")
        #expect(RoutingMode.manual.membersHeader == "组里的模型")
        #expect(RoutingMode.smart.membersHeader == "组里的模型")
        #expect(Self.group(routing: "order").agentModel == "group/g")
    }

    /// 设为首选's three branches.
    @Test func makePrimaryInOrderJustReorders() {
        let change = Self.group(routing: "order").primaryChange(to: "c/z")
        #expect(change == .reorder(["c/z", "a/x", "b/y"]))
        #expect(!change.needsConfirm)
    }

    @Test func makePrimaryInManualSetsThePick() {
        let change = Self.group(routing: "manual", pick: "a/x").primaryChange(to: "b/y")
        #expect(change == .pick("b/y"))
        #expect(!change.needsConfirm)
    }

    @Test(arguments: ["", "drain", "rotate", "usage", "pace", "free", "fast", "cheap", "expiring", "weight", "plug/mine"])
    func makePrimaryElsewhereSwitchesToOrderAfterConfirm(routing: String) {
        let change = Self.group(routing: routing).primaryChange(to: "b/y")
        #expect(change == .switchToOrder(["b/y", "a/x", "c/z"], from: RoutingMode(raw: routing)))
        #expect(change.needsConfirm)
    }

    @Test func mapsErrors() {
        let notAdmin = Data(#"{"error":{"code":"gateway_key_not_admin","message":"this gateway key may not manage magpie","type":"permission_error"}}"#.utf8)
        #expect(RoutingError.from(status: 403, body: notAdmin) == .notAdmin)
        let browser = Data(#"{"error":{"code":"admin_browser_refused","message":"no browsers"}}"#.utf8)
        #expect(RoutingError.from(status: 403, body: browser) == .rejected(status: 403, reason: "no browsers"))
        #expect(RoutingError.from(status: 401, body: Data()) == .unauthorized)
        let empty = Data(#"{"error":"a group needs a model in it, or a pattern its models match"}"#.utf8)
        #expect(RoutingError.from(status: 400, body: empty).reason == "a group needs a model in it, or a pattern its models match")
        #expect(RoutingError.from(status: 404, body: Data(#"{"error":"magpie has no routing group \"x\""}"#.utf8)) == .rejected(status: 404, reason: "magpie has no routing group \"x\""))
        #expect(RoutingError.from(status: 502, body: Data()) == .other("502"))
    }

    @Test func errorCopy() {
        #expect(RoutingError.rejected(status: 400, reason: "x").message == "没改成，一切保持原样。")
        #expect(RoutingError.unauthorized.message == "密钥对不上了，可能已在电脑上删掉。到「设置 → 电脑」重新填一把。")
        #expect(RoutingError.notAdmin.message == "这把密钥不能改路由组。在电脑的 magpie 里，密钥菜单 → 高级 → 管理 API，选「任何电脑均可」。")
        #expect(RoutingError.timeout.isOffline)
        #expect(!RoutingError.notAdmin.isOffline)
    }
}

/// Connect error wording, including Local Network denial.
struct ErrorCopyTests {
    @Test func quotaErrors() {
        #expect(QuotaError.unauthorized.message == "密钥对不上。回电脑上的 magpie 再复制一次。")
        #expect(QuotaError.forbidden.message == "这把密钥还不能看额度。在 magpie 里给它打开「可看额度」。")
        #expect(QuotaError.other("502").message == "出了点问题（代码 502），稍后再试。")
    }

    @Test func localNetworkDenialIsRecognised() {
        let path = "unsatisfied (Local network prohibited), interface: en0"
        let error = URLError(.notConnectedToInternet, userInfo: ["_NSURLErrorNWPathKey": path])
        #expect(TransportFailure.isLocalNetworkDenied(error))
        #expect(!TransportFailure.isLocalNetworkDenied(URLError(.cannotConnectToHost)))
    }
}
