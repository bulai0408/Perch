import SwiftUI

/// The 额度 tab: the hero summary and one card per account.
struct QuotasView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(QuotasStore.self) private var store
    @Environment(VersionStore.self) private var versions
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.dynamicTypeSize) private var typeSize

    @AppStorage(QuotaSort.storageKey) private var sort: QuotaSort = .mostUsed
    @State private var toast: String?
    @State private var now = Date.now
    @State private var pull = PullOutcome()
    @Namespace private var zoom

    var body: some View {
        NavigationStack {
            content
                .perchScreen()
                .navigationTitle("额度")
                .statusCapsule(computer: connection.computerName ?? "", freshness: store.freshness)
                .refreshable {
                    await load()
                    let ok = store.freshness.failure == nil && store.phase == .loaded
                    pull.record(ok)
                    if ok { store.breath += 1 }
                }
                .pullFeedback(pull)
                .sensoryFeedback(Haptic.runOut, trigger: runOutKey) { old, new in new != nil && old != new }
                .toast($toast, seconds: 2)
                .navigationDestination(for: AccountRoute.self) { route in
                    if reduce {
                        AccountDetailView(accountID: route.id)
                    } else {
                        AccountDetailView(accountID: route.id)
                            .navigationTransition(.zoom(sourceID: route.source, in: zoom))
                    }
                }
                .navigationDestination(for: ReleaseNotesRoute.self) { _ in
                    ReleaseNotesView()
                }
        }
        .task(id: connection.currentID) {
            await load()
            await versions.refresh(client: connection.magpieClient(), computerID: connection.currentID)
        }
        .task {
            // Relative times (「2 分钟前」, 「42 分后重置」) move on by themselves.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = .now
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                now = .now
                Task { await load() }
            }
        }
    }

    /// Loads the cards and records whether the computer answered.
    private func load() async {
        let id = connection.currentID
        await store.load(connection.quotaClient(), extras: connection.magpieClient(), computer: id)
        if let id, id == connection.currentID, store.phase != .idle { connection.markReachable(id, !store.isOffline) }
    }

    private var hero: QuotaHero? {
        QuotaHero.pick(store.cards) { store.runOut($0, now: now) }
    }

    /// The hero's run-out window: `.warning` once when one first shows.
    private var runOutKey: String? {
        guard let hero, let runOut = hero.runOut else { return nil }
        return hero.card.id + "|" + runOut.window
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle:
            placeholder
        case .loading where !store.hasData:
            placeholder
        case .failed(let error) where !store.hasData && error != .forbidden:
            ScrollView {
                if store.isOffline {
                    OfflineCard(computer: connection.computerName ?? "", since: nil, now: now) {
                        Task { await load() }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .riseIn()
                } else {
                    ArtStateView(art: "art-error", title: error.message, button: String(localized: "刷新")) {
                        Task { await load() }
                    }
                    .accessibilityIdentifier("quotas-error")
                }
            }
        default:
            if store.cards.isEmpty {
                ScrollView {
                    if store.isOffline {
                        OfflineCard(computer: connection.computerName ?? "", since: store.lastRead, now: now) {
                            Task { await load() }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                    } else if store.isStale, let since = store.lastRead {
                        StaleBanner(since: since, now: now) { Task { await load() } }
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                    }
                    ArtStateView(title: String(localized: "还没有额度可看"),
                                 message: String(localized: "magpie 里还没有订阅账号。"),
                                 button: String(localized: "刷新")) {
                        Task { await load() }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("quotas-empty")
                }
            } else {
                cardList
            }
        }
    }

    private var cardList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if store.isOffline {
                    OfflineCard(computer: connection.computerName ?? "", since: store.lastRead, now: now) {
                        Task { await load() }
                    }
                    .padding(.bottom, 12)
                    .transition(.offlineCard)
                }
                if store.isStale, let since = store.lastRead {
                    StaleBanner(since: since, now: now) { Task { await load() } }
                        .padding(.bottom, 12)
                        .transition(.staleBanner)
                }
                if versions.showsBanner, let release = versions.newer {
                    VersionBanner(computer: connection.computerName ?? "", release: release)
                        .padding(.bottom, 12)
                }

                Group {
                    if let hero {
                        NavigationLink(value: AccountRoute(id: hero.card.id, source: "hero")) {
                            QuotaHeroView(hero: hero, now: now)
                        }
                        .buttonStyle(.plain)
                        .matchedTransitionSource(id: "hero", in: zoom)
                        .padding(.bottom, 20)
                        .riseIn(0)
                    }

                    let sections = store.sections(sort: sort, now: now)
                    let justUsed = store.justUsed
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        VStack(alignment: .leading, spacing: 8) {
                            sectionHeader(section, sortMenu: index == 0)
                            LazyVStack(spacing: 12) {
                                ForEach(Array(section.cards.enumerated()), id: \.element.id) { i, card in
                                    Group {
                                        if card.kind == "subscription" {
                                            QuotaCardView(card: card, now: now, toast: $toast,
                                                          justUsed: justUsed.contains(card.id), opens: true)
                                                .matchedTransitionSource(id: "card-" + card.id, in: zoom)
                                        } else {
                                            QuotaCardView(card: card, now: now, toast: $toast)
                                        }
                                    }
                                    .riseIn(index + i + 1)
                                }
                            }
                        }
                        .padding(.bottom, 20)
                    }
                    footer
                }
                .offlineDimmed(store.isOffline)
                .environment(\.fromCache, store.fromCache)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .animation(Motion.offline(reduce, showing: store.isOffline), value: store.isOffline)
            .animation(Motion.banner(reduce, showing: store.isStale), value: store.isStale)
        }
    }

    /// The provider's name on the left; 「账号 N · 1 个已停用」 and (first
    /// section) 排序 on the right.
    private func sectionHeader(_ section: QuotaSection, sortMenu: Bool) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
        return layout {
            Text(verbatim: section.title)
                .font(.headline)
                .foregroundStyle(.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("quota-section-\(section.id)")
            if !typeSize.isAccessibilitySize { Spacer() }
            Text(verbatim: Self.count(section))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("quota-section-count-\(section.id)")
            if sortMenu { sortMenuButton }
        }
        .frame(minHeight: 32)
        .padding(.horizontal, 4)
    }

    /// 「账号 3 · 1 个已停用」.
    static func count(_ section: QuotaSection) -> String {
        let off = section.cards.filter(\.off).count
        let head = String(localized: "账号 \(section.cards.count.text)")
        return off > 0 ? head + " · " + String(localized: "\(off.text) 个已停用") : head
    }

    private var sortMenuButton: some View {
        Menu {
            Picker("排序", selection: $sort) {
                ForEach(QuotaSort.allCases, id: \.self) { option in
                    Text(verbatim: option.label).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text("排序")
                .font(.footnote.weight(.medium))
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .accessibilityIdentifier("quota-sort")
        .accessibilityValue(Text(verbatim: sort.label))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("下拉刷新全部，长按一张卡只刷新这一张。")
        }
        .font(.footnote)
        .foregroundStyle(.ink2)
        .padding(.horizontal, 4)
    }

    private var placeholder: some View {
        ScrollView {
            DelayedLoading(spoken: String(localized: "正在读取额度")) {
                QuotaSkeleton()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .scrollDisabled(true)
    }
}

// MARK: - Card

/// One account: header, windows two to a row, balance, error. Long-press
/// for 刷新这张额度 (still at most once every 30 s).
struct QuotaCardView: View {
    let card: QuotaCard
    let now: Date
    @Binding var toast: String?
    /// 刚刚在用: served this provider's latest call.
    var justUsed = false
    /// A subscription card: a chevron, and it opens Account detail.
    var opens = false

    @Environment(ConnectionStore.self) private var connection
    @Environment(QuotasStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var pressed = false

    private var hasError: Bool { card.error?.trimmed.isEmpty == false }
    /// This card's own refresh failed; when its data was read.
    private var staleSince: Date? { store.staleFooter(for: card.id) }
    /// 1.4 「照现在的速度，大约 %@ 用完」: one line per card, the window that
    /// runs out first.
    private var runOut: RunOut? {
        guard card.kind == "subscription", !card.off, !hasError else { return nil }
        return store.runOut(card, now: now)
    }
    private var balance: String? { card.balance?.trimmed.isEmpty == false ? card.balance?.trimmed : nil }
    private var balanceOnly: Bool { card.windows.isEmpty && balance != nil }

    /// The context menu goes on the link, not inside it: inside a
    /// NavigationLink the link's press wins and the menu never opens.
    var body: some View {
        link
            .contentShape(.contextMenuPreview, .rect(cornerRadius: 22))
            .contextMenu {
                Button("刷新这张额度", systemImage: "arrow.clockwise") { refresh() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: spoken))
            .accessibilityAction(named: Text("刷新这张额度")) { refresh() }
            .accessibilityAction(named: Text("重试")) { if staleSince != nil { retryCard() } }
            .accessibilityHint(opens ? Text("打开详情") : Text(verbatim: ""))
            .accessibilityIdentifier("quota-card")
    }

    @ViewBuilder
    private var link: some View {
        if opens {
            NavigationLink(value: AccountRoute(id: card.id)) { face }
                .buttonStyle(.plain)
        } else {
            face
        }
    }

    private var face: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !card.windows.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                        WindowCell(window: window, now: now, stacked: windows.count >= 3,
                                   runOut: runOut?.window == window.name ? runOut : nil)
                    }
                }
                .opacity(hasError ? 0.5 : 1)
            }
            if !balanceOnly, let balance {
                HStack {
                    Text("余额").font(.footnote).foregroundStyle(.ink2)
                    Spacer()
                    Text(verbatim: balance).font(.system(size: 17, weight: .medium, design: .serif).monospacedDigit())
                        .foregroundStyle(.ink)
                }
            }
            if let error = card.error?.trimmed, !error.isEmpty, !card.loginExpired {
                Label {
                    Text("读不到：\(error)")
                        .font(.footnote)
                        .lineLimit(2)
                        .foregroundStyle(.ink2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.warn)
                }
            }
            if let staleSince {
                StaleFooter(since: staleSince, now: now) { retryCard() }
                    .highPriorityGesture(TapGesture().onEnded { retryCard() })
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(card.off || card.loginExpired ? 0.55 : 1)
        .perchCard()
        .contentShape(.rect(cornerRadius: 22))
        .scaleEffect(pressed ? 0.98 : 1)
        .animation(Motion.settle, value: pressed)
    }

    /// 5 小时, 每周, then model windows (magpie's order otherwise).
    private var windows: [QuotaWindow] { QuotaCard.ordered(card.windows) }

    private var columns: [GridItem] {
        if typeSize.isAccessibilitySize { return [GridItem(.flexible(), alignment: .leading)] }
        return switch card.windows.count {
        case 1: [GridItem(.flexible())]
        case 2: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), alignment: .top)]
        default: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)
        }
    }

    /// The footer's tap: read this card again (no 30 s wait; it failed).
    private func retryCard() {
        Task { await store.refresh(card, client: connection.quotaClient(), force: true) }
    }

    /// Asks magpie to re-read this card, unless it was refreshed moments ago.
    private func refresh() {
        if let left = store.cooldownLeft(card) {
            toast = String(localized: "刚刷新过，\(left.text) 秒后再试")
            return
        }
        Task { await store.refresh(card, client: connection.quotaClient()) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Monogram(text: card.name.isEmpty ? card.provider : card.name, claude: SubscriptionAccounts.isClaude(card))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: card.title)
                    .font(.headline)
                    .foregroundStyle(.ink)
                    .lineLimit(ax ? nil : 1)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: ax)
                if !card.subtitle.isEmpty {
                    Text(verbatim: card.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.ink2)
                        .lineLimit(ax ? nil : 1)
                        .fixedSize(horizontal: false, vertical: ax)
                }
                if ax { chip }
            }
            Spacer(minLength: 4)
            if store.refreshing.contains(card.id) {
                ProgressView().controlSize(.small)
            }
            if !ax { chip }
            if balanceOnly, let balance {
                Text(verbatim: balance)
                    .font(.system(size: 20, weight: .medium, design: .serif).monospacedDigit())
                    .foregroundStyle(.ink)
                    .lineLimit(1)
            }
            if opens {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.ink2.opacity(0.6))
                    .accessibilityHidden(true)
            }
        }
    }

    private var ax: Bool { typeSize.isAccessibilitySize }

    @ViewBuilder
    private var chip: some View {
        if card.loginExpired {
            LoginExpiredChip()
        } else if card.off {
            OffChip()
        } else if justUsed {
            JustUsedCapsule()
        }
    }

    /// 「工作号，Claude Max，正在用。5 小时剩 38%，3 小时后重置；7 天剩 59%，周四 08:00 重置」
    private var spoken: String {
        var head = [card.title]
        if !card.subtitle.isEmpty { head.append(card.subtitle.replacingOccurrences(of: " · ", with: " ")) }
        if card.loginExpired { head.append(String(localized: "登录已失效")) } else if card.off { head.append(String(localized: "已停用")) } else if justUsed { head.append(String(localized: "刚刚在用")) }
        var parts: [String] = windows.map { window in
            let label = WindowCell.label(window)
            let value = [QuotaFormat.left(window), QuotaFormat.resets(window.resetsAt, now: now)].compactMap { $0 }
            return ([label + (value.first ?? "")] + value.dropFirst()).joined(separator: "，")
        }
        if let balance { parts.append(String(localized: "余额") + " " + balance) }
        if let error = card.error?.trimmed, !error.isEmpty, !card.loginExpired { parts.append(String(localized: "读不到：\(error)")) }
        var text = head.joined(separator: "，") + "。" + parts.joined(separator: "；")
        if let runOut { text += "。" + runOut.text(now: now) }
        if let staleSince { text += "。" + FreshnessText.cardFooter(staleSince, now: now) }
        return text
    }
}

