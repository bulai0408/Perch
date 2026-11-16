import SwiftUI

/// Connect until a 地址 and 密钥 are saved, then the three tabs.
struct RootView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(QuotasStore.self) private var quotas
    @Environment(RoutingStore.self) private var routing
    @Environment(UsageStore.self) private var usage
    @Environment(\.accessibilityReduceMotion) private var reduce

    /// One sky for the whole app.
    private var mood: SkyMood {
        SkyMood(health: QuotaHealth.of(quotas.cards) { quotas.runOut($0) },
                offline: connection.isConnected && quotas.isOffline,
                breath: quotas.breath)
    }

    var body: some View {
        Group {
            if connection.isConnected {
                MainTabs()
                    .transition(reduce ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            } else {
                NavigationStack {
                    ConnectView()
                }
                .transition(reduce ? .opacity : .offset(y: -40).combined(with: .opacity))
            }
        }
        .environment(\.skyMood, mood)
        .overlay { LaunchCover() }
        .animation(Motion.calm(reduce), value: connection.isConnected)
        .onChange(of: connection.isConnected) { _, connected in
            if !connected {
                quotas.reset()
                routing.reset()
                usage.reset()
            }
        }
    }
}

/// The four tabs: 额度, Agent, 路由组, 设置.
struct MainTabs: View {
    /// The tabs, for selection.
    enum TabID: Hashable { case quotas, agent, routing, settings }

    @Environment(ConnectionStore.self) private var connection
    @Environment(QuotasStore.self) private var quotas
    @Environment(RoutingStore.self) private var routing
    @Environment(UsageStore.self) private var usage

    @State private var selection: TabID = .quotas
    @State private var addingComputer = false

    var body: some View {
        TabView(selection: $selection) {
            Tab("额度", systemImage: "gauge.with.dots.needle.67percent", value: TabID.quotas) {
                QuotasView()
            }
            Tab("Agent", systemImage: "apple.terminal", value: TabID.agent) {
                AgentView()
            }
            Tab("路由组", systemImage: "arrow.triangle.branch", value: TabID.routing) {
                RoutingGroupsView()
            }
            Tab("设置", systemImage: "gearshape", value: TabID.settings) {
                SettingsView()
            }
        }
        .environment(\.openSettings, OpenSettingsAction { selection = .settings })
        .environment(\.openAgentTab, OpenSettingsAction { selection = .agent })
        .environment(\.addComputer, OpenSettingsAction { addingComputer = true })
        .sheet(isPresented: $addingComputer) {
            NavigationStack {
                ConnectView(adding: true)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { addingComputer = false }
                        }
                    }
            }
        }
        // 换一台电脑: every tab reads the new computer from scratch.
        .onChange(of: connection.currentID) { _, _ in
            quotas.reset()
            routing.reset()
            usage.reset()
        }
        .toast(Binding(get: { connection.toast }, set: { connection.toast = $0 }))
    }
}

/// The first frame: the launch screen's icon on paper,
/// scaling to 0.9 and fading over 0.35 s as the app comes in.
private struct LaunchCover: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var gone = false
    @State private var removed = false

    var body: some View {
        if !removed {
            ZStack {
                Color.paper
                Image("launchIcon")
                    .resizable()
                    .frame(width: 132, height: 132)
                    .scaleEffect(gone && !reduce ? 0.9 : 1)
            }
            .ignoresSafeArea()
            .opacity(gone ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                withAnimation(.easeOut(duration: 0.35)) { gone = true }
                try? await Task.sleep(for: .milliseconds(400))
                removed = true
            }
        }
    }
}

/// The status capsule's tap: switch to the 设置 tab.
struct OpenSettingsAction {
    var action: () -> Void = {}
    func callAsFunction() { action() }
}

extension EnvironmentValues {
    @Entry var openSettings = OpenSettingsAction()
    /// 「在 Agent 页看」: switch to the Agent tab.
    @Entry var openAgentTab = OpenSettingsAction()
    /// 1.4 「添加电脑…」: the 添加电脑 sheet.
    @Entry var addComputer = OpenSettingsAction()
}

