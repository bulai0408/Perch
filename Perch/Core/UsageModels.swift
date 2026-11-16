import Foundation

/// The periods magpie's `/usage` routes take. Anything else (the docs'
/// `week` and `month` among them, on 0.1.4266) silently reads as `30d`.
enum UsagePeriod: String, CaseIterable, Sendable {
    case today
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case all
}

/// The agent id magpie gives Claude Code (`agent`), shown as `agentName`
/// "Claude Code". magpie tells it by its User-Agent (`claude-cli/…`).
/// The Agent tab defaults to it.
enum ClaudeCode {
    /// magpie's agent id for Claude Code.
    static let agentID = "claude"
}

/// Sums magpie keeps for a period, a split row or a page.
struct UsageTotals: Equatable, Sendable {
    /// Requests counted.
    var calls = 0
    /// Requests that failed.
    var errors = 0
    /// Input tokens (uncached).
    var input = 0
    /// Output tokens.
    var output = 0
    /// Cache-read input tokens.
    var cacheRead = 0
    /// Cache-write input tokens.
    var cacheWrite = 0
    /// Reasoning tokens (already part of `output` for most vendors).
    var reasoning = 0
    /// USD at API prices: for a subscription account's calls an
    /// API-equivalent estimate, not what the subscription charges.
    var cost = 0.0
    /// Calls with no known price (not in `cost`).
    var unpriced = 0
    /// 1.4: answered after a failed try (magpie handed it on).
    var retried = 0

    /// Every token in and out (reasoning excluded: counted in output).
    var tokens: Int { input + output + cacheRead + cacheWrite }
    /// There were calls and none of them had a price.
    var allUnpriced: Bool { calls > 0 && unpriced >= calls }

    /// Adds one request to the sums.
    mutating func add(_ row: UsageRow) {
        calls += 1
        if row.failed { errors += 1 }
        if row.switched { retried += 1 }
        input += row.input
        output += row.output
        cacheRead += row.cacheRead
        cacheWrite += row.cacheWrite
        reasoning += row.reasoning
        if let c = row.cost, row.priced != false { cost += c } else { unpriced += 1 }
    }
}

/// One line of a split: an agent, model, provider, account or key.
struct UsageBucket: Equatable, Sendable, Identifiable {
    var id: String
    /// Display name, else the id.
    var name: String
    /// For model rows: the provider that served it.
    var provider: String?
    /// The newest call in this bucket.
    var last: Date?
    var totals: UsageTotals
}

/// `GET /v1/magpie/usage?period=`.
struct UsageSummary: Equatable, Sendable {
    /// The period magpie applied (`today`, `7d`…).
    var period: String
    /// Where the period starts.
    var since: Date?
    var totals: UsageTotals
    var agents: [UsageBucket]
    var models: [UsageBucket]
    var accounts: [UsageBucket]
    /// Distinct sessions in the period.
    var sessionCount: Int

    /// The agent split row for `id`.
    func agent(_ id: String) -> UsageBucket? { agents.first { $0.id == id } }
}

/// Filters of `/usage/requests` (the Requests log's).
struct UsageFilter: Equatable, Sendable {
    var period: UsagePeriod = .today
    var agent: String? = ClaudeCode.agentID
    var model: String?
    var provider: String?
    var account: String?
    var failedOnly = false
    /// 1.4 「换过账号的」: answered after a failed try (`retried=1`).
    var retriedOnly = false

    /// Claude Code, today: the Agent tab's default.
    static let claudeCodeToday = UsageFilter()

    /// The filter as `/usage/requests` query parameters.
    var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "period", value: period.rawValue)]
        if let agent, !agent.isEmpty { items.append(.init(name: "agent", value: agent)) }
        if let model, !model.isEmpty { items.append(.init(name: "model", value: model)) }
        if let provider, !provider.isEmpty { items.append(.init(name: "provider", value: provider)) }
        if let account, !account.isEmpty { items.append(.init(name: "account", value: account)) }
        if failedOnly { items.append(.init(name: "failed", value: "1")) }
        if retriedOnly { items.append(.init(name: "retried", value: "1")) }
        return items
    }
}

