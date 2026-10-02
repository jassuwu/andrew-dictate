import Foundation
import WhisperKit

/// Whisper reading a meeting a stretch at a time: large-v3 translating
/// into english, turbo writing it as spoken (turbo was never taught to
/// translate). Each stretch is one decode with no window of its own to
/// manage, because none is longer than the 30 s whisper reads at once.
///
/// Loaded the way `WhisperMeetingTranscriber` loads it, from the folder
/// setup downloaded it to and never from the network.
actor WhisperStretchEngine: StretchEngine {
    enum Failure: Error, LocalizedError {
        case notLoaded
        case notWhisper(MeetingModel)

        var errorDescription: String? {
            switch self {
            case .notLoaded: "whisper was asked to decode before it had loaded"
            case .notWhisper(let model): "\(model.shortName) is not a whisper model"
            }
        }
    }

    /// The longest stretch it is handed: comfortably inside the 30 s
    /// whisper reads at once.
    static let ceiling = Duration.seconds(25)

    private let model: MeetingModel
    private var whisper: WhisperKit?

    init(model: MeetingModel) {
        self.model = model
    }

    func load() async throws {
        guard whisper == nil else { return }
        guard let variant = model.whisperVariant,
              let folder = MeetingEngines.folder(for: model)
        else {
            throw Failure.notWhisper(model)
        }
        whisper = try await WhisperKit(WhisperKitConfig(
            model: variant,
            downloadBase: MeetingEngines.modelDirectory,
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false))
    }

    func text(of samples: [Float]) async throws -> String {
        guard let whisper else { throw Failure.notLoaded }
        var options = DecodingOptions()
        options.task = model.translatesToEnglish ? .translate : .transcribe
        options.language = nil
        options.detectLanguage = true
        options.usePrefillPrompt = true
        options.skipSpecialTokens = true
        options.withoutTimestamps = false
        options.temperature = 0
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        return results
            .flatMap(\.segments)
            .map { Self.clean($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Whisper marks a change of speaker with a leading dash, from the
    /// subtitles it learned on. The speaker is already known here: it is the
    /// side the stretch came from.
    private static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("-") || t.hasPrefix("–") {
            t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return t
    }
}
