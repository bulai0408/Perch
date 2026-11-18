import SwiftUI

/// 连接 magpie: 地址 + 密钥. First launch shows it as the root; Settings
/// pushes it to change what's saved. 1.4 「添加电脑」 reuses it with a
/// 名字 field and the 「添加」 button. 1.5 晨栖 layout.
struct ConnectView: View {
    /// 添加电脑: a new computer instead of the selected one.
    var adding = false

    @Environment(ConnectionStore.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme

    @State private var nameText = ""
    @State private var addressText = ""
    @State private var keyText = ""
    @State private var replacingKey = false

    @State private var busy = false
    @State private var quotaError: QuotaError?
    @State private var quotaOK = false
    /// Connected, but the key can't change routing groups yet.
    @State private var adminNote = false
    @State private var successes = 0
    @State private var failures = 0
    @State private var shakes: CGFloat = 0
    @State private var didPrefill = false
    @State private var artIn = false

    /// The text fields, for focus.
    @FocusState private var focus: Field?
    enum Field: Hashable { case name, address, key }

    private var editing: Bool { connection.isConnected && !adding }
    private var showsSavedKey: Bool { editing && !replacingKey && connection.maskedKey != nil }
    /// First run and 添加电脑 open on the art; editing from 设置 doesn't.
    private var showsArt: Bool { !editing }

    private var canConnect: Bool {
        !busy && !addressText.trimmed.isEmpty && (showsSavedKey || !keyText.trimmed.isEmpty)
    }

    private var title: LocalizedStringKey { adding ? "添加电脑" : "连接 magpie" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if showsArt { art }
                VStack(alignment: .leading, spacing: 16) {
                    if showsArt { heading }
                    intro
                    fields
                        .modifier(Shake(amount: reduce ? 0 : 6, shakes: shakes))
                    if let quotaError, !showsChecks { errorCard(quotaError) }
                    if quotaOK, adminNote {
                        Text("已连上，可以看额度。要改路由组，再给这把密钥打开管理 API。")
                            .font(.footnote)
                            .foregroundStyle(.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("quota-note")
                    }
                    connectButton
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, showsArt ? -8 : 12)
                .padding(.bottom, 32)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .perchScreen(sky: !showsArt)
        .background(Color.paper.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(showsArt && !adding ? .hidden : .automatic, for: .navigationBar)
        .disabled(busy)
        .sensoryFeedback(Haptic.connected, trigger: successes)
        .sensoryFeedback(Haptic.failed, trigger: failures)
        .onAppear {
            prefill()
            if reduce { artIn = true } else { withAnimation(.easeOut(duration: 1.4)) { artIn = true } }
        }
    }

    // MARK: Art + title

    /// Top 250 pt, full-bleed, bottom 30 % faded into paper; drifts in
    /// from 1.08; lifts 40 pt and fades on success.
    @ViewBuilder private var artImage: some View {
        if scheme == .dark {
            // Dark: a 22 pt light-paper card with margins, never full-bleed.
            Image("art-connect")
                .resizable()
                .scaledToFill()
                .frame(height: 210)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
                .padding(6)
                .background(Color.artPaper, in: .rect(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 20)
        } else {
            Image("art-connect")
                .resizable()
                .scaledToFill()
                .frame(height: 250)
                .frame(maxWidth: .infinity)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea(edges: .top)
        }
    }

    private var art: some View {
        artImage
            .scaleEffect(artIn || reduce ? 1 : 1.08)
            .opacity(artIn && !(quotaOK && !adminNote) ? 1 : 0)
            .offset(y: quotaOK && !adminNote && !reduce ? -40 : 0)
            .animation(Motion.calm(reduce), value: quotaOK)
            .accessibilityHidden(true)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.largeTitle, design: .serif, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("connect-title")
            if !adding {
                Text("magpie 的手机遥控器")
                    .font(.system(size: 17, design: .serif))
                    .foregroundStyle(.ink2)
            }
        }
    }

    /// 「在电脑上开好 magpie」: five numbered steps, then the optional
    /// routing-group line one size down (guide v2).
    private static let steps: [LocalizedStringKey] = [
        "在电脑上打开 magpie，点左边的「网关」。",
        "在「局域网共享」那一行，点「局域网」。",
        "在「网关密钥」右边点「添加网关密钥」，名字随便填（比如 手机），「自定义密钥（可选）」空着，点「创建」。",
        "在「网关」页复制标着「局域网」的那条地址，粘到下面的「地址」里。不要用标着「本机」的那条。",
        "点这把密钥那一行的复制按钮，粘到下面的「密钥」里。别的都不用改。",
    ]

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("在电脑上开好 magpie")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.ink)
                .accessibilityAddTraits(.isHeader)
            ForEach(Self.steps.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(index + 1, format: .number)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.tint)
                        .frame(minWidth: 14, alignment: .leading)
                        .accessibilityHidden(true)
                    Text(Self.steps[index])
                        .font(.subheadline)
                        .foregroundStyle(.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("guide-step-\(index + 1)")
            }
            Text("想在手机上改路由组：在这把密钥那一行点 ⋯ →「高级」→「管理 API」，选「任何电脑均可」。")
                .font(.footnote)
                .foregroundStyle(.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
                .accessibilityIdentifier("guide-routing")
        }
    }

    /// Under 地址 when an address was entered but Perch couldn't reach it (guide v2).
    private static let checks: [LocalizedStringKey] = [
        "手机和电脑在同一个 Wi-Fi 上",
        "magpie 的「网关」页里，「局域网共享」选的是「局域网」",
        "地址用的是标着「局域网」的那条",
        "电脑的防火墙没拦住 magpie",
    ]

    /// The same list for a Tailscale address (100.64/10, *.ts.net, a bare name, fd7a:115c:a1e0::/48).
    private static let tailscaleChecks: [LocalizedStringKey] = [
        "手机和电脑都开着 Tailscale，登的是同一个账号",
        "电脑上的 Tailscale 允许别的设备连进来",
        "magpie 的「网关」页里，「局域网共享」选的是「局域网」",
        "电脑的防火墙对 Tailscale 也放行了 magpie",
    ]

    private var shownChecks: [LocalizedStringKey] {
        let host = MagpieAddress.normalize(addressText)?.host(percentEncoded: false)
        return host.map(MagpieAddress.isTailscale(host:)) == true ? Self.tailscaleChecks : Self.checks
    }

    private var showsChecks: Bool {
        !addressText.trimmed.isEmpty && (quotaError == .unreachable || quotaError == .timeout)
    }

    private var checksList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("连不上这台电脑。看看：")
                .foregroundStyle(.ink)
            let checks = shownChecks
            ForEach(checks.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "•").accessibilityHidden(true)
                    Text(checks[index]).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.ink2)
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 54)
        .padding(.bottom, 12)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("address-checks")
    }

    // MARK: 地址 + 密钥

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                if adding {
                    FieldRow(label: "名字") {
                        TextField("名字", text: $nameText, prompt: Text("比如 家里、公司"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { focus = .address }
                            .accessibilityIdentifier("name-field")
                    }
                    Divider().overlay(Color.hairline).padding(.leading, 70)
                }
                FieldRow(label: "地址") {
                    TextField("地址", text: $addressText, prompt: Text(verbatim: "http://192.168.1.20:3425"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .address)
                        .submitLabel(.next)
                        .onSubmit { focus = showsSavedKey ? nil : .key }
                        .accessibilityIdentifier("address-field")
                }
                if showsChecks { checksList }
                Divider().overlay(Color.hairline).padding(.leading, 70)
                FieldRow(label: "密钥") {
                    if showsSavedKey, let masked = connection.maskedKey {
                        HStack {
                            Text(verbatim: masked)
                                .font(.body.monospaced())
                                .foregroundStyle(.ink2)
                                .lineLimit(1)
                                .accessibilityIdentifier("saved-key")
                            Spacer()
                            Button("更换") {
                                replacingKey = true
                                focus = .key
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("replace-key")
                        }
                    } else {
                        HStack {
                            SecureField("密钥", text: $keyText, prompt: Text(verbatim: "sk-magpie-…"))
                                .textContentType(.password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .key)
                                .submitLabel(.go)
                                .onSubmit { submit() }
                                .accessibilityIdentifier("key-field")
                            PasteButton(payloadType: String.self) { strings in
                                if let first = strings.first { keyText = first.trimmed }
                            }
                            .labelStyle(.iconOnly)
                            .buttonBorderShape(.circle)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .perchCard()
            Text("密钥只存在这台手机的钥匙串里。")
                .font(.footnote)
                .foregroundStyle(.ink2)
                .padding(.horizontal, 4)
        }
    }

    /// The error illustration 64 pt left of the line; 本地网络 adds 去设置.
    private func errorCard(_ error: QuotaError) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ArtImage(name: "art-error", size: 64, radius: 14)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: error.message)
                    .font(.subheadline)
                    .foregroundStyle(.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if error == .localNetworkDenied {
                    Button("去设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .perchCard()
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("quota-error")
    }

    // MARK: 连接

    /// Ink, 54 pt. Connecting: only a 2 pt accent sweep along the bottom
    /// edge; VoiceOver hears 「正在连接」.
    private var connectButton: some View {
        Button {
            Task { await connect() }
        } label: {
            Text(adding ? "添加" : "连接")
                .opacity(busy ? 0 : 1)
                .animation(Motion.fade, value: busy)
        }
        .buttonStyle(InkButtonStyle())
        .overlay(alignment: .bottom) {
            if busy { ButtonSweep().padding(.horizontal, 12).padding(.bottom, 1) }
        }
        .disabled(!canConnect)
        .accessibilityLabel(busy ? Text("正在连接") : Text(adding ? "添加" : "连接"))
        .accessibilityIdentifier("connect-button")
    }

    /// Return on the last field connects when it can; otherwise it just closes the keyboard.
    private func submit() {
        if canConnect && !busy {
            Task { await connect() }
        } else {
            focus = nil
        }
    }

    /// Fills the address field once from the saved connection (not when adding).
    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        if !adding, let address = connection.address {
            addressText = address.absoluteString
        }
    }

    /// Validates the fields, checks the key against magpie, then saves the
    /// connection or shows why it failed.
    private func connect() async {
        focus = nil
        busy = true
        quotaError = nil
        quotaOK = false
        adminNote = false
        defer { busy = false }

        guard let address = MagpieAddress.normalize(addressText) else {
            fail(.unreachable)
            return
        }
        let key = showsSavedKey ? (connection.gatewayKey() ?? "") : keyText.trimmed
        guard !key.isEmpty else {
            fail(.unauthorized)
            return
        }

        #if DEBUG
        let isDemo = DemoData.isOn
        #else
        let isDemo = false
        #endif
        if isDemo {
            #if DEBUG
            // Demo recordings: the demo key connects, any other key is refused.
            try? await Task.sleep(for: .milliseconds(700))
            guard key == DemoData.connectKey else {
                fail(.unauthorized)
                return
            }
            #endif
            withAnimation { quotaOK = true }
        } else {
            do {
                _ = try await QuotaClient(base: address, key: key).cards()
            } catch {
                fail(error)
                return
            }
            withAnimation { quotaOK = true }
        }

        // Routing groups need 管理 API 「任何电脑均可」. Without it Perch still
        // connects (额度 works) and says so; other answers don't block either.
        if !isDemo {
            do {
                _ = try await RoutingClient(base: address, key: key).groups()
            } catch {
                if error == .notAdmin { withAnimation { adminNote = true } }
            }
        }
        AccessibilityNotification.Announcement(adminNote
            ? String(localized: "已连上，可以看额度。要改路由组，再给这把密钥打开管理 API。")
            : String(localized: "已连上 magpie")).post()

        successes += 1
        try? await Task.sleep(for: adminNote ? .seconds(2.5) : .milliseconds(600))
        if adding {
            let computer = connection.add(name: nameText, address: address, key: key)
            connection.toast = String(localized: "已换到 \(computer.name)")
            dismiss()
            return
        }
        connection.saveQuotaConnection(address: address, key: key)
        if editing { dismiss() }
    }

    /// Shows a connect failure: shake, VoiceOver announcement, focus on the key
    /// when it was refused.
    private func fail(_ error: QuotaError) {
        withAnimation(Motion.calm(reduce)) { quotaError = error }
        failures += 1
        if !reduce { withAnimation(.linear(duration: 0.4)) { shakes += 1 } }
        AccessibilityNotification.Announcement(showsChecks ? String(localized: "连不上这台电脑。看看：") : error.message).post()
        focus = error == .unauthorized && !showsSavedKey ? .key : nil
    }
}

/// Three horizontal shakes, ±amount, as `shakes` goes up by one.
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: amount * sin(shakes * .pi * 6), y: 0))
    }
}

/// The 2 pt accent segment sweeping along the connect button.
private struct ButtonSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var x: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            Capsule()
                .fill(Color.accentColor)
                .frame(width: g.size.width * 0.3, height: 2)
                .offset(x: reduce ? g.size.width * 0.35 : x * g.size.width * 0.7)
                .opacity(reduce ? 0.6 : 1)
        }
        .frame(height: 2)
        .onAppear {
            guard !reduce else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { x = 1 }
        }
        .accessibilityHidden(true)
    }
}

/// A 44 pt ink2 label and the field, 52 pt tall.
private struct FieldRow<Field: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let field: Field

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.ink2)
                .frame(width: 44, alignment: .leading)
            field
        }
        .frame(minHeight: 52)
    }
}

/// One line of the connect screen's help.
struct HelpRow: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.tint)
        }
    }
}
