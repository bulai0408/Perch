import Foundation

/// One saved answer: magpie's raw response, read again with the same
/// defensive decoders as a live one. No 密钥, no address, no headers.
struct CachedResponse: Codable, Equatable, Sendable {
    var savedAt: Date
    /// The route and query it came from (for reading the file by hand).
    var endpoint: String
    var body: Data
}

/// 1.5: the last good answers per computer, so a cold launch shows them at
/// once. `Library/Caches/perch/<computerID>/<name>.json`, written
/// atomically. The system may purge it; Perch then just reads again.
struct SnapshotCache: Sendable {
    let root: URL

    static let shared = SnapshotCache(root: URL.cachesDirectory.appending(path: "perch", directoryHint: .isDirectory))

    func save(_ body: Data, computer: String, name: String, endpoint: String, at date: Date = .now) {
        let dir = directory(computer)
        let entry = CachedResponse(savedAt: date, endpoint: endpoint, body: body)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entry)
            try data.write(to: file(computer, name), options: [.atomic])
        } catch {
            // A cache that can't be written is only a slower next launch.
        }
    }

    func load(computer: String, name: String) -> CachedResponse? {
        guard let data = try? Data(contentsOf: file(computer, name)) else { return nil }
        return try? JSONDecoder().decode(CachedResponse.self, from: data)
    }

    /// 删掉 a computer: its saved answers go too.
    func remove(computer: String) {
        try? FileManager.default.removeItem(at: directory(computer))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    func directory(_ computer: String) -> URL {
        root.appending(path: Self.safe(computer), directoryHint: .isDirectory)
    }

    private func file(_ computer: String, _ name: String) -> URL {
        directory(computer).appending(path: Self.safe(name) + ".json", directoryHint: .notDirectory)
    }

    /// File-name safe: letters, digits, `-`, `_` and `.`; the rest `_`.
    static func safe(_ text: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let out = String(text.map { allowed.contains($0) ? $0 : "_" })
        return out.isEmpty || out == "." || out == ".." ? "_" : out
    }
}
