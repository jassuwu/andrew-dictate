import Foundation

/// Every speech model the app can listen with, for either job — ADR 0040.
///
/// Dictation and meetings each keep their own pick from these, because the
/// two jobs want opposite things: 200 ms in English versus every language
/// and no hurry. Any model can do either job; the card says what it costs
/// in the job it is shown for, rather than leaving it to be discovered.
///
/// The spike settled the meeting default: large-v3 turbo was fine-tuned on
/// transcription only and silently ignores the translate task, so the one
/// model that can turn a Hindi colleague into English is the full large-v3.
/// Turbo stays as the "as spoken" choice for someone who reads the language.
///
/// Parakeet v2 and v3 are the dictation models, by far the fastest. v3 knows
/// English and the European languages, v2 English alone; anything else,
/// Hindi included, comes out as confident nonsense, so neither is ever the
/// meeting default.
///
/// Whistle is Cactus Compute's, released 2026-10-02: 17 mb, on the cpu, in
/// English and six European languages. New enough that its card says so.
///
/// Stored by raw value in settings and in every spool's manifest: a case is
/// never renamed.
enum SpeechModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case whisperLargeV3
    case whisperLargeV3Turbo
    case parakeetV3
    case parakeetV2
    case whistle

    /// The two places a model is picked for.
    enum Job: Sendable {
        case dictation
        case meetings
    }

    /// Whose code runs it, and so where its files are and what loads it.
    enum Family: Sendable {
        case parakeet
        case whisper
        case whistle
    }

    static let meetingDefault: SpeechModel = .whisperLargeV3
    static let dictationDefault: SpeechModel = .parakeetV2

    /// The cards a job shows, in the order it shows them: the job's own
    /// choice first. Meetings keep the order they always had, which is
    /// also the order `record with ▸` lists them in.
    static func cards(for job: Job) -> [SpeechModel] {
        switch job {
        case .dictation: [.parakeetV2, .parakeetV3, .whisperLargeV3Turbo, .whisperLargeV3, .whistle]
        case .meetings: allCases
        }
    }

    var id: Self {
        self
    }

    /// Dictation's setting, as any build ever stored it. Before dictation
    /// could pick whisper its two choices were stored as "v2" and "v3".
    init?(storedDictationValue value: String) {
        switch value {
        case "v2": self = .parakeetV2
        case "v3": self = .parakeetV3
        default: self.init(rawValue: value)
        }
    }

    var family: Family {
        switch self {
        case .parakeetV2, .parakeetV3: .parakeet
        case .whisperLargeV3, .whisperLargeV3Turbo: .whisper
        case .whistle: .whistle
        }
    }

    var shortName: String {
        switch self {
        case .whisperLargeV3: "whisper large"
        case .whisperLargeV3Turbo: "whisper turbo"
        case .parakeetV3: "parakeet v3"
        case .parakeetV2: "parakeet v2"
        case .whistle: "whistle"
        }
    }

    /// A word beside the name, for a model too new to have earned the
    /// trust the others have.
    var badge: String? {
        switch self {
        case .whistle: "experimental"
        case .whisperLargeV3, .whisperLargeV3Turbo, .parakeetV3, .parakeetV2: nil
        }
    }

    /// The long name: what VoiceOver reads and what a timing report says
    /// it was measured on.
    var displayName: String {
        switch self {
        case .whisperLargeV3: "whisper large-v3"
        case .whisperLargeV3Turbo: "whisper large-v3 turbo"
        case .parakeetV3: "parakeet v3 (multilingual)"
        case .parakeetV2: "parakeet v2 (english)"
        case .whistle: "whistle (cactus compute)"
        }
    }

    /// The one-line reason you'd pick it for this job — the tradeoff *is*
    /// the decision, so it goes on the card, not in a popup you learn from
    /// after.
    func trait(for job: Job) -> String {
        switch (job, self) {
        case (.dictation, .parakeetV2): "english · fastest"
        case (.dictation, .parakeetV3): "25 languages · a touch slower"
        case (.dictation, .whisperLargeV3Turbo): "every language · slower than parakeet"
        case (.dictation, .whisperLargeV3): "every language · slowest, you'll wait for it"
        case (.meetings, .whisperLargeV3): "every language, in english"
        case (.meetings, .whisperLargeV3Turbo): "every language, as spoken · faster"
        case (.meetings, .parakeetV3): "fast · english and european languages only · anything else comes out as nonsense"
        case (.meetings, .parakeetV2): "fastest · english only · anything else comes out as nonsense"
        case (.dictation, .whistle): "english and 6 european languages · a tiny download"
        case (.meetings, .whistle): "a tiny download · english and 6 european languages only · anything else comes out wrong"
        }
    }

    /// How long a dictation take waits on it before the press stops
    /// waiting (`TranscriptionDeadline`). Whisper large reads at a few
    /// times real time on a good day and slower cold, so a take gets its
    /// own length again; turbo, half that.
    var dictationPace: TranscriptionDeadline.Pace {
        switch self {
        case .parakeetV2, .parakeetV3, .whistle: .parakeet
        case .whisperLargeV3Turbo: .init(floor: .seconds(10), perSecondOfAudio: 0.5)
        case .whisperLargeV3: .init(floor: .seconds(20), perSecondOfAudio: 1)
        }
    }

    /// One download serves both jobs: a model on disk for dictation is on
    /// disk for meetings.
    var approximateSize: String {
        switch self {
        case .whisperLargeV3: "~2.9 gb"
        case .whisperLargeV3Turbo: "~1.5 gb"
        case .parakeetV3: "~470 mb"
        case .parakeetV2: "~460 mb"
        case .whistle: "~17 mb"
        }
    }

    /// WhisperKit's name for it, and the folder it lands in. Parakeet is
    /// not whisper's, and lives in FluidAudio's folder; nor is whistle.
    var whisperVariant: String? {
        switch self {
        case .whisperLargeV3: "openai_whisper-large-v3"
        case .whisperLargeV3Turbo: "openai_whisper-large-v3-v20240930_turbo"
        case .parakeetV3, .parakeetV2, .whistle: nil
        }
    }

    /// Whether a meeting's far side comes out as English. Turbo cannot
    /// translate, so it transcribes — Hindi arrives in Devanagari, Hinglish
    /// keeps its English words in Latin script. Parakeet and whistle have
    /// no translate task at all. Dictation never translates: you are the one talking.
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
