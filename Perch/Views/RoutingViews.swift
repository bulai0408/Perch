import SwiftUI

// MARK: - 路由组 list

/// The 路由组 tab: every group and what the agent used most recently.
struct RoutingGroupsView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(RoutingStore.self) private var store
    @Environment(UsageStore.self) private var usage
    @Environment(\.scenePhase) private var scenePhase

    @State private var now = Date.now

    var body: some View {
        NavigationStack {
            content
                .perchScreen()
                .navigationTitle("路由组")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        StatusCapsule(computer: connection.computerName ?? "", offline: store.isOffline)
                    }
                    .plainBackground()
                }
                .refreshable { await reload() }
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

    /// Reloads the groups and the latest agent call.
    private func reload() async {
        now = .now
        await store.load(connection.routingClient())
        await usage.loadLatest(connection.magpieClient())
    }

    @ViewBuilder
    private var content: some View {
        if store.needsAdmin {
            ScrollView {
                ContentUnavailableView {
                    Label("还不能改路由组", systemImage: "lock")
                } description: {
                    Text("在电脑的 magpie 里，点这把密钥那一行的菜单 → 高级 → 管理 API，选「任何电脑均可」。额度不受影响，照常能看。")
                } actions: {
                    Button("我已打开，再试一次") { Task { await reload() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("routing-retry-admin")
                }
                .padding(.top, 80)
                .accessibilityIdentifier("routing-noadmin")
            }
        } else {
            switch store.phase {
            case .idle:
                placeholder
            case .loading where !store.hasData:
                placeholder
            case .failed(let error) where !store.hasData:
                ScrollView {
                    ContentUnavailableView {
                        Label {
                            Text(verbatim: error.message)
                        } icon: {
                            Image(systemName: "wifi.exclamationmark")
                        }
                    } actions: {
                        refreshButton
                    }
                    .padding(.top, 80)
                    .accessibilityIdentifier("routing-failed")
                }
            default:
                if store.groups.isEmpty {
                    ScrollView {
                        ContentUnavailableView {
                            Label("还没有路由组", systemImage: "arrow.triangle.branch")
                        } description: {
                            Text("在电脑的 magpie 里建一个路由组，再让 Claude Code 这些 Agent 用它，这里就能调了。")
                        } actions: {
                            refreshButton
                        }
                        .padding(.top, 80)
                        .accessibilityIdentifier("routing-empty")
                    }
                } else {
                    list
                }
            }
        }
    }

    private var refreshButton: some View {
        Button("刷新") { Task { await reload() } }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("routing-refresh")
    }

    private var list: some View {
        List {
            if let stale = store.staleSince {
                Section {
                    StaleRow(since: stale, now: now) { Task { await reload() } }
                }
            }
            if let target = usage.target(groups: store.groups) {
                AgentTargetSection(target: target, agentName: usage.agentName, now: now)
            }
            Section {
                ForEach(store.groups) { group in
                    NavigationLink(value: group.id) {
                        GroupRow(group: group)
                    }
                    .accessibilityIdentifier("group-\(group.id)")
                }
            } header: {
                Text("全部路由组")
            } footer: {
                Text("Agent 用哪个路由组，要在电脑的 magpie 里设一次。之后在这里改，用这个组的 Agent 就跟着换。")
            }
        }
        .accessibilityIdentifier("routing-list")
    }

    private var placeholder: some View {
        List {
            Section {
                ForEach(0..<3, id: \.self) { _ in
                    GroupRow(group: .placeholder)
                }
            }
        }
        .redacted(reason: .placeholder)
        .disabled(true)
        .accessibilityHidden(true)
    }
}

/// 「没读到最新的路由组，下面是 10:42 的数据。」 + 重试.
private struct StaleRow: View {
    let since: Date
    let now: Date
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text("没读到最新的路由组，下面是 \(QuotaFormat.clock(since, now: now)) 的数据。")
                    .font(.subheadline)
            } icon: {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 4)
            Button("重试", action: retry)
                .buttonStyle(.borderless)
        }
        .accessibilityIdentifier("routing-stale")
    }
}

