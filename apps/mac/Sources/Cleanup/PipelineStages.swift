import Foundation

/// the two layers a word passes through on its way to the page. the
/// playground renders these; nothing else in the app knew the pipeline had a
/// shape a user could see.
enum PipelineStage: String, CaseIterable, Identifiable, Sendable {
    case transcription
    case deterministic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcription:
            "speech model"
        case .deterministic:
            "cleanup"
        }
    }

    /// the stage cannot be switched off. transcription *is* the app.
    /// cleanup got its switch in ADR 0038 — off still runs the dictionary,
    /// so switching it off can't break a word you taught it.
    var isAlwaysOn: Bool {
        self == .transcription
    }
}

/// what the playground shows for one stage: the text as it leaves that layer,
/// and whether the layer actually did anything to it.
struct PipelineStageResult: Equatable, Sendable, Identifiable {
    let stage: PipelineStage
    let input: String
    let output: String
    let isEnabled: Bool

    var id: String { stage.rawValue }

    /// a stage that ran and changed nothing is not a failure — having
    /// nothing to add is an answer.
    var changedAnything: Bool {
        isEnabled && input != output
    }
}

/// which layers the playground is currently running. scratch state — it never
/// touches settings, so you can see what raw parakeet output looks like
/// without shipping yourself a broken dictation.
struct PipelineSelection: Equatable, Sendable {
    var deterministicEnabled = true

    func isEnabled(_ stage: PipelineStage) -> Bool {
        switch stage {
        case .transcription:
            true
        case .deterministic:
            deterministicEnabled
        }
    }

    mutating func toggle(_ stage: PipelineStage) {
        switch stage {
        case .transcription:
            break
        case .deterministic:
            deterministicEnabled.toggle()
        }
    }
}

/// the worked example the playground opens with: every layer has something to
/// do with it, so the diagram isn't two boxes that say the same thing.
enum PipelineSample {
    static let text =
        "send it to jass at jass dot gg comma and say we shipped "
            + "five hundred dollars of credits period"

    /// the markers, read out of the transform itself: the line settings
    /// prints can only ever name the phrases the cleaner listens for.
    static let spokenMarkerLine =
        "say them and they appear: "
            + SpokenPunctuation.spokenMarkers.joined(separator: " · ")
            + "."
}
