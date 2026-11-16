import Foundation

/// Why a 1.3 read (usage, quota history, limit) or an account
/// switch didn't work, with the line shown for each case.
enum MagpieAPIError: Error, Equatable, Sendable {
    case unreachable
    case timeout
    case localNetworkDenied
    /// 401: wrong, disabled or removed key.
    case unauthorized
    /// 403 `gateway_key_held`: the key is held to a budget, models or
    /// accounts. `/usage` refuses it; `/usage/requests` gives its own rows.
    case held
    /// 403 `gateway_key_read_only`: reads fine, may not change anything.
    case readOnly
    /// 403 `gateway_key_not_admin`: no 管理 API 「任何电脑均可」.
    case notAdmin
    /// 400 "subscription accounts are off in magpie (Settings → Privacy…)".
    case accountsOff
    /// 404/405 on a read: this magpie is older than the route.
    case unsupported
    /// Another 4xx with magpie's own reason (English, shown verbatim).
    case rejected(status: Int, reason: String)
    case other(String)

    /// The localized line Perch shows for this failure.
    var message: String {
        switch self {
        case .unreachable: QuotaError.unreachable.message
        case .timeout: QuotaError.timeout.message
        case .localNetworkDenied: QuotaError.localNetworkDenied.message
        case .unauthorized: RoutingError.unauthorized.message
        case .held: String(localized: "这把密钥在 magpie 里被限定了预算、模型或账号，看不到 Agent 的用量。换一把不加限定的密钥。")
        case .readOnly, .notAdmin: String(localized: "这把密钥不能改路由组。在电脑的 magpie 里，密钥菜单 → 高级 → 管理 API，选「任何电脑均可」。")
        case .accountsOff: String(localized: "magpie 里的订阅账号功能是关着的。在电脑上 magpie 的「设置 → 隐私」打开。")
        case .unsupported: QuotaError.other("404").message
        case .rejected: String(localized: "没改成，账号状态没动。")
        case .other(let code): QuotaError.other(code).message
        }
    }

    /// magpie's own reason, for the small text under a failure.
    var reason: String? {
        if case .rejected(_, let reason) = self, !reason.isEmpty { return reason }
        return nil
    }

    /// Network trouble (not magpie saying no): screens keep the last data.
    var isOffline: Bool {
        switch self {
        case .unreachable, .timeout, .localNetworkDenied: true
        default: false
        }
    }

    /// Maps a non-2xx answer to a case.
    /// - Parameters:
    ///   - status: the HTTP status code.
    ///   - body: magpie's error body, `{"error":{"code":…,"message":…}}` or a
    ///     plain `{"error":"…"}` (see `RoutingDecoding.errorInfo(from:)`).
    ///   - isRead: whether this was a GET; 404/405 on a read means the route
    ///     is missing in this magpie version (`.unsupported`).
    static func from(status: Int, body: Data, isRead: Bool) -> MagpieAPIError {
        let info = RoutingDecoding.errorInfo(from: body)
        let text = info.message ?? ""
        switch status {
        case 401: return .unauthorized
        case 403:
            switch info.code {
            case "gateway_key_held": return .held
            case "gateway_key_read_only": return .readOnly
            case "gateway_key_not_admin": return .notAdmin
            default: return .rejected(status: 403, reason: text.isEmpty ? "HTTP 403" : text)
            }
        case 400 where text.localizedCaseInsensitiveContains("subscription accounts are off"):
            return .accountsOff
        case 404 where isRead, 405 where isRead: return .unsupported
        case 400..<500: return .rejected(status: status, reason: text.isEmpty ? "HTTP \(status)" : text)
        default: return .other(String(status))
        }
    }
}

/// The 1.3 routes, with the sk-magpie 密钥 as Bearer on the gateway
/// address. Reads take any enabled key (read-only too); a held key gets
/// 403 `gateway_key_held` on `/usage`, and only its own rows on
/// `/usage/requests`. Account on/off takes an admin key.
struct MagpieClient: Sendable {
    /// The magpie gateway address, e.g. `http://office-mac.local:3425`.
    let base: URL
    /// The `sk-magpie-…` gateway key, sent as `Authorization: Bearer`.
    let key: String

    // MARK: Usage

