import Foundation

/// All of Perch's time, percent and quota-window wording (zh-Hans).
/// Pure functions; `now` is a parameter so tests can pin it.
enum QuotaFormat {
    /// magpie names windows like `5h`, `7d`, `week`, `month`.
    static func windowLabel(_ name: String) -> String {
        let raw = name.trimmed
        let lower = raw.lowercased()
        if let n = leadingNumber(lower, units: ["h", "hr", "hrs", "hour", "hours"]) { return String(localized: "\(n) 小时") }
        if let n = leadingNumber(lower, units: ["d", "day", "days"]) { return String(localized: "\(n) 天") }
        if let n = leadingNumber(lower, units: ["m", "min", "mins", "minutes"]) { return String(localized: "\(n) 分钟") }
        switch lower {
        case "week", "weekly": return String(localized: "本周")
        case "month", "monthly": return String(localized: "本月")
        case "day", "daily", "today": return String(localized: "今天")
        default: return raw
        }
    }

    /// The leading digits of `text` when the rest is one of `units`.
    private static func leadingNumber(_ text: String, units: [String]) -> String? {
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let unit = text.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        return units.contains(unit) ? String(digits) : nil
    }

    /// `38.4` → `38%`, clamped to 0...100.
    static func percent(_ value: Double) -> String {
        let clamped = min(max(value, 0), 100)
        return "\(Int(clamped.rounded()))%"
    }

    /// What is left of a window in percent, nil for count-only windows.
    static func remaining(_ window: QuotaWindow) -> Double? {
        if window.text { return nil }
        if let left = window.remaining { return min(max(left, 0), 100) }
        guard let used = window.used else { return nil }
        return min(max(100 - used, 0), 100)
    }

    /// Used percent, derived from what is left when magpie only sent that.
    static func used(_ window: QuotaWindow) -> Double? {
        if window.text { return nil }
        if let used = window.used { return min(max(used, 0), 100) }
        return remaining(window).map { 100 - $0 }
    }

    /// 「剩 38%」, 「已用完」 at zero, or the vendor's own count for a text window.
    static func left(_ window: QuotaWindow) -> String? {
        guard let left = remaining(window) else {
            return window.display?.trimmed.isEmpty == false ? window.display : nil
        }
        if left.rounded() <= 0 { return String(localized: "已用完") }
        return String(localized: "剩 \(percent(left))")
    }

    /// Bar and number colour band: 0 normal, 1 at ≥70 % used, 2 at ≥90 %.
    static func level(used: Double) -> Int {
        switch used {
        case ..<70: 0
        case ..<90: 1
        default: 2
        }
    }

    /// 「42 分后重置」 within the hour, 「3 小时后重置」 within a day (whole
    /// hours only), else 「周四 08:00 重置」. Nil when magpie gave no time.
    static func resets(_ date: Date?, now: Date = .now) -> String? {
        guard let date else { return nil }
        let minutes = minutesUntil(date, now: now)
        if minutes < 60 { return String(localized: "\(minutes.text) 分后重置") }
        if minutes < 1440 { return String(localized: "\((minutes / 60).text) 小时后重置") }
        return String(localized: "\(dayAndTime(date, now: now)) 重置")
    }

    /// A wait, as in 「过 3 分钟恢复」: 「N 分钟」 within the hour, else whole
    /// 「N 小时」 (rounded the same way as 「42 分后重置」).
    static func duration(until date: Date, now: Date = .now) -> String {
        let minutes = minutesUntil(date, now: now)
        if minutes < 60 { return String(localized: "\(minutes.text) 分钟") }
        return String(localized: "\(max(1, minutes / 60).text) 小时")
    }

    /// The 最快重置 tile: 「42 分」, 「3 小时」, else 「周四」.
    static func resetsShort(_ date: Date, now: Date = .now) -> String {
        let minutes = minutesUntil(date, now: now)
        if minutes < 60 { return String(localized: "\(minutes.text) 分") }
        if minutes < 1440 { return String(localized: "\((minutes / 60).text) 小时") }
        return day(date, now: now)
    }

    /// Whole minutes from `now` to `date`, at least 1.
    private static func minutesUntil(_ date: Date, now: Date) -> Int {
        max(1, Int((date.timeIntervalSince(now) / 60).rounded()))
    }

    /// Dates are always formatted in Chinese, whatever the device locale.
    private static let zh = Locale(identifier: "zh-Hans")

    /// 「周四」 within the coming week, 「11月21日」 past it (a weekday
    /// alone would read as this week).
    static func day(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let style: Date.FormatStyle = days < 7 ? .dateTime.weekday(.abbreviated) : .dateTime.month().day()
        return date.formatted(style.locale(zh))
    }

    /// 「周四 08:00」 (or 「11月21日 08:00」 a week or more ahead).
    static func dayAndTime(_ date: Date, now: Date = .now) -> String {
        let time = date.formatted(Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(zh))
        return "\(day(date, now: now)) \(time)"
    }

    /// 1.4 「大约 %@ 用完」 and reset times in failure lines: 「15:40」
    /// today, 「明天 09:10」, else 「周四 15:40」.
    static func until(_ date: Date, now: Date = .now) -> String {
        let time = date.formatted(Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(zh))
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "明天 \(time)")
        }
        return "\(day(date, now: now)) \(time)"
    }

    /// 1.4 正在进行 「已经 2 分钟」's %@: 「12 秒」, 「2 分钟」, 「1 小时 5 分钟」.
    static func elapsed(since date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return String(localized: "\(seconds.text) 秒") }
        let minutes = seconds / 60
        if minutes < 60 { return String(localized: "\(minutes.text) 分钟") }
        let rest = minutes % 60
        if rest == 0 { return String(localized: "\((minutes / 60).text) 小时") }
        return String(localized: "\((minutes / 60).text) 小时 \(rest.text) 分钟")
    }

    /// 1.5 正在进行: 「45 秒」, 「2 分 5 秒」, 「1 小时 2 分」,
    /// ticking every second. `step` rounds down (VoiceOver hears it every 15 s).
    static func elapsedTicking(since date: Date, now: Date = .now, step: Int = 1) -> String {
        var seconds = max(0, Int(now.timeIntervalSince(date)))
        if step > 1 { seconds -= seconds % step }
        if seconds < 60 { return String(localized: "\(seconds.text) 秒") }
        let minutes = seconds / 60
        if minutes < 60 {
            let rest = seconds % 60
            return rest == 0 ? String(localized: "\(minutes.text) 分") : String(localized: "\(minutes.text) 分 \(rest.text) 秒")
        }
        let rest = minutes % 60
        if rest == 0 { return String(localized: "\((minutes / 60).text) 小时") }
        return String(localized: "\((minutes / 60).text) 小时 \(rest.text) 分")
    }

    /// 「2 分钟前」 for the 「%@ 读取」 footer.
    static func ago(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return String(localized: "刚刚") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return String(localized: "\(minutes.text) 分钟前") }
        let hours = minutes / 60
        if hours < 24 { return String(localized: "\(hours.text) 小时前") }
        return clock(date)
    }

    /// 「10:42」 today, 「11月14日 10:42」 before.
    static func clock(_ date: Date, now: Date = .now) -> String {
        let style: Date.FormatStyle = Calendar.current.isDate(date, inSameDayAs: now)
            ? .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
            : .dateTime.month().day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        return date.formatted(style.locale(Locale(identifier: "zh-Hans")))
    }
}

extension Int {
    /// Interpolating an Int into String(localized:) would make a `%lld`
    /// key; Perch's catalog keys use `%@`, so numbers go in as strings.
    var text: String { String(self) }
}