/// 「Claude Code 刚刚在用」: the group
/// the selected agent's newest call asked for, or a note when it asked
/// for a model directly. Hidden when magpie can't tell.
private struct AgentTargetSection: View {
    let target: AgentTarget
    let agentName: String
    let now: Date

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
                } header: {
                    header(at)
                }
            }
        case .direct(let model, let at):
            Section {
                Text("\(agentName) 刚刚直接用的是 \(model)，没走路由组。要在手机上换模型，先在电脑上把它的模型设成某个路由组。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("agent-target-direct")
            } header: {
                header(at)
            }
        }
    }

    /// 「<agent> 刚刚在用」 with how long ago.
    private func header(_ at: Date?) -> some View {
        HStack {
            Text("\(agentName) 刚刚在用")
            Spacer()
            if let at {
                Text(verbatim: QuotaFormat.ago(at, now: now))
                    .font(.system(size: 13))
                    .textCase(nil)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent-target-header")
    }
}

/// A group's name, mode and member chain.
private struct GroupRow: View {
    let group: RoutingGroup

    private var chain: RoutingChain { RoutingChain(group) }

    /// The first choice in primary ink and semibold, the rest secondary.
    private var chainText: Text {
        let chain = chain
        var text = AttributedString(chain.lead ?? "")
        text.foregroundColor = .primary
        text.inlinePresentationIntent = .stronglyEmphasized
        var rest = AttributedString(chain.rest)
        rest.foregroundColor = .secondary
        text.append(rest)
        return Text(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(verbatim: group.name)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Text(verbatim: group.mode.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 7))
                    .lineLimit(1)
                    .fixedSize()
            }
            if !chain.text.isEmpty {
                chainText
                    .font(.system(size: 13).monospaced())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(minHeight: 60, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [group.name, group.mode.label, chain.spoken].filter { !$0.isEmpty }.joined(separator: "，")))
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

    private var group: RoutingGroup? { store.group(groupID) }
    private var saving: Bool { store.saving == groupID }
    private var readOnly: Bool { store.isReadOnly || store.needsAdmin }
    private var editing: Bool { editMode.isEditing }

    var body: some View {
        Group {
            if let group {
                content(group)
            } else {
                ContentUnavailableView("还没有路由组", systemImage: "arrow.triangle.branch")
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
        .sensoryFeedback(.success, trigger: successes)
    }

    /// The group screen's list.
    private func content(_ group: RoutingGroup) -> some View {
        List {
            if let stale = store.staleSince {
                Section {
                    StaleRow(since: stale, now: .now) {
                        Task { await store.load(connection.routingClient()) }
                    }
                }
            }

            Section {
                if group.mode.isOffered {
                    Menu {
                        Section("常用") { modeOptions(RoutingMode.common, in: group) }
                        Section("更多") { modeOptions(RoutingMode.more, in: group) }
                    } label: {
                        // A Menu label tints everything; only the value and
                        // chevron stay accent, the title is plain label colour.
                        HStack {
                            Text("选用方式")
                                .foregroundStyle(Color(uiColor: .label))
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
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("routing-mode")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(group.mode.footer, id: \.self) { Text(verbatim: $0) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("routing-mode-footer")
            }

            Section {
                if editing {
                    ForEach(Array(draft.enumerated()), id: \.element.id) { index, member in
                        MemberRow(member: member, number: index + 1, primary: false, action: nil)
                    }
                    .onMove { draft.move(fromOffsets: $0, toOffset: $1) }
                    .deleteDisabled(true)
                } else {
                    ForEach(Array(group.members.enumerated()), id: \.element.id) { index, member in
                        let isPrimary = member.id == group.shownPrimaryID
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
                Text(verbatim: group.mode.membersHeader)
            } footer: {
                Text("改完马上生效。正在跑的会话做完手上这一步就会跟上。")
            }

            Section {
                AgentModelRow(value: group.agentModel) {
                    UIPasteboard.general.string = group.agentModel
                    successes += 1
                    toast = String(localized: "已拷贝")
                }
            } header: {
                Text("在电脑上用这个组")
            }
        }
        .listSectionSpacing(18)
        .animation(.default, value: group.members.map(\.id))
        .disabled(saving)
        .accessibilityIdentifier("group-detail")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if let group {
                VStack(spacing: 0) {
                    Text(verbatim: group.name)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Text("共 \(group.members.count.text) 个模型")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
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
        finish(result, success: success)
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
        if changed { finish(result, success: String(localized: "顺序已保存")) }
    }

    /// Saves the group's routing mode.
    private func setMode(_ mode: RoutingMode, of group: RoutingGroup) async {
        let result = await store.setMode(mode, of: group, client: connection.routingClient())
        finish(result, success: String(localized: "已改成「\(mode.label)」"))
    }

    /// Toasts `success`, or shows the failure.
    private func finish(_ result: Result<Void, RoutingError>, success: String) {
        switch result {
        case .success:
            successes += 1
            toast = success
        case .failure(let error):
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
                    .font(.system(size: 15).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .leading)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: member.title)
                            .font(.system(size: 17))
                            .lineLimit(1)
                        if !member.ready {
                            Text("现在用不了")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(verbatim: member.id)
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if primary {
                    Text("首选")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.tint.opacity(0.12), in: .capsule)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("member-\(member.id)")

            if let action {
                Button(action: action) {
                    Text("设为首选")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(.tint.opacity(0.12), in: .capsule)
                        .foregroundStyle(.tint)
                        .contentShape(.capsule)
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
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(verbatim: value)
                    .font(.system(size: 15).monospaced())
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
