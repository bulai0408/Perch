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
    @State private var showsAdminHelp = false

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
                    if let quotaError { errorCard(quotaError) }
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

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("在电脑的 magpie 里打开「设置 → 网络与共享 → 在局域网共享」，再新建一把密钥，打开「可看额度」。")
                .font(.subheadline)
                .foregroundStyle(.ink)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(isExpanded: $showsAdminHelp) {
                Text("在这把密钥那一行的菜单 → 高级 → 管理 API，选「任何电脑均可」。")
                    .font(.footnote)
                    .foregroundStyle(.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } label: {
                // PingFang so 「？」 is the full-width glyph (SF draws U+FF1F narrow).
                Text("想在手机上改路由组？")
                    .font(.custom("PingFangSC-Regular", size: 15, relativeTo: .subheadline))
            }
            .tint(.accentColor)
        }
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
        AccessibilityNotification.Announcement(error.message).post()
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
