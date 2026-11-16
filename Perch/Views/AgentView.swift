import Charts
import SwiftUI

/// Pushes on the Agent tab.
enum AgentRoute: Hashable {
    /// 「最近的调用」, optionally opened on one account (「在 Agent 页看」)
    /// or on 只看失败 (the summary's 「失败 N 次。」).
    case all(account: String?, failedOnly: Bool = false)
    case call(UsageRow)
}

/// Tab 「Agent」: one agent's calls,
/// tokens and cost for 今天 or 7 天. The title is a menu of agents.
struct AgentView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(UsageStore.self) private var usage
    @Environment(QuotasStore.self) private var quotas
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings

    @State private var path = NavigationPath()
    @State private var now = Date.now
    @State private var live = LiveStore()

    var body: some View {
        NavigationStack(path: $path) {
            content
                // The system large title can't carry the chevron or open a
                // menu, so the content draws its own (titleMenu); the bar's
                // title stays for the back button and is hidden here.
                .perchScreen()
                .navigationTitle(Text(verbatim: usage.agentName))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
                    ToolbarItem(placement: .topBarTrailing) {
                        StatusCapsule(
                            computer: connection.computerName ?? "",
                            ago: usage.lastRead.map { QuotaFormat.ago($0, now: now) },
                            offline: usage.isOffline
                        )
                    }
                    .plainBackground()
                }
                .refreshable { await reload() }
                .navigationDestination(for: AgentRoute.self) { route in
                    switch route {
                    case .all(let account, let failedOnly): AllCallsView(account: account, failedOnly: failedOnly)
                    case .call(let row): CallDetailView(row: row)
                    }
                }
                .navigationDestination(for: AccountRoute.self) { route in
                    AccountDetailView(accountID: route.id)
                }
        }
        .task(id: "\(usage.agent ?? "*")|\(usage.period.rawValue)|\(connection.currentID ?? "")") { await reload() }
        // 正在进行: polled every 4 s while the tab shows and Perch is in front.
        .task(id: "\(usage.agent ?? "*")|\(connection.currentID ?? "")|\(scenePhase == .active)") {
            live.reset()
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await live.poll(agent: usage.agent, client: connection.magpieClient())
                now = .now
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .onChange(of: usage.pendingAccount, initial: true) { _, account in
            guard let account else { return }
            usage.pendingAccount = nil
            path = NavigationPath()
            path.append(AgentRoute.all(account: account, failedOnly: false))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload() } }
        }
    }

    /// Reloads usage, records whether the computer answered, and fills in
    /// quota cards when none are loaded yet.
    private func reload() async {
        now = .now
        let id = connection.currentID
        await usage.load(connection.magpieClient())
        if let id, id == connection.currentID, usage.phase != .idle { connection.markReachable(id, !usage.isOffline) }
        if quotas.cards.isEmpty {
            await quotas.load(connection.quotaClient(), extras: connection.magpieClient())
        }
    }

    /// 「换个 Agent」: agents seen in usage, most calls first, then 所有 Agent.
    @ViewBuilder
    private var agentMenu: some View {
        Section("换个 Agent") {
            ForEach(menuAgents) { bucket in
                Button {
                    usage.agent = bucket.id
                } label: {
                    if usage.agent == bucket.id {
                        Label { Text(verbatim: usage.name(of: bucket.id)) } icon: { Image(systemName: "checkmark") }
                    } else {
                        Text(verbatim: usage.name(of: bucket.id))
                    }
                    Text("\(bucket.totals.calls.text) 次调用")
                }
                .accessibilityIdentifier("agent-menu-\(bucket.id)")
            }
        }
        Divider()
        Button {
            usage.agent = nil
        } label: {
            if usage.agent == nil {
                Label("所有 Agent", systemImage: "checkmark")
            } else {
                Text("所有 Agent")
            }
        }
        .accessibilityIdentifier("agent-menu-all")
    }

    /// Large title: the agent's name and an accent chevron; tap for 换个 Agent.
    private var titleMenu: some View {
        Menu {
            agentMenu
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: usage.agentName)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .contentShape(.rect)
        }
        // Plain, so the menu label keeps its chevron and colours.
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .padding(.horizontal, 4)
        .accessibilityLabel(Text(verbatim: usage.agentName))
        .accessibilityHint(Text("换个 Agent"))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("agent-title-menu")
    }

    /// The selected agent stays listed even with no calls.
    private var menuAgents: [UsageBucket] {
        var list = usage.agents
        if let agent = usage.agent, !list.contains(where: { $0.id == agent }) {
            list.insert(UsageBucket(id: agent, name: usage.name(of: agent), totals: UsageTotals()), at: 0)
        }
        return list
    }

    @ViewBuilder
    private var content: some View {
        @Bindable var usage = usage
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleMenu
                Picker("时间段", selection: $usage.period) {
                    Text("今天").tag(UsagePeriod.today)
                    Text("7 天").tag(UsagePeriod.sevenDays)
                    Text("30 天").tag(UsagePeriod.thirtyDays)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("agent-period")

                if usage.isOffline, connection.computers.count > 1 {
                    UnreachableBar()
                }

                if let stale = usage.staleSince {
                    Label {
                        Text("没读到最新的用量，下面是 \(QuotaFormat.clock(stale, now: now)) 的数据。")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.card, in: .rect(cornerRadius: 18))
                    .accessibilityIdentifier("agent-stale")
                }

                state
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var state: some View {
        switch usage.phase {
        case .failed(.held):
            ContentUnavailableView {
                Label("看不到用量", systemImage: "lock")
            } description: {
                Text(verbatim: MagpieAPIError.held.message)
            } actions: {
                Button("去设置") { openSettings() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 40)
            .accessibilityIdentifier("agent-held")
        case .failed(let error) where !usage.hasData:
            ContentUnavailableView {
                Label { Text(verbatim: error.message) } icon: { Image(systemName: "wifi.exclamationmark") }
            } actions: {
                Button("再刷新一次") { Task { await reload() } }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 40)
            .accessibilityIdentifier("agent-failed")
        default:
            if let page = usage.page {
                if page.totals.calls == 0 && page.rows.isEmpty {
                    empty
                } else {
                    overview(page)
                }
            } else {
                placeholder
            }
        }
    }

    @ViewBuilder
    private var empty: some View {
        let nobody = usage.agents.isEmpty && (usage.summary?.totals.calls ?? 0) == 0
        ContentUnavailableView {
            Label {
                if nobody { Text("还没有 Agent 通过 magpie 调用过模型。") } else { Text("这段时间 \(usage.agentName) 没有调用") }
            } icon: {
                Image(systemName: "apple.terminal")
            }
        } description: {
            if !nobody { Text("让 \(usage.agentName) 通过 magpie 调用模型，这里就会有数据。") }
        }
        .padding(.top, 40)
        .accessibilityIdentifier("agent-empty")
    }

    private var placeholder: some View {
        VStack(spacing: 18) {
            Tiles(totals: UsageTotals(calls: 10, input: 1000, output: 100, cost: 1))
            RoundedRectangle(cornerRadius: 18).fill(Color.card).frame(height: 120)
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12).fill(Color.card).frame(height: 56)
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }

    /// The summary line, tiles, chart and model/account splits for a page.
    private func overview(_ page: UsageRequestsPage) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if let summary = AgentSummary.make(period: usage.period, agentName: usage.agentName, totals: page.totals, models: page.byModel) {
                SummaryLine(summary: summary) {
                    path.append(AgentRoute.all(account: nil, failedOnly: true))
                }
            }

            if live.state != .hidden {
                LiveCard(state: live.state, now: now, cards: quotas.cards) { row in
                    path.append(AgentRoute.call(row))
                }
            }

            Tiles(totals: page.totals)

            if !page.series.isEmpty {
                CostChart(series: page.series, period: usage.period, now: now)
            }

            if !page.byModel.isEmpty {
                block(Text("按模型")) {
                    let models = page.byModel.sorted {
                        $0.totals.cost != $1.totals.cost ? $0.totals.cost > $1.totals.cost : $0.totals.tokens > $1.totals.tokens
                    }
                    let total = max(1, page.totals.tokens)
                    ForEach(Array(models.enumerated()), id: \.element.id) { i, m in
                        if i > 0 { Divider() }
                        ModelRow(bucket: m, share: Double(m.totals.tokens) / Double(total))
                    }
                }
            }

            if !usage.accounts.isEmpty || usage.otherAccountTotals != nil {
                block(Text("按账号")) {
                    ForEach(Array(usage.accounts.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Divider() }
                        accountRow(a)
                    }
                    if let other = usage.otherAccountTotals {
                        if !usage.accounts.isEmpty { Divider() }
                        AccountUsageRow(name: String(localized: "其他"), claude: false, totals: other, chevron: false)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("最近的调用").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    NavigationLink(value: AgentRoute.all(account: nil, failedOnly: false)) {
                        Text("全部").font(.system(size: 13, weight: .medium)).frame(minHeight: 32)
                    }
                    .accessibilityIdentifier("agent-all-calls")
                }
                .padding(.horizontal, 4)
                VStack(spacing: 0) {
                    ForEach(Array(page.rows.prefix(5).enumerated()), id: \.element.id) { i, row in
                        if i > 0 { Divider().padding(.leading, 14) }
                        NavigationLink(value: AgentRoute.call(row)) {
                            CallRow(row: row, now: now, accountName: accountName(row.account), cards: quotas.cards)
                                .padding(.horizontal, 14)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("agent-call-row")
                    }
                }
                .background(Color.card, in: .rect(cornerRadius: 18))
            }

            Text("按 API 价格估算，订阅本身不额外收费。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("agent-cost-footer")
        }
    }

    /// A titled group of rows on a card.
    private func block<C: View>(_ title: Text, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title.font(.system(size: 13, weight: .semibold)).padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 10) { rows() }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.card, in: .rect(cornerRadius: 18))
        }
    }

    /// The account's 额度 card title, else the name as given.
    private func accountName(_ name: String?) -> String? {
        guard let name else { return nil }
        return QuotaGrouping.card(named: name, in: quotas.cards)?.title ?? name
    }

    /// An account's usage row, linking to Account detail when a card matches.
    @ViewBuilder
    private func accountRow(_ bucket: UsageBucket) -> some View {
        if let card = QuotaGrouping.card(named: bucket.id, in: quotas.cards) ?? QuotaGrouping.card(named: bucket.name, in: quotas.cards) {
            NavigationLink(value: AccountRoute(id: card.id)) {
                AccountUsageRow(name: card.title, claude: SubscriptionAccounts.isClaude(card), totals: bucket.totals, chevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("agent-account-row")
        } else {
            AccountUsageRow(name: bucket.name, claude: false, totals: bucket.totals, chevron: false)
        }
    }
}

// MARK: - Pieces

/// 调用 / token / 费用.
private struct Tiles: View {
    let totals: UsageTotals

    private var costSource: String {
        if totals.allUnpriced { return String(localized: "这些模型没有价格") }
        if totals.unpriced > 0 { return String(localized: "\(totals.unpriced.text) 次没有价格，没算进去") }
        return String(localized: "按 API 价格估算")
    }

    var body: some View {
        Grid(horizontalSpacing: 8) {
            GridRow {
                AgentTile(label: String(localized: "调用"), value: totals.calls.text,
                          source: totals.errors > 0 ? String(localized: "失败 \(totals.errors.text) 次") : nil, sourceColor: .red)
                    .accessibilityIdentifier("agent-tile-calls")
                AgentTile(label: "token", value: UsageFormat.tokens(totals.tokens),
                          source: String(localized: "输入 \(UsageFormat.tokens(totals.input)) · 输出 \(UsageFormat.tokens(totals.output))")
                            + "\n" + String(localized: "缓存 \(UsageFormat.tokens(totals.cacheRead + totals.cacheWrite))"))
                    .accessibilityIdentifier("agent-tile-tokens")
                AgentTile(label: String(localized: "费用"), value: UsageFormat.cost(totals), source: costSource)
                    .accessibilityIdentifier("agent-tile-cost")
            }
        }
    }
}

/// One headline number with its label and source.
private struct AgentTile: View {
    let label: String
    let value: String
    let source: String?
    var sourceColor: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: label).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(size: 22, weight: .bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(verbatim: source ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(sourceColor)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.card, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Text(verbatim: [value, source].compactMap { $0 }.joined(separator: "，")))
    }
}

/// A model's cost with its share bar.
private struct ModelRow: View {
    let bucket: UsageBucket
    let share: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: bucket.name.isEmpty ? bucket.id : bucket.name)
                    .font(.system(size: 14).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(verbatim: UsageFormat.cost(bucket.totals))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.track)
                    Capsule().fill(Color.primary).frame(width: geo.size.width * min(max(share, 0), 1))
                }
            }
            .frame(height: 4)
            Text("\(bucket.totals.calls.text) 次 · \(UsageFormat.tokens(bucket.totals.tokens)) token")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent-model-row")
    }
}