/// One request (never a session or model total).
struct UsageRow: Hashable, Sendable, Identifiable {
    var id: String
    var time: Date?
    var agent: String
    var agentName: String?
    var session: String?
    /// What the agent asked for (`req`): `group/<id>`, `provider/model`…
    var requested: String?
    /// What the vendor was asked (`model`) and said it served (`served`).
    var model: String
    var served: String?
    var provider: String?
    var providerName: String?
    /// The subscription account that answered (`providerAccount`), if any.
    var account: String?
    var status: Int
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int
    var reasoning: Int
    var cost: Double?
    var priced: Bool?
    var ms: Int?
    var error: String?
    /// 1.4: the vendor's own error type (`rate_limit_error`…), how many
    /// tries magpie made, how long the failed ones took, and whether
    /// magpie refused it itself (an unknown model).
    var errorType: String? = nil
    var tries: Int? = nil
    var retriedMs: Int? = nil
    var rejected: Bool = false

    /// HTTP error, or no status but an error text.
    var failed: Bool { status >= 400 || status == 0 && error != nil }
    /// magpie handed the call on after a failed try and it was answered.
    var switched: Bool { !failed && ((tries ?? 1) > 1 || (retriedMs ?? 0) > 0) }
    /// The model as Perch shows it: what was served, else what was asked.
    var shownModel: String { served.flatMap { $0.isEmpty ? nil : $0 } ?? model }
}

/// One bar of the Agent tab's chart.
struct UsageSeriesPoint: Equatable, Sendable, Identifiable {
    var time: Date
    var label: String
    var totals: UsageTotals
    var id: Date { time }
}

/// `GET /v1/magpie/usage/requests` (offset mode).
struct UsageRequestsPage: Equatable, Sendable {
    var period: String
    /// Index of the first row of this page.
    var offset: Int
    /// Rows matching the filters, across all pages.
    var total: Int
    var rows: [UsageRow]
    /// Totals of every row the filters keep, not just this page.
    var totals: UsageTotals
    var byModel: [UsageBucket]
    var byModelAt: [UsageBucket]
    var byProvider: [UsageBucket]
    /// `by.account` when magpie sends it (not seen on 0.1.4266).
    var byAccount: [UsageBucket]
    /// Accounts the Account filter offers.
    var accountNames: [String]
    /// Per bucket (`bucket`: hour for today, day for 7d), oldest first.
    var series: [UsageSeriesPoint] = []
    var bucket: String = ""

    /// More rows exist after this page.
    var hasMore: Bool { offset + rows.count < total }
}

// MARK: - Aggregation

/// Client-side splits of usage rows, for when magpie sends none.
enum UsageAggregation {
    /// Splits rows by the account that answered; calls no account served
    /// (an API key) go under "" so the caller can label or drop them.
    static func byAccount(_ rows: [UsageRow]) -> [UsageBucket] {
        split(rows) { $0.account ?? "" }
    }

    /// Splits rows by the model shown (served, else asked).
    static func byModel(_ rows: [UsageRow]) -> [UsageBucket] {
        split(rows) { $0.shownModel }
    }

    /// Groups rows by `key`, most tokens first (ties by id).
    private static func split(_ rows: [UsageRow], key: (UsageRow) -> String) -> [UsageBucket] {
        var buckets: [String: UsageBucket] = [:]
        for row in rows {
            let k = key(row)
            var bucket = buckets[k] ?? UsageBucket(id: k, name: k, provider: row.provider, last: nil, totals: UsageTotals())
            bucket.totals.add(row)
            if let t = row.time, bucket.last.map({ t > $0 }) ?? true { bucket.last = t }
            buckets[k] = bucket
        }
        return buckets.values.sorted { ($0.totals.tokens, $1.id) > ($1.totals.tokens, $0.id) }
    }

