import Foundation
import Observation

/// `GET /v1/magpie/me`.
struct MagpieMe: Equatable, Sendable {
    /// The key's name in magpie.
    var name: String?
    /// magpie's version, e.g. `0.1.4283` (absent before 0.1.4283).
    var version: String?
    /// Whether the key is read-only.
    var readOnly: Bool?
}

/// One call in flight, from `route-events/snapshot` `routes[]`. magpie
/// gives no account and no reason here, on purpose.
struct LiveRoute: Equatable, Sendable, Identifiable {
    var id: String
    var time: Date?
    var agent: String
    var provider: String?
    var model: String
    var attempt: Int
    /// The call is on a later try than the first.
    var fallback: Bool
    /// `started | attempt | responding | attempt_done | done | dropped`.
    var phase: String

    /// Still in flight (not `done` or `dropped`).
    var isRunning: Bool { phase != "done" && phase != "dropped" }
    /// 中途换过 N 次.
    var switches: Int { fallback ? max(1, attempt - 1) : 0 }
}

/// `GET /v1/magpie/concurrency` `active[]`.
struct LiveActive: Equatable, Sendable {
    var agent: String
    var model: String
    var started: Date?
}

/// Decoders for the live routes. All of them return empty on an
/// unreadable body instead of failing.
enum LiveDecoding {
    /// `{"routes":[{"id","time","agent","provider","model","attempt",
    /// "fallback","phase"}]}` → `[LiveRoute]`.
    static func snapshot(from data: Data) -> [LiveRoute] {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return (d["routes"] as? [Any] ?? []).compactMap { item in
            guard let r = item as? [String: Any] else { return nil }
            let model = QuotaDecoding.string(r["model"]) ?? ""
            return LiveRoute(
                id: QuotaDecoding.string(r["id"]) ?? UUID().uuidString,
                time: QuotaDecoding.date(r["time"]),
                agent: QuotaDecoding.string(r["agent"]) ?? "",
                provider: QuotaDecoding.string(r["provider"]),
                model: model,
                attempt: UsageDecoding.int(r["attempt"]),
                fallback: r["fallback"] as? Bool ?? false,
                phase: QuotaDecoding.string(r["phase"]) ?? ""
            )
        }
    }

    /// `{"active":[{"agent","model","started"}]}` → `[LiveActive]`; the model
    /// loses any `provider/` prefix.
    static func active(from data: Data) -> [LiveActive] {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return (d["active"] as? [Any] ?? []).compactMap { item in
            guard let a = item as? [String: Any] else { return nil }
            return LiveActive(agent: QuotaDecoding.string(a["agent"]) ?? "",
                              model: RoutingDecoding.modelPart(of: QuotaDecoding.string(a["model"]) ?? ""),
                              started: QuotaDecoding.date(a["started"]))
        }
    }

    /// `route.tries[].fail` of the tries that failed, in order.
    static func tryFailures(from data: Data) -> [String] {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let route = d["route"] as? [String: Any] else { return [] }
        return (route["tries"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap { QuotaDecoding.string($0["fail"]) } }
    }
}

/// The Agent tab's 「正在进行」 card: live from
/// route-events, then 「刚刚结束」 for 30 s from the newest usage row.
@MainActor
@Observable
final class LiveStore {
    /// What the card shows.
    enum State: Equatable {
        case hidden
        case running(model: String, since: Date, switches: Int)
        case finished(row: UsageRow?, model: String, reason: String?, at: Date)
    }

    /// How long 「刚刚结束」 stays after a call ends.
    static let finishedFor: TimeInterval = 30

    private(set) var state: State = .hidden
    /// 403 / 404 from magpie (held key, older magpie): no card at all.
    private(set) var unavailable = false
    private var firstSeen: [String: Date] = [:]
    private var lastRunning: (id: String, model: String)?

    /// Back to hidden (switching agent or computer).
    func reset() {
        state = .hidden
        unavailable = false
        firstSeen = [:]
        lastRunning = nil
    }

    /// One poll for `agent` (nil: every agent).
    func poll(agent: String?, client: MagpieClient?, now: Date = .now) async {
        #if DEBUG
        if DemoData.isOn {
            state = .running(model: "claude-opus-5-5", since: now.addingTimeInterval(-128), switches: 1)
            return
        }
        #endif
        guard let client, !unavailable else { return }
        let routes: [LiveRoute]
        do {
            routes = try await client.routeSnapshot()
        } catch {
            switch error {
            case .held, .unsupported, .readOnly, .notAdmin, .unauthorized, .rejected(status: 403, _):
                unavailable = true
                state = .hidden
            default: break
            }
            return
        }
        let mine = routes.filter { $0.isRunning && (agent == nil || $0.agent == agent) }
        if let route = mine.min(by: { start(of: $0, now: now) < start(of: $1, now: now) }) {
            var since = start(of: route, now: now)
            if route.time == nil, let active = try? await client.concurrency(),
               let match = active.first(where: { $0.agent == route.agent && $0.model == route.model }), let s = match.started {
                since = s
                firstSeen[route.id] = s
            }
            lastRunning = (route.id, route.model)
            state = .running(model: route.model, since: since, switches: route.switches)
            return
        }
        // Nothing in flight: one that just ended shows as 刚刚结束 for 30 s.
        if let last = lastRunning {
            lastRunning = nil
            var filter = UsageFilter(period: .today, agent: agent)
            filter.agent = agent
            let row = (try? await client.requests(filter, limit: 1))?.rows.first
            var reason: String?
            if let row, row.switched, let session = row.session,
               let fails = try? await client.sessionRoute(session), let first = fails.first {
                reason = CallFailure.shortReason(category: first)
            }
            state = .finished(row: row, model: row?.shownModel ?? last.model, reason: reason, at: now)
            return
        }
        if case .finished(_, _, _, let at) = state, now.timeIntervalSince(at) < Self.finishedFor { return }
        state = .hidden
    }

    /// When a call started: its own `time`, else when Perch first saw it.
    private func start(of route: LiveRoute, now: Date) -> Date {
        if let t = route.time { return t }
        if let seen = firstSeen[route.id] { return seen }
        firstSeen[route.id] = now
        return now
    }
}
