import Foundation
import Observation

/// One magpie Perch knows (1.4 多台电脑). magpie doesn't report a
/// computer name, so the name is the person's, else the 地址's host.
struct Computer: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// A random UUID; also names the computer's Keychain item.
    var id: String
    /// What the person called it, else the host part of the address.
    var name: String
    /// The normalized gateway base URL (see `MagpieAddress.normalize`).
    var address: URL
    /// The last time magpie answered on it.
    var lastConnected: Date?
}

/// What the capsule menu and Settings say about a computer.
enum ComputerStatus: Equatable, Sendable {
    /// magpie answered this session.
    case connected
    /// magpie didn't answer and never has.
    case unreachable
    /// Not answering (or not asked yet); it last answered at this date.
    case lastSeen(Date)
    /// Not asked yet and never connected.
    case unknown
}

/// The saved computers. Each 地址 sits in UserDefaults; each 密钥 only in
/// its own Keychain item (`gateway-key.<id>`). The masked key of the
/// selected one is kept in memory only.
@MainActor
@Observable
final class ConnectionStore {
    /// UserDefaults key for the JSON-encoded `[Computer]`.
    static let computersKey = "perch.computers"
    /// UserDefaults key for the selected computer's id.
    static let currentKey = "perch.computer"
    /// 1.0–1.3 kept one connection: this address and the `gateway-key` item.
    static let legacyAddressKey = "perch.address"

    /// Every saved computer, in the order they were added.
    private(set) var computers: [Computer] = []
    /// The selected computer's id; nil when none is saved.
    private(set) var currentID: String?
    /// The selected computer's key as `KeyMask` shows it; nil when no key.
    private(set) var maskedKey: String?
    /// Whether each computer answered this session (nil: not asked yet).
    private(set) var reachable: [String: Bool] = [:]
    /// 「已换到 %@」, shown by the tabs.
    var toast: String?

    private let defaults: UserDefaults
    private let secrets: SecretStore

