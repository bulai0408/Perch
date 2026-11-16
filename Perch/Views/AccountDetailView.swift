import Charts
import SwiftUI

/// Account detail: any subscription
/// account's windows, how they got used, today's calls and 用这个账号.
struct AccountDetailView: View {
    let accountID: String

    @Environment(ConnectionStore.self) private var connection
    @Environment(QuotasStore.self) private var store
    @Environment(RoutingStore.self) private var routing
    @Environment(UsageStore.self) private var usage
    @Environment(\.openAgentTab) private var openAgentTab

    @State private var now = Date.now
    @State private var toast: String?
    @State private var confirmOff = false
    @State private var failure: MagpieAPIError?

    var body: some View {
        Group {
            if let account = store.account(accountID) {
                content(account)
                    .perchScreen(sky: false)
                    .navigationTitle(account.title)
            } else {
                ContentUnavailableView("这个账号不在了", systemImage: "person.crop.circle.badge.questionmark")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toast($toast, seconds: 2)
        .task { await store.loadHistory(connection.magpieClient()) }
    }

    /// The provider's display name for this account.
    private func providerName(_ account: SubscriptionAccount) -> String {
        account.isClaude ? "Claude" : (account.card.name.isEmpty ? account.card.provider : account.card.name)
    }

    /// The detail list: sign-in notice, windows, history, calls and the on/off switch.
    @ViewBuilder
    private func content(_ account: SubscriptionAccount) -> some View {
        let justUsed = store.justUsed.contains(account.id)
        let runOut = account.off || account.card.error?.trimmed.isEmpty == false ? nil : store.runOut(account.card, now: now)
        List {
            if account.card.loginExpired {
                Section {
                    Label {
                        Text("\(account.title) 登录已失效，magpie 暂时不会用它。在电脑上的 magpie 里重新登录就好。")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.bad)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("login-expired-note")
                }
            }
            Section {
                HStack(spacing: 12) {
                    Monogram(text: providerName(account), claude: account.isClaude)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: account.card.subtitle)
                            .font(.system(size: 17))
                        if let user = account.user, user != account.title || account.card.alias != nil {
                            Text(verbatim: UsageFormat.masked(user))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    if account.card.loginExpired { LoginExpiredChip() } else if account.off { OffChip() } else if justUsed { JustUsedCapsule() }
                }
                .accessibilityElement(children: .combine)
            }

            if !account.windows.isEmpty {
                Section("额度") {
                    ForEach(account.windows) { w in
                        DetailWindowRow(window: w.window, now: now, runOut: runOut?.window == w.window.name ? runOut : nil)
                    }
                }
            }

            HistorySection(account: account, history: store.history, now: now, runOut: runOut)

            callsSection(account)

            if store.siblings(of: account).count >= 2, account.canToggle {
                toggleSection(account)
            }
        }
        .listSectionSpacing(18)
        .refreshable {
            now = .now
            await store.load(connection.quotaClient(), extras: connection.magpieClient())
            await store.loadHistory(connection.magpieClient())
        }
        .alert(Text("停用 \(account.title)？"), isPresented: $confirmOff) {
            Button("停用", role: .destructive) { Task { await set(account, on: false) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(verbatim: offMessage(account))
        }
    }

    /// The confirmation text for switching the account off, warning when it's
    /// the last usable one of its provider.
    private func offMessage(_ account: SubscriptionAccount) -> String {
        let provider = providerName(account)
        var text = String(localized: "停用后 magpie 不再用这个账号，会改用你其他的 \(provider) 账号。随时可以重新启用。")
        if SubscriptionAccounts.usableAfterDisabling(account, in: store.accounts) == 0 {
            text += String(localized: "这是最后一个能用的 \(provider) 账号，停用后就用不了 \(provider) 订阅了。")
        }
        return text
    }

    /// 「这个账号的调用」: today's calls and cost, linking to the Agent tab.
    @ViewBuilder
    private func callsSection(_ account: SubscriptionAccount) -> some View {
        let today = store.usageToday.flatMap { QuotaGrouping.bucket(for: account.card, in: $0.accounts) }
        Section("这个账号的调用") {
            if let today {
                Text("今天 \(today.totals.calls.text) 次 · \(UsageFormat.cost(today.totals))")
                    .monospacedDigit()
                    .accessibilityIdentifier("account-calls-today")
            }
            Button {
                usage.pendingAccount = today?.id ?? account.user ?? account.title
                openAgentTab()
            } label: {
                HStack {
                    Text("在 Agent 页看")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityIdentifier("account-open-agent")
        }
    }

    /// 「用这个账号」: the on/off switch (locked without admin rights).
    private func toggleSection(_ account: SubscriptionAccount) -> some View {
        let saving = store.switching == account.id
        let locked = routing.needsAdmin
        return Section {
            HStack {
                Text("用这个账号")
                Spacer()
                if saving {
                    ProgressView()
                } else {
                    Toggle("用这个账号", isOn: Binding(
                        get: { !account.off },
                        set: { on in
                            failure = nil
                            if on { Task { await set(account, on: true) } } else { confirmOff = true }
                        }
                    ))
                    .labelsHidden()
                    .tint(.accentColor)
                    .sensoryFeedback(Haptic.toggled, trigger: account.off)
                    .disabled(locked || store.switching != nil)
                    .accessibilityIdentifier("account-toggle")
                }
            }
            .frame(minHeight: 32)
        } footer: {
            if let failure {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: failure.message)
                    if let reason = failure.reason, failure.isRejected { Text(verbatim: reason).monospaced() }
                }
                .accessibilityIdentifier("account-toggle-error")
            } else if locked {
                Text(verbatim: MagpieAPIError.notAdmin.message)
            }
        }
    }

    /// Switches the account on or off in magpie, then toasts or shows the failure.
    private func set(_ account: SubscriptionAccount, on: Bool) async {
        let result = await store.setAccount(account, on: on, client: connection.magpieClient(), cards: connection.quotaClient())
        switch result {
        case .success:
            failure = nil
            toast = on ? String(localized: "已启用 \(account.title)") : String(localized: "已停用 \(account.title)")
        case .failure(let error):
            failure = error
        }
    }
}

extension MagpieAPIError {
    var isRejected: Bool { if case .rejected = self { true } else { false } }
}

/// One full-width window: label + 「剩 38%」, a 6 pt bar, the reset line.
private struct DetailWindowRow: View {
    let window: QuotaWindow
    let now: Date
    var runOut: RunOut?

    /// A mini-hero: label, serif 34 value, bar, reset.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: WindowCell.label(window))
                .font(.footnote)
                .foregroundStyle(.ink2)
            if let left = QuotaFormat.remaining(window), left.rounded() > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("剩").font(.system(size: 15)).foregroundStyle(.ink2)
                    Text(verbatim: "\(Int(left.rounded()))")
                        .font(.system(size: 34, design: .serif).monospacedDigit())
                        .contentTransition(.numericText(value: left))
                    Text(verbatim: "%").font(.system(size: 18, design: .serif))
                }
                .foregroundStyle((QuotaFormat.used(window).map { BarTone.of(used: $0) } ?? .ink).numberColor)
                .fixedSize()
            } else if let text = QuotaFormat.left(window) {
                Text(verbatim: text)
                    .font(.system(size: 28, design: .serif).monospacedDigit())
                    .foregroundStyle(QuotaFormat.remaining(window) != nil ? Color.bad : Color.ink)
            }
            if let used = QuotaFormat.used(window) {
                QuotaBar(used: used)
            }
            if let reset = QuotaFormat.resets(window.resetsAt, now: now) {
                Text(verbatim: reset)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.ink2)
            }
            if let runOut { RunOutLine(runOut: runOut, now: now) }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 额度是怎么用掉的

/// 「额度是怎么用掉的」: the history chart per window, or a note when
/// there is nothing to draw.
private struct HistorySection: View {
    let account: SubscriptionAccount
    let history: QuotaHistory?
    let now: Date
    var runOut: RunOut?

    @State private var picked: String?

    /// The account's series, 5 小时 / 每周 / model windows in card order.
    private var series: [QuotaHistorySeries] {
        guard case .series(let all) = history else { return [] }
        return all.filter { $0.belongs(to: account.card) && !$0.points.isEmpty }
            .sorted { $0.kind.rank < $1.kind.rank }
    }

    var body: some View {
        Section("额度是怎么用掉的") {
            switch history {
            case nil:
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(height: 120)
                    .accessibilityHidden(true)
            case .unrecognized?:
                // Under the error art, laid out like the empty state.
                ArtStateView(art: "art-error",
                             message: String(localized: "这版 magpie 的数据 Perch 还读不懂，先不显示这一块。别的照常能看。"),
                             top: 12)
                    .padding(.bottom, 18)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("history-unrecognized")
            default:
                if series.isEmpty {
                    note("还没有记录。magpie 会边用边记，过一阵再来看。")
                } else {
                    chart
                }
            }
        }
    }

    /// A plain note in place of the chart.
    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(.ink2)
            .padding(.vertical, 18)
            .accessibilityIdentifier("history-note")
    }

    private var current: QuotaHistorySeries? {
        let list = series
        return list.first { $0.id == picked } ?? list.first { s in runOut.map { s.window == $0.window } ?? false }
            ?? list.first { s in runOut.map { s.kind == WindowKind.classify(QuotaWindow(name: $0.window, unlimited: false, text: false)) } ?? false }
            ?? list.first { $0.kind == .weekly } ?? list.first
    }

    @ViewBuilder
    private var chart: some View {
        let list = series
        if list.count > 1 {
            Picker("窗口", selection: Binding(get: { current?.id ?? "" }, set: { picked = $0 })) {
                ForEach(list) { s in
                    Text(verbatim: WindowCell.label(QuotaWindow(name: s.window, unlimited: false, text: false))).tag(s.id)
                }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
        }
        if let s = current {
            let window = account.windows.first { $0.window.name == s.window }?.window ?? account.windows.first { $0.kind == s.kind }?.window
            HistoryChart(series: s, window: window, now: now, runOut: window.flatMap { w in runOut?.window == w.name ? runOut : nil })
        }
    }
}

/// One window's used-percent line over time, with the reset and run-out marks.
private struct HistoryChart: View {
    let series: QuotaHistorySeries
    let window: QuotaWindow?
    let now: Date
    /// 1.4: a dashed orange line to 100% at the run-out, labelled.
    var runOut: RunOut?

    @State private var explaining = false
    @State private var drawn: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduce

    private var span: TimeInterval? {
        switch series.kind {
        case .fiveHour: 5 * 3600
        case .weekly, .modelWeekly: 7 * 86400
        case .other: nil
        }
    }

    private var end: Date { window?.resetsAt ?? now }
    private var start: Date {
        if let span, let reset = window?.resetsAt { return reset.addingTimeInterval(-span) }
        return series.points.first?.time ?? now.addingTimeInterval(-3600)
    }
    private var points: [QuotaHistoryPoint] { series.points.filter { $0.time >= start && $0.time <= max(now, end) } }
    private var usedNow: Double {
        window.flatMap { QuotaFormat.used($0) } ?? points.last?.used ?? 0
    }

    private var caption: String {
        let since = series.kind == .fiveHour ? QuotaFormat.clock(start, now: now) : QuotaFormat.dayAndTime(start, now: now)
        return String(localized: "\(since) 起，用掉了 \(QuotaFormat.percent(usedNow))")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                    AreaMark(x: .value("时间", p.time), y: .value("用掉", p.used))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(Color.ink.opacity(0.06))
                    LineMark(x: .value("时间", p.time), y: .value("用掉", p.used), series: .value("线", "used"))
                        .interpolationMethod(.stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(Color.ink)
                }
                if let runOut, runOut.at > now {
                    ForEach([(now, usedNow), (runOut.at, 100.0)], id: \.0) { p in
                        LineMark(x: .value("时间", p.0), y: .value("用掉", p.1), series: .value("线", "projection"))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .foregroundStyle(Color.warn)
                    }
                    PointMark(x: .value("用完", runOut.at), y: .value("用掉", 100.0))
                        .symbolSize(20)
                        .foregroundStyle(Color.warn)
                        .annotation(position: .leading, spacing: 4) {
                            Text(verbatim: runOut.label(now: now))
                                .font(.system(size: 11))
                                .foregroundStyle(.warn)
                                .accessibilityIdentifier("run-out-label")
                        }
                } else if now < end {
                    RuleMark(xStart: .value("现在", now), xEnd: .value("重置", end), y: .value("用掉", usedNow))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(Color.ink2)
                }
                PointMark(x: .value("现在", min(now, end)), y: .value("用掉", usedNow))
                    .symbolSize(180)
                    .foregroundStyle(Color.accentColor.opacity(0.18))
                PointMark(x: .value("现在", min(now, end)), y: .value("用掉", usedNow))
                    .symbolSize(50)
                    .foregroundStyle(Color.accentColor)
                    .annotation(position: .bottom, spacing: 4) {
                        Text("现在").font(.caption2).foregroundStyle(.tint)
                    }
            }
            .chartXScale(domain: start...max(end, start.addingTimeInterval(60)))
            // Headroom above 100% so the top tick label and the run-out
            // annotation (both centred on y = 100) sit inside the plot and
            // aren't cut by the draw-in mask. Ticks stay 0/50/100.
            .chartYScale(domain: 0...114)
            .mask(alignment: .leading) {
                GeometryReader { g in
                    Rectangle().frame(width: g.size.width * drawn)
                }
            }
            .onAppear {
                guard drawn == 0 else { return }
                if let grow = Motion.grow(reduce) { withAnimation(grow) { drawn = 1 } } else { drawn = 1 }
            }
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { v in
                    AxisGridLine()
                    AxisValueLabel { Text(verbatim: "\(v.as(Int.self) ?? 0)%") }
                }
            }
            .chartXAxis {
                if series.kind == .fiveHour {
                    AxisMarks(values: .stride(by: .hour)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)))
                    }
                } else {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                    }
                }
            }
            .frame(height: 150)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: caption))
            .accessibilityChartDescriptor(HistoryDescriptor(points: points, title: caption))

            Text(verbatim: caption)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .accessibilityIdentifier("history-caption")
            if let runOut {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    RunOutLine(runOut: runOut, now: now)
                    Button("怎么算的") { explaining = true }
                        .font(.system(size: 12))
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("run-out-how")
                        .popover(isPresented: $explaining) {
                            Text("按最近一小时的用法往后推，用法变了时间也会变，只供参考。")
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(idealWidth: 280)
                                .padding()
                                .presentationCompactAdaptation(.popover)
                                .accessibilityIdentifier("run-out-explain")
                        }
                }
            }
        }
        .padding(.vertical, 6)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
    }
}

/// The VoiceOver audio-graph description of a history chart.
private struct HistoryDescriptor: AXChartDescriptorRepresentable {
    let points: [QuotaHistoryPoint]
    let title: String

    func makeChartDescriptor() -> AXChartDescriptor {
        let x = AXNumericDataAxisDescriptor(
            title: String(localized: "时间"),
            range: (points.first?.time.timeIntervalSince1970 ?? 0)...(max(points.last?.time.timeIntervalSince1970 ?? 1, (points.first?.time.timeIntervalSince1970 ?? 0) + 1)),
            gridlinePositions: []
        ) { value in QuotaFormat.clock(Date(timeIntervalSince1970: value)) }
        let y = AXNumericDataAxisDescriptor(title: String(localized: "用掉"), range: 0...100, gridlinePositions: [0, 50, 100]) { QuotaFormat.percent($0) }
        let data = AXDataSeriesDescriptor(name: title, isContinuous: true,
                                          dataPoints: points.map { .init(x: $0.time.timeIntervalSince1970, y: $0.used) })
        return AXChartDescriptor(title: title, summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [data])
    }
}
