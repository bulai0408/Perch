import Foundation

/// Why a call failed, in magpie's own Chinese words.
/// Usage rows carry only `status`, the vendor's `err` text and `err_type`,
/// and `rejected`; `/route` tries carry magpie's own `fail` category.
enum FailureKind: String, Equatable, Sendable, CaseIterable {
    /// 额度用完
    case quota
    /// 限流
    case rate
    /// 余额不足
    case credit
    /// 登录已失效
    case login
    /// magpie 找不到模型
    case modelNotFound
    /// 出错（5xx、超时）
    case upstream
    /// Anything Perch can't tell.
    case other
}

/// Turns a failed call (a usage row or a `/route` try) into a category
/// and the one human line Perch shows for it. Pure; no network.
enum CallFailure {
    /// The vendor text magpie passes on when a login lapsed
    /// (`provider/claude_auth.go`), and the usual OAuth wording.
    static let loginPhrases = [
        "sign in again", "signin again", "sign-in required", "log in again", "login again", "re-login", "relogin",
        "could not authenticate", "login expired", "session expired", "token expired", "oauth token",
        "invalid_grant", "refresh token", "authentication_error", "unauthorized",
        "登录已失效", "重新登录",
    ]
    private static let quotaPhrases = ["quota", "usage limit", "usage_limit", "limit reached", "allowance", "exhausted", "额度"]
    private static let creditPhrases = ["insufficient balance", "insufficient_balance", "insufficient credit", "credit balance",
                                        "billing", "payment required", "余额"]
    private static let timeoutPhrases = ["timeout", "timed out", "deadline exceeded", "overloaded", "bad gateway",
                                         "service unavailable", "connection reset", "eof"]

    /// A failed usage row's category.
    static func kind(status: Int, error: String?, errorType: String?, rejected: Bool) -> FailureKind {
        let text = (error ?? "").lowercased()
        let type = (errorType ?? "").lowercased()
        func has(_ phrases: [String]) -> Bool { phrases.contains { text.contains($0) || type.contains($0) } }

        if rejected || type == "not_found_error" && status == 404
            || status == 404 && (text.contains("unknown model") || text.contains("model not found") || text.contains("no such model")) {
            return .modelNotFound
        }
        if status == 401 || type == "authentication_error" || type == "permission_error" && has(loginPhrases) || has(loginPhrases) {
            return .login
        }
        if status == 402 || type.contains("billing") || type.contains("insufficient_balance") || has(creditPhrases) {
            return .credit
        }
        if ["usage_limit_reached", "insufficient_quota", "quota_exceeded", "usage_limit_exceeded"].contains(type) {
            return .quota
        }
        if type == "rate_limit_error" || type == "rate_limit_exceeded" { return .rate }
        if status == 429 { return has(quotaPhrases) ? .quota : .rate }
        if has(quotaPhrases) { return .quota }
        if status >= 500 || status == 408 || status == 0 || type == "overloaded_error" || type == "api_error" || has(timeoutPhrases) {
            return .upstream
        }
        return .other
    }

    /// A usage row's category (see `kind(status:error:errorType:rejected:)`).
    static func kind(of row: UsageRow) -> FailureKind {
        kind(status: row.status, error: row.error, errorType: row.errorType, rejected: row.rejected)
    }

    /// `/route` `tries[].fail` (magpie `gateway/routing.go`).
    static func kind(category: String) -> FailureKind {
        switch category.lowercased() {
        case "quota", "room", "floor": .quota
        case "rate": .rate
        case "credit": .credit
        case "auth", "verify": .login
        case "foreign", "sight", "restricted": .modelNotFound
        case "overloaded", "slow", "offline", "proxy", "update", "cut", "overflow": .upstream
        default: .other
        }
    }

    /// The short version in brackets: 额度用完 / 限流 /
    /// 余额不足 / 出错. Nil when Perch can't tell.
    static func short(_ kind: FailureKind) -> String? {
        switch kind {
        case .quota: String(localized: "额度用完")
        case .rate: String(localized: "限流")
        case .credit: String(localized: "余额不足")
        case .login: String(localized: "登录已失效")
        case .upstream: String(localized: "出错")
        case .modelNotFound, .other: nil
        }
    }

    /// The bracket text for a `/route` `fail` category, if Perch has one.
    static func shortReason(category: String) -> String? { short(kind(category: category)) }