    /// The subscription-account split of a page: `by.account` when magpie
    /// sends it, else summed from the rows Perch has read.
    static func accounts(_ page: UsageRequestsPage) -> [UsageBucket] {
        page.byAccount.isEmpty ? byAccount(page.rows).filter { !$0.id.isEmpty } : page.byAccount
    }
}

/// Where an agent's latest call went, read from `req` of its newest
/// usage row. magpie has no route that says what an agent is set to.
enum AgentTarget: Equatable, Sendable {
    /// The agent asked for routing group `id`.
    case group(id: String, at: Date?)
    /// The agent asked for a model directly.
    case direct(model: String, at: Date?)

    /// The target of `agent`'s newest row (any agent when nil), or nil
    /// without rows.
    static func latest(_ rows: [UsageRow], agent: String? = ClaudeCode.agentID, groups: [RoutingGroup]) -> AgentTarget? {
        let mine = rows.filter { (agent == nil || $0.agent == agent) && !($0.requested ?? $0.model).isEmpty }
        guard let row = mine.max(by: { ($0.time ?? .distantPast) < ($1.time ?? .distantPast) }) else { return nil }
        let asked = row.requested ?? row.model
        if let id = groupID(asked, groups: groups) { return .group(id: id, at: row.time) }
        return .direct(model: asked, at: row.time)
    }

    /// `group/<id>` (`magpie/group/<id>` too), or a group's bare id or
    /// name, which the gateway also routes to the group.
    static func groupID(_ asked: String, groups: [RoutingGroup]) -> String? {
        var text = asked.trimmed
        if text.hasPrefix("magpie/") { text.removeFirst("magpie/".count) }
        if text.hasPrefix("group/") {
            let id = String(text.dropFirst("group/".count))
            return id.isEmpty ? nil : id
        }
        return groups.first { $0.id == text || $0.name == text }?.id
    }
}

// MARK: - Decoding

/// Lenient decoders for magpie's usage routes.
///
/// `GET /v1/magpie/usage`: `{"period","since",<totals>,"agents":[bucket],
/// "models":[bucket],"accounts":[bucket],"sessionCount"}`.
/// `GET /v1/magpie/usage/requests`: `{"period","offset","total",<totals>,
/// "rows":[row],"by":{"model","modelAt","provider","account"},
/// "accounts":[…],"series":[{"time","label",<totals>}],"bucket"}`.
/// Totals: `calls, errors, input, output, cache_read, cache_write,
/// reasoning, cost, unpriced, retried`. Bucket: `{"id","name","provider",
/// "last",<totals>}`.
enum UsageDecoding {
    /// Decodes `/usage`; nil when the body isn't a JSON object.
    static func summary(from data: Data) -> UsageSummary? {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return UsageSummary(
            period: QuotaDecoding.string(d["period"]) ?? "",
            since: QuotaDecoding.date(d["since"]),
            totals: totals(d),
            agents: buckets(d["agents"]),
            models: buckets(d["models"]),
            accounts: buckets(d["accounts"]),
            sessionCount: int(d["sessionCount"])
        )
    }