/// An account's calls and cost.
private struct AccountUsageRow: View {
    let name: String
    let claude: Bool
    let totals: UsageTotals
    let chevron: Bool

    var body: some View {
        HStack(spacing: 10) {
            Monogram(text: name, claude: claude)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name).font(.system(size: 17)).lineLimit(1)
                Text("\(totals.calls.text) 次 · \(UsageFormat.tokens(totals.tokens)) token")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(verbatim: UsageFormat.cost(totals))
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// 「model · account」, 「48.2k token · 6.1 秒」, relative time, 失败.
struct CallRow: View {
    let row: UsageRow
    let now: Date
    let accountName: String?
    /// For the human failure line and 「换到了 %@」 (1.4).
    var cards: [QuotaCard] = []

    /// Off inside a List, where the NavigationLink draws its own.
    var chevron = true

    private var who: String? { accountName?.nilIfEmpty ?? row.providerName?.nilIfEmpty ?? row.provider?.nilIfEmpty }

    var body: some View {
        HStack(spacing: 8) {
            if row.failed {
                // 1.4: a human line first, then 「model · 账号 · time」.
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: CallFailure.line(for: row, cards: cards, now: now))
                        .font(.system(size: 15))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("call-human-line")
                    Text(verbatim: [row.shownModel, who, row.time.map { QuotaFormat.ago($0, now: now) }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 6)
                Spacer(minLength: 4)
                FailedChip()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text(verbatim: row.shownModel).font(.system(size: 14).monospaced())
                        if let who { Text(verbatim: " · \(who)").font(.system(size: 15)) }
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    Text(verbatim: detail)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if row.switched {
                    Text("换到了 \(CallFailure.switchedTo(row, cards: cards))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("call-switched")
                }
            }
            if !row.failed, let t = row.time {
                Text(verbatim: QuotaFormat.ago(t, now: now))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 56)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts = ["\(UsageFormat.tokens(row.input + row.output + row.cacheRead + row.cacheWrite)) token"]
        if let ms = row.ms { parts.append(UsageFormat.duration(ms: ms)) }
        return parts.joined(separator: " · ")
    }
}

/// The red 「失败」 tag on a failed call.
private struct FailedChip: View {
    var body: some View {
        Text("失败")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.red)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.12), in: .capsule)
            .fixedSize()
            .accessibilityLabel(Text("失败"))
    }
}

// MARK: - 全部

/// Every call of the agent and period, filtered by 模型 / 账号 / 只看失败,
/// 50 at a time as it scrolls.
struct AllCallsView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(UsageStore.self) private var usage
    @Environment(QuotasStore.self) private var quotas