    /// The human line of a failed call.
    /// - account: the account's name (else the provider's).
    /// - resetsAt: when that account's quota comes back (quota card), for 额度用完.
    /// - recoversAt: when a rate limit lifts, only when magpie actually said
    ///   so (a retry-after). A quota window's reset is not that time.
    /// - switchedTo: where magpie handed the call on, when it then worked.
    static func line(_ kind: FailureKind, account: String, provider: String, model: String,
                     resetsAt: Date?, recoversAt: Date? = nil, switchedTo: String? = nil, now: Date = .now) -> String {
        switch kind {
        case .quota:
            var text = resetsAt.map { String(localized: "\(account) 额度用完了，\(QuotaFormat.until($0, now: now)) 重置。") }
                ?? String(localized: "\(account) 额度用完了。")
            if let switchedTo, !switchedTo.isEmpty { text += String(localized: "magpie 换到了 \(switchedTo)。") }
            return text
        case .rate:
            if let recoversAt, recoversAt > now {
                return String(localized: "\(account) 被限流了，过 \(QuotaFormat.duration(until: recoversAt, now: now))恢复。")
            }
            return String(localized: "\(account) 被限流了，过一会儿就好。")
        case .credit:
            return String(localized: "\(account) 余额不足，充值后才能再用。")
        case .login:
            return String(localized: "\(account) 登录已失效，要在电脑上的 magpie 里重新登录。")
        case .modelNotFound:
            return String(localized: "magpie 找不到模型 \(model)。看看 Agent 里填的模型名对不对。")
        case .upstream:
            return String(localized: "\(provider) 那边出错了，不是你的问题，等一会儿再试。")
        case .other:
            return String(localized: "这次没成功。")
        }
    }

    /// 「magpie 原话：…」: the vendor's text, else the status.
    static func original(_ row: UsageRow) -> String? {
        if let e = row.error?.trimmed, !e.isEmpty { return e }
        if let t = row.errorType?.trimmed, !t.isEmpty { return "\(row.status) \(t)" }
        return row.status > 0 ? "HTTP \(row.status)" : nil
    }

    /// A failed row's line, names and reset time looked up in the cards.
    static func line(for row: UsageRow, cards: [QuotaCard], now: Date = .now) -> String {
        let card = row.account.flatMap { QuotaGrouping.card(named: $0, in: cards) }
        let providerName = row.providerName?.nilIfEmpty ?? row.provider?.nilIfEmpty
        let account = card?.title ?? row.account?.nilIfEmpty ?? providerName ?? row.shownModel
        let model = row.requested?.nilIfEmpty ?? row.shownModel
        let kind = kind(of: row)
        return line(kind, account: account, provider: providerName ?? account, model: model,
                    resetsAt: resetTime(card, kind: kind, now: now), now: now)
    }

    /// 额度用完: the window that is used up resets first. Not used for 限流,
    /// whose recovery has nothing to do with the quota windows.
    static func resetTime(_ card: QuotaCard?, kind: FailureKind, now: Date) -> Date? {
        guard let card, kind == .quota else { return nil }
        let future = card.windows.filter { ($0.resetsAt ?? .distantPast) > now }
        let full = future.filter { (QuotaFormat.used($0) ?? 0) >= 99.5 }
        return (full.isEmpty ? future : full).compactMap(\.resetsAt).min()
    }

    /// 「换到了 %@」: the account that took over, else provider/model.
    static func switchedTo(_ row: UsageRow, cards: [QuotaCard]) -> String {
        if let a = row.account?.nilIfEmpty { return QuotaGrouping.card(named: a, in: cards)?.title ?? a }
        if let p = row.providerName?.nilIfEmpty ?? row.provider?.nilIfEmpty { return "\(p)/\(row.shownModel)" }
        return row.shownModel
    }
}

extension String {
    /// The trimmed string, or nil when that is empty.
    var nilIfEmpty: String? {
        let t = trimmed
        return t.isEmpty ? nil : t
    }
}

extension QuotaCard {
    /// 1.4 「登录已失效」: magpie's cards have only a free-text `error`, so
    /// this matches magpie's own sign-in-required wording conservatively.
    var loginExpired: Bool {
        guard let text = error?.lowercased(), !text.isEmpty else { return false }
        let phrases = ["sign in again", "sign-in required", "signin required", "log in again", "login again",
                       "could not authenticate", "login expired", "login has expired", "re-login", "relogin",
                       "invalid_grant", "refresh token", "token expired", "token has expired", "登录已失效", "重新登录"]
        if phrases.contains(where: text.contains) { return true }
        return text.contains("401") && (text.contains("auth") || text.contains("login"))
    }
}
