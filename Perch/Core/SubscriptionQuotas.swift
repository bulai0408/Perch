import Foundation

/// What a subscription window measures, read from its `name`/`lane`.
/// magpie's text form names them `5h` and `7d`; a model's own weekly
/// window (Opus's) names the model. Names on a real Claude card are
/// unverified (the probe had no Claude account), so matching is loose.
enum WindowKind: Equatable, Hashable, Sendable {
    case fiveHour
    case weekly
    /// A weekly window that counts one model only, e.g. "Opus".
    case modelWeekly(String)
    case other

    /// Model families that have their own weekly windows.
    static let modelNames = ["opus", "sonnet", "haiku", "fable"]

    /// Reads the kind from the window's name and lane (case, spaces and
    /// dashes aside). A model name wins over 「weekly」, not over 「5h」.
    static func classify(_ window: QuotaWindow) -> WindowKind {
        let text = ([window.name] + [window.lane].compactMap { $0 }).joined(separator: " ").lowercased()
        let compact = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        let model = modelNames.first { text.contains($0) }
        let isFive = compact.contains("5h") || compact.contains("5hour") || compact.contains("fivehour") || compact.contains("session")
        let isWeek = compact.contains("7d") || compact.contains("week") || compact.contains("7day")
        if let model, !isFive { return .modelWeekly(model.prefix(1).uppercased() + model.dropFirst()) }
        if isFive { return .fiveHour }
        if isWeek { return .weekly }
        return .other
    }

    /// Order on the card: 5 小时, 每周, then model windows.
    var rank: Int {
        switch self {
        case .fiveHour: 0
        case .weekly: 1
        case .modelWeekly: 2
        case .other: 3
        }
    }
}

/// One window of a subscription account, with its kind.
struct AccountWindow: Equatable, Hashable, Sendable, Identifiable {
    var kind: WindowKind
    var window: QuotaWindow

    var id: String { window.name }
    /// % left, 0…100: `remaining`, else 100 − `used`.
    var percentLeft: Double? {
        if window.unlimited { return 100 }
        if let r = window.remaining { return min(max(r, 0), 100) }
        if let u = window.used { return min(max(100 - u, 0), 100) }
        return nil
    }
    /// When the window resets.
    var resetsAt: Date? { window.resetsAt }
}

/// A subscription account's card (Claude, Codex, Kimi…), with its
/// windows sorted out. Every provider gets the same detail; Claude's
/// grouping and tint are presentation only.
struct SubscriptionAccount: Equatable, Hashable, Sendable, Identifiable {
    var card: QuotaCard
    /// Windows sorted by kind (5 小时, 每周, model windows), then magpie's order.
    var windows: [AccountWindow]
    /// Served the latest call through the gateway (刚刚在用).
    var lastServed: Bool
    /// When it last served a call (from `/v1/magpie/quotas`).
    var lastServedAt: Date?

    var id: String { card.id }
    var title: String { card.title }
    /// The login magpie's `login/on|off` takes as `user`.
    var user: String? { card.user }
    var plan: String? { card.plan?.trimmed.isEmpty == false ? card.plan : nil }
    var off: Bool { card.off }
    /// The provider's own id, without a remote magpie's `office/` prefix.
    var providerKey: String { SubscriptionAccounts.providerKey(card.provider) }
    /// What `login/on|off` takes as `agent`: the provider's id
    /// (`claude`, `codex`, …), as magpie's own UI sends it.
    var loginAgent: String { providerKey }
    var isClaude: Bool { SubscriptionAccounts.isClaude(card) }
    /// A remote magpie's card can't be switched from here.
    var isRemote: Bool { card.from?.isEmpty == false || card.provider.contains("/") }
    /// Can be switched on/off from Perch (local, with a login).
    var canToggle: Bool { !isRemote && user?.isEmpty == false }