    /// Loads the saved computers, migrating a 1.0–1.3 single connection.
    /// - Parameters:
    ///   - defaults: where addresses live (a scratch suite in unit tests).
    ///   - secrets: where keys live (`MemorySecrets` in unit tests).
    init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainSecrets()) {
        self.defaults = defaults
        self.secrets = secrets
        // 1.0's 网页版链接 must not outlive the update.
        if secrets is KeychainSecrets { Keychain.purgeLegacy() }
        migrate()
        load()
    }

    /// The selected computer.
    var current: Computer? { computers.first { $0.id == currentID } }
    /// The selected computer's gateway address.
    /// The selected computer's gateway address.
    var address: URL? { current?.address }
    /// A computer is selected and has a key: the tabs show, not Connect.
    var isConnected: Bool { current != nil && maskedKey != nil }

    /// The selected computer's name, shown by every status capsule.
    var computerName: String? { current?.name }

    /// `office-mac` for `office-mac.local`, the IP when there's no name.
    nonisolated static func defaultName(for address: URL) -> String {
        ComputerName.display(host: address.host()) ?? address.absoluteString
    }

    /// The Keychain account holding computer `id`'s key.
    nonisolated static func keyAccount(_ id: String) -> String { Keychain.computerAccount(id) }

    /// The selected computer's key, read from the Keychain each time.
    func gatewayKey() -> String? { currentID.flatMap(key(for:)) }
    /// Computer `id`'s key; nil when missing or empty.
    func key(for id: String) -> String? { secrets.read(Self.keyAccount(id)).flatMap { $0.isEmpty ? nil : $0 } }

    /// A client for the selected computer's quota cards, or nil.
    func quotaClient() -> QuotaClient? {
        guard let address, let key = gatewayKey() else { return nil }
        return QuotaClient(base: address, key: key)
    }

    /// A client for the selected computer's routing groups, or nil.
    func routingClient() -> RoutingClient? {
        guard let address, let key = gatewayKey() else { return nil }
        return RoutingClient(base: address, key: key)
    }

    /// A client for the selected computer's usage/quota/me routes, or nil.
    func magpieClient() -> MagpieClient? {
        guard let current else { return nil }
        return magpieClient(for: current)
    }

    /// A client for any saved computer (used to probe the others).
    func magpieClient(for computer: Computer) -> MagpieClient? {
        guard let key = key(for: computer.id) else { return nil }
        return MagpieClient(base: computer.address, key: key)
    }

    // MARK: Changes

    /// First connect and 更换 密钥: updates the selected computer, or adds
    /// one named after its host when there is none.
    func saveQuotaConnection(address: URL, key: String) {
        guard let id = currentID, let i = computers.firstIndex(where: { $0.id == id }) else {
            add(name: nil, address: address, key: key)
            return
        }
        if computers[i].address != address, computers[i].name == Self.defaultName(for: computers[i].address) {
            computers[i].name = Self.defaultName(for: address)
        }
        computers[i].address = address
        computers[i].lastConnected = .now
        secrets.write(key, Self.keyAccount(id))
        reachable[id] = true
        save()
    }

    /// 添加电脑: a new computer (or the one already at this 地址, with the
    /// new 密钥), selected. An empty name becomes the host part.
    @discardableResult
    func add(name: String?, address: URL, key: String) -> Computer {
        let given = name?.trimmed ?? ""
        let computer: Computer
        if let i = computers.firstIndex(where: { $0.address == address }) {
            if !given.isEmpty { computers[i].name = given }
            computers[i].lastConnected = .now
            computer = computers[i]
        } else {
            computer = Computer(id: UUID().uuidString, name: given.isEmpty ? Self.defaultName(for: address) : given,
                                address: address, lastConnected: .now)
            computers.append(computer)
        }
        secrets.write(key, Self.keyAccount(computer.id))
        reachable[computer.id] = true
        currentID = computer.id
        save()
        return computer
    }

    /// 换一台电脑. `announce` shows 「已换到 %@」.
    func select(_ id: String, announce: Bool = true) {
        guard let computer = computers.first(where: { $0.id == id }), id != currentID else { return }
        currentID = id
        save()
        if announce { toast = String(localized: "已换到 \(computer.name)") }
    }

    /// Renames a computer; an empty name goes back to the host part.
    func rename(_ id: String, to name: String) {
        guard let i = computers.firstIndex(where: { $0.id == id }) else { return }
        let text = name.trimmed
        computers[i].name = text.isEmpty ? Self.defaultName(for: computers[i].address) : text
        save()
    }

    /// 删掉: the computer and its 密钥. Removing the selected one selects
    /// the next; with none left, Perch is back at 连接 magpie.
    func remove(_ id: String) {
        secrets.delete(Self.keyAccount(id))
        // 1.5: its saved answers go with it.
        SnapshotCache.shared.remove(computer: id)
        computers.removeAll { $0.id == id }
        reachable[id] = nil
        if currentID == id { currentID = computers.first?.id }
        save()
    }

    /// 断开连接: forgets the selected computer and its 密钥.
    func disconnect() {
        if let id = currentID { remove(id) }
        if computers.isEmpty { purgeLegacyConnection() }
    }

    /// `-perch-reset`: every computer and 密钥 gone.
    func removeAll() {
        for c in computers {
            secrets.delete(Self.keyAccount(c.id))
            SnapshotCache.shared.remove(computer: c.id)
        }
        computers = []
        currentID = nil
        reachable = [:]
        purgeLegacyConnection()
        save()
    }

    /// What a read just said about a computer.
    func markReachable(_ id: String, _ ok: Bool, at date: Date = .now) {
        reachable[id] = ok
        if ok, let i = computers.firstIndex(where: { $0.id == id }) {
            // Saved at most once a minute; the menu shows minutes at best.
            let old = computers[i].lastConnected
            computers[i].lastConnected = date
            if old.map({ date.timeIntervalSince($0) > 60 }) ?? true { save() }
        }
    }

    /// Settings: 已连接 / 连不上. The menu adds 「上次连上：…」.
    func status(of computer: Computer) -> ComputerStatus {
        switch reachable[computer.id] {
        case true?: return .connected
        case false?: return computer.lastConnected.map { .lastSeen($0) } ?? .unreachable
        case nil: return computer.lastConnected.map { .lastSeen($0) } ?? .unknown
        }
    }

    /// Asks every other computer's magpie whether it is there (`/me`).
    func probeOthers() async {
        for computer in computers where computer.id != currentID {
            guard let client = magpieClient(for: computer) else { continue }
            let ok: Bool
            do { _ = try await client.me(timeout: 4); ok = true } catch { ok = !error.isOffline }
            markReachable(computer.id, ok)
        }
    }

    #if DEBUG
    /// `-perch-demo`: office-mac (selected) and 家里, seen 2 hours ago.
    func seedDemo(_ list: [(name: String, address: URL, key: String, lastSeen: Date?, reachable: Bool?)]) {
        removeAll()
        for item in list {
            let c = Computer(id: UUID().uuidString, name: item.name, address: item.address, lastConnected: item.lastSeen)
            computers.append(c)
            secrets.write(item.key, Self.keyAccount(c.id))
            reachable[c.id] = item.reachable
        }
        currentID = computers.first?.id
        save()
    }
    #endif

    // MARK: Storage

    /// 1.3's one connection becomes the first computer, its 密钥 moved to
    /// the computer's own item.
    private func migrate() {
        guard defaults.data(forKey: Self.computersKey) == nil,
              let raw = defaults.string(forKey: Self.legacyAddressKey),
              let address = URL(string: raw)
        else { return }
        let computer = Computer(id: UUID().uuidString, name: Self.defaultName(for: address), address: address, lastConnected: nil)
        if let key = secrets.read(Keychain.Account.gatewayKey.rawValue), !key.isEmpty {
            secrets.write(key, Self.keyAccount(computer.id))
        }
        secrets.delete(Keychain.Account.gatewayKey.rawValue)
        computers = [computer]
        currentID = computer.id
        save()
        defaults.removeObject(forKey: Self.legacyAddressKey)
    }

    /// Deletes the 1.0–1.3 key item and address, if still there.
    private func purgeLegacyConnection() {
        secrets.delete(Keychain.Account.gatewayKey.rawValue)
        defaults.removeObject(forKey: Self.legacyAddressKey)
    }

    /// Reads computers and the selection from UserDefaults; a stale
    /// selection falls back to the first computer.
    private func load() {
        computers = defaults.data(forKey: Self.computersKey).flatMap { try? JSONDecoder().decode([Computer].self, from: $0) } ?? []
        let saved = defaults.string(forKey: Self.currentKey)
        currentID = computers.contains { $0.id == saved } ? saved : computers.first?.id
        // Before 1.5 a pasted `…/v1` address was kept and calls went to /v1/v1/….
        var fixed = false
        for i in computers.indices {
            let address = MagpieAddress.droppingV1(computers[i].address)
            if address != computers[i].address {
                computers[i].address = address
                fixed = true
            }
        }
        if fixed { save() } else { refreshMask() }
    }

    /// Writes computers and the selection back, and refreshes `maskedKey`.
    private func save() {
        if let data = try? JSONEncoder().encode(computers) { defaults.set(data, forKey: Self.computersKey) }
        if let currentID { defaults.set(currentID, forKey: Self.currentKey) } else { defaults.removeObject(forKey: Self.currentKey) }
        refreshMask()
    }

    /// Recomputes `maskedKey` from the selected computer's key.
    private func refreshMask() {
        maskedKey = gatewayKey().map(KeyMask.mask)
    }
}