    /// Decodes `/usage/requests`; nil when the body isn't a JSON object.
    static func requestsPage(from data: Data) -> UsageRequestsPage? {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let rows = (d["rows"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(row) }
        let by = d["by"] as? [String: Any] ?? [:]
        let accountNames: [String] = (d["accounts"] as? [Any] ?? []).compactMap {
            if let s = $0 as? String { return s }
            guard let a = $0 as? [String: Any] else { return nil }
            return QuotaDecoding.string(a["id"]) ?? QuotaDecoding.string(a["name"])
        }
        return UsageRequestsPage(
            period: QuotaDecoding.string(d["period"]) ?? "",
            offset: int(d["offset"]),
            total: d["total"] == nil ? rows.count : int(d["total"]),
            rows: rows,
            totals: totals(d),
            byModel: buckets(by["model"]),
            byModelAt: buckets(by["modelAt"]),
            byProvider: buckets(by["provider"]),
            byAccount: buckets(by["account"]),
            accountNames: accountNames,
            series: series(d["series"]),
            bucket: QuotaDecoding.string(d["bucket"]) ?? ""
        )
    }

    /// One row: `{"id","t","agent","agentName","session","req","model",
    /// "served","provider","providerName","providerAccount","status","in",
    /// "out","cache_read","cache_write","reasoning","cost","priced","ms",
    /// "err","err_type","tries","retried_ms","rejected"}`.
    static func row(_ d: [String: Any]) -> UsageRow? {
        let s = { (k: String) in QuotaDecoding.string(d[k]).flatMap { $0.isEmpty ? nil : $0 } }
        let time = QuotaDecoding.date(d["t"])
        let model = s("model") ?? s("req") ?? ""
        let agent = s("agent") ?? ""
        let id = s("id") ?? [d["t"].flatMap { QuotaDecoding.string($0) } ?? "", agent, model, s("session") ?? ""].joined(separator: "|")
        return UsageRow(
            id: id,
            time: time,
            agent: agent,
            agentName: s("agentName"),
            session: s("session"),
            requested: s("req"),
            model: model,
            served: s("served"),
            provider: s("provider"),
            providerName: s("providerName"),
            account: s("providerAccount") ?? s("account"),
            status: int(d["status"]),
            input: int(d["in"] ?? d["input"]),
            output: int(d["out"] ?? d["output"]),
            cacheRead: int(d["cache_read"]),
            cacheWrite: int(d["cache_write"]),
            reasoning: int(d["reasoning"]),
            cost: QuotaDecoding.number(d["cost"]),
            priced: d["priced"] as? Bool,
            ms: d["ms"] == nil ? nil : int(d["ms"]),
            error: s("err") ?? s("error"),
            errorType: s("err_type") ?? s("errType"),
            tries: d["tries"] == nil ? nil : int(d["tries"]),
            retriedMs: d["retried_ms"] == nil ? nil : int(d["retried_ms"]),
            rejected: d["rejected"] as? Bool ?? false
        )
    }

    /// Chart points, oldest first; points without a time are skipped.
    static func series(_ value: Any?) -> [UsageSeriesPoint] {
        (value as? [Any] ?? []).compactMap { item in
            guard let d = item as? [String: Any], let time = QuotaDecoding.date(d["time"]) else { return nil }
            return UsageSeriesPoint(time: time, label: QuotaDecoding.string(d["label"]) ?? "", totals: totals(d))
        }
        .sorted { $0.time < $1.time }
    }

    /// The totals fields of any object (missing → 0).
    static func totals(_ d: [String: Any]) -> UsageTotals {
        UsageTotals(
            calls: int(d["calls"]),
            errors: int(d["errors"]),
            input: int(d["input"]),
            output: int(d["output"]),
            cacheRead: int(d["cache_read"]),
            cacheWrite: int(d["cache_write"]),
            reasoning: int(d["reasoning"]),
            cost: QuotaDecoding.number(d["cost"]) ?? 0,
            unpriced: int(d["unpriced"]),
            retried: int(d["retried"])
        )
    }

    /// Split rows; rows without an `id` are skipped.
    static func buckets(_ value: Any?) -> [UsageBucket] {
        (value as? [Any] ?? []).compactMap { item in
            guard let d = item as? [String: Any], let id = QuotaDecoding.string(d["id"]) else { return nil }
            return UsageBucket(
                id: id,
                name: QuotaDecoding.string(d["name"]) ?? QuotaDecoding.string(d["model"]) ?? id,
                provider: QuotaDecoding.string(d["provider"]),
                last: QuotaDecoding.date(d["last"]),
                totals: totals(d)
            )
        }
    }

    /// A number or numeric string, rounded; 0 otherwise.
    static func int(_ value: Any?) -> Int {
        guard let n = QuotaDecoding.number(value), n.isFinite else { return 0 }
        return Int(n.rounded())
    }

    /// The string elements of an array.
    static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { QuotaDecoding.string($0) }
    }
}
