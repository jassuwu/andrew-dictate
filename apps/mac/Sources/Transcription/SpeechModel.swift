import Foundation

/// Which speech model listens to meetings — ADR 0040.
///
/// Separate from `EngineVersion` on purpose: dictation and meetings are two
/// jobs with opposite needs (200 ms in English versus every language, no
/// hurry), and each picks its own model from the same cards.
///
/// The spike settled the default: large-v3 turbo was fine-tuned on
/// transcription only and silently ignores the translate task, so the one
/// model that can turn a Hindi colleague into English is the full large-v3.
/// Turbo stays as the "as spoken" choice for someone who reads the language.
///
/// Parakeet is the third and fourth card: dictation's v3 and v2, by far the
/// fastest and already on disk for anyone who dictates with them. v3 knows
/// English and the European languages, v2 English alone; anything else,
/// Hindi included, comes out as confident nonsense, so neither is ever the
/// default.
///
/// Stored by raw value in settings and in every spool's manifest: a case is
/// never renamed.
enum SpeechModel: String, CaseIterable, Codable, Sendable {
    case whisperLargeV3
    case whisperLargeV3Turbo
    case parakeetV3
    case parakeetV2

    static let `default`: SpeechModel = .whisperLargeV3

    var shortName: String {
        switch self {
        case .whisperLargeV3: "whisper large"
        case .whisperLargeV3Turbo: "whisper turbo"
        case .parakeetV3: "parakeet v3"
        case .parakeetV2: "parakeet v2"
        }
    }

    /// The consequence, stated on the card rather than discovered later.
    var trait: String {
        switch self {
        case .whisperLargeV3: "every language, in english"
        case .whisperLargeV3Turbo: "every language, as spoken · faster"
        case .parakeetV3: "fast · english and european languages only · anything else comes out as nonsense"
        case .parakeetV2: "fastest · english only · anything else comes out as nonsense"
        }
    }

    var approximateSize: String {
        switch self {
        case .whisperLargeV3: "~2.9 gb"
        case .whisperLargeV3Turbo: "~1.5 gb"
        // the same file dictation's v3 reads: nothing more to fetch for
        // anyone who already dictates with it.
        case .parakeetV3: "~470 mb, shared with dictation's v3"
        case .parakeetV2: "~460 mb, shared with dictation's v2"
        }
    }

    /// WhisperKit's name for it, and the folder it lands in. Parakeet is
    /// not whisper's, and lives where dictation keeps it.
    var whisperVariant: String? {
        switch self {
        case .whisperLargeV3: "openai_whisper-large-v3"
        case .whisperLargeV3Turbo: "openai_whisper-large-v3-v20240930_turbo"
        case .parakeetV3, .parakeetV2: nil
        }
    }

    /// Whether the far side comes out as English. Turbo cannot translate, so
    /// it transcribes — Hindi arrives in Devanagari, Hinglish keeps its
    /// English words in Latin script. Parakeet has no translate task at all.
    var translatesToEnglish: Bool {
        self == .whisperLargeV3
    }
}

extension SpeechModel {
    /// What making a transcriber for a model that is not on this mac throws.
    /// Its own type, in a file the coordinator can see, because recovery
    /// answers it differently from every other failure: it reads the spool
    /// with a model that is there, or waits, and counts nothing against it.
    struct NotInstalled: Error, LocalizedError {
        let model: SpeechModel

        var errorDescription: String? {
            "\(model.shortName) is not on this mac"
        }
    }
}
