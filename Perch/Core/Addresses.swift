import Foundation

/// The 地址 a person types, made into the base URL Perch calls.
enum MagpieAddress {
    /// The port `magpie serve` listens on by default.
    static let defaultPort = 3425

    /// Adds `http://` when there's no scheme and `:3425` when a plain-http
    /// address has no port. Drops any query, fragment and trailing slash,
    /// and a trailing `/v1` (magpie's OpenAI-style address in Settings):
    /// Perch adds `/v1/magpie/…` itself, so keeping it would call `/v1/v1/…`.
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
        parts.path = trimmedPath(parts.path)
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.url
    }

    /// Without trailing slashes and one trailing `/v1` (`/v1/`, any case).
    static func trimmedPath(_ path: String) -> String {
        var path = path
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/v1") {
            path.removeLast(3)
            while path.hasSuffix("/") { path.removeLast() }
        }
        return path
    }

    /// A saved address (before 1.5 a trailing `/v1` was kept) as Perch
    /// calls it now: `…/v1` dropped, everything else as it was.
    static func droppingV1(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let path = trimmedPath(parts.path)
        guard path != parts.path, parts.path.lowercased().hasSuffix("/v1") || parts.path.lowercased().hasSuffix("/v1/") else { return url }
        parts.path = path
        return parts.url ?? url
    }

    /// Whether a host is reached over Tailscale: 100.64.0.0/10, a MagicDNS
    /// name (`*.ts.net`, or a bare name with no dot), or fd7a:115c:a1e0::/48.
    /// Picks which 连不上 checklist ConnectView shows.
    static func isTailscale(host raw: String) -> Bool {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }
        if host.contains(":") {
            // IPv6 (a zone like `%en0` dropped): the first 48 bits.
            let address = host.split(separator: "%").first.map(String.init) ?? host
            var bytes = [UInt8](repeating: 0, count: 16)
            guard inet_pton(AF_INET6, address, &bytes) == 1 else { return false }
            return bytes.prefix(6).elementsEqual([0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0])
        }
        if ComputerName.isIPAddress(host) {
            let octets = host.split(separator: ".").compactMap { Int($0) }
            return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
        }
        if host.hasSuffix(".ts.net") { return true }
        // A bare MagicDNS name (`office-mac`); all digits is no name at all.
        return !host.contains(".") && !host.allSatisfy(\.isNumber)
    }

    /// The address as Settings shows it: without `http://` or `https://`,
    /// everything else kept (`office-mac.local:3425`, `box.example/magpie`).
    static func shown(_ url: URL) -> String {
        let text = url.absoluteString
        for scheme in ["http://", "https://"] where text.lowercased().hasPrefix(scheme) {
            return String(text.dropFirst(scheme.count))
        }
        return text
    }

    /// `shown(url)` prepared for a two-line wrap that never breaks inside
    /// the host or the port: a zero-width space before `:port` (the one
    /// preferred break), one after each `.` of an IPv4 host (only used when
    /// the host alone doesn't fit), and `-` in the host as U+2011 so the
    /// line can't break after a hyphen. Lay it out as `en` (see
    /// `wrappingText`) so CJK char-level breaking doesn't apply.
    static func wrappable(_ url: URL) -> String {
        let text = shown(url)
        // The host runs up to the first `/`, `?` or `#`; `[v6]` keeps its colons.
        let hostEnd = text.firstIndex(where: { "/?#".contains($0) }) ?? text.endIndex
        var authority = String(text[..<hostEnd])
        let rest = String(text[hostEnd...])
        var port = ""
        if let colon = authority.lastIndex(of: ":"),
           !authority[authority.index(after: colon)...].contains("]"),
           authority.hasPrefix("[") ? authority[..<colon].hasSuffix("]") : true {
            port = String(authority[colon...])
            authority = String(authority[..<colon])
        }
        var host = authority.replacingOccurrences(of: "-", with: "\u{2011}")
        if ComputerName.isIPAddress(host), !host.contains(":") {
            host = host.replacingOccurrences(of: ".", with: ".\u{200B}")
        }
        return host + (port.isEmpty ? "" : "\u{200B}" + port) + rest
    }

    /// `wrappable(url)` laid out as `en`: under zh-Hans CoreText breaks
    /// Latin runs anywhere (`192.168.1.30:342` / `5`), as in AgentSummary.
    static func wrappingText(_ url: URL) -> AttributedString {
        var text = AttributedString(wrappable(url))
        text.languageIdentifier = "en"
        return text
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
