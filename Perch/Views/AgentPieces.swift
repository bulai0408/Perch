import Charts
import SwiftUI

// MARK: - 一句话小结

/// 「今天 Claude Code 调用 184 次，约 $12.40，八成是 Opus。」 and a red,
/// tappable 「失败 3 次。」 → the call list on 只看失败.
struct SummaryLine: View {
    let summary: AgentSummary
    let openFailures: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: summary.sentence)
                .font(.system(size: 17))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("agent-summary")
            if let failures = summary.failures {
                Button(action: openFailures) {
                    Text(verbatim: failures)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.red)
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

// MARK: - 正在进行

/// 「正在进行」: the calls magpie is serving right now.
struct LiveCard: View {
    let state: LiveStore.State
    let now: Date
    let cards: [QuotaCard]
    let open: (UsageRow) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var running: Bool { if case .running = state { true } else { false } }

    var body: some View {
        Button {
            if case .finished(let row?, _, _, _) = state { open(row) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(running ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                        .opacity(running && pulse ? 0.4 : 1)
                    Text(running ? "正在进行" : "刚刚结束")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 4)
                    if case .running(_, let since, _) = state {
                        Text("已经 \(QuotaFormat.elapsed(since: since, now: now))")
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: modelLine)
                    .font(.system(size: 14).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let switchLine {
                    Text(verbatim: switchLine)
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.card, in: .rect(cornerRadius: 18))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent-live")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
        }
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

    /// Bar colour: selected, future, current or past.
    private func color(_ p: UsageSeriesPoint) -> Color {
        if let picked { return p.id == picked.id ? .accentColor : Color.primary.opacity(0.4) }
        if p.time > now { return Color(uiColor: .tertiarySystemFill) }
        if now < p.time.addingTimeInterval(step) { return .accentColor }
        return Color.primary.opacity(0.85)
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
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 6) {
                callout
                Chart(series) { p in
                    BarMark(x: .value("时间", p.time, unit: unit), y: .value("费用", p.totals.cost))
                        .foregroundStyle(color(p))
                        .cornerRadius(2)
                        .annotation(position: .top, spacing: 2) {
                            if picked == nil, p.id == busiest?.id {
                                Text(verbatim: String(format: "$%.1f", p.totals.cost))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                        }
                }
                .chartXScale(domain: start...end)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: xValues) { v in
                        AxisValueLabel(centered: !hourly) {
                            Text(verbatim: xLabel(v.as(Date.self) ?? start))
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
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.card, in: .rect(cornerRadius: 18))
            .contentShape(.rect)
            .onTapGesture { selected = nil }
        }
    }

    @ViewBuilder
    private var callout: some View {
        if let picked {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: CostBars.callout(picked, hourly: hourly, now: now))
                    .font(.system(size: 13).monospacedDigit())
                if let note = CostBars.unpricedNote(picked) {
                    Text(verbatim: note).font(.system(size: 12)).foregroundStyle(.secondary)
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
        label()
            .font(.system(size: 14, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(selected ? Color.accentColor : Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 16))
            .contentShape(.rect(cornerRadius: 16))
    }
}
