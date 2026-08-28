import AppKit
import SwiftUI

/// the picker is the list (ADR 0039, prototype 014 B): one card per model,
/// the one-line reason you'd choose it, its size, its state. choosing a
/// model that isn't on disk downloads it and switches when it's ready —
/// downloading is not a separate activity. built as its own view so a
/// second consumer (meetings, if it ever exists) can embed it and keep its
/// own pick.
struct ModelChooserView: View {
    @Binding var selection: EngineVersion
    let active: EngineVersion
    let preparation: EnginePreparationState
    let installed: [InstalledModel]
    let onRetry: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(EngineVersion.allCases) { version in
                card(for: version)
            }
        }
    }

    private func card(for version: EngineVersion) -> some View {
        let isChosen = version == selection
        let isActive = version == active
        let downloaded = installed.first { $0.version == version }
            .map(\.isDownloaded) ?? false
        let size = installed.first { $0.version == version }
            .flatMap { $0.isDownloaded ? $0.onDiskSize : nil }
            ?? version.approximateSize

        return Button {
            selection = version
        } label: {
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
                    Text(version.shortName)
                        .font(BrandUI.bodyFont.weight(.medium))
                        .foregroundStyle(BrandUI.textPrimary)

                    Text(version.trait)
                        .font(.caption)
                        .foregroundStyle(BrandUI.textSecondary)

                    HStack(spacing: 6) {
                        Text(size)
                            .font(BrandUI.machineFont(size: 11))
                        Text("·")
                        Text(stateLine(
                            isChosen: isChosen,
                            isActive: isActive,
                            downloaded: downloaded
                        ))
                    }
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)
                    .padding(.top, 4)

                    if isChosen, !isActive,
                       case let .downloading(progress) = preparation {
                        ProgressView(value: min(max(progress, 0), 1))
                            .progressViewStyle(.linear)
                            .tint(BrandUI.gold)
                            .padding(.top, 2)
                    }

                    if isChosen, preparation == .failed {
                        Button("retry", action: onRetry)
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(BrandUI.gold)
                            .padding(.top, 2)
                    }
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
        .accessibilityLabel(version.displayName)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// what choosing this card does, said before you do it.
    private func stateLine(
        isChosen: Bool,
        isActive: Bool,
        downloaded: Bool
    ) -> String {
        if isActive {
            return "on this mac"
        }
        if isChosen {
            switch preparation {
            case .downloading: return "downloading"
            case .warmingUp: return "loading"
            case .failed: return "download failed"
            case .notStarted, .ready: return "switching…"
            }
        }
        return downloaded ? "on this mac" : "downloads when chosen"
    }
}

extension EngineVersion {
    var shortName: String {
        switch self {
        case .v2: "parakeet v2"
        case .v3: "parakeet v3"
        }
    }

    /// the one-line reason you'd pick it — the tradeoff *is* the decision,
    /// so it goes on the control, not in a popup you learn from after.
    var trait: String {
        switch self {
        case .v2: "english · fastest"
        case .v3: "25 languages · a touch slower"
        }
    }

    var approximateSize: String {
        switch self {
        case .v2: "~460 mb"
        case .v3: "~470 mb"
        }
    }
}
