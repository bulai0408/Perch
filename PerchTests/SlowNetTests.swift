import Foundation
import Testing
@testable import Perch

/// 1.5 slow network: disk cache, freshness, its wording and the debug hook.

private func tempCache() -> SnapshotCache {
    SnapshotCache(root: FileManager.default.temporaryDirectory
        .appending(path: "perch-tests-\(UUID().uuidString)", directoryHint: .isDirectory))
}

private let shanghai: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return c
}()

private func at(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 11) -> Date {
    shanghai.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

struct SnapshotCacheTests {
    @Test func roundTrip() throws {
        let cache = tempCache()
        defer { cache.removeAll() }
        let body = Data(#"{"data":[]}"#.utf8)
        let saved = Date(timeIntervalSince1970: 1_800_000_000)
        cache.save(body, computer: "c1", name: "cards", endpoint: "/v1/magpie/quotas/cards", at: saved)
        let entry = try #require(cache.load(computer: "c1", name: "cards"))
        #expect(entry.body == body)
        #expect(entry.savedAt == saved)
        #expect(entry.endpoint == "/v1/magpie/quotas/cards")
        #expect(cache.load(computer: "c2", name: "cards") == nil)
    }

    @Test func removeOneComputer() {
        let cache = tempCache()
        defer { cache.removeAll() }
        cache.save(Data("1".utf8), computer: "a", name: "cards", endpoint: "")
        cache.save(Data("2".utf8), computer: "b", name: "cards", endpoint: "")
        cache.remove(computer: "a")
        #expect(cache.load(computer: "a", name: "cards") == nil)
        #expect(cache.load(computer: "b", name: "cards") != nil)
        cache.removeAll()
        #expect(cache.load(computer: "b", name: "cards") == nil)
    }

    @Test func safeNames() {
        #expect(SnapshotCache.safe("requests-claude-code-7d") == "requests-claude-code-7d")
        #expect(SnapshotCache.safe("../x/y") == ".._x_y")
        #expect(SnapshotCache.safe("..") == "_")
        #expect(SnapshotCache.safe("") == "_")
        #expect(SnapshotCache.safe("家里") == "__")
    }

    @Test func unreadableFileIsNoCache() throws {
        let cache = tempCache()
        defer { cache.removeAll() }
        let dir = cache.directory("c1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appending(path: "cards.json"))
        #expect(cache.load(computer: "c1", name: "cards") == nil)
    }
}

struct FreshnessTextTests {
    let now = at(17, 10, 45)

    @Test func updated() {
        #expect(FreshnessText.updated(now.addingTimeInterval(-20), now: now, calendar: shanghai) == "刚刚更新")
        #expect(FreshnessText.updated(now.addingTimeInterval(-3 * 60 - 5), now: now, calendar: shanghai) == "3 分钟前更新")
        #expect(FreshnessText.updated(now.addingTimeInterval(-59 * 60), now: now, calendar: shanghai) == "59 分钟前更新")
        #expect(FreshnessText.updated(at(17, 8, 2), now: now, calendar: shanghai) == "08:02 更新")
        #expect(FreshnessText.updated(at(16, 22, 10), now: now, calendar: shanghai) == "昨天 22:10 更新")
        #expect(FreshnessText.updated(at(14, 22, 10), now: now, calendar: shanghai) == "11月14日 22:10 更新")
    }

    @Test func bannerAndFooter() {
        #expect(FreshnessText.banner(at(17, 10, 42), now: now) .contains("没读到最新的，下面是 "))
        #expect(FreshnessText.banner(at(17, 10, 42), now: now).hasSuffix(" 的数据。"))
        #expect(FreshnessText.cardFooter(at(17, 10, 42), now: now).hasPrefix("这张没读到最新的，还是 "))
    }

    @Test func capsuleStates() {
        var f = Freshness()
        #expect(FreshnessText.capsule(computer: "office-mac", f, now: now) == "office-mac")
        f.succeed(at: now.addingTimeInterval(-3 * 60))
        #expect(FreshnessText.capsule(computer: "office-mac", f, now: now) == "office-mac · 3 分钟前更新")
        #expect(FreshnessText.spoken(computer: "office-mac", f, now: now) == "office-mac，3 分钟前更新")
        f.begin()
        // Under 400 ms: still the time, no 正在刷新 flicker.
        #expect(FreshnessText.status(f, now: now) == "3 分钟前更新")
        _ = f.mark(.show)
        #expect(FreshnessText.capsule(computer: "office-mac", f, now: now) == "office-mac · 正在刷新")
        _ = f.mark(.slow)
        #expect(FreshnessText.status(f, now: now) == "还在刷新")
        f.end(.stale)
        // A failed (reachable) refresh keeps the last success time, as the
        // banner's clock time.
        #expect(FreshnessText.status(f, now: now, calendar: shanghai) == "10:42 更新")
        f.begin()
        f.end(.unreachable)
        #expect(FreshnessText.capsule(computer: "office-mac", f, now: now) == "office-mac · 连不上")
    }

    /// The banner showing, the capsule says the
    /// banner's clock time, even under a minute; back to 刚刚更新 after 重试.
    @Test func pageFailedCapsuleSaysTheClockTime() {
        var f = Freshness()
        f.succeed(at: now.addingTimeInterval(-20))  // 10:44:40, under a minute ago
        #expect(FreshnessText.status(f, now: now, calendar: shanghai) == "刚刚更新")
        f.begin()
        f.end(.stale)
        #expect(FreshnessText.status(f, now: now, calendar: shanghai) == "10:44 更新")
        #expect(FreshnessText.banner(at(17, 10, 44), now: now).contains(FreshnessText.when(at(17, 10, 44), now: now)))
        #expect(FreshnessText.status(f, now: at(18, 9, 0), calendar: shanghai) == "昨天 10:44 更新")
        #expect(FreshnessText.status(f, now: at(20, 9, 0), calendar: shanghai) == "11月17日 10:44 更新")
        // The retry runs: 正在刷新; it works: 刚刚更新.
        f.begin()
        _ = f.mark(.show)
        #expect(FreshnessText.status(f, now: now) == "正在刷新")
        f.succeed(at: now)
        f.end(nil)
        #expect(FreshnessText.status(f, now: now, calendar: shanghai) == "刚刚更新")
        // A card's own failure doesn't touch the page's freshness: relative.
        f.succeed(at: now.addingTimeInterval(-3 * 60))
        #expect(FreshnessText.status(f, now: now, calendar: shanghai) == "3 分钟前更新")
    }

    @Test func noBannedWords() {
        let f = Freshness(lastRead: now)
        let texts = [
            FreshnessText.status(f, now: now) ?? "",
            FreshnessText.banner(now, now: now),
            FreshnessText.cardFooter(now, now: now),
            FreshnessText.updated(at(1, 9, 0), now: now),
        ]
        for word in ["同步", "加载完成", "最新数据", "缓存", "离线数据", "旧数据", "读取"] {
            #expect(!texts.contains { $0.contains(word) }, "\(word)")
        }
    }
}

struct FreshnessTransitionTests {
    @Test func markOnlyWhileRunning() {
        var f = Freshness()
        let r1 = f.mark(.show)
        #expect(!r1)
        #expect(!f.refreshing)
        f.begin()
        #expect(f.running && !f.refreshing)
        let r2 = f.mark(.show)
        #expect(r2)
        #expect(f.refreshing && !f.slow)
        let r3 = f.mark(.slow)
        #expect(r3)
        #expect(f.slow)
        f.end(nil)
        #expect(!f.running && !f.refreshing && !f.slow)
        let r4 = f.mark(.slow)
        #expect(!r4)
    }

    @Test func successClearsFailure() {
        var f = Freshness()
        f.end(.unreachable)
        #expect(f.isUnreachable)
        f.begin()
        f.succeed(at: .now)
        f.end(nil)
        #expect(f.failure == nil && f.lastRead != nil)
    }

    @Test func reachability() {
        #expect(Reachability.failure(trouble: .connection, answered: false, probe: nil) == .unreachable)
        #expect(Reachability.failure(trouble: .connection, answered: true, probe: nil) == .stale)
        #expect(Reachability.failure(trouble: .answered, answered: false, probe: false) == .stale)
        #expect(Reachability.failure(trouble: .timeout, answered: false, probe: true) == .stale)
        #expect(Reachability.failure(trouble: .timeout, answered: false, probe: false) == .unreachable)
    }

    @Test func readTrouble() {
        #expect(ReadTrouble(QuotaError.unreachable) == .connection)
        #expect(ReadTrouble(QuotaError.timeout) == .timeout)
        #expect(ReadTrouble(QuotaError.forbidden) == .denied)
        #expect(ReadTrouble(MagpieAPIError.held) == .denied)
        #expect(ReadTrouble(MagpieAPIError.other("502")) == .answered)
        #expect(ReadTrouble(MagpieAPIError.other("JSON")) == .answered)
        #expect(ReadTrouble(RoutingError.other("-1001")) == .timeout)
        #expect(ReadTrouble(RoutingError.notAdmin) == .denied)
    }

    @Test func budget() {
        #expect(LoadBudget.showAfter == .milliseconds(400))
        #expect(LoadBudget.slowAfter == .seconds(4))
        #expect(LoadBudget.total == .seconds(12))
    }

    @MainActor @Test func togetherAppliesEachAsItLands() async {
        var landed: [Int] = []
        let cut = await Together.run(until: .now + .seconds(5), [
            { try? await Task.sleep(for: .milliseconds(300)); return 2 },
            { 1 },
        ]) { landed.append($0) }
        #expect(!cut)
        #expect(landed == [1, 2])
    }

    @MainActor @Test func togetherStopsAtTheDeadline() async {
        var landed: [Int] = []
        let cut = await Together.run(until: .now + .milliseconds(200), [
            { 1 },
            { try? await Task.sleep(for: .seconds(5)); return 2 },
        ]) { landed.append($0) }
        #expect(cut)
        #expect(landed == [1])
    }

    /// 1.5 (5) crash: `land` ran on a cooperative thread and the stores'
    /// main-actor code trapped. Every hand-over must be on the main thread,
    /// even when the reads finish on other threads at once.
    @MainActor @Test func togetherLandsOnTheMainThread() async {
        var onMain: [Bool] = []
        let jobs: [@Sendable () async -> Int] = (0..<40).map { i in
            { @Sendable () async -> Int in try? await Task.sleep(for: .milliseconds(i % 5)); return i }
        }
        let cut = await Together.run(until: .now + .seconds(10), jobs) { _ in
            onMain.append(Thread.isMainThread)
        }
        #expect(!cut)
        #expect(onMain.count == 40)
        #expect(onMain.allSatisfy { $0 })
    }

    /// Called from off the main actor, it still hands over on the main thread.
    @Test func togetherLandsOnTheMainThreadFromElsewhere() async {
        let all = await Task.detached { () -> [Bool] in
            await Together.landedOnMain(count: 8)
        }.value
        #expect(all.count == 8)
        #expect(all.allSatisfy { $0 })
    }

    /// A cancelled load stops waiting instead of hanging.
    @MainActor @Test func togetherEndsWhenCancelled() async {
        let jobs: [@Sendable () async -> Int] = [
            { @Sendable () async -> Int in try? await Task.sleep(for: .seconds(30)); return 1 },
        ]
        let task = Task { @MainActor in
            await Together.run(until: .now + .seconds(30), jobs) { _ in }
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let start = ContinuousClock.now
        _ = await task.value
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}

extension Together {
    @MainActor static func landedOnMain(count: Int) async -> [Bool] {
        var onMain: [Bool] = []
        let jobs: [@Sendable () async -> Int] = (0..<count).map { i in { @Sendable () async -> Int in i } }
        _ = await run(until: .now + .seconds(10), jobs) { _ in
            onMain.append(Thread.isMainThread)
        }
        return onMain
    }
}

/// Cold launch: each store shows the computer's saved answers at once.
@MainActor
struct CacheRestoreTests {
    @Test func quotasRestoreAndSwitch() throws {
        let cache = tempCache()
        defer { cache.removeAll() }
        let saved = Date(timeIntervalSince1970: 1_800_000_000)
        cache.save(Data(#"{"data":[{"provider":"claude","name":"Claude","kind":"subscription","user":"w@example.com","windows":[]}]}"#.utf8),
                   computer: "c1", name: "cards", endpoint: QuotaClient.cardsPath, at: saved)
        let store = QuotasStore(cache: cache)
        store.use("c1")
        #expect(store.cards.count == 1)
        #expect(store.fromCache)
        #expect(store.lastRead == saved)
        #expect(store.phase == .loaded)
        #expect(!store.isOffline && !store.isStale)
        // Another computer with nothing saved: nothing of c1's shows.
        store.use("c2")
        #expect(store.cards.isEmpty)
        #expect(store.lastRead == nil)
        #expect(!store.fromCache)
    }

    /// 连不上: a card's leftover 「这张没读到最新的」 footer hides; the
    /// offline card alone explains it.
    @MainActor @Test func unreachableHidesCardFooters() async throws {
        let cache = tempCache()
        defer { cache.removeAll() }
        cache.save(Data(#"{"data":[{"provider":"claude","name":"Claude","kind":"subscription","user":"w@example.com","windows":[]}]}"#.utf8),
                   computer: "c1", name: "cards", endpoint: QuotaClient.cardsPath, at: .now.addingTimeInterval(-600))
        let store = QuotasStore(cache: cache)
        store.use("c1")
        let card = try #require(store.cards.first)
        // Nothing listens on port 9: connection refused, i.e. unreachable.
        let dead = URL(string: "http://127.0.0.1:9")!
        await store.refresh(card, client: QuotaClient(base: dead, key: "k"), force: true)
        #expect(store.cardStale[card.id] != nil)
        #expect(!store.isOffline)
        #expect(store.staleFooter(for: card.id) != nil)
        await store.load(QuotaClient(base: dead, key: "k"), extras: MagpieClient(base: dead, key: "k"))
        #expect(store.isOffline)
        #expect(!store.isStale)
        #expect(store.staleFooter(for: card.id) == nil)
    }

    @Test func routingRestoreIsReadOnlyUntilRead() throws {
        let cache = tempCache()
        defer { cache.removeAll() }
        cache.save(Data(RoutingDecodingTests.sample.utf8), computer: "c1", name: "routing-groups", endpoint: RoutingClient.root)
        let store = RoutingStore(cache: cache)
        store.use("c1")
        #expect(store.groups.count == 3)
        #expect(store.fromCache && store.isReadOnly)
    }

    @Test func usageRestoresThePeriodViewed() throws {
        let cache = tempCache()
        defer { cache.removeAll() }
        let defaults = try #require(UserDefaults(suiteName: "slownet-\(UUID().uuidString)"))
        let store = UsageStore(defaults: defaults, cache: cache)
        let page = #"{"period":"today","rows":[],"calls":4,"accounts":[]}"#
        cache.save(Data(page.utf8), computer: "c1", name: UsageStore.pageName(store.filter), endpoint: "")
        store.use("c1")
        #expect(store.page?.totals.calls == 4)
        #expect(store.fromCache)
        #expect(store.phase == .loaded)
    }
}

#if DEBUG
struct NetworkHookSettingsTests {
    @Test func off() {
        #expect(!NetworkHook.Settings([:]).isOn)
    }

    @Test func delay() {
        let s = NetworkHook.Settings(["PERCH_NET_DELAY_MS": "7000"])
        #expect(s.isOn && s.delayMS == 7000 && s.fail == nil)
        #expect(s.failure(for: "/v1/magpie/usage") == nil)
    }

    @Test func timeoutKeepsMeAnswering() {
        let s = NetworkHook.Settings(["PERCH_NET_FAIL": "timeout"])
        #expect(s.failure(for: "/v1/magpie/quotas/cards") == .timeout)
        #expect(s.failure(for: "/v1/magpie/me") == nil)
    }

    @Test func offlineFailsEverything() {
        let s = NetworkHook.Settings(["PERCH_NET_FAIL": "offline"])
        #expect(s.failure(for: "/v1/magpie/me") == .offline)
    }

    @Test func paths() {
        let s = NetworkHook.Settings(["PERCH_NET_FAIL_PATHS": "/v1/magpie/usage/requests, /v1/magpie/usage$"])
        #expect(s.fail == .timeout)
        #expect(s.failure(for: "/v1/magpie/usage/requests") == .timeout)
        #expect(s.failure(for: "/v1/magpie/usage") == .timeout)
        #expect(s.failure(for: "/v1/magpie/usage/x") == nil)
        #expect(s.failure(for: "/v1/magpie/quotas/cards") == nil)
    }

    @Test func failuresStopAfterAWhile() {
        let s = NetworkHook.Settings(["PERCH_NET_FAIL": "offline", "PERCH_NET_FAIL_FOR_S": "10"])
        #expect(s.failFor == 10)
        #expect(s.failure(for: "/v1/magpie/me", elapsed: 3) == .offline)
        #expect(s.failure(for: "/v1/magpie/me", elapsed: 10.5) == nil)
        #expect(NetworkHook.Settings(["PERCH_NET_FAIL": "offline"]).failure(for: "/v1/magpie/me", elapsed: 999) == .offline)
    }
}
#endif
