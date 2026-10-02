import Foundation

/// The `record with ▸` submenu under `record a meeting`: the other meeting
/// models that are on this mac, for the one meeting that wants one.
enum RecordWith {
    struct Choice: Equatable, Sendable {
        let model: MeetingModel
        let title: String
    }

    static func choices(
        installed: Set<MeetingModel>,
        default defaultModel: MeetingModel,
        isRecording: Bool
    ) -> [Choice] {
        guard !isRecording else { return [] }
        return MeetingModel.allCases
            .filter { installed.contains($0) && $0 != defaultModel }
            .map { Choice(model: $0, title: "\($0.shortName) — \($0.trait)") }
    }
}
