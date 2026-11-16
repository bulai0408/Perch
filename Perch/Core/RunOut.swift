import Foundation

/// 1.4 「照现在的速度，大约 %@ 用完」.
/// Pace = % used over the last 60 min (5 小时 window) or 24 h (weekly
/// windows), from quota history; with no history, from Perch's own reads
/// at least 10 min apart. Shown only with ≥ 15 min of data, pace > 0, and
/// a run-out before the window resets.
struct RunOut: Equatable, Sendable {
    /// The window's name as magpie gives it (`5h`, `7d`…).
    var window: String
    /// When the window is projected to hit 100 % used.
    var at: Date
    /// %/second.
    var pace: Double

    /// Orange when ≤ 60 min away.
    func urgent(now: Date = .now) -> Bool { at.timeIntervalSince(now) <= 3600 }

    /// The card line 「照现在的速度，大约 15:40 用完」.
    func text(now: Date = .now) -> String {
        String(localized: "照现在的速度，大约 \(QuotaFormat.until(at, now: now)) 用完")
    }

    /// The chart label 「15:40 用完」.
    func label(now: Date = .now) -> String {
        String(localized: "\(QuotaFormat.until(at, now: now)) 用完")
    }
}

/// One reading of a window: % used at a time.
struct UsageSample: Equatable, Sendable {
    var time: Date
    var used: Double
}

/// Projects when a window runs out from its recent pace. Pure.
enum RunOutEstimate {
    /// At least this much data before a pace is trusted.
    static let minSpan: TimeInterval = 15 * 60
    /// Perch's own reads must be at least this far apart.
    static let minReadGap: TimeInterval = 10 * 60

    /// How far back the pace looks: 1 h for 5-hour windows, else 24 h.
    static func lookback(_ kind: WindowKind) -> TimeInterval {
        kind == .fiveHour ? 3600 : 24 * 3600
    }

    /// One window. `history` from `/quotas/history`, `reads` from Perch's
    /// own card reads; the current reading is the window itself.
    static func estimate(window: QuotaWindow, history: [UsageSample], reads: [UsageSample], now: Date = .now) -> RunOut? {
        guard !window.unlimited, !window.text, let used = QuotaFormat.used(window), used < 100 else { return nil }
        let kind = WindowKind.classify(window)
        let current = UsageSample(time: now, used: used)
        let since = now.addingTimeInterval(-lookback(kind))

        var pace = self.pace(afterReset(history.filter { $0.time >= since && $0.time <= now } + [current]))
        if pace == nil {
            let fromReads = afterReset(reads.filter { $0.time >= since && $0.time <= now } + [current])
            // Two reads at least 10 min apart.
            if let first = fromReads.first, let last = fromReads.last, last.time.timeIntervalSince(first.time) >= minReadGap {
                pace = self.pace(fromReads)
            }
        }
        guard let pace, pace > 0 else { return nil }
        let at = now.addingTimeInterval((100 - used) / pace)
        if let reset = window.resetsAt, at >= reset { return nil }
        return RunOut(window: window.name, at: at, pace: pace)
    }

    /// The card's line: the window that runs out first.
    static func first(card: QuotaCard, history: QuotaHistory?, reads: [String: [UsageSample]], now: Date = .now) -> RunOut? {
        card.windows.compactMap { w in
            estimate(window: w, history: samples(history, card: card, window: w),
                     reads: reads[readKey(card, w)] ?? [], now: now)
        }.min { $0.at < $1.at }
    }

    /// The key under which Perch keeps its own reads of one window.
    static func readKey(_ card: QuotaCard, _ window: QuotaWindow) -> String { "\(card.id)#\(window.name)" }

    /// History points of `card`'s `window`, matched by name, else kind.
    static func samples(_ history: QuotaHistory?, card: QuotaCard, window: QuotaWindow) -> [UsageSample] {
        guard case .series(let list)? = history else { return [] }
        let mine = list.filter { $0.belongs(to: card) }
        let kind = WindowKind.classify(window)
        let series = mine.first { $0.window == window.name } ?? mine.first { $0.kind == kind && kind != .other }
        return (series?.points ?? []).map { UsageSample(time: $0.time, used: $0.used) }
    }

    /// Points since the last reset (a drop in % used), oldest first.
    static func afterReset(_ samples: [UsageSample]) -> [UsageSample] {
        let sorted = samples.sorted { $0.time < $1.time }
        var start = 0
        for i in sorted.indices.dropFirst() where sorted[i].used < sorted[i - 1].used - 1 { start = i }
        return Array(sorted[start...])
    }

    /// %/second between the first and the last point, given ≥ 15 min.
    static func pace(_ samples: [UsageSample]) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.time.timeIntervalSince(first.time)
        guard span >= minSpan else { return nil }
        return (last.used - first.used) / span
    }
}
