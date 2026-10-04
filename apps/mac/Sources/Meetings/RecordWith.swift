import Foundation

/// The `record with ▸` submenu under `record a meeting`: the other meeting
/// models that are on this mac, for the one meeting that wants one, by
/// name. What each one does is on its card in settings; parakeet's would
/// make a menu line wider than the menu.
enum RecordWith {
    struct Choice: Equatable, Sendable {
        let model: SpeechModel
        let title: String
    }

    static func choices(
        installed: Set<SpeechModel>,
        default defaultModel: SpeechModel,
        isRecording: Bool
    ) -> [Choice] {
        guard !isRecording else { return [] }
        return SpeechModel.cards(for: .meetings)
            .filter { installed.contains($0) && $0 != defaultModel }
            .map { Choice(model: $0, title: $0.shortName) }
    }
}
