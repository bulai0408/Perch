import Foundation
import Observation

/// magpie versions are `0.1.4283`: compared as numbers, part by part
/// (never as strings: `0.1.999` is older). A leading `v` is dropped; any
/// non-numeric part makes the version unknown.
struct MagpieVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// The numeric parts, e.g. `[0, 1, 4283]`.
    let parts: [Int]

    /// Parses `0.1.4283` or `v0.1.4283`; nil for anything else.
    init?(_ raw: String?) {
        guard var text = raw?.trimmed, !text.isEmpty else { return nil }
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy(\.isASCII), let n = Int(piece), n >= 0 else { return nil }
            parts.append(n)
        }
        guard !parts.isEmpty else { return nil }
        self.parts = parts
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    /// Numeric, part by part; missing parts count as 0.
    static func < (a: MagpieVersion, b: MagpieVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    /// `0.1` equals `0.1.0`.
    static func == (a: MagpieVersion, b: MagpieVersion) -> Bool { !(a < b) && !(b < a) }
    /// Hashes without trailing zeros, consistent with `==`.
    func hash(into hasher: inout Hasher) {
        var p = parts
        while p.last == 0 { p.removeLast() }
        hasher.combine(p)
    }
}

/// The newest magpie on GitHub (`yetone/magpie-releases`).
struct MagpieRelease: Codable, Equatable, Sendable {
    var tag: String
    var notes: String
    var url: URL?
    var published: Date?

    var version: MagpieVersion? { MagpieVersion(tag) }

    /// Decodes GitHub's `GET /repos/{owner}/{repo}/releases/latest`
    /// (`tag_name`, `body`, `html_url`, `published_at`); nil unless the tag
    /// is a version.
    static func decode(_ data: Data) -> MagpieRelease? {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = d["tag_name"] as? String, MagpieVersion(tag) != nil else { return nil }
        return MagpieRelease(tag: tag, notes: d["body"] as? String ?? "",
                             url: (d["html_url"] as? String).flatMap(URL.init(string:)),
                             published: QuotaDecoding.date(d["published_at"]))
    }
}

/// 1.4 magpie 版本落后提醒: the selected computer's version (`/me`) against
/// the latest release, checked at most every 6 h. Perch never updates
/// magpie (`/v1/magpie/update` is never called).
@MainActor
@Observable
final class VersionStore {
    /// GitHub's public API: the only request Perch makes outside your LAN.
    /// No token and nothing about you is sent.
    static let latestURL = URL(string: "https://api.github.com/repos/yetone/magpie-releases/releases/latest")!
    static let cacheFor: TimeInterval = 6 * 3600
    static let cacheKey = "perch.magpie-release"
    static let checkedKey = "perch.magpie-release-checked"
    static let dismissedKey = "perch.magpie-release-dismissed"

    /// The selected computer's version; nil when unread or unreadable.
    private(set) var current: MagpieVersion?
    /// Whether `/me` was asked and gave no usable version (「—」).
    private(set) var unreadable = false
    /// The newest release, cached in UserDefaults between launches.
    private(set) var latest: MagpieRelease?
    /// The release tag whose banner was closed.
    private(set) var dismissed: String?

    private let defaults: UserDefaults
    private var computerID: String?

    /// Restores the cached latest release and the dismissed tag.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        latest = defaults.data(forKey: Self.cacheKey).flatMap { try? JSONDecoder().decode(MagpieRelease.self, from: $0) }
        dismissed = defaults.string(forKey: Self.dismissedKey)
    }

    /// The release the computer is behind, if any.
    var newer: MagpieRelease? { Self.newer(current: current, latest: latest) }
    /// 「已是最新」 only when both versions are known and equal or ahead.
    var upToDate: Bool { current != nil && latest?.version != nil && newer == nil }
    /// The 额度 banner: behind, and this version not closed.
    var showsBanner: Bool { newer.map { $0.tag != dismissed } ?? false }

    /// The latest release when it is newer than `current`, else nil.
    nonisolated static func newer(current: MagpieVersion?, latest: MagpieRelease?) -> MagpieRelease? {
        guard let current, let latest, let v = latest.version, current < v else { return nil }
        return latest
    }

    /// Hides the banner until a newer release comes out.
    func dismissBanner() {
        guard let tag = newer?.tag else { return }
        dismissed = tag
        defaults.set(tag, forKey: Self.dismissedKey)
    }

    /// For a newly selected computer: forget the old one's version.
    func reset(for id: String?) {
        guard id != computerID else { return }
        computerID = id
        current = nil
        unreadable = false
    }

    /// Reads the computer's version (`GET /v1/magpie/me`) and then the
    /// latest release. Offline errors leave the version unknown, not 「—」.
    func refresh(client: MagpieClient?, computerID: String?, now: Date = .now) async {
        reset(for: computerID)
        #if DEBUG
        if DemoData.isOn {
            current = MagpieVersion("0.1.4211")
            latest = DemoData.release
            return
        }
        #endif
        if let client {
            do {
                let me = try await client.me()
                current = MagpieVersion(me.version)
                unreadable = current == nil
            } catch {
                if !error.isOffline { unreadable = true }
            }
        }
        await refreshLatest(now: now)
    }

    /// Fetches the latest magpie release from GitHub, at most every 6 h;
    /// failures are silent and keep the cached one.
    func refreshLatest(now: Date = .now) async {
        let checked = defaults.object(forKey: Self.checkedKey) as? Date
        if let checked, now.timeIntervalSince(checked) < Self.cacheFor, latest != nil { return }
        var request = URLRequest(url: Self.latestURL, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Perch", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = MagpieRelease.decode(data) else { return }
        latest = release
        defaults.set(now, forKey: Self.checkedKey)
        if let data = try? JSONEncoder().encode(release) { defaults.set(data, forKey: Self.cacheKey) }
    }
}
