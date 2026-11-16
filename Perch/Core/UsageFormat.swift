import Foundation

/// Numbers on the Agent tab and Account detail.
enum UsageFormat {
    /// 「3.1M」, 「48.2k」, 「870」.
    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        func short(_ x: Double, _ unit: String) -> String {
            let text = x >= 100 ? String(Int(x.rounded())) : String(format: "%.1f", x)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
        }
        if v >= 1_000_000_000 { return short(v / 1_000_000_000, "B") }
        if v >= 1_000_000 { return short(v / 1_000_000, "M") }
        if v >= 1_000 { return short(v / 1_000, "k") }
        return String(n)
    }

    /// 「$12.40」; under a cent 「$0.004」; 0 「$0」.
    static func dollars(_ cost: Double) -> String {
        if cost <= 0 { return "$0" }
        if cost < 0.01 { return "$" + String(format: "%.3f", cost) }
        if cost >= 1000 { return "$" + String(Int(cost.rounded())) }
        return "$" + String(format: "%.2f", cost)
    }

    /// 「约 $12.40」, or 「—」 when nothing had a price.
    static func cost(_ totals: UsageTotals) -> String {
        if totals.allUnpriced { return "—" }
        return String(localized: "约 \(dollars(totals.cost))")
    }

    /// 「6.1 秒」, 「800 毫秒」.
    static func duration(ms: Int) -> String {
        if ms < 1000 { return String(localized: "\(String(ms)) 毫秒") }
        return String(localized: "\(String(format: "%.1f", Double(ms) / 1000)) 秒")
    }

    /// `wo***@example.com`: the first two letters of the name, then the domain.
    static func masked(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return email }
        let name = email[..<at]
        guard name.count > 2 else { return email }
        return String(name.prefix(2)) + "***" + email[at...]
    }
}
