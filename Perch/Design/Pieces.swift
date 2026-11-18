import SwiftUI

// Shared pieces: the segmented control on
// a track background, the live card's ping dot and sweep, block headers,
// card rows inside Lists and Forms.

// MARK: - Segmented

/// Track background, the selected segment a card with a 1 pt shadow that
/// slides between segments (settle; a crossfade under Reduce Motion).
struct PerchSegmented<Value: Hashable>: View {
    struct Option {
        var value: Value
        var title: LocalizedStringKey
        var id: String
    }

    @Binding var selection: Value
    let options: [Option]

    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.colorScheme) private var scheme
    @State private var changes = 0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.id) { option in
                let selected = option.value == selection
                Button {
                    guard !selected else { return }
                    withAnimation(Motion.settle(reduce)) { selection = option.value }
                    changes += 1
                } label: {
                    Text(option.title)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.ink : Color.ink2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.card)
                                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.10), radius: 0.5, y: 1)
                                    .overlay {
                                        if scheme == .dark {
                                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                .strokeBorder(Color.hairline, lineWidth: 0.5)
                                        }
                                    }
                                    .matchedGeometryEffect(id: "selected", in: ns)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier(option.id)
            }
        }
        .padding(2)
        .background(Color.track, in: .rect(cornerRadius: 11, style: .continuous))
        .sensoryFeedback(Haptic.selection, trigger: changes)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Live

/// 「正在进行」's dot: a good-coloured dot with a ring that pings outwards.
/// Still under Reduce Motion.
struct PingDot: View {
    var color: Color = .good
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var ping = false

    var body: some View {
        ZStack {
            if active && !reduce {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: 8, height: 8)
                    .scaleEffect(ping ? 2.6 : 1)
                    .opacity(ping ? 0 : 1)
            }
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .frame(width: 20, height: 20)
        .onAppear {
            guard active, !reduce else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { ping = true }
        }
        .accessibilityHidden(true)
    }
}

/// A 2 pt track line with a 30 %-wide accent segment sweeping left → right
/// every 2.8 s (easeInOut). Under Reduce Motion the segment rests still.
struct SweepLine: View {
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let seg = w * 0.3
            ZStack(alignment: .leading) {
                Capsule().fill(Color.track)
                if active {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: seg)
                        .offset(x: reduce ? 0 : -seg + phase * (w + seg))
                }
            }
            .clipShape(.capsule)
        }
        .frame(height: 2)
        .onAppear {
            guard active, !reduce else { return }
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: false)) { phase = 1 }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Blocks

/// A block title above a card (「按模型」, 「最近的调用」): headline ink,
/// like 额度's provider headers.
struct BlockHeader<Trailing: View>: View {
    let title: Text
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            title
                .font(.headline)
                .foregroundStyle(.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 32)
        .padding(.horizontal, 4)
    }
}

extension BlockHeader where Trailing == EmptyView {
    init(_ title: Text) {
        self.title = title
        self.trailing = EmptyView()
    }
}

extension View {
    /// Rows of grouped Lists and Forms on white (dark: #1E1C18) cards.
    func cardRow() -> some View {
        listRowBackground(Color.card)
    }

    /// 1.5: a banner or the offline card as a List section of its own,
    /// drawing its own background.
    func bannerRow() -> some View {
        listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
    }

    /// Section headers in Lists and Forms: footnote semibold ink2, no caps.
    func listHeaderStyle() -> some View {
        font(.footnote.weight(.semibold))
            .foregroundStyle(.ink2)
            .textCase(nil)
    }
}

/// 「时间 … 11/16 10:42」 rows: label ink, value ink2 (system grey is
/// not part of the palette).
struct PerchLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label
                .foregroundStyle(.ink)
            Spacer(minLength: 8)
            configuration.content
                .foregroundStyle(.ink2)
                .multilineTextAlignment(.trailing)
        }
    }
}

extension LabeledContentStyle where Self == PerchLabeledContentStyle {
    static var perch: PerchLabeledContentStyle { .init() }
}