    /// `GET /v1/magpie/usage?period=`: the Usage page's summary for every
    /// agent. magpie ignores `agent=` here; use `requests` for one agent.
    func usage(_ period: UsagePeriod) async throws(MagpieAPIError) -> UsageSummary {
        let data = try await send("GET", "/v1/magpie/usage", query: [.init(name: "period", value: period.rawValue)])
        guard let summary = UsageDecoding.summary(from: data) else { throw .other("JSON") }
        return summary
    }

    /// `GET /v1/magpie/usage/requests`: one page (newest first) plus the
    /// filtered totals and splits (`by.model`, `by.modelAt`, `by.provider`).
    func requests(_ filter: UsageFilter, offset: Int = 0, limit: Int = 100) async throws(MagpieAPIError) -> UsageRequestsPage {
        var query = filter.queryItems
        query.append(.init(name: "offset", value: String(max(0, offset))))
        query.append(.init(name: "limit", value: String(min(max(1, limit), 500))))
        let data = try await send("GET", "/v1/magpie/usage/requests", query: query)
        guard let page = UsageDecoding.requestsPage(from: data) else { throw .other("JSON") }
        return page
    }

    // MARK: 1.4

    /// `GET /v1/magpie/me`: the key's name, read-only flag and magpie's
    /// `version` (0.1.4283+). Any enabled key; never `?key=`.
    func me(timeout: TimeInterval = 10) async throws(MagpieAPIError) -> MagpieMe {
        let data = try await send("GET", "/v1/magpie/me", query: [], timeout: timeout)
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw .other("JSON") }
        return MagpieMe(name: QuotaDecoding.string(d["name"]), version: QuotaDecoding.string(d["version"]),
                        readOnly: d["readOnly"] as? Bool)
    }

    /// `GET /v1/magpie/route-events/snapshot`: calls in flight now (any
    /// unheld key, read-only too; a held key gets 403).
    func routeSnapshot() async throws(MagpieAPIError) -> [LiveRoute] {
        let data = try await send("GET", "/v1/magpie/route-events/snapshot", query: [], timeout: 6)
        return LiveDecoding.snapshot(from: data)
    }

    /// `GET /v1/magpie/concurrency` `active[]`: when each call started.
    func concurrency() async throws(MagpieAPIError) -> [LiveActive] {
        let data = try await send("GET", "/v1/magpie/concurrency", query: [], timeout: 6)
        return LiveDecoding.active(from: data)
    }

    /// `GET /v1/magpie/route?session=`: why earlier tries failed
    /// (`tries[].fail`). A read-only key gets 403.
    func sessionRoute(_ session: String) async throws(MagpieAPIError) -> [String] {
        let data = try await send("GET", "/v1/magpie/route", query: [.init(name: "session", value: session)], timeout: 6)
        return LiveDecoding.tryFailures(from: data)
    }

    // MARK: Quotas

    /// `GET /v1/magpie/quotas`: the cards with `lastServedAt` and `last`.
    func quotas() async throws(MagpieAPIError) -> [QuotaCard] {
        let data = try await send("GET", "/v1/magpie/quotas", query: [])
        do { return try QuotaDecoding.cards(from: data) } catch { throw .other("JSON") }
    }

    /// `GET /v1/magpie/quotas/history`. Its items' shape isn't documented;
    /// the result says so rather than failing.
    func quotaHistory() async throws(MagpieAPIError) -> QuotaHistory {
        let data = try await send("GET", "/v1/magpie/quotas/history", query: [])
        return QuotaHistoryDecoding.history(from: data)
    }

    /// `GET /v1/magpie/limit`: what this key itself is held to.
    func limit() async throws(MagpieAPIError) -> KeyLimit {
        let data = try await send("GET", "/v1/magpie/limit", query: [])
        guard let limit = KeyLimitDecoding.limit(from: data) else { throw .other("JSON") }
        return limit
    }

    // MARK: Subscription accounts (admin)

    /// `POST /v1/magpie/admin/login/on|off {"agent":…,"user":…}`: one
    /// signed-in account (Claude, Codex…) resumed or paused. Body fields
    /// come from magpie's own UI; unverified against a real account.
    func setAccount(agent: String, user: String, on: Bool) async throws(MagpieAPIError) {
        let body = ["agent": agent, "user": user]
        guard let json = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { throw .other("JSON") }
        _ = try await send("POST", "/v1/magpie/admin/login/" + (on ? "on" : "off"), query: [], body: json, timeout: 15)
    }

    // MARK: Transport

    /// Sends one request to `base + path` with the Bearer key and JSON
    /// headers over the shared ephemeral `QuotaClient.session`.
    /// - Returns: the raw body of a 2xx answer.
    /// - Throws: `MagpieAPIError` for transport failures and non-2xx answers.
    private func send(_ method: String, _ path: String, query: [URLQueryItem], body: Data? = nil, timeout: TimeInterval = 10) async throws(MagpieAPIError) -> Data {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw .unreachable }
        parts.percentEncodedPath = parts.percentEncodedPath + path
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw .unreachable }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await QuotaClient.session.data(for: request)
        } catch {
            switch TransportFailure.classify(error) {
            case .unreachable: throw .unreachable
            case .timeout: throw .timeout
            case .localNetworkDenied: throw .localNetworkDenied
            case .other(let code): throw .other(code)
            }
        }
        guard let http = response as? HTTPURLResponse else { throw .other("?") }
        guard (200..<300).contains(http.statusCode) else {
            throw MagpieAPIError.from(status: http.statusCode, body: data, isRead: method == "GET")
        }
        return data
    }
}

