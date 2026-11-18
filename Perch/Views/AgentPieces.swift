import Charts
import SwiftUI

// MARK: - 一句话小结

/// 「今天 Claude Code 调用 184 次，约 $12.40，八成是 Opus。」 in serif 22
/// (numbers semibold), and a
/// bad-coloured, tappable 「失败 3 次。」 → the call list on 只看失败.
struct SummaryLine: View {
    let summary: AgentSummary
    let openFailures: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CountingSentence(sentence: summary.sentence)
                .font(.system(.title2, design: .serif))
                .lineSpacing(6)
                .foregroundStyle(.ink)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.numericText())
                .animation(Motion.calm(reduce), value: summary.sentence)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: summary.sentence))
                .accessibilityIdentifier("agent-summary")
            if let failures = summary.failures {
                Button(action: openFailures) {
                    Text(verbatim: failures)
                        .font(.system(.title2, design: .serif).weight(.semibold))
                        .foregroundStyle(.bad)
                        .contentTransition(.numericText())
                        .animation(Motion.calm(reduce), value: failures)
                        .frame(minHeight: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("只看失败"))
                .accessibilityIdentifier("agent-summary-failures")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

/// The sentence with every number semibold. No count-up from 0;
/// numbers on screen (or saved) roll old → new with `.numericText()` only
/// when they change, in step with the 调用 tile (same animation, same
/// totals), so both read the same number in every frame.
struct CountingSentence: View {
    let sentence: String

    var body: some View {
        var text = AttributedString()
        var prefix = ""
        for part in Self.parts(sentence) {
            if part.number {
                // 「$」 rides in the number's run so 「$28.29」 never breaks.
                var run = AttributedString(prefix + part.text)
                prefix = ""
                run.font = .system(.title2, design: .serif).weight(.semibold).monospacedDigit()
                text.append(run)
            } else {
                var plain = part.text
                if plain.hasSuffix("$") {
                    plain.removeLast()
                    prefix = "$"
                    // NBSP keeps 「约」 / "about" on the amount's line.
                    if plain.hasSuffix(" ") { plain = String(plain.dropLast()) + "\u{00A0}" }
                }
                text.append(AttributedString(plain))
            }
        }
        // Laid out as `en`: under zh-Hans, CoreText breaks Latin runs anywhere
        // (「约 $」 / 「28.29」, even through NBSP and U+2060) and compresses
        // 「，」 to half width. As `en` the line breaks before 「约」 and the
        // comma keeps its full width; Chinese glyphs are unchanged (PingFang SC).
        // With the NBSP above, 「约 $28.29」 moves to the next line as one piece.
        text.languageIdentifier = "en"
        return Text(text)
    }

    /// Runs of digits (with 「,」 and 「.」 inside) and the text between.
    static func parts(_ s: String) -> [(text: String, number: Bool)] {
        var out: [(String, Bool)] = []
        var current = ""
        var inNumber = false
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            let digit = c.isASCII && c.isNumber
            let joiner = (c == "," || c == ".") && inNumber && i + 1 < chars.count && chars[i + 1].isASCII && chars[i + 1].isNumber
            let isNum = digit || joiner
            if isNum != inNumber, !current.isEmpty {
                out.append((current, inNumber))
                current = ""
            }
            inNumber = isNum
            current.append(c)
        }
        if !current.isEmpty { out.append((current, inNumber)) }
        return out
    }
}

// MARK: - 正在进行

/// Ping dot, 「正在进行」, elapsed ticking every second, the model and
/// 「中途换过一次」, and the accent sweep along the bottom. 「刚刚结束」 keeps
/// the card for 30 s without the dot, the tick and the sweep.
struct LiveCard: View {
    let state: LiveStore.State
    let now: Date
    let cards: [QuotaCard]
    let open: (UsageRow) -> Void

    private var running: Bool { if case .running = state { true } else { false } }
    private var since: Date? { if case .running(_, let since, _) = state { since } else { nil } }

    var body: some View {
        Button {
            if case .finished(let row?, _, _, _) = state { open(row) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        PingDot(color: running ? .good : .ink2, active: running)
                            .padding(.leading, -6)
                        Text(running ? "正在进行" : "刚刚结束")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.ink)
                        Spacer(minLength: 4)
                        if let since {
                            TimelineView(.periodic(from: since, by: 1)) { context in
                                Text("已经 \(QuotaFormat.elapsedTicking(since: since, now: max(context.date, now)))")
                                    .font(.system(size: 13).monospacedDigit())
                                    .foregroundStyle(.ink2)
                                    .contentTransition(.numericText(countsDown: false))
                                    .animation(Motion.calm, value: context.date)
                            }
                        }
                    }
                    Text(verbatim: modelLine)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let switchLine {
                        Text(verbatim: switchLine)
                            .font(.system(size: 13))
                            .foregroundStyle(.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
                SweepLine(active: running)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .opacity(running ? 1 : 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .perchCard()
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
        .accessibilityIdentifier("agent-live")
    }

    /// 「正在进行，claude-opus-5-5，已经 2 分 5 秒，中途换过一次」, moving on
    /// in 15 s steps, not every second.
    private var spoken: String {
        var parts = [running ? String(localized: "正在进行") : String(localized: "刚刚结束"), modelLine]
        if let since { parts.append(String(localized: "已经 \(QuotaFormat.elapsedTicking(since: since, now: now, step: 15))")) }
        if let switchLine { parts.append(switchLine) }
        return parts.filter { !$0.isEmpty }.joined(separator: "，")
    }

    /// Running: just the model (magpie doesn't say the account yet).
    /// Finished: 「model · account」.
    private var modelLine: String {
        switch state {
        case .running(let model, _, _): return model
        case .finished(let row, let model, _, _):
            guard let row else { return model }
            let who = row.account.map { QuotaGrouping.card(named: $0, in: cards)?.title ?? $0 } ?? row.providerName ?? row.provider
            return [model, who].compactMap { $0?.nilIfEmpty }.joined(separator: " · ")
        case .hidden: return ""
        }
    }

    private var switchLine: String? {
        switch state {
        case .running(_, _, let switches) where switches == 1:
            return String(localized: "中途换过一次")
        case .running(_, _, let switches) where switches > 1:
            return String(localized: "中途换过 \(switches.text) 次")
        case .finished(let row?, _, let reason, _) where row.switched:
            let to = CallFailure.switchedTo(row, cards: cards)
            if let reason { return String(localized: "换到了 \(to)（\(reason)）") }
            return String(localized: "换到了 \(to)")
        default:
            return nil
        }
    }
}

// MARK: - 每天的费用 / 每小时的费用

/// Cost per hour (today) or per day, with a tap-to-read selection.
struct CostChart: View {
    let series: [UsageSeriesPoint]
    let period: UsagePeriod
    let now: Date

    @State private var selected: Date?
    @State private var risen = false
    @State private var scrubs = 0
    @Environment(\.accessibilityReduceMotion) private var reduce

    private var hourly: Bool { period == .today }
    private var unit: Calendar.Component { hourly ? .hour : .day }
    private var step: TimeInterval { hourly ? 3600 : 86400 }
    private var start: Date { series.first?.time ?? now }
    private var end: Date { (series.last?.time ?? now).addingTimeInterval(step) }
    private var busiest: UsageSeriesPoint? {
        series.filter { $0.totals.cost > 0 }.max { $0.totals.cost < $1.totals.cost }
    }

    private var picked: UsageSeriesPoint? {
        guard let selected else { return nil }
        return series.last { $0.time <= selected && selected < $0.time.addingTimeInterval(step) }
    }

    /// Non-zero bars ink 85 %, empty ones ink 18 % at 2 pt, the
    /// current hour/day accent; while scrubbing the rest fade to 40 %.
    private func color(_ p: UsageSeriesPoint) -> Color {
        if let picked { return p.id == picked.id ? .accentColor : Color.ink.opacity(0.4) }
        if now >= p.time, now < p.time.addingTimeInterval(step) { return .accentColor }
        if p.totals.cost <= 0 || p.time > now { return Color.ink.opacity(0.18) }
        return Color.ink.opacity(0.85)
    }

    /// Empty bars show as a 2 pt stub, so the day still has a shape.
    private func height(_ p: UsageSeriesPoint) -> Double {
        let top = max(series.map(\.totals.cost).max() ?? 0, 0.0001)
        let value = p.totals.cost > 0 ? p.totals.cost : top * 2 / 110
        return risen ? value : 0
    }

    private var title: LocalizedStringKey { hourly ? "每小时的费用" : "每天的费用" }

    private var xValues: [Date] {
        switch period {
        case .today: return [0, 6, 12, 18].map { start.addingTimeInterval(Double($0) * 3600) }
        case .sevenDays: return series.map(\.time)
        default: return stride(from: 0, to: series.count, by: 7).map { series[$0].time }
        }
    }

    /// The axis label for a bar's time.
    private func xLabel(_ d: Date) -> String {
        switch period {
        case .today: return String(Calendar.current.component(.hour, from: d))
        case .sevenDays: return CostBars.dayLabel(d, now: now) == String(localized: "今天")
            ? String(localized: "今天")
            : d.formatted(Date.FormatStyle.dateTime.weekday(.abbreviated).locale(Locale(identifier: "zh-Hans")))
        default: return CostBars.dayLabel(d, now: now)
        }
    }

    private var axLabel: String {
        let head = hourly ? String(localized: "每小时的费用") : String(localized: "每天的费用")
        guard let b = busiest else { return head }
        let when = hourly ? CostBars.hourLabel(b.time) : CostBars.dayLabel(b.time, now: now)
        return String(localized: "\(head)，最多是 \(when)，约 \(UsageFormat.dollars(b.totals.cost))")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BlockHeader(Text(title))
            VStack(alignment: .leading, spacing: 6) {
                callout
                Chart(series) { p in
                    BarMark(x: .value("时间", p.time, unit: unit), y: .value("费用", height(p)))
                        .foregroundStyle(color(p))
                        .cornerRadius(3)
                        .annotation(position: .top, spacing: 2) {
                            if picked == nil, p.id == busiest?.id {
                                Text(verbatim: String(format: "$%.1f", p.totals.cost))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.ink2)
                                    .opacity(risen ? 1 : 0)
                                    .fixedSize()
                            }
                        }
                }
                .chartXScale(domain: start...end)
                .chartYScale(domain: 0...max(series.map(\.totals.cost).max() ?? 0, 0.0001) * 1.18)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: xValues) { v in
                        AxisValueLabel(centered: !hourly) {
                            Text(verbatim: xLabel(v.as(Date.self) ?? start))
                                .foregroundStyle(Color.ink2)
                        }
                    }
                }
                .chartXSelection(value: $selected)
                .frame(height: 110)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: axLabel))
                .accessibilityChartDescriptor(CostDescriptor(series: series, hourly: hourly, title: axLabel, now: now))
                .accessibilityIdentifier("agent-chart")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .perchCard()
            .contentShape(.rect)
            .onTapGesture { selected = nil }
        }
        .sensoryFeedback(Haptic.selection, trigger: picked?.id) { old, new in old != nil && new != nil && old != new }
        // Bars rise from the baseline (0.8 s calm) on appear and again
        // after a segment change; they appear at value under Reduce Motion.
        .task(id: "\(period.rawValue)|\(series.count)") {
            if reduce { risen = true; return }
            if risen {
                withAnimation(.easeInOut(duration: 0.25)) { risen = false }
                try? await Task.sleep(for: .milliseconds(250))
            }
            withAnimation(.spring(duration: 0.8, bounce: 0)) { risen = true }
        }
    }

    @ViewBuilder
    private var callout: some View {
        if let picked {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: CostBars.callout(picked, hourly: hourly, now: now))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.ink)
                    .contentTransition(.numericText())
                    .animation(Motion.settle, value: picked.id)
                if let note = CostBars.unpricedNote(picked) {
                    Text(verbatim: note).font(.system(size: 12)).foregroundStyle(.ink2)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("agent-chart-callout")
        }
    }
}

