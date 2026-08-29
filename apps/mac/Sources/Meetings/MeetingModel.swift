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
enum MeetingModel: String, CaseIterable, Codable, Sendable {
    case whisperLargeV3
    case whisperLargeV3Turbo

    static let `default`: MeetingModel = .whisperLargeV3

    var shortName: String {
        switch self {
        case .whisperLargeV3: "whisper large"
        case .whisperLargeV3Turbo: "whisper turbo"
        }
    }

    /// The consequence, stated on the card rather than discovered later.
    var trait: String {
        switch self {
        case .whisperLargeV3: "every language, in english"
        case .whisperLargeV3Turbo: "every language, as spoken · faster"
        }
    }

    var approximateSize: String {
        switch self {
        case .whisperLargeV3: "~2.9 gb"
        case .whisperLargeV3Turbo: "~1.5 gb"
        }
    }

    /// WhisperKit's name for it, and the folder it lands in.
    var whisperVariant: String {
        switch self {
        case .whisperLargeV3: "openai_whisper-large-v3"
        case .whisperLargeV3Turbo: "openai_whisper-large-v3-v20240930_turbo"
        }
    }

    /// Whether the far side comes out as English. Turbo cannot translate, so
    /// it transcribes — Hindi arrives in Devanagari, Hinglish keeps its
    /// English words in Latin script.
    var translatesToEnglish: Bool {
        self == .whisperLargeV3
    }
}