/// The trailing toolbar capsule on every tab: a dot
/// and the computer's name, 「· 2 分钟前」 on 额度, 「· 连不上」 when
/// magpie can't be reached. 1.4: tapping it opens 「换一台电脑」.
struct StatusCapsule: View {
    let computer: String
    /// 「2 分钟前」 on 额度; nil on 路由组.
    var ago: String?
    let offline: Bool

    @Environment(ConnectionStore.self) private var connection
    @Environment(\.addComputer) private var addComputer

    private var text: String {
        if offline { return String(localized: "\(computer) · 连不上") }
        if let ago { return "\(computer) · \(ago)" }
        return computer
    }

    var body: some View {
        Menu {
            Section("换一台电脑") {
                ForEach(connection.computers) { c in
                    Button {
                        connection.select(c.id)
                    } label: {
                        if c.id == connection.currentID {
                            Label(c.name, systemImage: "checkmark")
                        } else {
                            Text(verbatim: c.name)
                        }
                        Text(verbatim: ComputerStatusText.menu(connection.status(of: c), current: c.id == connection.currentID, offline: offline))
                    }
                    .accessibilityIdentifier("computer-menu-\(c.name)")
                }
            }
            Divider()
            Button {
                addComputer()
            } label: {
                Label("添加电脑…", systemImage: "plus")
            }
            .accessibilityIdentifier("add-computer-menu")
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(offline ? Color.warn : Color.good)
                    .frame(width: 7, height: 7)
                Text(verbatim: text)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.ink)
                    .contentTransition(.numericText())
                    .animation(Motion.calm, value: text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .frame(maxWidth: 220)
            .background(Color.card, in: .capsule)
            .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 0.5))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("连接状态，轻点换一台电脑"))
        .accessibilityValue(Text(verbatim: text))
        .accessibilityIdentifier("status-capsule")
    }
}

/// 「● 已连接」 / 「● 连不上」 / 「上次连上：2 小时前」.
enum ComputerStatusText {
    /// The status line; the current computer follows the latest read.
    static func menu(_ status: ComputerStatus, current: Bool = false, offline: Bool = false, now: Date = .now) -> String {
        if current { return offline ? String(localized: "● 连不上") : String(localized: "● 已连接") }
        switch status {
        case .connected: return String(localized: "● 已连接")
        case .unreachable: return String(localized: "● 连不上")
        // Never reached yet: say nothing rather than guess.
        case .unknown: return ""
        case .lastSeen(let date): return String(localized: "上次连上：\(QuotaFormat.ago(date, now: now))")
        }
    }
}

extension ToolbarContent {
    /// iOS 26 puts toolbar items on glass; the capsule draws its own.
    func plainBackground() -> some ToolbarContent {
        sharedBackgroundVisibility(.hidden)
    }
}

/// A short message in a glass capsule above the tab bar.
struct ToastModifier: ViewModifier {
    @Binding var message: String?
    var seconds: Double = 2.5

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityIdentifier("toast")
                        .task(id: message) {
                            AccessibilityNotification.Announcement(message).post()
                            try? await Task.sleep(for: .seconds(Self.hold(seconds)))
                            withAnimation { self.message = nil }
                        }
                }
            }
            .animation(.spring(duration: 0.3), value: message)
    }

    /// UI tests (Debug only) pass `-perch-long-toasts` so a toast outlives
    /// XCUITest's idle wait after a menu tap.
    private static func hold(_ seconds: Double) -> Double {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-perch-long-toasts") { return 8 }
        #endif
        return seconds
    }
}

extension View {
    /// Shows `message` as a toast for `seconds`, then clears it.
    func toast(_ message: Binding<String?>, seconds: Double = 2.5) -> some View {
        modifier(ToastModifier(message: message, seconds: seconds))
    }
}
