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

    /// The groups from the last successful read, in magpie's order.
    private(set) var groups: [RoutingGroup] = []
    /// The latest read's state; drives loading/error screens.
    private(set) var phase: Phase = .idle
    /// When `groups` was last read successfully.
    private(set) var lastRead: Date?
    /// Set when the latest read failed for network reasons but older
    /// groups are still shown (read-only).
    private(set) var staleSince: Date?
    /// The group being saved, so its screen can disable itself.
    private(set) var saving: String?

    /// Groups have been read at least once.
    var hasData: Bool { lastRead != nil }
    /// Older groups are shown while offline: changes are disabled.
    var isReadOnly: Bool { staleSince != nil }

    /// 403 gateway_key_not_admin: the tab shows only the explanation.
    var needsAdmin: Bool { phase == .failed(.notAdmin) }

    /// Whether this 密钥 may change 路由组: nil until magpie has answered.
    var canChange: Bool? {
        if needsAdmin { return false }
        return hasData ? true : nil
    }

    /// The last read failed for want of a connection.
    var isOffline: Bool {
        if staleSince != nil { return true }
        if case .failed(let error) = phase { return error.isOffline }
        return false
    }

    /// The group with `id` from the last read.
    func group(_ id: String) -> RoutingGroup? { groups.first { $0.id == id } }

    /// Reads every group (`GET /v1/magpie/admin/routing-groups`).
    /// Offline with data → keep the old list and mark it stale; 401/403 → drop
    /// the list and fail; other errors → `.failed`. In DEBUG demo mode the
    /// synthetic groups from `DemoData` are used instead.
    func load(_ client: RoutingClient?) async {
        #if DEBUG
        if DemoData.isOn, !hasData { apply(DemoData.routingGroups()); return }
        if DemoData.isOn { return }
        #endif
        guard let client else { return }
        if !hasData || needsAdmin { phase = .loading }
        do {
            apply(try await client.groups())
        } catch {
            if error.isOffline, hasData {
                staleSince = lastRead
                phase = .loaded
            } else {
                if error == .notAdmin || error == .unauthorized {
                    groups = []
                    lastRead = nil
                    staleSince = nil
                }
                phase = .failed(error)
            }
        }
    }

    /// 设为首选, as `group.primaryChange(to:)` plans it.
    func makePrimary(_ memberID: String, in group: RoutingGroup, client: RoutingClient?) async -> Result<Void, RoutingError> {
        let plan = group.primaryChange(to: memberID)
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
                apply(try await client.groups())
            } else {
                apply(fresh)
            }
            return .success(())
        } catch {
            if error == .notAdmin || error == .unauthorized { phase = .failed(error) }
            return .failure(error)
        }
    }

    /// Forgets everything (on disconnect or switching computers).
    func reset() {
        groups = []
        phase = .idle
        lastRead = nil
        staleSince = nil
        saving = nil
    }

    /// Adopts a freshly read list and clears any stale/failed state.
    private func apply(_ fresh: [RoutingGroup]) {
        groups = fresh
        lastRead = .now
        staleSince = nil
        phase = .loaded
    }
}