    /// The 5-hour window, if any.
    var fiveHour: AccountWindow? { windows.first { $0.kind == .fiveHour } }
    /// The all-models weekly window, if any.
    var weekly: AccountWindow? { windows.first { $0.kind == .weekly } }
    /// Per-model weekly windows.
    var modelWeekly: [AccountWindow] { windows.filter { if case .modelWeekly = $0.kind { true } else { false } } }
}

/// Accounts of one provider, as 额度 groups them.
struct ProviderGroup: Equatable, Sendable, Identifiable {
    /// The provider key (`claude` for every Claude card).
    var provider: String
    /// The provider's display name.
    var name: String
    var accounts: [SubscriptionAccount]
    var id: String { provider }
    var isClaude: Bool { provider == "claude" }
}

/// Derives `SubscriptionAccount`s from quota cards. Pure.
enum SubscriptionAccounts {
    /// The provider id, lowercased, without a remote magpie's `office/` prefix.
    static func providerKey(_ provider: String) -> String {
        let lower = provider.lowercased()
        return lower.split(separator: "/").last.map(String.init) ?? lower
    }

    /// Claude cards (`claude`, `claude-*`, or named Claude…) group together.
    static func isClaude(_ card: QuotaCard) -> Bool {
        let key = providerKey(card.provider)
        return key == "claude" || key.hasPrefix("claude-") || card.name.lowercased().hasPrefix("claude")
    }

    /// Subscription accounts from `/quotas/cards` (kind `subscription`),
    /// marked with `/quotas`' `last`/`lastServedAt` (by card id) when read.
    static func accounts(cards: [QuotaCard], served: [QuotaCard] = []) -> [SubscriptionAccount] {
        let servedByID = Dictionary(served.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return cards.filter { $0.kind == "subscription" }.map { card in
            let s = servedByID[card.id]
            let windows = card.windows
                .map { AccountWindow(kind: WindowKind.classify($0), window: $0) }
                .enumerated()
                .sorted { ($0.element.kind.rank, $0.offset) < ($1.element.kind.rank, $1.offset) }
                .map(\.element)
            return SubscriptionAccount(
                card: card,
                windows: windows,
                lastServed: s?.last ?? card.last,
                lastServedAt: s?.lastServedAt ?? card.lastServedAt
            )
        }
    }

    /// Accounts by provider, the provider used most recently first
    /// (newest `lastServedAt`, then the most tokens in `usage` accounts,
    /// then magpie's order). Accounts keep magpie's order inside a group.
    static func groups(_ accounts: [SubscriptionAccount], usage: [UsageBucket] = []) -> [ProviderGroup] {
        var order: [String] = []
        var byProvider: [String: [SubscriptionAccount]] = [:]
        for account in accounts {
            let key = account.isClaude ? "claude" : account.providerKey
            if byProvider[key] == nil { order.append(key) }
            byProvider[key, default: []].append(account)
        }
        func tokens(_ list: [SubscriptionAccount]) -> Int {
            list.reduce(0) { sum, a in
                sum + (usage.first { $0.id == a.user || $0.name == a.user || $0.id == a.title }?.totals.tokens ?? 0)
            }
        }
        let ranked = order.enumerated().map { index, key -> (String, Date, Int, Int) in
            let list = byProvider[key] ?? []
            let last = list.compactMap(\.lastServedAt).max() ?? (list.contains(where: \.lastServed) ? .distantFuture : .distantPast)
            return (key, last, tokens(list), index)
        }
        .sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.2 != b.2 { return a.2 > b.2 }
            return a.3 < b.3
        }
        return ranked.map { key, _, _, _ in
            let list = byProvider[key] ?? []
            let card = list.first?.card
            let name = key == "claude" ? "Claude" : (card.map { $0.name.isEmpty ? $0.provider : $0.name } ?? key)
            return ProviderGroup(provider: key, name: name, accounts: list)
        }
    }

    /// Accounts of the same provider left serving if `account` is off.
    static func usableAfterDisabling(_ account: SubscriptionAccount, in all: [SubscriptionAccount]) -> Int {
        all.filter { $0.id != account.id && !$0.off && $0.providerKey == account.providerKey }.count
    }
}