/// The VoiceOver audio-graph description of the cost chart.
private struct CostDescriptor: AXChartDescriptorRepresentable {
    let series: [UsageSeriesPoint]
    let hourly: Bool
    let title: String
    let now: Date

    func makeChartDescriptor() -> AXChartDescriptor {
        let labels = series.map { hourly ? CostBars.hourLabel($0.time) : CostBars.dayLabel($0.time, now: now) }
        let x = AXCategoricalDataAxisDescriptor(title: String(localized: "时间"), categoryOrder: labels)
        let top = max(1, series.map(\.totals.cost).max() ?? 1)
        let y = AXNumericDataAxisDescriptor(title: String(localized: "费用"), range: 0...top, gridlinePositions: []) {
            UsageFormat.dollars($0)
        }
        let data = AXDataSeriesDescriptor(name: title, isContinuous: false,
                                          dataPoints: zip(labels, series).map { AXDataPoint(x: $0, y: $1.totals.cost) })
        return AXChartDescriptor(title: title, summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [data])
    }
}

// MARK: - Filter chips

/// A capsule toggle in the filter row.
struct FilterChip<Label: View>: View {
    let selected: Bool
    @ViewBuilder let label: () -> Label

    var body: some View {
        // Chips: semibold on 12 % of their colour, radius 10.
        label()
            .font(.system(size: 14, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.accentColor : Color.ink)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.track, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect(cornerRadius: 10))
            .animation(Motion.settle, value: selected)
    }
}
