import Accelerate
import Foundation

/// how one press of the dictation key ended, and what the mic and the
/// pipeline did on the way there: the evidence a dead press leaves behind.
///
/// never any of the words. not what the engine heard, not what was pasted,
/// not a length that would give either away — a word count is the most a
/// record knows about them, which is what makes it safe to send to jass.
struct PressRecord: Equatable, Sendable, Codable {
    /// every way a press ends. the cap ending a take is not one of them: a
    /// capped take still ends in one of these, and `capped` says the rest.
    enum Outcome: Equatable, Sendable {
        /// ⌘V posted with focus where we left it (glossary: delivered).
        case delivered
        case leftOnPasteboard(LeftOnPasteboardReason)
        case heardNothing
        /// a brush of the key: too short to be a hold, or the first tap of
        /// a double tap, whose take the lock replaces.
        case brushed
        /// the engine threw; the samples are kept and a retry is offered.
        case couldNotTranscribe
        /// `esc`, the only way you throw an utterance away.
        case cancelled
        case interrupted(CaptureInterruption)
        /// the press was answered with a pill and never recorded.
        case refused(Refusal)
        case couldNotStartRecording
        case recordingLost
        /// the app took the take away: a setting that rebuilds the mic, or
        /// the speech model being switched or removed under it.
        case abandoned
        /// still transcribing so long after key-up that the next press
        /// dropped it and recorded instead.
        case droppedAsHung
    }

    enum Refusal: String, Equatable, Sendable, Codable {
        case meetingRunning = "meeting-running"
        case stillFinishing = "still-finishing"
        case modelNotReady = "model-not-ready"
        case microphonePermissionOff = "mic-permission-off"
        case noMicrophone = "no-microphone"
        /// the pill still offered a retry, but its samples had lapsed.
        case retryLapsed = "retry-lapsed"
    }

    /// milliseconds from key-down. nil is a stage the press never reached.
    struct Stages: Equatable, Sendable, Codable {
        var firstBuffer: Int?
        var keyUp: Int?
        var samplesReady: Int?
        var transcriptReady: Int?
        var cleaned: Int?
        var pastePosted: Int?
        var pasteCompleted: Int?
        var ended: Int?
    }

    var outcome: Outcome
    /// wall-clock key-down, so a record can be matched to a report.
    var startedAt: Date
    var mic: MicDescription?
    /// 16 kHz mono samples handed to the engine.
    var samples: Int?
    /// the loudest sample's absolute value. zero is a mic that sent silence.
    var peak: Float?
    var words: Int?
    var stages: Stages
    var engine: String
    /// the capture ceiling ended this take, not the finger.
    var capped: Bool
    /// a replay of samples the engine threw on, not a fresh recording.
    var retry: Bool
    /// the longest the main thread stalled while this press was in flight.
    var mainStallMs: Int?
}

// MARK: - the press in flight

extension PressRecord {
    /// one press while it is still in flight: instants, not offsets, until
    /// it ends.
    struct Draft {
        typealias Instant = ContinuousClock.Instant

        let keyDown: Instant
        let startedAt: Date
        let retry: Bool
        var mic: MicDescription?
        var firstBuffer: Instant?
        var keyUp: Instant?
        var samplesReady: Instant?
        var transcriptReady: Instant?
        var cleaned: Instant?
        var pastePosted: Instant?
        var pasteCompleted: Instant?
        /// held until the end so the peak is measured after the paste, not
        /// in front of it. a copy-on-write share of the pipeline's array.
        var samples: [Float]?
        var words: Int?
        var capped = false
        var mainStall: Duration?

        init(keyDown: Instant, startedAt: Date, retry: Bool = false) {
            self.keyDown = keyDown
            self.startedAt = startedAt
            self.retry = retry
        }

        func finished(
            _ outcome: Outcome,
            at ended: Instant,
            engine: String
        ) -> PressRecord {
            PressRecord(
                outcome: outcome,
                startedAt: startedAt,
                mic: mic,
                samples: samples?.count,
                peak: samples.map(Self.peak),
                words: words,
                stages: Stages(
                    firstBuffer: offset(firstBuffer),
                    keyUp: offset(keyUp),
                    samplesReady: offset(samplesReady),
                    transcriptReady: offset(transcriptReady),
                    cleaned: offset(cleaned),
                    pastePosted: offset(pastePosted),
                    pasteCompleted: offset(pasteCompleted),
                    ended: offset(ended)
                ),
                engine: engine,
                capped: capped,
                retry: retry,
                mainStallMs: mainStall.map(Self.milliseconds)
            )
        }

