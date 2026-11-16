import Foundation

/// 1.4 一句话小结: 「今天 Claude Code 调用 184 次，约 $12.40，
/// 八成是 Opus。」 plus a tappable 「失败 3 次。」.
struct AgentSummary: Equatable, Sendable {
    /// The summary sentence, ending in 「。」.
    var sentence: String
    /// 「失败 %d 次。」, nil without failures.
    var failures: String?
    /// How many calls failed in the period.
    var failureCount: Int

    /// Nil when there were no calls (the empty state shows instead).
    static func make(period: UsagePeriod, agentName: String, totals: UsageTotals, models: [UsageBucket]) -> AgentSummary? {
        guard totals.calls > 0 else { return nil }
        let calls = totals.calls.text
        var parts: [String]
        switch period {
        case .today: parts = [String(localized: "今天 \(agentName) 调用 \(calls) 次")]
        case .sevenDays: parts = [String(localized: "这 7 天 \(agentName) 调用 \(calls) 次")]
        default: parts = [String(localized: "这 30 天 \(agentName) 调用 \(calls) 次")]
        }
        if !totals.allUnpriced {
            parts.append(String(localized: "约 \(UsageFormat.dollars(totals.cost))"))
        }
        if let top = topModel(models) { parts.append(top) }
        let sentence = parts.joined(separator: "，") + "。"
        let failures = totals.errors > 0 ? String(localized: "失败 \(totals.errors.text) 次。") : nil
        return AgentSummary(sentence: sentence, failures: failures, failureCount: totals.errors)
    }

    /// 「八成是 Opus」 when one model has seven tenths or more of the use,
    /// else 「Opus 用得最多」. Use = cost when anything had a price, else calls.
    static func topModel(_ models: [UsageBucket]) -> String? {
        let merged = byFamily(models)
        let priced = merged.contains { $0.cost > 0 }
        let weight: ((name: String, cost: Double, calls: Int)) -> Double = { priced ? $0.cost : Double($0.calls) }
        let total = merged.reduce(0) { $0 + weight($1) }
        guard total > 0, let top = merged.max(by: { weight($0) < weight($1) }) else { return nil }
        let share = weight(top) / total
        if share >= 0.7, let tenths = tenthsWord(share) {
            return String(localized: "\(tenths)成是 \(top.name)")
        }
        return String(localized: "\(top.name) 用得最多")
    }

    /// 七、八、九 (rounded; 95% and up still reads 九成).
    static func tenthsWord(_ share: Double) -> String? {
        switch min(9, Int((share * 10).rounded())) {
        case 7: String(localized: "七")
        case 8: String(localized: "八")
        case 9: String(localized: "九")
        default: nil
        }
    }

    /// 「Opus」 for every `claude-opus-*`; other models by their own name.
    static func shortName(_ model: String) -> String {
        let lower = model.lowercased()
        if let family = WindowKind.modelNames.first(where: { lower.contains($0) }) {
            return family.prefix(1).uppercased() + family.dropFirst()
        }
        return RoutingDecoding.modelPart(of: model)
    }

    /// Sums cost and calls per model family (see `shortName`), in first-seen order.
    private static func byFamily(_ models: [UsageBucket]) -> [(name: String, cost: Double, calls: Int)] {
        var order: [String] = []
        var sums: [String: (cost: Double, calls: Int)] = [:]
        for m in models where m.totals.calls > 0 {
            let name = shortName(m.name.isEmpty ? m.id : m.name)
            if sums[name] == nil { order.append(name) }
            sums[name, default: (0, 0)].cost += m.totals.cost
            sums[name, default: (0, 0)].calls += m.totals.calls
        }
        return order.map { (name: $0, cost: sums[$0]!.cost, calls: sums[$0]!.calls) }
    }
}

/// One bar of 每天的费用 / 每小时的费用.
enum CostBars {
    /// 「11/16」, 「今天」 for today.
    static func dayLabel(_ date: Date, now: Date = .now) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) { return String(localized: "今天") }
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    /// 「08:00」 for an hour bar.
    static func hourLabel(_ date: Date) -> String {
        date.formatted(Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "zh-Hans")))
    }

    /// 「11/16 · 约 $18.20 · 412 次」.
    static func callout(_ point: UsageSeriesPoint, hourly: Bool, now: Date = .now) -> String {
        let when = hourly ? hourLabel(point.time) : dayLabel(point.time, now: now)
        let cost = UsageFormat.dollars(point.totals.cost)
        return String(localized: "\(when) · 约 \(cost) · \(point.totals.calls.text) 次")
    }

    /// 「%d 次没有价格，没算进去」 under the callout.
    static func unpricedNote(_ point: UsageSeriesPoint) -> String? {
        point.totals.unpriced > 0 ? String(localized: "\(point.totals.unpriced.text) 次没有价格，没算进去") : nil
    }
}
