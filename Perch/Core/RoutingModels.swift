import Foundation

/// One model in a routing group, as magpie lists it: `provider/model`
/// (or `group/<id>` for a group inside a group, or a pattern).
struct RoutingMember: Hashable, Sendable, Identifiable {
    /// What magpie stores in `members`: `alpha/m-alpha`, `claude/claude-opus-5-5`.
    var id: String
    /// The model's display name (`Claude Opus 5.5`), else its vendor id.
    var title: String
    /// The provider's display name, when magpie knows it.
    var providerName: String?
    /// false when no provider serves it right now (magpie's `ready`).
    var ready: Bool
}

/// A routing group as `GET /v1/magpie/admin/routing-groups` describes it.
struct RoutingGroup: Hashable, Sendable, Identifiable {
    /// magpie's group id, e.g. `coder`.
    var id: String
    /// The group's display name (its id when unnamed).
    var name: String
    /// In magpie's order: who is tried first under 按顺序.
    var members: [RoutingMember]
    /// magpie's raw routing value; empty means Smart (magpie leaves it out).
    var routing: String
    /// Manual routing's chosen member. magpie keeps it after leaving
    /// Manual, so it only counts while `routing == "manual"`.
    var pick: String?
    /// Switched off in magpie.
    var disabled: Bool
    /// One magpie found by itself (a model two providers serve).
    var auto: Bool
    /// What an Agent picks: `group/coder`.
    var ref: String

    /// The routing as a `RoutingMode`.
    var mode: RoutingMode { RoutingMode(raw: routing) }

    /// The member requests go to first: Manual's pick, else the first one.
    /// What 设为首选 moves; shown as 首选 only when `mode.hasPrimary`.
    var primaryID: String? {
        if mode == .manual, let pick, members.contains(where: { $0.id == pick }) { return pick }
        return members.first?.id
    }

    /// The 首选 shown, nil under modes without one.
    var shownPrimaryID: String? { mode.hasPrimary ? primaryID : nil }

    /// The member requests go to first.
    var primary: RoutingMember? {
        guard let id = primaryID else { return nil }
        return members.first { $0.id == id }
    }

    /// The members with `memberID` moved to the top, the rest in order.
    func membersWithFirst(_ memberID: String) -> [String] {
        let ids = members.map(\.id)
        guard ids.contains(memberID) else { return ids }
        return [memberID] + ids.filter { $0 != memberID }
    }
    /// What 设为首选 sends for this group (product decision, v1.1):
    /// 按顺序 reorders; 手动 sets `pick` (no confirm); any other routing
    /// switches to 按顺序 with the reordered members, in one call, after
    /// a confirm that names the routing it leaves.
    func primaryChange(to memberID: String) -> PrimaryChange {
        switch mode {
        case .order: .reorder(membersWithFirst(memberID))
        case .manual: .pick(memberID)
        default: .switchToOrder(membersWithFirst(memberID), from: mode)
        }
    }
}

/// The request(s) 设为首选 turns into (see `RoutingGroup.primaryChange`).
enum PrimaryChange: Equatable, Sendable {
    /// `update {id, members}`.
    case reorder([String])
    /// `pick {id, pick}`; routing stays 手动.
    case pick(String)
    /// `update {id, routing: "order", members}`.
    case switchToOrder([String], from: RoutingMode)

    /// Only leaving another mode for 按顺序 asks first.
    var needsConfirm: Bool {
        if case .switchToOrder = self { return true }
        return false
    }
}

/// magpie's `routing` values for a group (its Routing page's
/// GROUP_ROUTE_OPTS).
enum RoutingMode: Hashable, Sendable {
    case smart, order, drain, rotate, usage, pace, free, fast, cheap, expiring, weight, manual
    /// A gateway plugin's own routing (`<plugin>/<name>`) or one this
    /// version doesn't know: shown as magpie says it, never offered.
    case other(String)

    /// Parses magpie's `routing` string (case-insensitive; empty is Smart).
    init(raw: String) {
        switch raw.trimmed.lowercased() {
        case "", "smart": self = .smart
        case "order": self = .order
        case "drain": self = .drain
        case "rotate": self = .rotate
        case "usage": self = .usage
        case "pace": self = .pace
        case "free": self = .free
        case "fast", "fastest", "speed": self = .fast
        case "cheap": self = .cheap
        case "expiring": self = .expiring
        case "weight": self = .weight
        case "manual": self = .manual
        default: self = .other(raw.trimmed)
        }
    }

    /// What `update` takes: Smart is the empty string.
    var raw: String {
        switch self {
        case .smart: ""
        case .order: "order"
        case .drain: "drain"
        case .rotate: "rotate"
        case .usage: "usage"
        case .pace: "pace"
        case .free: "free"
        case .fast: "fast"
        case .cheap: "cheap"
        case .expiring: "expiring"
        case .weight: "weight"
        case .manual: "manual"
        case .other(let value): value
        }
    }

    /// The modes Perch offers, in magpie's own order. By weight needs a
    /// number per model, so it stays on the computer.
    static let offered: [RoutingMode] = [.smart, .order, .drain, .rotate, .usage, .pace, .free, .fast, .cheap, .expiring, .manual]