        private func offset(_ instant: Instant?) -> Int? {
            instant.map { Self.milliseconds(keyDown.duration(to: $0)) }
        }

        private static func milliseconds(_ duration: Duration) -> Int {
            Int(duration.inMilliseconds.rounded())
        }

        /// vDSP, not a loop: five minutes is 4.8 million samples.
        private static func peak(_ samples: [Float]) -> Float {
            samples.isEmpty ? 0 : vDSP.maximumMagnitude(samples)
        }
    }
}

// MARK: - names

extension PressRecord.Outcome {
    /// the outcome's name in the log, the file and the diagnostics.
    var name: String {
        switch self {
        case .delivered: "delivered"
        case .leftOnPasteboard: "left-on-pasteboard"
        case .heardNothing: "heard-nothing"
        case .brushed: "brushed"
        case .couldNotTranscribe: "couldnt-transcribe"
        case .cancelled: "cancelled"
        case .interrupted: "interrupted"
        case .refused: "refused"
        case .couldNotStartRecording: "couldnt-start-recording"
        case .recordingLost: "recording-lost"
        case .abandoned: "abandoned"
        case .droppedAsHung: "dropped-as-hung"
        }
    }

    /// the reason, for the three outcomes that carry one.
    var why: String? {
        switch self {
        case let .leftOnPasteboard(reason):
            Self.name(of: reason)
        case let .interrupted(reason):
            switch reason {
            case .deviceChanged: "mic-changed"
            case .systemPaused: "sleep-or-lock"
            }
        case let .refused(refusal):
            refusal.rawValue
        case .delivered, .heardNothing, .brushed, .couldNotTranscribe,
             .cancelled, .couldNotStartRecording, .recordingLost,
             .abandoned, .droppedAsHung:
            nil
        }
    }

    init?(name: String, why: String?) {
        switch (name, why) {
        case ("delivered", nil): self = .delivered
        case ("heard-nothing", nil): self = .heardNothing
        case ("brushed", nil): self = .brushed
        case ("couldnt-transcribe", nil): self = .couldNotTranscribe
        case ("cancelled", nil): self = .cancelled
        case ("couldnt-start-recording", nil): self = .couldNotStartRecording
        case ("recording-lost", nil): self = .recordingLost
        case ("abandoned", nil): self = .abandoned
        case ("dropped-as-hung", nil): self = .droppedAsHung
        case let ("left-on-pasteboard", why?):
            guard let reason = Self.leftOnPasteboardReasons.first(where: {
                Self.name(of: $0) == why
            }) else {
                return nil
            }
            self = .leftOnPasteboard(reason)
        case ("interrupted", "mic-changed"):
            self = .interrupted(.deviceChanged)
        case ("interrupted", "sleep-or-lock"):
            self = .interrupted(.systemPaused)
        case let ("refused", why?):
            guard let refusal = PressRecord.Refusal(rawValue: why) else {
                return nil
            }
            self = .refused(refusal)
        default:
            return nil
        }
    }

    private static let leftOnPasteboardReasons: [LeftOnPasteboardReason] = [
        .secureField,
        .focusChanged,
        .accessibilityUnavailable,
        .shortcutUnavailable,
        .cancelled,
        .pasteboardUnavailable,
    ]

    private static func name(of reason: LeftOnPasteboardReason) -> String {
        switch reason {
        case .secureField: "secure-field"
        case .focusChanged: "focus-changed"
        case .accessibilityUnavailable: "no-accessibility"
        case .shortcutUnavailable: "no-paste-shortcut"
        case .cancelled: "paste-cancelled"
        case .pasteboardUnavailable: "clipboard-busy"
        }
    }
}

/// one string on disk, `name` or `name:why`, so a record written today
/// still reads after a case is added.
extension PressRecord.Outcome: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let parts = raw.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).map(String.init)
        guard let outcome = Self(
            name: parts[0],
            why: parts.count > 1 ? parts[1] : nil
        ) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown press outcome \(raw)"
            )
        }
        self = outcome
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(why.map { "\(name):\($0)" } ?? name)
    }
}
