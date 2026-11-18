import SwiftUI

// MARK: - 路由组 list

/// The 路由组 tab: every group and what the agent used most recently.
struct RoutingGroupsView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(RoutingStore.self) private var store
    @Environment(UsageStore.self) private var usage
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduce

    @State private var now = Date.now
    @State private var pull = PullOutcome()

    var body: some View {
        NavigationStack {
            content
                .perchScreen()
                .navigationTitle("路由组")
                .statusCapsule(computer: connection.computerName ?? "", freshness: store.freshness)
                .refreshable {
                    await reload()
                    pull.record(store.freshness.failure == nil && store.phase == .loaded && usage.latestStale == nil)
                }
                .pullFeedback(pull)
                .navigationDestination(for: String.self) { id in
                    RoutingGroupView(groupID: id)
                }
        }
        .task(id: connection.currentID) { await reload() }
        .task(id: usage.agent) { await usage.loadLatest(connection.magpieClient()) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload() } }
        }
    }

    /// The groups and the agent's newest call together; each shows as it lands.
    private func reload() async {
        now = .now
        let id = connection.currentID
        let client = connection.routingClient()
        let magpie = connection.magpieClient()
        async let groups: Void = store.load(client, probe: magpie, computer: id)
        async let latest: Void = usage.loadLatest(magpie)
        _ = await (groups, latest)
        if let id, id == connection.currentID, store.phase != .idle { connection.markReachable(id, !store.isOffline) }
    }

    /// States with art.
    @ViewBuilder
    private var content: some View {
        if store.needsAdmin {
            ScrollView {
                ArtStateView(title: String(localized: "这把密钥只能看额度"),
                             message: String(localized: "在电脑的 magpie 里，这把密钥那一行点 ⋯ →「高级」→「管理 API」，选「任何电脑均可」。"))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("routing-noadmin")
            }
        } else {
            switch store.phase {
            case .idle:
                placeholder
            case .loading where !store.hasData:
                placeholder
            case .failed where !store.hasData && store.isOffline:
                ScrollView {
                    OfflineCard(computer: connection.computerName ?? "", since: nil, now: now) {
                        Task { await reload() }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                }
            case .failed(let error) where !store.hasData:
                ScrollView {
                    ArtStateView(art: "art-error", title: error.message, button: String(localized: "刷新")) {
                        Task { await reload() }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("routing-failed")
                }
            default:
                if store.groups.isEmpty {
                    ScrollView {
                        ArtStateView(title: String(localized: "还没有路由组"),
                                     message: String(localized: "在电脑的 magpie 里建好，这里就能看到，也能换首选。"),
                                     button: String(localized: "刷新")) {
                            Task { await reload() }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("routing-empty")
                    }
                } else {
                    list
                }
            }
        }
    }

    private var list: some View {
        List {
            if store.isOffline {
                Section {
                    OfflineCard(computer: connection.computerName ?? "", since: store.lastRead, now: now) {
                        Task { await reload() }
                    }
                }
                .bannerRow()
            } else if store.isStale, let since = store.lastRead {
                Section {
                    StaleBanner(since: since, now: now) { Task { await reload() } }
                }
                .bannerRow()
            }
            if let target = usage.target(groups: store.groups) {
                AgentTargetSection(target: target, agentName: usage.agentName, now: now,
                                   staleSince: store.isOffline ? nil : usage.latestFooter) { Task { await usage.loadLatest(connection.magpieClient()) } }
                    .cardRow()
                    .offlineDimmed(store.isOffline)
            }
            if !store.activeGroups.isEmpty {
                Section {
                    ForEach(store.activeGroups) { group in
                        NavigationLink(value: group.id) {
                            GroupRow(group: group)
                        }
                        .offlineDimmed(store.isOffline)
                        .accessibilityIdentifier("group-\(group.id)")
                    }
                } header: {
                    Text("全部路由组").listHeaderStyle()
                } footer: {
                    if store.disabledGroups.isEmpty { listFooter }
                }
                .cardRow()
            }
            // Stopped on the computer: last, dimmed, read-only on tap.
            if !store.disabledGroups.isEmpty {
                Section {
                    ForEach(store.disabledGroups) { group in
                        NavigationLink(value: group.id) {
                            GroupRow(group: group)
                        }
                        .accessibilityIdentifier("group-\(group.id)")
                    }
                } header: {
                    Text("已停用").listHeaderStyle()
                        .accessibilityIdentifier("routing-disabled-header")
                } footer: {
                    listFooter
                }
                .cardRow()
            }
        }
        .listRowSeparatorTint(Color.hairline)
        .environment(\.fromCache, store.fromCache)
        .animation(Motion.offline(reduce, showing: store.isOffline), value: store.isOffline)
        .animation(Motion.banner(reduce, showing: store.isStale), value: store.isStale)
        .accessibilityIdentifier("routing-list")
    }

    private var listFooter: some View {
        Text("Agent 用哪个路由组，要在电脑的 magpie 里设一次。之后在这里改，用这个组的 Agent 就跟着换。")
            .foregroundStyle(.ink2)
    }

    /// Skeleton rows in the list's layout, after 250 ms.
    private var placeholder: some View {
        ScrollView {
            DelayedLoading(spoken: String(localized: "正在读取路由组")) {
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(width: 80, height: 12).padding(.leading, 20)
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(0..<3, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    SkeletonBlock(width: 90, height: 16)
                                    SkeletonBlock(width: 48, height: 16, radius: 8)
                                }
                                SkeletonBlock(width: 220, height: 12)
                            }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .perchCard()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
    }
}

/// 「Claude Code 刚刚在用」: the group
/// the selected agent's newest call asked for, or a note when it asked
/// for a model directly. Hidden when magpie can't tell.
private struct AgentTargetSection: View {
    let target: AgentTarget
    let agentName: String
    let now: Date
    /// 1.5: the newest call didn't read this time; when the shown one was.
    var staleSince: Date? = nil
    var retry: () -> Void = {}

    @Environment(RoutingStore.self) private var store

    var body: some View {
        switch target {
        case .group(let id, let at):
            if let group = store.group(id) {
                Section {
                    NavigationLink(value: group.id) {
                        HStack(spacing: 12) {
                            Monogram(text: agentName, claude: agentName.lowercased().contains("claude"))
                            GroupRow(group: group)
                        }
                    }
                    .accessibilityIdentifier("agent-target-group")
                    if let staleSince { StaleFooter(since: staleSince, now: now, hairline: false, retry: retry) }
                } header: {
                    header(at)
                }
            }
        case .direct(let model, let at):
            Section {
                Text("\(agentName) 刚刚直接用的是 \(model)，没走路由组。要在手机上换模型，先在电脑上把它的模型设成某个路由组。")
                    .font(.subheadline)
                    .foregroundStyle(.ink2)
                    .accessibilityIdentifier("agent-target-direct")
                if let staleSince { StaleFooter(since: staleSince, now: now, hairline: false, retry: retry) }
            } header: {
                header(at)
            }
        }
    }

    /// 「<agent> 刚刚在用」 with how long ago.
    private func header(_ at: Date?) -> some View {
        HStack(spacing: 6) {
            BreathingDot()
            Text("\(agentName) 刚刚在用")
                .foregroundStyle(.good)
            Spacer()
            if let at {
                Text(verbatim: QuotaFormat.ago(at, now: now))
                    .font(.footnote)
                    .foregroundStyle(.ink2)
                    .monospacedDigit()
            }
        }
        .listHeaderStyle()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent-target-header")
    }
}

/// A group's name, mode and member chain.
private struct GroupRow: View {
    let group: RoutingGroup

    private var chain: RoutingChain { RoutingChain(group) }

    /// A group stopped on the computer is drawn all in ink2.
    private var dimmed: Bool { group.disabled }

    /// The first choice in ink and semibold, the other models ink2, all
    /// monospaced; words after them (「 · 另有 2 个」) in the body font at
    /// footnote size, ink2.
    private var chainText: Text {
        let chain = chain
        var text = AttributedString(chain.lead ?? "")
        text.foregroundColor = dimmed ? Color.ink2 : Color.ink
        text.font = Font.system(size: 13, weight: .semibold).monospaced()
        var rest = AttributedString(chain.rest)
        rest.foregroundColor = Color.ink2
        rest.font = Font.system(size: 13).monospaced()
        text.append(rest)
        var note = AttributedString(chain.note)
        note.foregroundColor = Color.ink2
        note.font = Font.footnote
        text.append(note)
        return Text(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(verbatim: group.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(dimmed ? Color.ink2 : Color.ink)
                    .lineLimit(1)
                Chip(text: "\(group.mode.label)", color: .ink2)
            }
            if !chain.text.isEmpty {
                chainText
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(minHeight: 60, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [group.name, group.mode.label, chain.spoken, dimmed ? String(localized: "已停用") : ""]
            .filter { !$0.isEmpty }.joined(separator: "，")))
    }
}

// MARK: - One group

/// One group: its mode, members and reordering.
struct RoutingGroupView: View {
    let groupID: String

    @Environment(ConnectionStore.self) private var connection
    @Environment(RoutingStore.self) private var store

    @State private var editMode: EditMode = .inactive
    @State private var draft: [RoutingMember] = []
    @State private var confirming: RoutingMember?
    @State private var failure: RoutingError?
    @State private var toast: String?
    @State private var successes = 0
    @State private var failures = 0
    @State private var lastHaptic: SensoryFeedback = .success
    @Environment(\.accessibilityReduceMotion) private var reduce

    private var group: RoutingGroup? { store.group(groupID) }
    private var saving: Bool { store.saving == groupID }
    /// Offline, a key without 管理 API, or a group stopped on the computer.
    private var readOnly: Bool { store.isReadOnly || store.needsAdmin || group?.disabled == true }
    private var editing: Bool { editMode.isEditing }

    var body: some View {
        Group {
            if let group {
                content(group)
            } else {
                ScrollView {
                    ArtStateView(title: String(localized: "还没有路由组"),
                                 message: String(localized: "在电脑的 magpie 里建好，这里就能看到，也能换首选。"))
                }
            }
        }
        .perchScreen(sky: false)
        .navigationTitle(group?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .environment(\.editMode, $editMode)
        .alert("改成按顺序？", isPresented: confirmingBinding, presenting: confirming) { member in
            Button("改成按顺序") {
                Task { await makePrimary(member) }
            }
            .keyboardShortcut(.defaultAction)
            Button("取消", role: .cancel) {}
        } message: { member in
            if let group {
                Text("这个组现在是「\(group.mode.label)」。设为首选会把选用方式改成「按顺序」：以后一直先用 \(member.title)，用不了再往下。")
            }
        }
        .alert(failureTitle, isPresented: failureBinding, presenting: failure) { _ in
            Button("好", role: .cancel) {}
        } message: { error in
            if let reason = error.reason { Text(verbatim: reason) }
        }
        .toast($toast, seconds: 2)
        // Haptics: 设为首选 rigid, 选用方式 selection, failures error; 拷贝 and
        // saved order a plain success.
        .sensoryFeedback(trigger: successes) { _, _ in lastHaptic }
        .sensoryFeedback(Haptic.failed, trigger: failures)
    }

    /// The group screen's list.
    private func content(_ group: RoutingGroup) -> some View {
        List {
            if store.isOffline {
                Section {
                    OfflineCard(computer: connection.computerName ?? "", since: store.lastRead, now: .now) {
                        Task { await store.load(connection.routingClient(), probe: connection.magpieClient(), computer: connection.currentID) }
                    }
                }
                .bannerRow()
            } else if store.isStale, let since = store.lastRead {
                Section {
                    StaleBanner(since: since, now: .now) {
                        Task { await store.load(connection.routingClient(), probe: connection.magpieClient(), computer: connection.currentID) }
                    }
                }
                .bannerRow()
            }

            if group.disabled {
                Section {
                    Label {
                        Text("这个组在电脑上停用了，Agent 用不了它。要在电脑的 magpie 里启用。")
                            .font(.subheadline)
                            .foregroundStyle(.ink2)
                    } icon: {
                        Image(systemName: "pause.circle")
                            .foregroundStyle(.ink2)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("group-disabled-note")
                }
                .cardRow()
            }

            Section {
                if group.mode.isOffered && !group.disabled {
                    Menu {
                        Section("常用") { modeOptions(RoutingMode.common, in: group) }
                        Section("更多") { modeOptions(RoutingMode.more, in: group) }
                    } label: {
                        // A Menu label tints everything; only the value and
                        // chevron stay accent, the title is plain label colour.
                        HStack {
                            Text("选用方式")
                                .foregroundStyle(Color.ink)
                            Spacer()
                            HStack(spacing: 4) {
                                Text(verbatim: group.mode.label)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.footnote.weight(.semibold))
                            }
                            .foregroundStyle(Color.accentColor)
                        }
                        .contentShape(.rect)
                    }
                    .disabled(readOnly || editing || saving)
                    .accessibilityIdentifier("routing-mode")
                } else {
                    LabeledContent("选用方式") {
                        Text(verbatim: group.mode.label)
                    }
                    .labeledContentStyle(.perch)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("routing-mode")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(group.mode.footer, id: \.self) { Text(verbatim: $0) }
                }
                .foregroundStyle(.ink2)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("routing-mode-footer")
            }
            .cardRow()

            Section {
                if editing {
                    ForEach(Array(draft.enumerated()), id: \.element.id) { index, member in
                        MemberRow(member: member, number: index + 1, primary: false, action: nil)
                    }
                    .onMove { draft.move(fromOffsets: $0, toOffset: $1) }
                    .deleteDisabled(true)
                } else {
                    ForEach(Array(group.members.enumerated()), id: \.element.id) { index, member in
                        // A stopped group has no 首选 to show: Agent can't use it.
                        let isPrimary = !group.disabled && member.id == group.shownPrimaryID
                        let canPick = !isPrimary && !readOnly
                        MemberRow(member: member, number: index + 1, primary: isPrimary,
                                  action: canPick ? { request(member, in: group) } : nil)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if canPick {
                                    Button("设为首选") { request(member, in: group) }
                                        .tint(.accentColor)
                                }
                            }
                            .contextMenu {
                                if canPick {
                                    Button("设为首选", systemImage: "star") { request(member, in: group) }
                                }
                            }
                    }
                }
            } header: {
                Text(verbatim: group.mode.membersHeader).listHeaderStyle()
            } footer: {
                // Nothing changes on a stopped group, so no 「改完马上生效」.
                if !group.disabled {
                    Text("改完马上生效。正在跑的会话做完手上这一步就会跟上。")
                        .foregroundStyle(.ink2)
                }
            }
            .cardRow()

            Section {
                AgentModelRow(value: group.agentModel) {
                    UIPasteboard.general.string = group.agentModel
                    lastHaptic = .success
                    successes += 1
                    toast = String(localized: "已拷贝")
                }
            } header: {
                Text("在电脑上用这个组").listHeaderStyle()
            }
            .cardRow()
        }
        .listSectionSpacing(20)
        .listRowSeparatorTint(Color.hairline)
        // 设为首选: the row moves to the top (calm 0.5 s) and the
        // 首选 chip crossfades onto it; a crossfade under Reduce Motion.
        .animation(Motion.calm(reduce), value: group.members.map(\.id))
        .animation(Motion.calm(reduce), value: group.shownPrimaryID)
        .disabled(saving)
        .accessibilityIdentifier("group-detail")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if let group {
                VStack(spacing: 0) {
                    Text(verbatim: group.name)
                        .font(.system(.headline, design: .serif))
                        .foregroundStyle(.ink)
                        .lineLimit(1)
                    Text("共 \(group.members.count.text) 个模型")
                        .font(.caption)
                        .foregroundStyle(.ink2)
                        .contentTransition(.numericText())
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if saving {
                ProgressView()
                    .accessibilityLabel(Text("正在保存…"))
            } else if let group, group.members.count > 1 {
                Button(editing ? "完成" : "调整顺序") {
                    if editing {
                        Task { await finishReorder(group) }
                    } else {
                        draft = group.members
                        withAnimation { editMode = .active }
                    }
                }
                .fontWeight(editing ? .semibold : .regular)
                .disabled(readOnly)
                .accessibilityIdentifier("reorder-button")
            }
        }
    }

    /// One menu item per mode: name, its one line, a check on the current.
    @ViewBuilder
    private func modeOptions(_ modes: [RoutingMode], in group: RoutingGroup) -> some View {
        ForEach(modes, id: \.raw) { mode in
            Button {
                guard mode != group.mode else { return }
                Task { await setMode(mode, of: group) }
            } label: {
                if mode == group.mode {
                    Label {
                        Text(verbatim: mode.label)
                        Text(verbatim: mode.detail)
                    } icon: {
                        Image(systemName: "checkmark")
                    }
                } else {
                    Text(verbatim: mode.label)
                    Text(verbatim: mode.detail)
                }
            }
            .accessibilityIdentifier("mode-\(mode.raw.isEmpty ? "smart" : mode.raw)")
        }
    }

    // MARK: Actions

    /// 手动 sets the pick straight away; the others confirm first.
    private func request(_ member: RoutingMember, in group: RoutingGroup) {
        if group.primaryChange(to: member.id).needsConfirm {
            confirming = member
        } else {
            Task { await makePrimary(member) }
        }
    }

    /// Makes `member` the first choice (reorders or picks, by mode).
    private func makePrimary(_ member: RoutingMember) async {
        guard let group else { return }
        let plan = group.primaryChange(to: member.id)
        let result = await store.makePrimary(member.id, in: group, client: connection.routingClient())
        let success = switch plan {
        case .reorder: String(localized: "已把 \(member.title) 设为首选")
        case .pick: String(localized: "现在只用 \(member.title)")
        case .switchToOrder: String(localized: "已改成按顺序，\(member.title) 是首选")
        }
        finish(result, success: success, haptic: Haptic.primary)
    }

    /// While dragging: the top row is 首选 under 按顺序/用完再换/轮换;
    /// 手动 keeps its pick wherever it goes.
    private func draftPrimaryID(_ group: RoutingGroup) -> String? {
        switch group.mode {
        case .manual: group.shownPrimaryID
        case let mode where mode.hasPrimary: draft.first?.id
        default: nil
        }
    }

    /// Leaves edit mode and saves the new order if it changed.
    private func finishReorder(_ group: RoutingGroup) async {
        let order = draft.map(\.id)
        let changed = order != group.members.map(\.id)
        let result = await store.reorder(group, to: order, client: connection.routingClient())
        withAnimation { editMode = .inactive }
        if changed { finish(result, success: String(localized: "顺序已保存"), haptic: .success) }
    }

    /// Saves the group's routing mode.
    private func setMode(_ mode: RoutingMode, of group: RoutingGroup) async {
        let result = await store.setMode(mode, of: group, client: connection.routingClient())
        finish(result, success: String(localized: "已改成「\(mode.label)」"), haptic: Haptic.selection)
    }

    /// Toasts `success`, or shows the failure.
    private func finish(_ result: Result<Void, RoutingError>, success: String, haptic: SensoryFeedback) {
        switch result {
        case .success:
            lastHaptic = haptic
            successes += 1
            toast = success
        case .failure(let error):
            failures += 1
            failure = error
        }
    }

    // MARK: Alerts

    private var confirmingBinding: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private var failureTitle: String {
        guard let failure else { return "" }
        switch failure {
        case .rejected: return String(localized: "没改成，一切保持原样。")
        default: return failure.message
        }
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
    }
}

/// A numbered member, with 设为首选 when allowed.
private struct MemberRow: View {
    let member: RoutingMember
    let number: Int
    let primary: Bool
    /// 设为首选, when this row may become the first choice.
    let action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(verbatim: number.text)
                    .font(.system(size: 15, design: .serif).monospacedDigit())
                    .foregroundStyle(.ink2)
                    .frame(width: 18, alignment: .leading)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: member.title)
                            .font(.body)
                            .foregroundStyle(.ink)
                            .lineLimit(1)
                        if !member.ready {
                            Text("现在用不了")
                                .font(.footnote)
                                .foregroundStyle(.ink2)
                        }
                    }
                    Text(verbatim: member.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if primary {
                    Chip(text: "首选", color: .accentColor)
                        .transition(.opacity)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("member-\(member.id)")

            if let action {
                Button(action: action) {
                    Text("设为首选")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 10, style: .continuous))
                        .contentShape(.rect(cornerRadius: 10))
                        .fixedSize()
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("make-primary-\(member.id)")
            }
        }
        .frame(minHeight: 52)
    }
}

/// 「在电脑上用这个组」: what to put in an Agent's model, and 拷贝.
private struct AgentModelRow: View {
    let value: String
    let copy: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("把这个填进 Agent 的模型")
                    .font(.footnote)
                    .foregroundStyle(.ink2)
                Text(verbatim: value)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("agent-model")
            Spacer(minLength: 4)
            Button(action: copy) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 17))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("拷贝组名"))
            .accessibilityIdentifier("copy-agent-model")
        }
    }
}

extension RoutingGroup {
    static let placeholder = RoutingGroup(
        id: "placeholder", name: "Coder",
        members: [RoutingMember(id: "claude/claude-opus-5-5", title: "Claude Opus 5.5", providerName: "Claude", ready: true)],
        routing: "order", pick: nil, disabled: false, auto: false, ref: "group/placeholder"
    )
}
