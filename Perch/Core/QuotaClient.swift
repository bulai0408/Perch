import Foundation

/// Why talking to magpie's share port didn't work. Each case has one line
/// of copy.
enum QuotaError: Error, Equatable, Sendable {
    /// No route to the address (wrong address, other network, magpie off).
    case unreachable
    /// The request timed out.
    case timeout
    /// iOS Local Network permission was refused.
    case localNetworkDenied
    /// 401: magpie doesn't know the key.
    case unauthorized
    /// 403: the key may not read quotas (「可看额度」 is off).
    case forbidden
    /// Anything else, with a short code shown to the person.
    case other(String)

    /// The localized line Perch shows for this failure.
    var message: String {
        switch self {
        case .unreachable: String(localized: "没找到这台 magpie。确认电脑开着、和手机在同一个网络，地址也没写错。")
        case .timeout: String(localized: "magpie 没有回应。等一会儿再试。")
        case .localNetworkDenied: String(localized: "Perch 还没有本地网络权限。")
        case .unauthorized: String(localized: "密钥对不上。回电脑上的 magpie 再复制一次。")
        case .forbidden: String(localized: "这把密钥还不能看额度。在 magpie 里给它打开「可看额度」。")
        case .other(let code): String(localized: "出了点问题（代码 \(code)），稍后再试。")
        }
    }
}

/// A URLSession error reduced to what Perch tells apart. Shared by
/// `QuotaClient`, `MagpieClient` and `RoutingClient`.
enum TransportFailure {
    case unreachable, timeout, localNetworkDenied, other(String)

    /// Classifies a thrown URLSession error. Non-URLError errors become
    /// `.other("<domain> <code>")`.
    static func classify(_ error: Error) -> TransportFailure {
        guard let urlError = error as? URLError else {
            return .other((error as NSError).domain + " \((error as NSError).code)")
        }
        if isLocalNetworkDenied(urlError) { return .localNetworkDenied }
        switch urlError.code {
        case .timedOut: return .timeout
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost,
             .notConnectedToInternet, .badURL, .unsupportedURL, .secureConnectionFailed,
             .cannotLoadFromNetwork, .internationalRoamingOff, .dataNotAllowed:
            return .unreachable
        default: return .other(String(urlError.code.rawValue))
        }
    }

    /// iOS reports a refused Local Network permission through the
    /// connection's path ("unsatisfied (Local network prohibited)").
    static func isLocalNetworkDenied(_ error: URLError) -> Bool {
        var texts = [String(describing: error.userInfo)]
        var underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        while let next = underlying {
            texts.append(String(describing: next.userInfo))
            underlying = next.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return texts.contains { $0.localizedCaseInsensitiveContains("local network prohibited") }
    }
}

/// magpie's public quota routes, with the sk-magpie 密钥 as Bearer.
struct QuotaClient: Sendable {
    /// The magpie gateway address.
    let base: URL
    /// The `sk-magpie-…` gateway key, sent as `Authorization: Bearer`.
    let key: String

    /// The one URLSession every client uses: ephemeral, no cache, no
    /// cookies, fails fast instead of waiting for connectivity.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// `GET /v1/magpie/quotas/cards`: what magpie has kept, no vendor calls.
    func cards(timeout: TimeInterval = 8) async throws(QuotaError) -> [QuotaCard] {
        try await send(method: "GET", path: "/v1/magpie/quotas/cards", query: [], timeout: timeout)
    }

    /// `POST /v1/magpie/quotas/refresh`: reads one card again (magpie
    /// allows it once every 30 s a card) and answers with the cards.
    func refresh(_ card: QuotaCard) async throws(QuotaError) -> [QuotaCard] {
        var query = [URLQueryItem(name: "provider", value: card.provider)]
        if let user = card.user, !user.isEmpty { query.append(URLQueryItem(name: "user", value: user)) }
        return try await send(method: "POST", path: "/v1/magpie/quotas/refresh", query: query, timeout: 35)
    }

    /// Sends one request and decodes the answer as quota cards
    /// (`{"data":[QuotaCard…]}` or a bare array; see `QuotaDecoding.cards`).
    /// 404/405 count as unreachable: that address isn't a magpie.
    private func send(method: String, path: String, query: [URLQueryItem], timeout: TimeInterval) async throws(QuotaError) -> [QuotaCard] {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw .unreachable }
        let basePath = parts.path
        parts.path = basePath + path
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw .unreachable }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            switch TransportFailure.classify(error) {
            case .unreachable: throw .unreachable
            case .timeout: throw .timeout
            case .localNetworkDenied: throw .localNetworkDenied
            case .other(let code): throw .other(code)
            }
        }
        guard let http = response as? HTTPURLResponse else { throw .other("?") }
        switch http.statusCode {
        case 200..<300:
            do { return try QuotaDecoding.cards(from: data) } catch { throw .other("JSON") }
        case 401: throw .unauthorized
        case 403: throw .forbidden
        case 404, 405: throw .unreachable
        default: throw .other(String(http.statusCode))
        }
    }
}
