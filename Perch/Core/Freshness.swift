import Foundation

/// 1.5 slow network: how fresh one tab's data is, shared by
/// 额度, Agent and 路由组. The status capsule reads it.
struct Freshness: Equatable, Sendable {
    enum Failure: Equatable, Sendable {
        /// The computer doesn't answer (connection errors, `/me` fails too):
        /// OfflineCard, data dimmed, capsule 「连不上」.
        case unreachable
        /// The computer answers but the page's data didn't come (timeout,
        /// HTTP error): banner 「没读到最新的，下面是 10:42 的数据。」.
        case stale
    }

    /// When the page's main data was last read (or saved, from the cache).
    var lastRead: Date?
    /// A load is running (any load: first, pull, foreground, `.task`).
    var running = false
    /// Shown as 「正在刷新」: the load has run past 400 ms (no flicker on LAN).
    var refreshing = false
    /// The load has run longer than `LoadBudget.slowAfter`: 「还在刷新」.
    var slow = false
    /// How the last load ended, when it didn't work.
    var failure: Failure?

    var isUnreachable: Bool { failure == .unreachable }
    var isStale: Bool { failure == .stale }

    mutating func begin() {
        running = true
        slow = false
    }

    mutating func succeed(at date: Date = .now) {
        lastRead = date
        failure = nil
    }

    mutating func end(_ failure: Failure?) {
        running = false
        refreshing = false
        slow = false
        self.failure = failure
    }
}

/// Timing of one load.
enum LoadBudget {
    static let showAfter: Duration = .milliseconds(400)
    static let slowAfter: Duration = .seconds(4)
    static let total: Duration = .seconds(12)
    /// `/me`, asked when a load is slow or failed, to tell 连不上 from 没读到.
    static let probeTimeout: TimeInterval = 4
}

/// The one way Perch writes when data was read.
enum FreshnessText {
    /// 刚刚更新 · 3 分钟前更新 · 10:42 更新 · 昨天 22:10 更新 · 11月14日 22:10 更新.
    static func updated(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return String(localized: "刚刚更新") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return String(localized: "\(minutes.text) 分钟前更新") }
        return String(localized: "\(when(date, now: now, calendar: calendar)) 更新")
    }

    /// 「10:42」 today, 「昨天 22:10」, 「11月14日 22:10」 before.
    static func when(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let clock = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) || date > now { return clock }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "昨天 \(clock)")
        }
        return String(localized: "\(c.month ?? 0)月\(c.day ?? 0)日 \(clock)")
    }

    /// What follows the computer's name in the capsule, if anything.
    static func status(_ f: Freshness, now: Date = .now, calendar: Calendar = .current) -> String? {
        if f.isUnreachable { return String(localized: "连不上") }
        if f.refreshing { return f.slow ? String(localized: "还在刷新") : String(localized: "正在刷新") }
        guard let last = f.lastRead else { return nil }
        // While the whole-page banner shows, the
        // clock time, the same as the banner's, never 刚刚 / x 分钟前.
        if f.isStale { return String(localized: "\(when(last, now: now, calendar: calendar)) 更新") }
        return updated(last, now: now, calendar: calendar)
    }

    /// 「office-mac · 3 分钟前更新」.
    static func capsule(computer: String, _ f: Freshness, now: Date = .now) -> String {
        guard let status = status(f, now: now) else { return computer }
        return "\(computer) · \(status)"
    }

    /// VoiceOver: 「office-mac，3 分钟前更新」.
    static func spoken(computer: String, _ f: Freshness, now: Date = .now) -> String {
        guard let status = status(f, now: now) else { return computer }
        return "\(computer)，\(status)"
    }

    /// Banner 「没读到最新的，下面是 10:42 的数据。」.
    static func banner(_ since: Date, now: Date = .now) -> String {
        String(localized: "没读到最新的，下面是 \(when(since, now: now)) 的数据。")
    }

    /// A card's footer 「这张没读到最新的，还是 10:42 的数据。」.
    static func cardFooter(_ since: Date, now: Date = .now) -> String {
        String(localized: "这张没读到最新的，还是 \(when(since, now: now)) 的数据。")
    }
}

/// What kind of trouble a failed read was.
enum ReadTrouble: Equatable, Sendable {
    /// No connection at all (refused, no route, no network, no permission).
    case connection
    /// Asked, but no answer in time.
    case timeout
    /// magpie answered with an error.
    case answered
    /// 401/403 and the like: a permission state, not a network one.
    case denied

    /// `other` codes: an HTTP status or unreadable JSON means magpie
    /// answered; URLError codes and the rest count as no answer in time.
    static func other(_ code: String) -> ReadTrouble {
        if code == "JSON" || code == "?" { return .answered }
        if let n = Int(code), n >= 400 { return .answered }
        return .timeout
    }

    init(_ e: QuotaError) {
        switch e {
        case .unreachable, .localNetworkDenied: self = .connection
        case .timeout: self = .timeout
        case .unauthorized, .forbidden: self = .denied
        case .other(let code): self = Self.other(code)
        }
    }

    init(_ e: MagpieAPIError) {
        switch e {
        case .unreachable, .localNetworkDenied: self = .connection
        case .timeout: self = .timeout
        case .unauthorized, .held, .readOnly, .notAdmin: self = .denied
        case .accountsOff, .unsupported, .rejected: self = .answered
        case .other(let code): self = Self.other(code)
        }
    }

