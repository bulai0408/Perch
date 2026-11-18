import Foundation
import Observation

/// The 路由组 tab's state: the groups last read, and changes to them.
@MainActor
@Observable
final class RoutingStore {
    /// Where the latest read stands.
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(RoutingError)
    }

    /// What the tab shows (`RoutingGroup.listed`): no deleted group, the
    /// stopped ones last.
    private(set) var groups: [RoutingGroup] = []
    /// The groups in use, then those stopped on the computer (「已停用」).
    var activeGroups: [RoutingGroup] { groups.filter { !$0.disabled } }
    var disabledGroups: [RoutingGroup] { groups.filter(\.disabled) }
    private(set) var phase: Phase = .idle
    /// 1.5: when the groups were read, whether a load runs, how it ended.
    private(set) var freshness = Freshness()
    var lastRead: Date? { freshness.lastRead }
    /// What's shown came from the disk cache; no fresh answer yet.
    private(set) var fromCache = false
    private(set) var computerID: String?
    /// The group being saved, so its screen can disable itself.
    private(set) var saving: String?

    @ObservationIgnored private let cache: SnapshotCache
    @ObservationIgnored private var inflight: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(cache: SnapshotCache = .shared) {
        self.cache = cache
    }

    var hasData: Bool { lastRead != nil }
    /// Groups shown that aren't this load's answer: no changes until read.
    var isReadOnly: Bool { hasData && (fromCache || freshness.failure != nil) }
    /// The computer answered but the groups didn't come: the banner.
    var isStale: Bool { freshness.isStale && hasData }

    /// 403 gateway_key_not_admin: the tab shows only the explanation.
    var needsAdmin: Bool { phase == .failed(.notAdmin) }

    /// Whether this 密钥 may change 路由组: nil until magpie has answered.
    var canChange: Bool? {
        if needsAdmin { return false }
        return hasData ? true : nil
    }

    /// The computer didn't answer (连不上): OfflineCard, data dimmed.
    var isOffline: Bool { freshness.isUnreachable }

    /// The group with `id` from the last read.
    func group(_ id: String) -> RoutingGroup? { groups.first { $0.id == id } }

    /// The computer the groups are for: switching clears memory, then
    /// shows that computer's saved groups. Idempotent.
    func use(_ computer: String?) {
        guard computer != computerID else { return }
        #if DEBUG
        // Demo data isn't per computer; a reset here would blank it.
        if DemoData.isOn { computerID = computer; return }
        #endif
        reset()
        computerID = computer
        #if DEBUG
        if DemoData.isOn { return }
        #endif
        if let computer, let e = cache.load(computer: computer, name: "routing-groups"),
           let groups = try? RoutingDecoding.groups(from: e.body) {
            apply(groups, at: e.savedAt)
            fromCache = true
        }
    }

    /// One load at a time; a second call waits for the one running.
    /// `probe` asks `/me` to tell 连不上 from 没读到.
    func load(_ client: RoutingClient?, probe: MagpieClient? = nil, computer: String? = nil) async {
        #if DEBUG
        if DemoData.isOn {
            if !hasData || DemoData.state != "calm" { loadDemo() }
            return
        }
        #endif
        if let computer { use(computer) }
        guard let client else { return }
        if let inflight {
            await inflight.value
            return
        }
        generation += 1
        let mine = generation
        let task = Task { await self.run(client, probe: probe, mine: mine) }
        inflight = task
        await task.value
        if mine == generation { inflight = nil }
    }

    private func run(_ client: RoutingClient, probe: MagpieClient?, mine: Int) async {
        freshness.begin()
        if !hasData || needsAdmin { phase = .loading }
        let watch = LoadWatch(probe: probe) { [weak self] stage in
            guard let self, self.generation == mine else { return false }
            return self.freshness.mark(stage)
        }
        defer { watch.stop() }
        var error: RoutingError?
        let cut = await Together.run(until: watch.deadline, [{ @Sendable () async -> Result<Fetched<[RoutingGroup]>, RoutingError> in
            await Fetch.run { try await client.groupsWithData() }
        }], land: { [self] result in
            guard mine == generation else { return }
            switch result {
            case .success(let f):
                apply(f.value)
                if let computerID { cache.save(f.data, computer: computerID, name: "routing-groups", endpoint: RoutingClient.root) }
            case .failure(let e):
                error = e
            }
        })
        if cut { error = .timeout }
        guard mine == generation else { return }
        guard let error else {
            freshness.end(nil)
            return
        }
        let trouble = ReadTrouble(error)
        if trouble == .denied || !hasData {
            if error == .notAdmin || error == .unauthorized {
                groups = []
                freshness = Freshness()
                fromCache = false
            }
            if trouble == .denied {
                freshness.end(nil)
                phase = .failed(error)
                return
            }
        }
        let failure = await watch.failure(trouble: trouble, answered: false)
        guard mine == generation else { return }
        phase = hasData ? .loaded : .failed(error)
        freshness.end(failure)
    }

    #if DEBUG
    /// `-perch-demo`: made-up groups in the state `PERCH_DEMO_STATE` asks.
    private func loadDemo() {
        apply(DemoData.routingGroups())
        let earlier = Date.now.addingTimeInterval(-26 * 60)
        switch DemoData.state {
        case "offline":
            freshness.lastRead = earlier
            freshness.end(.unreachable)
        case "stale":
            freshness.lastRead = earlier
            freshness.end(.stale)
        case "refreshing", "slow":
            freshness.lastRead = Date.now.addingTimeInterval(-3 * 60)
            freshness.begin()
            _ = freshness.mark(DemoData.state == "slow" ? .slow : .show)
        default: break
        }
    }
    #endif

    /// 设为首选, as `group.primaryChange(to:)` plans it.
    func makePrimary(_ memberID: String, in group: RoutingGroup, client: RoutingClient?) async -> Result<Void, RoutingError> {
        let plan = group.primaryChange(to: memberID)
        #if DEBUG
        if DemoData.isOn {
            // Demo screens: change the made-up group in place, no magpie.
            guard let i = groups.firstIndex(where: { $0.id == group.id }) else { return .failure(.other("demo")) }
            func ordered(_ ids: [String]) -> [RoutingMember] { ids.compactMap { id in group.members.first { $0.id == id } } }
            switch plan {
            case .reorder(let ids): groups[i].members = ordered(ids)
            case .pick(let member): groups[i].pick = member
            case .switchToOrder(let ids, _): groups[i].members = ordered(ids); groups[i].routing = "order"
            }
            return .success(())
        }
        #endif
        return await change(group, client: client) { (client: RoutingClient) async throws(RoutingError) -> [RoutingGroup] in
            switch plan {
            case .reorder(let members):
                try await client.update(group.id, members: members)
            case .pick(let member):
                try await client.pick(group.id, member: member)
            case .switchToOrder(let members, _):
                try await client.update(group.id, members: members, routing: .order)
            }
        }
    }

    /// 调整顺序 → 完成: only the order changes.
    func reorder(_ group: RoutingGroup, to members: [String], client: RoutingClient?) async -> Result<Void, RoutingError> {
        guard members != group.members.map(\.id) else { return .success(()) }
        return await change(group, client: client) { (client: RoutingClient) async throws(RoutingError) -> [RoutingGroup] in
            try await client.update(group.id, members: members)
        }
    }

    /// 选用方式. Manual starts on the first model, so 首选 stays the top row.
    func setMode(_ mode: RoutingMode, of group: RoutingGroup, client: RoutingClient?) async -> Result<Void, RoutingError> {
        guard mode != group.mode else { return .success(()) }
        return await change(group, client: client) { (client: RoutingClient) async throws(RoutingError) -> [RoutingGroup] in
            try await client.update(group.id, routing: mode, pick: mode == .manual ? group.members.first?.id : nil)
        }
    }

    /// Runs one change (`work`) on `group` while marking it as saving.
    /// Adopts the group list magpie answers with (or re-reads it when the
    /// answer was unreadable). Only one change runs at a time.
    private func change(_ group: RoutingGroup, client: RoutingClient?,
                        _ work: (RoutingClient) async throws(RoutingError) -> [RoutingGroup]) async -> Result<Void, RoutingError> {
        guard let client else { return .failure(.unauthorized) }
        guard saving == nil else { return .failure(.other("busy")) }
        saving = group.id
        defer { saving = nil }
        do {
            let fresh = try await work(client)
            if fresh.isEmpty {
                // An answer this version can't read: read the list again.
                let f = try await client.groupsWithData()
                apply(f.value)
                if let computerID { cache.save(f.data, computer: computerID, name: "routing-groups", endpoint: RoutingClient.root) }
            } else {
                apply(fresh)
            }
            return .success(())
        } catch {
            if error == .notAdmin || error == .unauthorized { phase = .failed(error) }
            return .failure(error)
        }
    }

    /// Memory only (disconnect, 换一台电脑); the disk cache stays.
    func reset() {
        inflight?.cancel()
        inflight = nil
        generation += 1
        computerID = nil
        groups = []
        phase = .idle
        freshness = Freshness()
        fromCache = false
        saving = nil
    }

    /// Adopts a freshly read list and clears any stale/failed state.
    private func apply(_ fresh: [RoutingGroup], at date: Date = .now) {
        groups = RoutingGroup.listed(fresh)
        freshness.succeed(at: date)
        fromCache = false
        phase = .loaded
    }
}
