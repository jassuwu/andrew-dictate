import AppKit
import SwiftUI

/// the picker is the list (ADR 0039, prototype 014 B): one card per model,
/// the one-line reason you'd choose it, its size, its state. choosing a
/// model that isn't on disk downloads it and switches when it's ready —
/// downloading is not a separate activity. the card itself is
/// `ModelCardView`, shared with meetings, which picks its own model from
/// the same cards (ADR 0040).
struct ModelChooserView: View {
    @Binding var selection: EngineVersion
    let active: EngineVersion
    let preparation: EnginePreparationState
    let installed: [InstalledModel]
    let onRetry: () -> Void

    var body: some View {
        ModelCardGrid {
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

        return ModelCardView(
            name: version.shortName,
            trait: version.trait,
            size: size,
            state: stateLine(
                isChosen: isChosen,
                isActive: isActive,
                downloaded: downloaded
            ),
            isChosen: isChosen,
            isActive: isActive,
            progress: progress(isChosen: isChosen, isActive: isActive),
            accessibilityName: version.displayName,
            choose: { selection = version }
        ) {
            if isChosen, preparation == .failed {
                Button("retry", action: onRetry)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(BrandUI.gold)
                    .padding(.top, 2)
            }
        }
    }

    private func progress(isChosen: Bool, isActive: Bool) -> Double? {
        guard isChosen, !isActive,
              case let .downloading(progress) = preparation else {
            return nil
        }
        return progress
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
