#if DEBUG
import Foundation

/// Debug builds only: slows or breaks the Perch → magpie link, for the
/// slow-network e2e tests and Simulator checks. Release builds don't compile
/// this file's contents. It sits in `QuotaClient.session` (every client's
/// session) only when one of these is set:
///
/// - `PERCH_NET_DELAY_MS=6000`: wait, then send the request for real.
/// - `PERCH_NET_FAIL=offline`: fail with no connection (`notConnectedToInternet`).
/// - `PERCH_NET_FAIL=timeout`: hang until the request's timeout, then `timedOut`.
///   `/v1/magpie/me` still answers, so the computer looks reachable.
/// - `PERCH_NET_FAIL_PATHS=/v1/magpie/usage/requests,/v1/magpie/quotas/history`:
///   fail only paths starting with one of these (`…$` for the exact path).
///   Without `PERCH_NET_FAIL` they fail as `timeout`.
/// - `PERCH_NET_FAIL_FOR_S=10`: the failures above stop 10 s after launch
///   (requests started later go through), so a recording shows 重试 recover.
final class NetworkHook: URLProtocol, @unchecked Sendable {
    enum Failure: String, Sendable { case offline, timeout }

    struct Settings: Sendable, Equatable {
        var delayMS = 0
        var fail: Failure?
        var paths: [String] = []
        /// Seconds after launch the failures stop; 0 is never.
        var failFor: Double = 0
        let started = Date()

        init(delayMS: Int = 0, fail: Failure? = nil, paths: [String] = [], failFor: Double = 0) {
            self.delayMS = delayMS
            self.fail = fail
            self.paths = paths
            self.failFor = failFor
        }

        init(_ env: [String: String]) {
            delayMS = max(0, Int(env["PERCH_NET_DELAY_MS"] ?? "") ?? 0)
            fail = env["PERCH_NET_FAIL"].flatMap { Failure(rawValue: $0.lowercased()) }
            paths = (env["PERCH_NET_FAIL_PATHS"] ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if fail == nil, !paths.isEmpty { fail = .timeout }
            failFor = max(0, Double(env["PERCH_NET_FAIL_FOR_S"] ?? "") ?? 0)
        }

        static func == (a: Settings, b: Settings) -> Bool {
            a.delayMS == b.delayMS && a.fail == b.fail && a.paths == b.paths && a.failFor == b.failFor
        }

        /// How a request to `path` started `elapsed` s after launch fails.
        func failure(for path: String, elapsed: TimeInterval) -> Failure? {
            if failFor > 0, elapsed >= failFor { return nil }
            return failure(for: path)
        }

        var isOn: Bool { delayMS > 0 || fail != nil }

        /// How a request to `path` fails, or nil to let it through.
        func failure(for path: String) -> Failure? {
            guard let fail else { return nil }
            if paths.isEmpty {
                // `timeout` is magpie not answering data reads: /me still does.
                if fail == .timeout, path.hasSuffix("/v1/magpie/me") { return nil }
                return fail
            }
            let hit = paths.contains { entry in
                entry.hasSuffix("$") ? path == String(entry.dropLast()) : path.hasPrefix(entry)
            }
            return hit ? fail : nil
        }
    }

    static let settings = Settings(ProcessInfo.processInfo.environment)
    static var isOn: Bool { settings.isOn }

    /// The real link, without the hook.
    private static let forward: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private var work: Task<Void, Never>?

    /// URLProtocol isn't Sendable; its client calls are thread-safe.
    private struct Box: @unchecked Sendable { let hook: NetworkHook }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            request.httpBody = Self.read(stream)
            request.httpBodyStream = nil
        }
        let settings = Self.settings
        let path = request.url?.path ?? ""
        let me = Box(hook: self)
        let req = request
        work = Task.detached {
            let hook = me.hook
            if settings.delayMS > 0 {
                try? await Task.sleep(for: .milliseconds(settings.delayMS))
            }
            guard !Task.isCancelled else { return }
            switch settings.failure(for: path, elapsed: Date().timeIntervalSince(settings.started)) {
            case .offline?:
                hook.client?.urlProtocol(hook, didFailWithError: URLError(.notConnectedToInternet))
            case .timeout?:
                try? await Task.sleep(for: .seconds(min(max(req.timeoutInterval, 1), 30)))
                guard !Task.isCancelled else { return }
                hook.client?.urlProtocol(hook, didFailWithError: URLError(.timedOut))
            case nil:
                do {
                    let (data, response) = try await Self.forward.data(for: req)
                    guard !Task.isCancelled else { return }
                    hook.client?.urlProtocol(hook, didReceive: response, cacheStoragePolicy: .notAllowed)
                    hook.client?.urlProtocol(hook, didLoad: data)
                    hook.client?.urlProtocolDidFinishLoading(hook)
                } catch {
                    hook.client?.urlProtocol(hook, didFailWithError: error)
                }
            }
        }
    }

    override func stopLoading() {
        work?.cancel()
    }

    private static func read(_ stream: InputStream) -> Data {
        var data = Data()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
#endif
