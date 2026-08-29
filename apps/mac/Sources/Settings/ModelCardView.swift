import SwiftUI

/// one card in a model picker: the radio, the short name, the tradeoff, the
/// size and what choosing it does.
///
/// the picker is the list (ADR 0039) and each job picks its own model from
/// the same cards (ADR 0040) — so the card is handed strings and a closure
/// and knows nothing about dictation or meetings. what a card cannot do is
/// hide the consequence: `trait` and `state` are not optional.
struct ModelCardView<Footer: View>: View {
    let name: String
    let trait: String
    /// on disk if it is there, the estimate if it isn't.
    let size: String
    /// what choosing this card does, said before you do it.
    let state: String
    let isChosen: Bool
    /// the one actually doing the job. gets the pill.
    let isActive: Bool
    /// 0…1 while this model is downloading, nil the rest of the time.
    let progress: Double?
    /// what VoiceOver reads — the long name, not the card's short one.
    let accessibilityName: String
    let choose: () -> Void
    let footer: () -> Footer

    init(
        name: String,
        trait: String,
        size: String,
        state: String,
        isChosen: Bool,
        isActive: Bool,
        progress: Double?,
        accessibilityName: String,
        choose: @escaping () -> Void,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.name = name
        self.trait = trait
        self.size = size
        self.state = state
        self.isChosen = isChosen
        self.isActive = isActive
        self.progress = progress
        self.accessibilityName = accessibilityName
        self.choose = choose
        self.footer = footer
    }

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .strokeBorder(
                        isChosen ? BrandUI.gold : BrandUI.textSecondary,
                        lineWidth: 1.5
                    )
                    .background {
                        if isChosen {
                            Circle().fill(BrandUI.gold).padding(3.5)
                        }
                    }
                    .frame(width: 14, height: 14)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(BrandUI.bodyFont.weight(.medium))
                        .foregroundStyle(BrandUI.textPrimary)

                    Text(trait)
                        .font(.caption)
                        .foregroundStyle(BrandUI.textSecondary)

                    HStack(spacing: 6) {
                        Text(size)
                            .font(BrandUI.machineFont(size: 11))
                        Text("·")
                        Text(state)
                    }
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)
                    .padding(.top, 4)

                    if let progress {
                        ProgressView(value: min(max(progress, 0), 1))
                            .progressViewStyle(.linear)
                            .tint(BrandUI.gold)
                            .padding(.top, 2)
                    }

                    footer()
                }

                Spacer(minLength: 0)

                if isActive {
                    Text("active")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(BrandUI.goldPale)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule().fill(BrandUI.goldDeep.opacity(0.22))
                        }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(BrandUI.cardBg.opacity(0.7))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isChosen ? BrandUI.gold.opacity(0.7) : BrandUI.hairline,
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

extension ModelCardView where Footer == EmptyView {
    init(
        name: String,
        trait: String,
        size: String,
        state: String,
        isChosen: Bool,
        isActive: Bool,
        progress: Double?,
        accessibilityName: String,
        choose: @escaping () -> Void
    ) {
        self.init(
            name: name,
            trait: trait,
            size: size,
            state: state,
            isChosen: isChosen,
            isActive: isActive,
            progress: progress,
            accessibilityName: accessibilityName,
            choose: choose,
            footer: { EmptyView() }
        )
    }
}

/// two columns, ten apart — the shape every model picker in the app takes.
struct ModelCardGrid<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            content
        }
    }
}