// MARK: - Quota history

/// `GET /v1/magpie/quotas/history`. magpie (0.1.43xx) answers
/// `{"object":"list","data":[{"provider","user","lines":[{"name",
/// "points":[{"at","left","start","resetsAt"}]}]}]}`: one item per
/// account, `user` lowercased (empty when the account has none), a line
/// per card window named as the card names it ("5 hours", "7 days",
/// "7 days · Fable", a pool's "gemini · 5 hours"), `left` the % left.
/// Older guesses (`windows`, flat samples, `used`/`remaining`, [t, used]
/// pairs) are still read. Anything not understood is skipped; only a
/// reply with nothing recognisable at all is `.unrecognized`.
enum QuotaHistory: Equatable, Sendable {
    /// magpie answered with no history (or Perch couldn't read it at all and
    /// had nothing before).
    case empty
    /// One series per account window.
    case series([QuotaHistorySeries])
    /// A reply whose shape this version doesn't understand.
    case unrecognized
}

/// One window's history for one account.
struct QuotaHistorySeries: Equatable, Sendable, Identifiable {
    var provider: String
    /// The account login (magpie lowercases it); nil for a provider-wide series.
    var user: String?
    /// The window name, as the card names it.
    var window: String
    /// Oldest first.
    var points: [QuotaHistoryPoint]

    var id: String { [provider, user ?? "", window].joined(separator: "|") }
    /// The window's kind, read from its name.
    var kind: WindowKind {
        WindowKind.classify(QuotaWindow(name: window, unlimited: false, text: false))
    }

    /// Same provider (as the card names it, a remote magpie's `office/`
    /// prefix included) and, when the series names one, the same login.
    /// magpie lowercases `user` in its history, so case is ignored.
    func belongs(to card: QuotaCard) -> Bool {
        guard provider.caseInsensitiveCompare(card.provider) == .orderedSame else { return false }
        guard let user = user?.trimmingCharacters(in: .whitespaces), !user.isEmpty else { return true }
        return [card.user, card.alias].contains { $0?.caseInsensitiveCompare(user) == .orderedSame }
    }
}

/// One history reading.
struct QuotaHistoryPoint: Equatable, Sendable {
    var time: Date
    /// % used then.
    var used: Double
}

/// Lenient decoder for `GET /v1/magpie/quotas/history` (see `QuotaHistory`).
enum QuotaHistoryDecoding {
    /// Decodes the reply. Series with the same provider, user and window are
    /// merged and their points sorted by time.
    static func history(from data: Data) -> QuotaHistory {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return .unrecognized }
        guard let items = items(object) else { return .unrecognized }
        if items.isEmpty { return .empty }

        var series: [String: QuotaHistorySeries] = [:]
        var order: [String] = []
        /// Some item had a shape this knows, even if no point was usable.
        var understood = false
        func add(_ provider: String, _ user: String?, _ window: String, _ points: [QuotaHistoryPoint]) {
            guard !points.isEmpty else { return }
            let s = QuotaHistorySeries(provider: provider, user: user, window: window, points: points)
            if series[s.id] == nil { order.append(s.id); series[s.id] = s } else { series[s.id]!.points += points }
        }

