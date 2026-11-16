import Foundation

/// The 地址 a person types, made into the base URL Perch calls.
enum MagpieAddress {
    /// The port `magpie serve` listens on by default.
    static let defaultPort = 3425

    /// Adds `http://` when there's no scheme and `:3425` when a plain-http
    /// address has no port. Drops any query, fragment and trailing slash.
    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty
        else { return nil }
        parts.scheme = scheme
        if parts.port == nil, scheme == "http" { parts.port = defaultPort }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.url
    }

    /// `192.168.1.20:3425`, for showing an address without its scheme.
    static func hostAndPort(_ url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        let shownHost = host.contains(":") ? "[\(host)]" : host
        if let port = url.port { return "\(shownHost):\(port)" }
        return shownHost
    }
}

/// The one place the computer's shown name comes from (status capsule on
/// 额度 and 路由组, the Settings connection row): a host name without its
/// trailing `.local`; an IP address as it is.
enum ComputerName {
    /// The name to show for `host`, or nil when there is nothing to show.
    /// IPv6 brackets are dropped; IPv4/IPv6 addresses are returned unchanged.
    static func display(host: String?) -> String? {
        guard var host = host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if isIPAddress(host) { return host }
        while host.hasSuffix(".") { host.removeLast() }
        if host.lowercased().hasSuffix(".local"), host.count > 6 { host.removeLast(6) }
        return host.isEmpty ? nil : host
    }

    /// Whether `host` is a literal address: anything with `:` (IPv6) or a
    /// dotted quad with each part in 0...255.
    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }   // IPv6
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard let n = Int(part), part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else { return false }
            return (0...255).contains(n)
        }
    }
}

/// How a 密钥 (`sk-magpie-…` gateway key) is shown on screen: never in full.
enum KeyMask {
    /// `sk-magpie-••••3f9a`: only the last four characters, ever.
    static func mask(_ key: String) -> String {
        let tail = key.count > 8 ? String(key.suffix(4)) : ""
        let head = key.hasPrefix("sk-magpie-") ? "sk-magpie-" : ""
        return head + "••••" + tail
    }
}