    /// The mode's name. A plugin's routing shows raw.
    var label: String {
        switch self {
        case .smart: String(localized: "智能")
        case .order: String(localized: "按顺序")
        case .drain: String(localized: "用完再换")
        case .rotate: String(localized: "轮换")
        case .usage: String(localized: "最少使用")
        case .pace: String(localized: "赶在重置前用")
        case .free: String(localized: "免费优先")
        case .fast: String(localized: "速度优先")
        case .cheap: String(localized: "最便宜优先")
        case .expiring: String(localized: "免费且最快到期优先")
        case .weight: String(localized: "按权重")
        case .manual: String(localized: "手动")
        case .other(let value): value
        }
    }

    /// The one line under each option. Empty for a plugin's.
    var detail: String {
        switch self {
        case .smart: String(localized: "额度最先续上的先用；快用完的往后排。")
        case .order: String(localized: "一直用第一个，用不了再换下一个。")
        case .drain: String(localized: "一个用到额度用完，再换下一个。")
        case .rotate: String(localized: "每条消息轮流交给下一个。")
        case .usage: String(localized: "剩得最多的先用。")
        case .pace: String(localized: "快要重置、还剩很多的先用，别浪费。")
        case .free: String(localized: "先用不花钱的，再用付费的。")
        case .fast: String(localized: "最近回得最快的先用。")
        case .cheap: String(localized: "现在最便宜的先用。")
        case .expiring: String(localized: "先用快过期的免费额度，没有了才用付费的。")
        case .weight: String(localized: "按电脑上设好的比例分配。")
        case .manual: String(localized: "只用选定的一个，用不了不换。")
        case .other: ""
        }
    }

    /// Choosable on the phone. By weight needs numbers and a plugin's
    /// routing isn't Perch's to offer: both are shown read-only.
    var isOffered: Bool { Self.offered.contains(self) }

    /// Whether the group has a 首选 under this mode: the first model
    /// (按顺序, 用完再换, 轮换) or the chosen one (手动). Other modes don't.
    var hasPrimary: Bool {
        switch self {
        case .order, .drain, .rotate, .manual: true
        default: false
        }
    }

    /// The lines under 选用方式, swapped by mode, never empty.
    var footer: [String] {
        switch self {
        case .order, .drain: [String(localized: "先用首选，用不了会自动往下用。")]
        case .manual: [String(localized: "只用选定的这一个。它用不了时不会换别的，会直接报错。")]
        default:
            ([detail] + (isOffered ? [] : [String(localized: "要在电脑上改")])).filter { !$0.isEmpty }
        }
    }

    /// Whether 「先用首选，用不了会自动往下用。」 is what magpie
    /// does: true for In order (verified on magpie 0.1.4260) and Until used up.
    var fallsThroughInOrder: Bool { self == .order || self == .drain }
}

/// The model chain under a group's name in the 路由组 list:
/// 「m-alpha → m-beta → m-gamma」 for 按顺序 and 用完再换 with the first one
/// bold, 「kimi-k3 · 另有 2 个」 for 手动 with the pick bold, and the models
/// joined by 「 · 」 for every other mode, none bold.
struct RoutingChain: Equatable, Sendable {
    /// The bold part (the first choice), when the mode has one.
    var lead: String?
    /// What follows it, separator included: 「 → m-beta → m-gamma」.
    var rest: String

    /// Builds the chain for `group` according to its mode.
    init(_ group: RoutingGroup) {
        let models = Self.names(group.members.map(\.id))
        switch group.mode {
        case .order, .drain:
            lead = models.first
            rest = models.dropFirst().map { " → \($0)" }.joined()
        case .manual:
            let pick = group.primary.flatMap { p in group.members.firstIndex { $0.id == p.id }.map { models[$0] } }
                ?? group.primary.map { RoutingDecoding.modelPart(of: $0.id) } ?? models.first
            lead = pick
            let others = max(0, models.count - 1)
            rest = pick != nil && others > 0 ? String(localized: " · 另有 \(others.text) 个") : ""
        default:
            lead = nil
            rest = models.joined(separator: " · ")
        }
    }

    /// The whole chain as plain text.
    var text: String { (lead ?? "") + rest }

    /// Each member's model name; where two members share it,
    /// their provider names instead: 「claude · copilot」.
    static func names(_ ids: [String]) -> [String] {
        let models = ids.map { RoutingDecoding.modelPart(of: $0) }
        var counts: [String: Int] = [:]
        for m in models { counts[m, default: 0] += 1 }
        return zip(ids, models).map { id, model in
            guard counts[model, default: 0] > 1, let slash = id.firstIndex(of: "/") else { return model }
            let provider = String(id[..<slash])
            return provider.isEmpty ? model : provider
        }
    }

    /// For VoiceOver: arrows and dots read as pauses.
    var spoken: String {
        text.replacingOccurrences(of: " → ", with: "，").replacingOccurrences(of: " · ", with: "，")
    }
}