/// One quota window: name, 「剩 x%」, bar and reset time.
struct WindowCell: View {
    let window: QuotaWindow
    let now: Date
    /// 3+ windows: label, 「剩 21%」, bar and reset stacked.
    var stacked = false
    /// 1.4: the line under the reset time when this window runs out first.
    var runOut: RunOut? = nil

    /// 5 小时 / 每周 / Opus 每周; a window Perch doesn't know
    /// keeps magpie's name.
    static func label(_ window: QuotaWindow) -> String {
        switch WindowKind.classify(window) {
        case .fiveHour: return String(localized: "5 小时")
        case .weekly: return String(localized: "每周")
        case .modelWeekly(let model): return String(localized: "\(model) 每周")
        case .other:
            let base = QuotaFormat.windowLabel(window.name)
            if let lane = window.lane?.trimmed, !lane.isEmpty { return "\(base) · \(lane)" }
            return base
        }
    }

    private var used: Double? { QuotaFormat.used(window) }
    @ScaledMetric(relativeTo: .title2) private var valueSize: CGFloat = 22
    @ScaledMetric(relativeTo: .footnote) private var smallSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: Self.label(window))
                .font(.footnote)
                .foregroundStyle(.ink2)
                .lineLimit(1)
            value
            if let used { QuotaBar(used: used) }
            if let reset = QuotaFormat.resets(window.resetsAt, now: now) {
                Text(verbatim: reset)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            if let runOut { RunOutLine(runOut: runOut, now: now) }
        }
    }

    /// 「剩 38%」: 剩 13 ink2, the number serif 22 medium, 「%」 smaller.
    @ViewBuilder
    private var value: some View {
        let tone = used.map { BarTone.of(used: $0) } ?? .ink
        if let left = QuotaFormat.remaining(window), left.rounded() > 0 {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("剩").font(.system(size: smallSize)).foregroundStyle(.ink2)
                Text(verbatim: "\(Int(left.rounded()))")
                    .font(.system(size: valueSize, weight: .medium, design: .serif).monospacedDigit())
                    .contentTransition(.numericText(value: left))
                Text(verbatim: "%").font(.system(size: (valueSize * 15 / 22).rounded(), weight: .medium, design: .serif))
            }
            .foregroundStyle(tone.numberColor)
            .fixedSize()
            .animation(Motion.calm, value: left)
        } else if let text = QuotaFormat.left(window) {
            Text(verbatim: text)
                .font(.system(size: (valueSize * 20 / 22).rounded(), weight: .medium, design: .serif).monospacedDigit())
                .foregroundStyle(QuotaFormat.remaining(window) != nil ? tone.numberColor : .ink)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
    }
}

