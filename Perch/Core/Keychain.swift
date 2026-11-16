import Foundation
import Security

/// The 密钥 lives only here: a generic password, readable after first
/// unlock, never synced off this device.
enum Keychain {
    /// The Keychain service every Perch item is stored under: the app's own
    /// bundle identifier, so forks with their own bundle id keep separate items.
    static let service = Bundle.main.bundleIdentifier ?? "perch"

    /// The fixed (non-per-computer) Keychain accounts Perch has used.
    enum Account: String {
        /// 1.0–1.3: the one `sk-magpie-…` key. 1.4 moves it to a per-computer
        /// item (see `computerAccount(_:)`) and deletes this one.
        case gatewayKey = "gateway-key"
        /// 1.0 kept the `magpie web --lan` link here. 1.1 has no use for
        /// it: `purgeLegacy()` deletes it so it doesn't linger.
        case legacyWebLink = "web-link"
    }

    /// Reads a fixed account; nil when missing or empty.
    static func read(_ account: Account) -> String? { read(raw: account.rawValue) }

    /// Stores `value` under a fixed account. Returns whether it was saved.
    @discardableResult
    static func write(_ value: String, for account: Account) -> Bool { write(value, raw: account.rawValue) }

    /// Deletes a fixed account's item (no error when it is already gone).
    static func delete(_ account: Account) { delete(raw: account.rawValue) }

    /// 1.4: each computer's 密钥 is its own item, `gateway-key.<id>`.
    static func computerAccount(_ id: String) -> String { "\(Account.gatewayKey.rawValue).\(id)" }

    /// Reads the UTF-8 string stored under `account`.
    /// - Returns: the value, or nil when there is no item or it is empty.
    static func read(raw account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Updates the item under `account`, or adds it when there is none.
    /// Items are `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: never in
    /// backups restored to another device, never in iCloud Keychain.
    /// - Returns: whether the Keychain accepted the write.
    @discardableResult
    static func write(_ value: String, raw account: String) -> Bool {
        let data = Data(value.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = baseQuery(account)
        add.merge(update) { _, new in new }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Deletes the item under `account`, if any.
    static func delete(raw account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    /// Removes what older versions stored and 1.1 no longer uses.
    static func purgeLegacy() {
        delete(.legacyWebLink)
    }

    /// The generic-password query that identifies one item of this app.
    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Where the 密钥 are kept: the Keychain in the app, memory in unit tests.
protocol SecretStore {
    /// The secret stored under `account`, or nil.
    func read(_ account: String) -> String?
    /// Stores (or replaces) the secret under `account`.
    func write(_ value: String, _ account: String)
    /// Forgets the secret under `account`.
    func delete(_ account: String)
}

/// The production `SecretStore`: a thin wrapper over `Keychain`.
struct KeychainSecrets: SecretStore {
    func read(_ account: String) -> String? { Keychain.read(raw: account) }
    func write(_ value: String, _ account: String) { Keychain.write(value, raw: account) }
    func delete(_ account: String) { Keychain.delete(raw: account) }
}