extension RoutingMode {
    /// The 选用方式 menu's 「常用」 section, in this order; 「更多」 is the rest.
    static let common: [RoutingMode] = [.order, .smart, .drain, .manual]
    /// The 「更多」 section: the offered modes not in `common`.
    static var more: [RoutingMode] { offered.filter { !common.contains($0) } }

    /// The members header says 「从上往下用」 where the order is the route.
    var membersHeader: String {
        fallsThroughInOrder ? String(localized: "组里的模型 · 从上往下用") : String(localized: "组里的模型")
    }
}

extension RoutingGroup {
    /// What an agent sends to use this group. The gateway routes
    /// `group/<id>`; `magpie/group/<id>` is a 404 (verified on 0.1.4266).
    var agentModel: String { "group/\(id)" }
}

// MARK: - Defensive decoding

/// Lenient decoding for `/v1/magpie/admin/routing-groups` and its POSTs.
///
/// List shape: `{"groups":[{"id","name","members":["provider/model"…],
/// "memberInfo":[{"id","model","name"|"provider","ready"}],"routing",
/// "pick","disabled","auto","ref"}],"models":[{"id","name","providerName"}]}`.
enum RoutingDecoding {
    /// The answer had no groups in any known shape.
    struct Failure: Error {}

    /// The list answer (`{"groups": [...], "models": [...], …}`, also what
    /// every POST answers), a bare array, or one group object.
    /// Groups that can't be read are skipped, never fatal.
    static func groups(from data: Data) throws -> [RoutingGroup] {
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        var models: [String: [String: Any]] = [:]
        let rawGroups: [Any]
        if let object = json as? [String: Any] {
            if let list = object["groups"] as? [Any] {
                rawGroups = list
            } else if object["id"] != nil, object["members"] != nil {
                rawGroups = [object]
            } else {
                throw Failure()
            }
            for case let model as [String: Any] in object["models"] as? [Any] ?? [] {
                if let id = model["id"] as? String { models[id] = model }
            }
        } else if let list = json as? [Any] {
            rawGroups = list
        } else {
            throw Failure()
        }
        return rawGroups.compactMap { ($0 as? [String: Any]).flatMap { group($0, models: models) } }
    }

    /// One group; nil without an `id`. Member titles come from `models`
    /// (display names), else `memberInfo`, else the id's model part.
    static func group(_ g: [String: Any], models: [String: [String: Any]] = [:]) -> RoutingGroup? {
        guard let id = string(g["id"]), !id.isEmpty else { return nil }
        let memberIDs = (g["members"] as? [Any] ?? []).compactMap { string($0) }.filter { !$0.isEmpty }
        var info: [String: [String: Any]] = [:]
        for case let m as [String: Any] in g["memberInfo"] as? [Any] ?? [] {
            if let mid = string(m["id"]) { info[mid] = m }
        }
        let members = memberIDs.map { mid -> RoutingMember in
            let i = info[mid] ?? [:]
            let model = models[mid] ?? [:]
            let vendorModel = string(i["model"]) ?? modelPart(of: mid)
            let title = string(model["name"]).flatMap { $0.isEmpty ? nil : $0 } ?? vendorModel
            let provider = string(model["providerName"]) ?? string(i["name"]) ?? string(i["provider"])
            let ready = bool(i["ready"]) ?? true
            return RoutingMember(id: mid, title: title, providerName: provider, ready: ready)
        }
        let name = string(g["name"]).flatMap { $0.trimmed.isEmpty ? nil : $0 } ?? id
        return RoutingGroup(
            id: id,
            name: name,
            members: members,
            routing: string(g["routing"]) ?? "",
            pick: string(g["pick"]).flatMap { $0.isEmpty ? nil : $0 },
            disabled: bool(g["disabled"]) ?? false,
            auto: bool(g["auto"]) ?? false,
            ref: string(g["ref"]).flatMap { $0.isEmpty ? nil : $0 } ?? "group/\(id)"
        )
    }

    /// `alpha/m-alpha` → `m-alpha`; `openrouter/anthropic/x` → `anthropic/x`.
    static func modelPart(of member: String) -> String {
        guard let slash = member.firstIndex(of: "/") else { return member }
        let rest = member[member.index(after: slash)...]
        let withoutAccount = rest.split(separator: "#", maxSplits: 1).first.map(String.init) ?? String(rest)
        return withoutAccount.isEmpty ? member : withoutAccount
    }

    /// magpie's error text: `{"error":"…"}` (admin routes) or
    /// `{"error":{"code":…,"message":…}}` (auth). Nil when there's none.
    static func errorInfo(from data: Data) -> (code: String?, message: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data.prefix(400), encoding: .utf8)?.trimmed
            return (nil, text?.isEmpty == false ? text : nil)
        }
        if let text = object["error"] as? String { return (nil, text) }
        if let error = object["error"] as? [String: Any] {
            return (string(error["code"]), string(error["message"]))
        }
        return (string(object["code"]), string(object["message"]))
    }

    /// A string, or a number as a string.
    private static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }

    /// A bool from a JSON bool, number or `"true"/"1"/"yes"`.
    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool: b
        case let n as NSNumber: n.intValue != 0
        case let s as String: ["true", "1", "yes"].contains(s.lowercased())
        default: nil
        }
    }
}