/// 6 pt, radius 3, ink / warn / bad by used; grows from the leading edge
/// on first appear (0.9 s), then animates to new values.
struct QuotaBar: View {
    let used: Double

    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.fromCache) private var fromCache
    @State private var grown = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.track)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(BarTone.of(used: used).color)
                    .frame(width: geo.size.width * min(max(used, 0), 100) / 100)
                    .scaleEffect(x: grown ? 1 : 0, anchor: .leading)
            }
        }
        .frame(height: 6)
        .animation(Motion.calm(reduce), value: used)
        .onAppear {
            guard !grown else { return }
            if fromCache { grown = true; return }
            if let grow = Motion.grow(reduce) { withAnimation(grow) { grown = true } } else { grown = true }
        }
        .accessibilityHidden(true)
    }
}

/// 「● 刚刚在用」: good, a breathing 6 pt dot.
struct JustUsedCapsule: View {
    var body: some View {
        HStack(spacing: 5) {
            BreathingDot(color: .good)
            Text("刚刚在用")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.good)
        .fixedSize()
        .accessibilityIdentifier("just-used")
    }
}

/// 1.4 「照现在的速度，大约 15:40 用完」: hourglass + 12 pt, orange when
/// it is an hour or less away.
struct RunOutLine: View {
    let runOut: RunOut
    let now: Date

