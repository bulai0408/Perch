import Foundation

/// Why reading or changing routing groups didn't work.
enum RoutingError: Error, Equatable, Sendable {
    case unreachable
    case timeout
    case localNetworkDenied
    /// 401: the key is wrong, disabled or removed.
    case unauthorized
    /// 403 `gateway_key_not_admin`: the key lacks 管理 API 「任何电脑均可」
    /// (admin level `any`), or has it from this computer only.
    case notAdmin
    /// magpie refused the change (400, 404, 409, another 403) and said
    /// why, in English: shown verbatim in small text.
    case rejected(status: Int, reason: String)
    case other(String)

    /// The one line Perch shows (for 401/403 the whole message).
    var message: String {
        switch self {
        case .unreachable: QuotaError.unreachable.message
        case .timeout: QuotaError.timeout.message
        case .localNetworkDenied: QuotaError.localNetworkDenied.message
        case .unauthorized: String(localized: "密钥对不上了，可能已在电脑上删掉。到「设置 → 电脑」重新填一把。")
        case .notAdmin: String(localized: "这把密钥不能改路由组。在电脑的 magpie 里，密钥菜单 → 高级 → 管理 API，选「任何电脑均可」。")
        case .rejected: String(localized: "没改成，一切保持原样。")
        case .other(let code): QuotaError.other(code).message
        }
    }

    /// magpie's own reason, for the small text under a failure.
    var reason: String? {
        if case .rejected(_, let reason) = self, !reason.isEmpty { return reason }
        return nil
    }

    /// Network trouble: keep what was read last and show it read-only.
    var isOffline: Bool {
        switch self {
        case .unreachable, .timeout, .localNetworkDenied: true
        default: false
        }
    }

    /// Maps a non-2xx answer to a case. A bare 403 without a code is
    /// treated as not-admin (older magpie).
    static func from(status: Int, body: Data) -> RoutingError {
        let info = RoutingDecoding.errorInfo(from: body)
        switch status {
        case 401: return .unauthorized
        case 403 where info.code == "gateway_key_not_admin": return .notAdmin
        case 403 where info.code == nil && info.message == nil: return .notAdmin
        case 400, 403, 404, 409, 422:
            return .rejected(status: status, reason: info.message ?? "HTTP \(status)")
        case 405: return .unreachable
        default:
            if let message = info.message, !message.isEmpty, status < 500 {
                return .rejected(status: status, reason: message)
            }
            return .other(String(status))
        }
    }
}

/// magpie's public Management API for routing groups, with the same
/// sk-magpie 密钥 as Bearer on the gateway address. URLSession sends no
/// `Origin`/`Sec-Fetch-*`, which magpie refuses (admin_browser_refused).
struct RoutingClient: Sendable {
    /// The magpie gateway address.
    let base: URL
    /// The `sk-magpie-…` key; changes need 管理 API 「任何电脑均可」.
    let key: String

    /// Every route below is relative to this path.
    private static let root = "/v1/magpie/admin/routing-groups"

    /// `GET routing-groups`: every group, in magpie's list order.
    func groups(timeout: TimeInterval = 8) async throws(RoutingError) -> [RoutingGroup] {
        let data = try await send(method: "GET", path: Self.root, body: nil, timeout: timeout)
        do { return try RoutingDecoding.groups(from: data) } catch { throw .other("JSON") }
    }

    /// `GET routing-groups/{id}`.
    func group(_ id: String) async throws(RoutingError) -> RoutingGroup {
        let data = try await send(method: "GET", path: Self.root + "/" + Self.segment(id), body: nil, timeout: 8)
        guard let group = (try? RoutingDecoding.groups(from: data))?.first(where: { $0.id == id }) ?? (try? RoutingDecoding.groups(from: data))?.first
        else { throw .other("JSON") }
        return group
    }

    /// `POST routing-groups/update` with the id and only what changes.
    /// magpie answers with every group; Perch keeps the new list.
    func update(_ id: String, members: [String]? = nil, routing: RoutingMode? = nil, pick: String? = nil) async throws(RoutingError) -> [RoutingGroup] {
        var body: [String: Any] = ["id": id]
        if let members { body["members"] = members }
        if let routing { body["routing"] = routing.raw }
        if let pick { body["pick"] = pick }
        return try await post("update", body)
    }

    /// `POST routing-groups/pick`: Manual routing's member.
    func pick(_ id: String, member: String) async throws(RoutingError) -> [RoutingGroup] {
        try await post("pick", ["id": id, "pick": member])
    }

    /// `POST routing-groups/{action}` (pick, switch, arrange…).
    func action(_ name: String, _ body: [String: Any]) async throws(RoutingError) -> [RoutingGroup] {
        try await post(name, body)
    }

    /// POSTs a JSON body to `routing-groups/<action>` (15 s timeout) and
    /// decodes the full group list magpie answers with.
    private func post(_ action: String, _ body: [String: Any]) async throws(RoutingError) -> [RoutingGroup] {
        guard let json = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { throw .other("JSON") }
        let data = try await send(method: "POST", path: Self.root + "/" + Self.segment(action), body: json, timeout: 15)
        do { return try RoutingDecoding.groups(from: data) } catch { throw .other("JSON") }
    }

    /// Percent-encodes one path segment, keeping `/` so that a group id like
    /// `group/coder` stays one path, as magpie expects.
    static func segment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        // group/<id> stays one path, as magpie takes it.
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Sends one request with the Bearer key and returns the raw 2xx body.
    /// - Throws: `RoutingError` for transport failures and non-2xx answers.
    private func send(method: String, path: String, body: Data?, timeout: TimeInterval) async throws(RoutingError) -> Data {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw .unreachable }
        parts.percentEncodedPath = parts.percentEncodedPath + path
        parts.queryItems = nil
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
            throw RoutingError.from(status: http.statusCode, body: data)
        }
        return data
    }
}
