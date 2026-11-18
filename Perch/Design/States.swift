import SwiftUI

// MARK: - Art

/// The delivered artwork sits on paper, so it is shown as a paper card
/// (in dark mode that reads as a printed card; never inverted).
/// Decorative: hidden from VoiceOver.
struct ArtImage: View {
    let name: String
    var size: CGFloat
    var radius: CGFloat = 22
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let image = Image(name).resizable().scaledToFill()
        Group {
            if scheme == .dark {
                // Dark: always on a light-paper card with a margin, never full-bleed, never inverted.
                let inset = max(4, (size * 0.06).rounded())
                image
                    .frame(width: size - inset * 2, height: size - inset * 2)
                    .clipShape(.rect(cornerRadius: max(4, Self.cardRadius(size) - inset), style: .continuous))
                    .frame(width: size, height: size)
                    .background(Color.artPaper, in: .rect(cornerRadius: Self.cardRadius(size), style: .continuous))
            } else {
                image
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: radius, style: .continuous))
            }
        }
        .accessibilityHidden(true)
    }

    /// 22 pt, capped for small thumbnails so they stay rounded squares.
    static func cardRadius(_ size: CGFloat) -> CGFloat { min(22, size * 0.25) }
}

extension Color {
    /// The light paper the artwork is printed on (#F6F3EE) in both schemes.
    static let artPaper = Color(red: 0xF6 / 255, green: 0xF3 / 255, blue: 0xEE / 255)
}

// MARK: - Buttons

/// Primary: ink fill, paper text, semibold 17, radius 18, 54 pt.
struct InkButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.paper)
            .padding(.horizontal, compact ? 22 : 16)
            .frame(maxWidth: compact ? nil : .infinity, minHeight: compact ? 44 : 54)
            .background(Color.ink.opacity(enabled ? 1 : 0.35), in: .rect(cornerRadius: compact ? 14 : 18, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.settle, value: configuration.isPressed)
            .contentShape(.rect(cornerRadius: compact ? 14 : 18))
    }
}

// MARK: - Empty / error

/// Art 160 pt, title serif 22 (optional), body 15 ink2 (max 280 wide),
/// optional button. `top`: 40 pt below the title on a screen; less in a list row.
struct ArtStateView: View {
    var art = "art-empty"
    var title: String?
    var message: String?
    var button: String?
    var action: (() -> Void)?
    var top: CGFloat = 40

    var body: some View {
        VStack(spacing: 14) {
            ArtImage(name: art, size: 160)
                .padding(.bottom, 4)
            if let title {
                Text(verbatim: title)
                    .font(.system(size: 22, design: .serif))
                    .foregroundStyle(.ink)
                    .multilineTextAlignment(.center)
            }
            if let message {
                Text(verbatim: message)
                    .font(.system(size: 15))
                    .foregroundStyle(.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let button, let action {
                Button(action: action) { Text(verbatim: button) }
                    .buttonStyle(InkButtonStyle(compact: true))
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, top)
        .riseIn()
    }
}

// MARK: - Offline

/// 「office-mac 现在连不上」: sleeping-magpie art that bobs, what the data
/// below is, 重试 and (with two computers or more) 换一台.
struct OfflineCard: View {
    let computer: String
    /// When the data below was read; nil when there is none.
    let since: Date?
    let now: Date
    var retry: () -> Void

    @Environment(ConnectionStore.self) private var connection
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var bob = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ArtImage(name: "art-offline", size: 56, radius: 14)
                .offset(y: bob ? -2 : 2)
                .rotationEffect(.degrees(bob ? -3 : 0))
                .onAppear {
                    guard !reduce else { return }
                    withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { bob = true }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(computer) 现在连不上")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ink)
                if let since {
                    Text("下面是 \(FreshnessText.when(since, now: now)) 的数据，连上后自动更新。")
                        .font(.footnote)
                        .foregroundStyle(.ink2)
                    Text("确认电脑开着、和手机在同一个网络。")
                        .font(.caption)
                        .foregroundStyle(.ink2)
                } else {
                    Text("确认电脑开着、和手机在同一个网络。")
                        .font(.footnote)
                        .foregroundStyle(.ink2)
                }
                HStack(spacing: 18) {
                    Button("重试", action: retry)
                        .accessibilityIdentifier("offline-retry")
                    if connection.computers.count > 1 {
                        Menu {
                            ForEach(connection.computers.filter { $0.id != connection.currentID }) { c in
                                Button {
                                    connection.select(c.id)
                                } label: {
                                    Text(verbatim: c.name)
                                    Text(verbatim: ComputerStatusText.menu(connection.status(of: c)))
                                }
                            }
                        } label: {
                            Text("换一台")
                        }
                        .accessibilityIdentifier("switch-computer")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .tint(.accentColor)
                .frame(minHeight: 32)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .perchCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("offline-card")
    }
}

/// Data under the offline card: 60 % opacity, 50 % saturation.
extension View {
    /// Dims the view while `on`.
    func offlineDimmed(_ on: Bool) -> some View {
        self.opacity(on ? 0.6 : 1).saturation(on ? 0.5 : 1)
            .animation(.easeInOut(duration: 0.4), value: on)
    }
}

// MARK: - Loading

/// A track-coloured block with the shimmer sweeping every 1.4 s.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var radius: CGFloat = 6

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.track)
            .frame(width: width, height: height)
            .overlay {
                if !reduce {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, .white.opacity(scheme == .dark ? 0.08 : 0.45), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(80, g.size.width * 0.5))
                            .offset(x: phase * (g.size.width + 160) - 80)
                    }
                    .clipShape(.rect(cornerRadius: radius, style: .continuous))
                }
            }
            .onAppear {
                guard !reduce else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

/// Shown only after 250 ms (never a spinner on blank); after 8 s a line
/// says magpie is slow. VoiceOver hears `spoken` (「正在读取额度」).
struct DelayedLoading<Content: View>: View {
    let spoken: String
    @ViewBuilder var content: Content

    @State private var visible = false
    @State private var slow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            if slow {
                Text("magpie 回得有点慢，再等一下。")
                    .font(.footnote)
                    .foregroundStyle(.ink2)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                    .accessibilityIdentifier("loading-slow")
            }
        }
        .opacity(visible ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
        .accessibilityIdentifier("loading")
        .task {
            try? await Task.sleep(for: .milliseconds(Self.delay))
            withAnimation(Motion.fade) { visible = true }
            try? await Task.sleep(for: .seconds(8))
            withAnimation(Motion.calm) { slow = true }
        }
    }

    private static var delay: Int {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-perch-demo-loading") { return 0 }
        #endif
        return 250
    }
}

/// 额度's skeleton: the hero (30 % line, 55 % × 48 pt block, 70 % line),
/// then cards (name + a value and a bar per window).
struct QuotaSkeleton: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 36
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    SkeletonBlock(width: w * 0.3, height: 12)
                    SkeletonBlock(width: w * 0.55, height: 48, radius: 10)
                    SkeletonBlock(width: w * 0.7, height: 12)
                    SkeletonBlock(height: 2, radius: 1).padding(.top, 10)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .perchCard()
                .padding(.bottom, 8)
                SkeletonBlock(width: 70, height: 14).padding(.leading, 4)
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Circle().fill(Color.track).frame(width: 32, height: 32)
                            SkeletonBlock(width: 110, height: 14)
                        }
                        HStack(spacing: 16) {
                            ForEach(0..<2, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 8) {
                                    SkeletonBlock(width: 60, height: 20)
                                    SkeletonBlock(height: 6, radius: 3)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .perchCard()
                }
            }
        }
        .frame(height: 560)
    }
}