        for item in items {
            guard let item = item as? [String: Any] else { continue }
            let provider = QuotaDecoding.string(item["provider"]) ?? ""
            let user = (QuotaDecoding.string(item["user"]) ?? QuotaDecoding.string(item["account"]))
                .flatMap { $0.isEmpty ? nil : $0 }
            // An account with its windows' lines (magpie's `lines`).
            if let raw = item["lines"] ?? item["windows"] ?? item["series"] {
                for (name, rawPoints) in lines(raw) {
                    understood = true
                    add(provider, user, name, points(rawPoints))
                }
                if raw is [Any] || raw is [String: Any] { understood = true }
                continue
            }
            let name = QuotaDecoding.string(item["window"]) ?? QuotaDecoding.string(item["name"]) ?? ""
            // A series with its points.
            if let raw = item["points"] ?? item["samples"] {
                understood = true
                add(provider, user, name, points(raw))
                continue
            }
            // One flat sample.
            if let p = point(item) {
                understood = true
                add(provider, user, name, [p])
            }
        }
        if order.isEmpty { return understood ? .empty : .unrecognized }
        return .series(order.compactMap { id in
            series[id].map { var s = $0; s.points.sort { $0.time < $1.time }; return s }
        })
    }

    /// The reply's account items: `data` (or `items`/`histories`) of an
    /// envelope, a bare list, or magpie's history file form
    /// `{"provider|user": {"window": [points]}}`, made into items.
    /// nil: no list anywhere.
    static func items(_ object: Any) -> [Any]? {
        if let list = object as? [Any] { return list }
        guard let d = object as? [String: Any] else { return nil }
        if d.isEmpty { return [] }
        for key in ["data", "items", "histories", "history"] {
            switch d[key] {
            case let list as [Any]: return list
            case is NSNull: return []
            case let inner as [String: Any]:
                if let list = items(inner) { return list }
            default: break
            }
        }
        // `{"object":"list"}` with no data is an empty list.
        if d["data"] == nil, QuotaDecoding.string(d["object"]) == "list" { return [] }
        let file = d.compactMap { key, value -> [String: Any]? in
            guard key.contains("|"), let windows = value as? [String: Any] else { return nil }
            let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return ["provider": parts[0], "user": parts.count > 1 ? parts[1] : "", "lines": windows]
        }
        return file.isEmpty ? nil : file.sorted { "\($0["provider"]!)|\($0["user"]!)" < "\($1["provider"]!)|\($1["user"]!)" }
    }

    /// (window name, its raw points): a list of `{"name","points"}` or a
    /// map of name → points.
    static func lines(_ raw: Any) -> [(String, Any?)] {
        if let map = raw as? [String: Any] {
            return map.keys.sorted().map { ($0, map[$0]) }
        }
        return (raw as? [Any] ?? []).compactMap { line in
            guard let w = line as? [String: Any] else { return nil }
            let name = QuotaDecoding.string(w["name"]) ?? QuotaDecoding.string(w["window"]) ?? QuotaDecoding.string(w["label"]) ?? ""
            return (name, w["points"] ?? w["samples"] ?? w["history"])
        }
    }

    /// Points from `[{"at","left"|"used"|"remaining"}]` or `[[time, used]]`.
    static func points(_ value: Any?) -> [QuotaHistoryPoint] {
        (value as? [Any] ?? []).compactMap { item in
            if let d = item as? [String: Any] { return point(d) }
            // [time, used] pairs.
            if let pair = item as? [Any], pair.count >= 2, let used = QuotaDecoding.number(pair[1]) {
                if let t = QuotaDecoding.date(pair[0]) { return QuotaHistoryPoint(time: t, used: used) }
                if let n = QuotaDecoding.number(pair[0]) { return QuotaHistoryPoint(time: epoch(n), used: used) }
            }
            return nil
        }
    }

    /// One point: time from `at`/`t`/`time`/`readAt`/`asOf` (RFC 3339 or
    /// epoch), % used from `used`, else 100 − `left`/`remaining`.
    static func point(_ d: [String: Any]) -> QuotaHistoryPoint? {
        let rawTime = d["at"] ?? d["t"] ?? d["time"] ?? d["readAt"] ?? d["asOf"]
        let time = QuotaDecoding.date(rawTime) ?? QuotaDecoding.number(rawTime).map(epoch)
        let left = QuotaDecoding.number(d["left"]) ?? QuotaDecoding.number(d["remaining"])
        let used = QuotaDecoding.number(d["used"]) ?? left.map { 100 - $0 }
        guard let time, let used else { return nil }
        return QuotaHistoryPoint(time: time, used: min(max(used, 0), 100))
    }

    /// Seconds or milliseconds since 1970.
    static func epoch(_ n: Double) -> Date {
        Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
    }
}
