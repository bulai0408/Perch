import Foundation

/// One window of an allowance, as `GET /v1/magpie/quotas/cards` tells it:
/// `used` and `remaining` are percentages.
struct QuotaWindow: Hashable, Sendable {
    /// magpie's window name: `5h`, `7d`, `week`, `7 days · Opus`…
    var name: String
    /// % used (0–100), when magpie sent it.
    var used: Double?
    /// % left (0–100), when magpie sent it.
    var remaining: Double?
    /// When the window resets.
    var resetsAt: Date?
    /// The vendor's own text for count-only windows (e.g. 「12 / 50」).
    var display: String?
    /// No cap: never counted as tight.
    var unlimited: Bool
    /// A count-only window: no percentages, show `display`.
    var text: Bool
    /// The model lane a window is for (e.g. a per-model weekly cap).
    var lane: String?
}

/// One account's, plan's or key's card.
struct QuotaCard: Hashable, Sendable, Identifiable {
    /// Provider id, e.g. `claude`, `codex`, `openrouter`.
    var provider: String
    var name: String
    /// `subscription` (a signed-in account), or a pay-as-you-go kind
    /// (`balance`, `plan`, `key`).
    var kind: String
    /// Plan name, e.g. `Max`.
    var plan: String?
    /// The account's login (often an email).
    var user: String?
    /// The name the person gave the account in magpie.
    var alias: String?
    /// Team seat name, when the vendor reports one.
    var seat: String?
    /// Where the card comes from (a plugin or source name).
    var from: String?
    /// The allowance windows (`5h`, `7d`…).
    var windows: [QuotaWindow]
    /// Pay-as-you-go balance text.
    var balance: String?
    /// Why magpie couldn't read this card last time (free text).
    var error: String?
    /// When the vendor's numbers are from.
    var asOf: Date?
    /// When magpie last read the card.
    var readAt: Date?
    /// magpie's flag for the account that served the latest call.
    var last: Bool
    /// `/v1/magpie/quotas` only: when this account last answered a call
    /// through the gateway (last 30 days); `last` marks the newest.
    var lastServedAt: Date? = nil
    /// Turned off in magpie (`on: false`, `off`, `paused` or `disabled`).
    /// The field name is a guess: magpie's docs don't show a paused
    /// account's card, and the probe had none.
    var off: Bool = false

    /// A stable identity built from the fields that tell cards apart.
    var id: String {
        [kind, from ?? "", provider, user ?? "", seat ?? "", name].joined(separator: "|")
    }

    /// Account alias, else the login, else the provider's name.
    var title: String {
        for candidate in [alias, user, seat] {
            if let value = candidate?.trimmed, !value.isEmpty { return value }
        }
        return name.isEmpty ? provider : name
    }

    /// 「Claude · Max」: provider name and plan, minus what the title says.
    var subtitle: String {
        var parts: [String] = []
        let providerName = name.isEmpty ? provider : name
        if providerName != title { parts.append(providerName) }
        if let plan = plan?.trimmed, !plan.isEmpty { parts.append(plan) }
        if let from = from?.trimmed, !from.isEmpty, !providerName.contains(from) { parts.append(from) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Defensive decoding

/// Lenient JSON decoding for magpie's quota cards, shared by other
/// decoders for its `string`/`number`/`date` helpers.
///
/// Card shape (`GET /v1/magpie/quotas/cards`, `/quotas`):
/// `{"provider","name","kind","plan","user","alias","seat","from",
/// "windows":[{"name","used","remaining","resetsAt","display","unlimited",
/// "text","lane"}],"balance","error","asOf","readAt","last","lastServedAt",
/// "on"|"off"|"paused"|"disabled"}`.
enum QuotaDecoding {
    /// Accepts `{"data": [...]}` (what magpie sends) or a bare array.
    /// Cards or windows that can't be read are skipped, never fatal.
    static func cards(from data: Data) throws -> [QuotaCard] {
        let object = try JSONSerialization.jsonObject(with: data)
        let list: [Any]
        if let dict = object as? [String: Any] {
            if dict["data"] is NSNull { return [] }
            guard let items = dict["data"] as? [Any] else { throw DecodingFailure() }
            list = items
        } else if let items = object as? [Any] {
            list = items
        } else {
            throw DecodingFailure()
        }
        return list.compactMap { ($0 as? [String: Any]).flatMap(card) }
    }

    /// The top level wasn't `{"data":[…]}` or an array.
    struct DecodingFailure: Error {}

    /// One card; nil when it has neither `provider` nor `name`.
    static func card(_ d: [String: Any]) -> QuotaCard? {
        let provider = string(d["provider"]) ?? ""
        let name = string(d["name"]) ?? ""
        guard !(provider.isEmpty && name.isEmpty) else { return nil }
        let windows = (d["windows"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(window) }
        return QuotaCard(
            provider: provider,
            name: name,
            kind: string(d["kind"]) ?? "subscription",
            plan: string(d["plan"]),
            user: string(d["user"]),
            alias: string(d["alias"]),
            seat: string(d["seat"]),
            from: string(d["from"]),
            windows: windows,
            balance: string(d["balance"]),
            error: string(d["error"]),
            asOf: date(d["asOf"]),
            readAt: date(d["readAt"]),
            last: d["last"] as? Bool ?? false,
            lastServedAt: date(d["lastServedAt"]),
            off: (d["on"] as? Bool).map { !$0 } ?? [d["off"], d["paused"], d["disabled"]].contains { ($0 as? Bool) == true }
        )
    }

    /// One window; nil without a `name`.
    static func window(_ d: [String: Any]) -> QuotaWindow? {
        guard let name = string(d["name"]) else { return nil }
        return QuotaWindow(
            name: name,
            used: number(d["used"]),
            remaining: number(d["remaining"]),
            resetsAt: date(d["resetsAt"]),
            display: string(d["display"]),
            unlimited: d["unlimited"] as? Bool ?? false,
            text: d["text"] as? Bool ?? false,
            lane: string(d["lane"])
        )
    }

    /// A string, or a number as a string (never a JSON bool).
    static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: s
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): n.stringValue
        default: nil
        }
    }

    /// A finite number, or a numeric string.
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: n.doubleValue.isFinite ? n.doubleValue : nil
        case let s as String: Double(s)
        default: nil
        }
    }

    /// An RFC 3339 string as a Date.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return RFC3339.parse(text)
    }
}

/// Go writes times as RFC 3339 with up to nine fraction digits, which
/// ISO8601DateFormatter doesn't always take; the fraction is read apart.
enum RFC3339 {
    /// Parses `2026-11-16T14:40:11.123456789Z`; nil when unreadable.
    static func parse(_ text: String) -> Date? {
        var main = text
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            let after = text[text.index(after: dot)...]
            let digits = after.prefix { $0.isASCII && $0.isNumber }
            fraction = Double("0." + digits) ?? 0
            main = String(text[..<dot]) + after.dropFirst(digits.count)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: main).map { $0.addingTimeInterval(fraction) }
    }
}

extension String {
    /// Without leading/trailing whitespace and newlines.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