// MARK: - Key limit

/// `GET /v1/magpie/limit`. It doesn't say read-only or admin.
struct KeyLimit: Equatable, Sendable {
    /// The key's name as magpie shows it.
    var keyName: String?
    /// `budget`, `models`, `accounts`: what the key is held to.
    var heldTo: [String]
    /// Whether any limit applies to the key at all.
    var limited: Bool
    /// Held keys only: whether Quotas is on for it.
    var quotas: Bool?
    /// The models a model-held key may use.
    var models: [String]
    /// The subscription accounts an account-held key may use.
    var accounts: [String]
    /// The budgets (per period) the key is held to.
    var budgets: [Budget]

    /// Whether the key is held to anything (budget, models or accounts).
    var isHeld: Bool { !heldTo.isEmpty }

    /// One budget window: what was spent and the caps, if any.
    struct Budget: Equatable, Sendable {
        var period: String
        var resetsAt: Date?
        var calls: Int
        var tokens: Int
        var cost: Double
        var tokenLimit: Int?
        var costLimit: Double?
        var spent: Bool
    }
}

/// Decodes `GET /v1/magpie/limit`:
/// `{"key":…,"heldTo":[…],"limited":bool,"quotas":bool?,"models":[…],
/// "accounts":[…],"limits":[{"period","reset","calls","tokens","cost",
/// "tokenLimit","costLimit","spent"}]}` (older magpie: one `limit` object).
enum KeyLimitDecoding {
    /// nil when the body isn't a JSON object; missing fields get defaults.
    static func limit(from data: Data) -> KeyLimit? {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let budgets = ((d["limits"] as? [Any]) ?? (d["limit"].map { [$0] } ?? []))
            .compactMap { $0 as? [String: Any] }
            .map { b in
                KeyLimit.Budget(
                    period: QuotaDecoding.string(b["period"]) ?? "",
                    resetsAt: QuotaDecoding.date(b["reset"]),
                    calls: UsageDecoding.int(b["calls"]),
                    tokens: UsageDecoding.int(b["tokens"]),
                    cost: QuotaDecoding.number(b["cost"]) ?? 0,
                    tokenLimit: QuotaDecoding.number(b["tokenLimit"]).map { Int($0) },
                    costLimit: QuotaDecoding.number(b["costLimit"]),
                    spent: b["spent"] as? Bool ?? false
                )
            }
        return KeyLimit(
            keyName: QuotaDecoding.string(d["key"]),
            heldTo: UsageDecoding.strings(d["heldTo"]),
            limited: d["limited"] as? Bool ?? false,
            quotas: d["quotas"] as? Bool,
            models: UsageDecoding.strings(d["models"]),
            accounts: UsageDecoding.strings(d["accounts"]),
            budgets: budgets
        )
    }
}