    var body: some View {
        Label {
            Text(verbatim: runOut.text(now: now))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "hourglass")
        }
        .labelStyle(TightLabelStyle())
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(runOut.urgent(now: now) ? Color.warn : Color.ink2)
        .accessibilityIdentifier("run-out")
    }
}

/// Icon and title 3 pt apart, on the text baseline.
struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

/// 1.4 「登录已失效」: red on 14% red.
struct LoginExpiredChip: View {
    var body: some View {
        Chip(text: "登录已失效", color: .bad)
            .accessibilityIdentifier("login-expired")
    }
}

/// 「已停用」: secondary on fill3.
struct OffChip: View {
    var body: some View {
        Chip(text: "已停用", color: .ink2, fill: .track)
            .accessibilityIdentifier("account-off")
    }
}

/// A provider's letters in a circle.
struct Monogram: View {
    let text: String
    /// Claude's tinted 「C」: the only non-accent hue, and only here.
    var claude = false

    static let claudeFill = Color(uiColor: UIColor { t in
        UIColor(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: t.userInterfaceStyle == .dark ? 0.24 : 0.16)
    })
    static let claudeInk = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0xE8 / 255, green: 0x95 / 255, blue: 0x7A / 255, alpha: 1)
            : UIColor(red: 0xB4 / 255, green: 0x53 / 255, blue: 0x2F / 255, alpha: 1)
    })

    private var letters: String {
        let t = text.trimmed
        if t.count <= 3, t.allSatisfy({ $0.isASCII && $0.isUppercase }) { return t }
        return t.first.map { String($0).uppercased() } ?? "?"
    }

    /// 32 pt, no fill, 1 pt ink ring, serif 15 semibold.
    var body: some View {
        Text(verbatim: claude ? "C" : letters)
            .font(.system(size: letters.count > 1 && !claude ? 11 : 15, weight: .semibold, design: .serif))
            .foregroundStyle(.ink)
            .frame(width: 32, height: 32)
            .overlay(Circle().strokeBorder(Color.ink, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// Pushes Account detail (額度 and the Agent tab's 按账号).
struct AccountRoute: Hashable {
    var id: String
    /// The zoom transition's source: 「hero」 or 「card-<id>」.
    var source: String = ""

    /// The source defaults to the card itself.
    init(id: String, source: String? = nil) {
        self.id = id
        self.source = source ?? "card-" + id
    }
}

extension QuotaCard {
    /// 5 小时, 每周, model windows, then the rest; ties keep magpie's order.
    static func ordered(_ windows: [QuotaWindow]) -> [QuotaWindow] {
        windows.enumerated()
            .sorted { (WindowKind.classify($0.element).rank, $0.offset) < (WindowKind.classify($1.element).rank, $1.offset) }
            .map(\.element)
    }
}

extension QuotaCard {
    static let placeholder = QuotaCard(
        provider: "claude", name: "Claude", kind: "subscription", plan: "Max",
        user: "someone@example.com", alias: nil, seat: nil, from: nil,
        windows: [
            QuotaWindow(name: "5h", used: 40, remaining: 60, resetsAt: nil, display: nil, unlimited: false, text: false, lane: nil),
            QuotaWindow(name: "7d", used: 20, remaining: 80, resetsAt: nil, display: nil, unlimited: false, text: false, lane: nil),
        ],
        balance: nil, error: nil, asOf: nil, readAt: nil, last: false
    )
}
