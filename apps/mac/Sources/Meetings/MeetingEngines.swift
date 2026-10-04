import FluidAudio
import Foundation
import os

/// What listens to a meeting, and what a meeting needs on disk besides
/// its model. The model files themselves are `ModelFiles`, shared with
/// dictation.
enum MeetingEngines {
    private static let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "meeting-models")

    /// What listens to a meeting, for the model it was started with.
    ///
    /// Every model reads the meeting a stretch at a time: each side cut where
    /// Silero hears speech begin and end, and each stretch decoded once.
    static func makeTranscriber(for model: SpeechModel) async throws -> any MeetingTranscriber {
        guard ModelFiles.isInstalled(model) else {
            throw SpeechModel.NotInstalled(model: model)
        }
        // the speaker split is read at the end of the meeting; a mac that
        // was set up before its models came down with the meeting model
        // gets them now, in the background, so they are there by then.
        // whisper's tokenizer is not fetched here: the load needs it before
        // anything else, and fetches it itself.
        if !FluidDiarizer.isOnDisk {
            Task.detached(priority: .utility) { await fetchSpeakerSplit() }
        }
        if model.asrModelVersion != nil {
            return stretches(ParakeetStretchEngine(model: model), ceiling: ParakeetStretchEngine.ceiling)
        }
        return stretches(WhisperModel(model, translates: model.translatesToEnglish), ceiling: WhisperModel.ceiling)
    }

    /// A meeting heard a stretch at a time, both sides by one voice model
    /// loaded for this meeting and let go with it.
    private static func stretches(_ engine: any StretchEngine, ceiling: Duration) -> StretchTranscriber {
        let voice = SileroVoice()
        return StretchTranscriber(engine: engine, ceiling: ceiling, detector: { voice.detector() })
    }

    static func makeDiarizer() -> any MeetingDiarizer {
        FluidDiarizer()
    }

    // MARK: - what a meeting reads besides the model

    /// The speaker-split models, one download at a time in the same way:
    /// setup, and a meeting started on a mac that does not have them yet.
    private static let speakerSplit = OneDownload { try await FluidDiarizer.fetch() }

    /// The speaker-split models, for a mac that does not have them yet.
    /// Failing is logged and nothing more: a meeting without them has
    /// plain `them`.
    static func fetchSpeakerSplit() async {
        do {
            try await speakerSplit.run()
        } catch {
            logger.error("the speaker-split models did not download: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Downloads (or verifies) the model, reporting 0…1. False means it did
    /// not finish; the caller shows "try again".
    ///
    /// The speaker-split models come down after it, so that no meeting
    /// waits on the network at its end. Their failing is logged and is not
    /// the model failing: a meeting without the split has plain `them`.
    static func prepare(
        _ model: SpeechModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        do {
            try await ModelFiles.download(model, progress: progress)
        } catch {
            return false
        }
        await fetchSpeakerSplit()
        progress(1)
        return ModelFiles.isInstalled(model)
    }
}