    @State private var filter: UsageFilter
    @State private var rows: [UsageRow] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: MagpieAPIError?
    @State private var now = Date.now

    /// All calls, optionally for one account and/or only failures.
    init(account: String?, failedOnly: Bool = false) {
        var f = UsageFilter(period: .today, agent: nil, account: account)
        f.failedOnly = failedOnly
        _filter = State(initialValue: f)
    }

    private var hasMore: Bool { rows.count < total }

    var body: some View {
        List {
            chips
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            ForEach(shown) { row in
                NavigationLink(value: AgentRoute.call(row)) {
                    CallRow(row: row, now: now, accountName: row.account.map { QuotaGrouping.card(named: $0, in: quotas.cards)?.title ?? $0 },
                            cards: quotas.cards, chevron: false)
                }
                .accessibilityIdentifier("all-call-row")
                .onAppear {
                    if row.id == shown.last?.id, hasMore { Task { await more() } }
                }
            }
            Section {
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let error {
                    Text(verbatim: error.message).foregroundStyle(.secondary)
                } else if !hasMore {
                    Group {
                        if !shown.isEmpty { Text("没有更早的了") }
                        else if filter.failedOnly { Text("这段时间没有失败的调用。") }
                        else { Text("这段时间 \(usage.agentName) 没有调用") }
                    }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("all-calls-end")
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .perchScreen(sky: false)
        .navigationTitle("最近的调用")
        .navigationSubtitle(Text(verbatim: usage.agentName))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await first() }
        .task(id: filterKey) { await first() }
    }

    private var filterKey: String {
        [filter.model ?? "", filter.account ?? "", filter.failedOnly ? "1" : "0", filter.retriedOnly ? "1" : "0",
         usage.agent ?? "*", usage.period.rawValue].joined(separator: "|")
    }

    /// 全部 / 只看失败 / 换过账号的 / 模型 ▾, plus the
    /// account when opened from 「在 Agent 页看」 (tap to clear).
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { filter.failedOnly = false; filter.retriedOnly = false } label: {
                    FilterChip(selected: !filter.failedOnly && !filter.retriedOnly) { Text("全部") }
                }
                .accessibilityIdentifier("chip-all")
                Button { filter.failedOnly = true; filter.retriedOnly = false } label: {
                    FilterChip(selected: filter.failedOnly) { Text("只看失败") }
                }
                .accessibilityIdentifier("chip-failed")
                Button { filter.retriedOnly = true; filter.failedOnly = false } label: {
                    FilterChip(selected: filter.retriedOnly) { Text("换过账号的") }
                }
                .accessibilityIdentifier("chip-switched")
                Menu {
                    Picker("模型", selection: $filter.model) {
                        Text("全部模型").tag(String?.none)
                        ForEach(modelOptions, id: \.self) { m in
                            Text(verbatim: m).tag(String?.some(m))
                        }
                    }
                } label: {
                    FilterChip(selected: filter.model != nil) {
                        HStack(spacing: 3) {
                            if let m = filter.model { Text(verbatim: m).lineLimit(1) } else { Text("模型") }
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                        }
                    }
                }
                .accessibilityIdentifier("chip-model")
                if let a = filter.account {
                    Button { filter.account = nil } label: {
                        FilterChip(selected: true) {
                            HStack(spacing: 3) {
                                Text(verbatim: QuotaGrouping.card(named: a, in: quotas.cards)?.title ?? a).lineLimit(1)
                                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            }
                        }
                    }
                    .accessibilityIdentifier("chip-account")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// magpie's `errors=1` also returns calls it handed on and that then
    /// worked; those are not failures, so 只看失败 drops them.
    private var shown: [UsageRow] {
        filter.failedOnly ? rows.filter(\.failed) : rows
    }

    private var modelOptions: [String] {
        var list = usage.page?.byModel.map(\.id) ?? []
        if let m = filter.model, !list.contains(m) { list.insert(m, at: 0) }
        return list
    }

    /// Loads the first page for the current filter.
    private func first() async {
        now = .now
        var f = filter
        f.period = usage.period
        f.agent = usage.agent
        loading = true
        error = nil
        switch await usage.page(f, offset: 0, client: connection.magpieClient()) {
        case .success(let page):
            rows = page.rows
            total = page.total
        case .failure(let e):
            rows = []
            total = 0
            error = e
        }
        loading = false
    }

    /// Appends the next page, unless one is already loading.
    private func more() async {
        guard !loading else { return }
        var f = filter
        f.period = usage.period
        f.agent = usage.agent
        loading = true
        if case .success(let page) = await usage.page(f, offset: rows.count, client: connection.magpieClient()) {
            let known = Set(rows.map(\.id))
            rows += page.rows.filter { !known.contains($0.id) }
            total = page.total
            if page.rows.isEmpty { total = rows.count }
        }
        loading = false
    }
}

// MARK: - 一次调用

/// 「一次调用」: everything magpie recorded about one call.
struct CallDetailView: View {
    let row: UsageRow

    @Environment(QuotasStore.self) private var quotas

    /// How the call ended.
    private enum Outcome { case ok, failed, refused }

    private var outcome: Outcome {
        if row.status == 401 || row.status == 403 { return .refused }
        return row.failed ? .failed : .ok
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("结果")
                    Spacer()
                    resultCapsule
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("call-result")
                if outcome != .ok {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: CallFailure.line(for: row, cards: quotas.cards))
                            .font(.system(size: 15))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("call-human-line")
                        if let original = CallFailure.original(row) {
                            Text("magpie 原话：\(original)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("call-original")
                        }
                    }
                } else if row.switched {
                    Text("换到了 \(CallFailure.switchedTo(row, cards: quotas.cards))")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if let t = row.time {
                    LabeledContent("时间") {
                        Text(verbatim: t.formatted(Date.FormatStyle.dateTime.month().day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).locale(Locale(identifier: "zh-Hans"))))
                            .monospacedDigit()
                    }
                }
                LabeledContent("模型") {
                    Text(verbatim: modelText).font(.system(size: 14).monospaced()).multilineTextAlignment(.trailing)
                }
                LabeledContent("账号") {
                    Text(verbatim: accountText)
                }
                if let ms = row.ms {
                    LabeledContent("耗时") { Text(verbatim: UsageFormat.duration(ms: ms)).monospacedDigit() }
                }
                LabeledContent("费用") {
                    Text(verbatim: row.priced == false || row.cost == nil ? "—" : String(localized: "约 \(UsageFormat.dollars(row.cost ?? 0))"))
                        .monospacedDigit()
                }
            }
            Section {
                LabeledContent("输入") { Text(verbatim: row.input.formatted()).monospacedDigit() }
                LabeledContent("输出") { Text(verbatim: row.output.formatted()).monospacedDigit() }
                LabeledContent("缓存读") { Text(verbatim: row.cacheRead.formatted()).monospacedDigit() }
                LabeledContent("缓存写") { Text(verbatim: row.cacheWrite.formatted()).monospacedDigit() }
            } header: {
                Text(verbatim: "token")
            } footer: {
                Text("magpie 不记录对话内容，这里只有这些数字。")
            }
        }
        .perchScreen(sky: false)
        .navigationTitle("一次调用")
        .navigationSubtitle(Text(verbatim: row.time.map { QuotaFormat.ago($0) } ?? ""))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var modelText: String {
        let asked = row.requested ?? row.model
        let used = row.shownModel
        return asked == used || asked.isEmpty ? used : "\(asked) → \(used)"
    }

    private var accountText: String {
        if let a = row.account { return QuotaGrouping.card(named: a, in: quotas.cards)?.title ?? a }
        return row.providerName ?? row.provider ?? "—"
    }

    @ViewBuilder
    private var resultCapsule: some View {
        let (text, color): (LocalizedStringKey, Color) = switch outcome {
        case .ok: ("成功", .green)
        case .failed: ("失败", .red)
        case .refused: ("被拒", .orange)
        }
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: .capsule)
    }
}
