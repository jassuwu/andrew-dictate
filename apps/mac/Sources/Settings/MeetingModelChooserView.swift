import SwiftUI

/// the meeting model, picked from the same cards dictation uses (ADR 0040).
/// the two jobs want opposite things — 200 ms in english versus every
/// language and no hurry — so each keeps its own pick and the card states
/// the consequence rather than leaving it to be discovered.
///
/// `installed` and `downloading` default to empty: the view draws whatever
/// it is told, and the coordinator is the only thing that knows the truth.
struct MeetingModelChooserView: View {
    @Binding var selection: MeetingModel
    var installed: Set<MeetingModel> = []
    var downloading: [MeetingModel: Double] = [:]

    var body: some View {
        ModelCardGrid {
            ForEach(MeetingModel.allCases, id: \.self) { model in
                card(for: model)
            }
        }
    }

    private func card(for model: MeetingModel) -> some View {
        let isChosen = model == selection
        let isDownloaded = installed.contains(model)

        return ModelCardView(
            name: model.shortName,
            trait: model.trait,
            size: model.approximateSize,
            state: stateLine(
                isChosen: isChosen,
                isDownloaded: isDownloaded,
                progress: downloading[model]
            ),
            isChosen: isChosen,
            // there is no separate "active" meeting model: the one you
            // picked *is* the one that listens, once it is on disk.
            isActive: isChosen && isDownloaded,
            progress: downloading[model],
            accessibilityName: model.shortName,
            choose: { selection = model }
        )
    }

    /// what choosing this card does, said before you do it.
    private func stateLine(
        isChosen: Bool,
        isDownloaded: Bool,
        progress: Double?
    ) -> String {
        if progress != nil {
            return "downloading"
        }
        if isDownloaded {
            return "on this mac"
        }
        return isChosen
            ? "downloads at the next meeting"
            : "downloads when chosen"
    }
}

#Preview("meeting model") {
    @Previewable @State var selection: MeetingModel = .whisperLargeV3Turbo

    return MeetingModelChooserView(
        selection: $selection,
        installed: [.whisperLargeV3Turbo],
        downloading: [.parakeetV3: 0.4]
    )
    .padding(24)
    .frame(width: 800)
    .background(BrandUI.windowBg)
    .foregroundStyle(BrandUI.textPrimary)
    .font(BrandUI.bodyFont)
    .brandTinted()
    .controlSize(.small)
    .preferredColorScheme(.dark)
}