    init(_ e: RoutingError) {
        switch e {
        case .unreachable, .localNetworkDenied: self = .connection
        case .timeout: self = .timeout
        case .unauthorized, .notAdmin: self = .denied
        case .rejected: self = .answered
        case .other(let code): self = Self.other(code)
        }
    }
}

/// Tells 「连不上」 from 「连得上但没读到」 for one load.
enum Reachability {
    /// `answered`: something in this load got an answer from magpie.
    /// `probe`: whether `/me` answered (nil if not asked).
    static func failure(trouble: ReadTrouble, answered: Bool, probe: Bool?) -> Freshness.Failure {
        if answered || trouble == .answered { return .stale }
        if trouble == .connection { return .unreachable }
        return probe == true ? .stale : .unreachable
    }

    /// Whether the computer answers at all: `/me` with any HTTP answer.
    static func probe(_ client: MagpieClient?) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.me(timeout: LoadBudget.probeTimeout)
            return true
        } catch {
            return ReadTrouble(error) != .connection && ReadTrouble(error) != .timeout
        }
    }
}

/// Runs reads together and hands each result over on the main actor as it
/// lands; stops waiting at `deadline`.
///
/// Build 1.5 (5) crashed on launch (iOS 27.2.1): this took
/// `isolation: isolated (any Actor)? = #isolation` and called `land` inside
/// a `withTaskGroup` body, which on device ran on a cooperative thread, so
/// the stores' main-actor code ran off the main actor and the runtime's
/// isolation check trapped (QuotasStore.record ← applyCards ← land). Now
/// `land` is only ever called from this `@MainActor` function's own body,
/// after an `await`, never from a closure handed to the concurrency library.
enum Together {
    /// Returns true when the deadline cut it short.
    @MainActor
    static func run<P: Sendable>(until deadline: ContinuousClock.Instant,
                                 _ jobs: [@Sendable () async -> P],
                                 land: (P) -> Void) async -> Bool {
        guard !jobs.isEmpty else { return false }
        let (results, sink) = AsyncStream.makeStream(of: P?.self)
        var tasks = jobs.map { job in
            Task.detached { _ = sink.yield(await job()) }
        }
        tasks.append(Task.detached {
            try? await Task.sleep(until: deadline, clock: .continuous)
            _ = sink.yield(nil)
        })
        defer {
            for task in tasks { task.cancel() }
            sink.finish()
        }
        var left = jobs.count
        // Ends early (nil) when the caller's task is cancelled.
        for await next in results {
            guard let part = next else { return true }
            land(part)
            left -= 1
            if left == 0 { return false }
        }
        return false
    }
}

/// The three read errors share a `timeout` case.
protocol ReadError: Error, Sendable {
    static var timeout: Self { get }
}

extension QuotaError: ReadError {}
extension MagpieAPIError: ReadError {}
extension RoutingError: ReadError {}

/// A decoded answer and the raw one (for the disk cache).
struct Fetched<T: Sendable>: Sendable {
    var value: T
    var data: Data
}

enum Fetch {
    /// One read as a `Result`, for `Together.run`.
    static func run<T: Sendable, E: ReadError>(_ work: () async throws -> (value: T, data: Data)) async -> Result<Fetched<T>, E> {
        do {
            let r = try await work()
            return .success(Fetched(value: r.value, data: r.data))
        } catch let error as E {
            return .failure(error)
        } catch {
            return .failure(E.timeout)
        }
    }
}

/// One load's clock: 「还在刷新」 after 4 s, the 12 s deadline, and the
/// `/me` probe (asked once the load is slow, or when it fails) that tells
/// 连不上 from 没读到.
@MainActor
final class LoadWatch {
    let deadline: ContinuousClock.Instant
    private let client: MagpieClient?
    private var slowTask: Task<Void, Never>?
    private var probeTask: Task<Bool, Never>?

    enum Stage: Sendable { case show, slow }

    /// `onStage` marks 正在刷新 (400 ms) and 还在刷新 (4 s) on the store and
    /// returns whether the load is still the current, running one.
    init(probe client: MagpieClient?, onStage: @escaping @MainActor @Sendable (Stage) -> Bool) {
        deadline = .now + LoadBudget.total
        self.client = client
        slowTask = Task { [weak self] in
            try? await Task.sleep(for: LoadBudget.showAfter)
            guard !Task.isCancelled, onStage(.show) else { return }
            try? await Task.sleep(for: LoadBudget.slowAfter - LoadBudget.showAfter)
            guard !Task.isCancelled, onStage(.slow) else { return }
            self?.startProbe()
        }
    }

    private func startProbe() {
        guard probeTask == nil else { return }
        let client = client
        probeTask = Task { await Reachability.probe(client) }
    }

    /// How a failed load ends: 连不上 or 没读到.
    func failure(trouble: ReadTrouble, answered: Bool) async -> Freshness.Failure {
        if answered || trouble == .answered { return .stale }
        if trouble == .connection { return .unreachable }
        startProbe()
        let ok = await probeTask?.value ?? false
        return Reachability.failure(trouble: trouble, answered: answered, probe: ok)
    }

    func stop() {
        slowTask?.cancel()
    }
}

extension Freshness {
    /// What `LoadWatch` asks for at 400 ms and 4 s. False once ended.
    mutating func mark(_ stage: LoadWatch.Stage) -> Bool {
        guard running else { return false }
        switch stage {
        case .show: refreshing = true
        case .slow: refreshing = true; slow = true
        }
        return true
    }
}
