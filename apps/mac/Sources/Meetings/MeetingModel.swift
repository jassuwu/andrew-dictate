import Foundation

/// Which speech model listens to meetings — ADR 0040.
///
/// Separate from `EngineVersion` on purpose: dictation and meetings are two
/// jobs with opposite needs (200 ms in English versus every language, no
/// hurry), and each picks its own model from the same cards.
enum MeetingModel: String, CaseIterable, Codable, Sendable {
    case whisperLargeV3Turbo
    case whisperLargeV3
    case parakeetV3

    var shortName: String {
        switch self {
        case .whisperLargeV3Turbo: "whisper turbo"
        case .whisperLargeV3: "whisper large"
        case .parakeetV3: "parakeet v3"
        }
    }

    /// The consequence, stated on the card rather than discovered later.
    var trait: String {
        switch self {
        case .whisperLargeV3Turbo: "every language · english out"
        case .whisperLargeV3: "every language · most accurate · slow"
        case .parakeetV3: "25 languages · no hindi"
        }
    }

    var approximateSize: String {
        switch self {
        case .whisperLargeV3Turbo: "~650 mb"
        case .whisperLargeV3: "~1.5 gb"
        case .parakeetV3: "~470 mb"
        }
    }
}
