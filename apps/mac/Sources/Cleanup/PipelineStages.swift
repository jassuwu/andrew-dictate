import Foundation

/// the three layers a word passes through on its way to the page. the
/// playground renders these; nothing else in the app knew the pipeline had a
/// shape a user could see.
enum PipelineStage: String, CaseIterable, Identifiable, Sendable {
    case transcription
    case deterministic
    case polish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcription:
            "speech model"
        case .deterministic:
            "cleanup"
        case .polish:
            "ai polish"
        }
    }

    var summary: String {
        switch self {
        case .transcription:
            "parakeet turns what you said into words. on-device."
        case .deterministic:
            "eight rules: punctuation you spoke, emails, numbers, "
                + "your dictionary. it never rewrites your words."
        case .polish:
            "apple's on-device model, only when the text looks messy."
        }
    }

    /// the stage cannot be switched off. transcription *is* the app, and the
    /// deterministic pass is where your dictionary and spoken punctuation
    /// live — a toggle would only teach people to break it.
    var isAlwaysOn: Bool {
        self != .polish
    }
}

/// what the playground shows for one stage: the text as it leaves that layer,
/// and whether the layer actually did anything to it.
struct PipelineStageResult: Equatable, Sendable, Identifiable {
    let stage: PipelineStage
    let input: String
    let output: String
    let isEnabled: Bool
    /// nil unless the stage couldn't run at all (no model on this mac, the
    /// polish threw). a stage that ran and changed nothing is not a failure —
    /// having nothing to add is an answer.
    let unavailableReason: String?

    var id: String { stage.rawValue }

    var changedAnything: Bool {
        isEnabled && unavailableReason == nil && input != output
    }
}

/// which layers the playground is currently running. scratch state — it never
/// touches settings, so you can see what raw parakeet output looks like
/// without shipping yourself a broken dictation.
struct PipelineSelection: Equatable, Sendable {
    var deterministicEnabled = true
    var polishEnabled = false

    func isEnabled(_ stage: PipelineStage) -> Bool {
        switch stage {
        case .transcription:
            true
        case .deterministic:
            deterministicEnabled
        case .polish:
            polishEnabled
        }
    }

    mutating func toggle(_ stage: PipelineStage) {
        switch stage {
        case .transcription:
            break
        case .deterministic:
            deterministicEnabled.toggle()
        case .polish:
            polishEnabled.toggle()
        }
    }
}

/// the worked example the playground opens with: every layer has something to
/// do with it, so the diagram isn't three boxes that all say the same thing.
enum PipelineSample {
    static let text =
        "send it to jass at jass dot gg comma and say we shipped "
            + "five hundred dollars of credits period"
}
