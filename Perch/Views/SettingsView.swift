import SwiftUI

/// The 设置 tab: computers, magpie version and about.
struct SettingsView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(QuotasStore.self) private var quotas
    @Environment(RoutingStore.self) private var routing
    @Environment(VersionStore.self) private var versions
    @Environment(\.addComputer) private var addComputer

    @State private var confirmingDisconnect = false
    @State private var changingKey = false
    @State private var removing: Computer?

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                computersSection

                Section {
                    LabeledContent("密钥") {
                        HStack(spacing: 12) {
                            Text(verbatim: connection.maskedKey ?? "")
                                .font(.subheadline.monospaced())
                                .lineLimit(1)
                                .accessibilityIdentifier("settings-key")
                            changeKey
                        }
                    }

                    LabeledContent("这把密钥能") {
                        HStack(spacing: 6) {
                            PermissionCapsule(title: String(localized: "看额度"), granted: quotas.canRead,
                                              help: QuotaError.forbidden.message)
                                .accessibilityIdentifier("permission-quotas")
                            PermissionCapsule(title: String(localized: "改路由组"), granted: routing.canChange,
                                              help: RoutingError.notAdmin.message)
                                .accessibilityIdentifier("permission-routing")
                        }
                    }

                    Button("断开连接", role: .destructive) {
                        confirmingDisconnect = true
                    }
                    .accessibilityIdentifier("settings-disconnect")
                    .confirmationDialog("断开后需要重新填密钥。", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
                        Button("断开", role: .destructive) { connection.disconnect() }
                        Button("取消", role: .cancel) {}
                    }
                } header: {
                    Text(verbatim: connection.computerName ?? "")
                        .accessibilityIdentifier("settings-current-header")
                }

                Section {
                    // 1.5 关于: the icon, Perch and the one-liner.
                    VStack(spacing: 8) {
                        Image("launchIcon")
                            .resizable()
                            .frame(width: 60, height: 60)
                            .clipShape(.rect(cornerRadius: 14, style: .continuous))
                            .accessibilityHidden(true)
                        Text(verbatim: "Perch")
                            .font(.system(size: 20, weight: .semibold, design: .serif))
                            .foregroundStyle(.ink)
                        Text("额度一眼看清，模型随手调。")
                            .font(.footnote)
                            .foregroundStyle(.ink2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("about-header")
                }

                Section {
                    Text("版本 \(version)")
                    magpieVersionRow
                    Link(destination: URL(string: "https://github.com/yetone/magpie")!) {
                        HStack {
                            Text("magpie 项目主页")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("关于")
                } footer: {
                    Text("Perch 是 magpie 的手机遥控器，和 magpie 官方无关。")
                }

                Section {
                    MadeWithAirBuild()
                }
            }
            .perchScreen()
            .navigationTitle("设置")
            .navigationDestination(isPresented: $changingKey) { ConnectView() }
            .navigationDestination(for: ReleaseNotesRoute.self) { _ in ReleaseNotesView() }
            .alert(Text("删掉 \(removing?.name ?? "")？"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                   presenting: removing) { c in
                Button("删除", role: .destructive) { connection.remove(c.id) }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text("这台电脑的密钥会从手机里一起删掉。")
            }
        }
        .task(id: connection.currentID) {
            await versions.refresh(client: connection.magpieClient(), computerID: connection.currentID)
        }
        .task(id: connection.currentID) {
            // The permission capsules need both answers; 额度 is read at launch,
            // 路由组 only once its tab opened.
            if routing.phase == .idle { await routing.load(connection.routingClient()) }
            if quotas.phase == .idle { await quotas.load(connection.quotaClient()) }
        }
    }

    /// 1.4 「电脑」: every saved magpie; tap to switch, swipe to delete.
    private var computersSection: some View {
        Section {
            ForEach(connection.computers) { c in
                let current = c.id == connection.currentID
                Button {
                    connection.select(c.id)
                } label: {
                    ComputerRow(computer: c, current: current, status: status(of: c, current: current))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(current ? "settings-status" : "computer-row-\(c.name)")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("删除", role: .destructive) { removing = c }
                }
            }
        } header: {
            HStack {
                Text("电脑")
                Spacer()
                Button("添加") { addComputer() }
                    .font(.subheadline.weight(.medium))
                    .textCase(nil)
                    .accessibilityIdentifier("settings-add-computer")
            }
        } footer: {
            Text("密钥只存在这台手机的钥匙串里。")
        }
    }

    /// The computer's status line.
    private func status(of c: Computer, current: Bool) -> String {
        ComputerStatusText.menu(connection.status(of: c), current: current, offline: quotas.isOffline || routing.isOffline)
    }

    /// 「magpie 版本」 0.1.4211, 「有新版本 0.1.4283」 (→ 改了什么), 「已是最新」,
    /// or 「—」 when magpie doesn't say.
    @ViewBuilder
    private var magpieVersionRow: some View {
        let value = versions.current?.description ?? "—"
        if let newer = versions.newer {
            NavigationLink(value: ReleaseNotesRoute()) {
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: value).monospacedDigit()
                        Text("有新版本 \(newer.version?.description ?? newer.tag)")
                            .font(.system(size: 12))
                            .foregroundStyle(.tint)
                    }
                } label: {
                    Text("magpie 版本")
                }
            }
            .accessibilityIdentifier("settings-magpie-version")
        } else {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: value).monospacedDigit()
                    if versions.upToDate {
                        Text("已是最新").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            } label: {
                Text("magpie 版本")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings-magpie-version")
        }
    }

    private var changeKey: some View {
        // A Button, not a NavigationLink: no trailing chevron, just 「更换」.
        Button("更换") { changingKey = true }
            .buttonStyle(.borderless)
            .fixedSize()
    }
}

/// 「✓ 看额度」 when the 密钥 has it; 「改路由组 · 未打开」 (orange) when it
/// doesn't, which explains where to turn it on; plain while unknown.
private struct PermissionCapsule: View {
    let title: String
    let granted: Bool?
    let help: String

    @State private var explaining = false

    var body: some View {
        switch granted {
        case true?:
            capsule(Text(verbatim: "✓ \(title)"), color: .green)
        case false?:
            Button {
                explaining = true
            } label: {
                capsule(Text("\(title) · 未打开"), color: .orange)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $explaining) {
                Text(verbatim: help)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(idealWidth: 280)
                    .padding()
                    .presentationCompactAdaptation(.popover)
            }
        case nil:
            capsule(Text(verbatim: title), color: .secondary)
        }
    }

    /// A small tinted label.
    private func capsule(_ text: Text, color: Color) -> some View {
        text
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(color.opacity(0.14), in: .capsule)
    }
}
