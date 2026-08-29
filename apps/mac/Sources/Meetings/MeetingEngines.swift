import Foundation
import WhisperKit

/// Where the meeting models come from and go. Whisper lives beside parakeet
/// under FluidAudio's shared folder, so removal (ADR 0035) has one place to
/// look, and `installed()` is a question for the disk, never a memory.
enum MeetingEngines {
    enum Failure: Error, LocalizedError {
        case notInstalled(MeetingModel)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let model): "\(model.shortName) is not on this mac"
            }
        }
    }

    static var modelDirectory: URL {
        AppIdentity.sharedModelDirectory.appendingPathComponent("whisperkit", isDirectory: true)
    }

    /// WhisperKit lays models out as `models/<repo>/<variant>` under its base.
    static func folder(for model: MeetingModel) -> URL {
        modelDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(model.whisperVariant, isDirectory: true)
    }

    static func isInstalled(_ model: MeetingModel) -> Bool {
        let decoder = folder(for: model).appendingPathComponent("TextDecoder.mlmodelc")
        return FileManager.default.fileExists(atPath: decoder.path)
    }

    static func installed() -> Set<MeetingModel> {
        Set(MeetingModel.allCases.filter(isInstalled))
    }

    static func makeTranscriber(for model: MeetingModel) async throws -> any MeetingTranscriber {
        guard isInstalled(model) else {
            throw Failure.notInstalled(model)
        }
        return WhisperMeetingTranscriber(model: model)
    }

    static func makeDiarizer() -> any MeetingDiarizer {
        FluidDiarizer()
    }

    /// Downloads (or verifies) the model, reporting 0…1. False means it did
    /// not finish; the caller shows "try again".
    static func prepare(
        _ model: MeetingModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        do {
            _ = try await WhisperKit.download(
                variant: model.whisperVariant,
                downloadBase: modelDirectory,
                progressCallback: { progress($0.fractionCompleted) }
            )
            progress(1)
            return isInstalled(model)
        } catch {
            return false
        }
    }
}
