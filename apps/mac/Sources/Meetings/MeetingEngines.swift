import Foundation

/// Where the meeting models come from and go. The whisper engine is the
/// next piece to land; until it does, every model is "not on this mac" and
/// pressing record routes to setup — which is the honest state.
enum MeetingEngines {
    enum Failure: Error, LocalizedError {
        case notAvailable(MeetingModel)

        var errorDescription: String? {
            switch self {
            case .notAvailable(let model): "\(model.shortName) is not on this mac yet"
            }
        }
    }

    /// Whisper models live beside parakeet, under FluidAudio's shared folder,
    /// so removal (ADR 0035) has one place to look.
    static var modelDirectory: URL {
        AppIdentity.sharedModelDirectory.appendingPathComponent("whisperkit", isDirectory: true)
    }

    @MainActor
    static func installed() -> Set<MeetingModel> {
        []
    }

    static func makeTranscriber(for model: MeetingModel) async throws -> any MeetingTranscriber {
        throw Failure.notAvailable(model)
    }

    static func makeDiarizer() -> any MeetingDiarizer {
        NoDiarizer()
    }

    /// Downloads (or verifies) the model, reporting 0…1. False means it did
    /// not finish.
    static func prepare(
        _ model: MeetingModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        false
    }
}

/// Leaves `them` whole. Stands in until FluidAudio's diarizer is wired.
struct NoDiarizer: MeetingDiarizer {
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] {
        turns
    }
}
