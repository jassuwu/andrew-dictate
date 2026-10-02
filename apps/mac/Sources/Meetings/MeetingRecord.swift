import Foundation

/// how one meeting ended, and what the capture and the engine did on the
/// way there: the evidence a lost meeting or a hollow transcript leaves.
///
/// never any of the words. not what was said, not the path to the file it
/// went into — counts and times are all a record knows about the talk,
/// which is what makes it safe to send to jass.
struct MeetingRecord: Equatable, Sendable, Codable {
    /// every way a meeting ends. a recovery is not one of them: it ends in
    /// one of these like any other, and `recovered` says the rest.
    enum Outcome: Equatable, Sendable {
        /// the transcript is on disk.
        case saved
        /// the transcript is on disk and the coverage check found it thin,
        /// read again or not: it says `complete: false` and why, and the
        /// audio is kept.
        case savedThin
        /// nothing was captured, so there was nothing to write.
        case nothingKept(NothingKept)
        /// the model could not be made or would not load. the audio stays
        /// for the next launch, which writes it out as a recovery.
        case modelFailed
        /// the transcript could not be written where it was asked to go.
        /// the audio stays for the next launch.
        case couldNotWrite
        /// a recovery tried to write a spool out and the model failed it.
        /// the attempt is counted, and the next launch tries again.
        case couldNotRecover
        /// the second failure of a recovery: the spool is kept, out of the
        /// retry loop, and settings says it is there.
        case setAside
        /// an earlier build's: a recovery found audio it could not read at
        /// all, and let it go. nothing writes it now — that audio is set
        /// aside — but a record that says so still reads.
        case spoolUnreadable
        /// a recovery found audio it could not read at all. it is set aside
        /// with the rest, kept and out of the retry loop, and settings says
        /// it is there.
        case setAsideUnreadable
        /// a recovery found no meeting model on this mac to read the audio
        /// with. nothing is counted and nothing is set aside: the spool
        /// waits for a later launch. one being tried again from settings
        /// goes back aside instead, so the line that counts it still does.
        case waitingForModel
    }

    enum NothingKept: Equatable, Sendable {
        /// the start sound never came back through the tap: a permission
        /// that is off, or a tap that was dead on arrival.
        case tapNeverHeard
        /// stopped before the tap had been heard, so nothing is known to
        /// be wrong with it.
        case stoppedBeforeCapture
        /// a recovery found audio that reads and has nothing in it: a
        /// meeting that never captured a sample.
        case spoolEmpty
    }

    /// what one side of the call said, as counts.
    struct Side: Equatable, Sendable, Codable {
        var turns = 0
        var words = 0
    }

    var outcome: Outcome
    /// the app as shown to people: "zoom", "chrome".
    var app: String
    /// the meeting model, by the name the spool and the file use.
    var model: String
    /// wall-clock start, so a record can be matched to a report.
    var startedAt: Date
    /// seconds of the meeting, gaps included.
    var durationS: Double
    /// stretches the tap was lost for, and the seconds of the meeting they
    /// took between them.
    var gaps = 0
    var gapsLostS: Double = 0
    var you = Side()
    var them = Side()
    /// seconds from the stop to the transcript being on disk. nil when it
    /// never got there, and for a recovery, which has no stop of its own.
    var toDiskS: Double?
    /// the ending is a recovery's: the audio came from a spool a past run
    /// left, found at launch. true of a recovery that failed too.
    var recovered = false
    /// what happened on the way, in order, each with the meeting time it
    /// happened at.
    var events: [Event] = []
    /// the engine's own count of its work, for an engine that keeps one.
    var decoding: Decoding?
    /// what the coverage check made of the transcript, for a meeting that
    /// got as far as being checked.
    var coverage: Coverage?
    /// whether the meeting's audio was kept after its transcript was
    /// written, and until when. kept with no date is kept until you delete
    /// it: the transcript did not cover the meeting.
    var audioKept = false
    var audioKeptUntil: Date?
}

// MARK: - coverage

extension MeetingRecord {
    /// the coverage check's result and the numbers it was reached from:
    /// counts and seconds, never what was said.
    struct Coverage: Equatable, Sendable, Codable {
        var result: CoverageCheck.Result
        /// the check's reason, in the front matter's words: why it stayed
        /// thin, or, for a pass after a rerun, why it was read again.
        var reason: String?
        /// seconds of speech the transcriber cut, per side, and of that the
        /// seconds it never read. nil for an engine that keeps no count.
        var speechYouS: Double?
        var speechThemS: Double?
        var unreadYouS: Double?
        var unreadThemS: Double?
        /// `you` stretches let go as the far side coming back through the
        /// mic: not speech of yours, and not counted as any.
        var bleed: Int?
        /// how long the far side was louder than the silence floor, from
        /// the spool and not the transcriber.
        var farSideLoudS: Double = 0
    }
}

// MARK: - decoding

extension MeetingRecord {
    /// what a stretch-by-stretch engine's decoding came to: counts and
    /// seconds, never what any stretch said.
    struct Decoding: Equatable, Sendable, Codable {
        var decodedYou = 0
        var decodedThem = 0
        /// stretches the engine threw on twice. their words are not in the
        /// transcript.
        var failed = 0
        /// how far behind the meeting the decoding ran: the worst of the
        /// meeting, and the latest.
        var mostBehindS: Double = 0
        var lastBehindS: Double = 0
    }
}

// MARK: - events

extension MeetingRecord {
    /// something a meeting went through, as a short fixed label. a string
    /// underneath, not a case list: a label a later build adds is still a
    /// label to an earlier one reading the file, and adding one is a line.
    struct Label: RawRepresentable, Hashable, Sendable, Codable {
        let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// the tap stopped delivering and is being rebuilt.
        static let gapBegan = Label(rawValue: "gap-began")
        /// the rebuilt tap was heard again.
        static let gapEnded = Label(rawValue: "gap-ended")
        /// the tap could not be rebuilt, and the meeting ended there.
        static let rebuildFailed = Label(rawValue: "rebuild-failed")
    }

    struct Event: Equatable, Sendable, Codable {
        var label: Label
        /// seconds into the meeting.
        var atS: Double

        init(_ label: Label, atS: Double) {
            self.label = label
            self.atS = atS
        }
    }
}

// MARK: - reading an older record

/// the file outlives the build that wrote it, so a field added later must
/// not make an earlier record unreadable. what a record cannot be without —
/// how it ended, what it was, when it began, how long — is required; every
/// other field is read if it is there and is what it would have been had
/// nothing happened if it is not. a later field is a property and one line
/// here, in its own part's reader if it is inside one.
extension MeetingRecord {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            outcome: try container.decode(Outcome.self, forKey: .outcome),
            app: try container.decode(String.self, forKey: .app),
            model: try container.decode(String.self, forKey: .model),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            durationS: try container.decode(Double.self, forKey: .durationS),
            gaps: try container.decodeIfPresent(Int.self, forKey: .gaps) ?? 0,
            gapsLostS: try container.decodeIfPresent(Double.self, forKey: .gapsLostS) ?? 0,
            you: try container.decodeIfPresent(Side.self, forKey: .you) ?? Side(),
            them: try container.decodeIfPresent(Side.self, forKey: .them) ?? Side(),
            toDiskS: try container.decodeIfPresent(Double.self, forKey: .toDiskS),
            recovered: try container.decodeIfPresent(Bool.self, forKey: .recovered) ?? false,
            events: try container.decodeIfPresent([Event].self, forKey: .events) ?? [],
            decoding: try container.decodeIfPresent(Decoding.self, forKey: .decoding),
            // a coverage this build cannot make out — a result it has no
            // name for — is a coverage it does not have, not a record lost.
            coverage: (try? container.decodeIfPresent(Coverage.self, forKey: .coverage)) ?? nil,
            audioKept: try container.decodeIfPresent(Bool.self, forKey: .audioKept) ?? false,
            audioKeptUntil: try container.decodeIfPresent(Date.self, forKey: .audioKeptUntil)
        )
    }
}

extension MeetingRecord.Coverage {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            result: try container.decode(CoverageCheck.Result.self, forKey: .result),
            reason: try container.decodeIfPresent(String.self, forKey: .reason),
            speechYouS: try container.decodeIfPresent(Double.self, forKey: .speechYouS),
            speechThemS: try container.decodeIfPresent(Double.self, forKey: .speechThemS),
            unreadYouS: try container.decodeIfPresent(Double.self, forKey: .unreadYouS),
            unreadThemS: try container.decodeIfPresent(Double.self, forKey: .unreadThemS),
            bleed: try container.decodeIfPresent(Int.self, forKey: .bleed),
            farSideLoudS: try container.decodeIfPresent(Double.self, forKey: .farSideLoudS) ?? 0
        )
    }
}

extension MeetingRecord.Side {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            turns: try container.decodeIfPresent(Int.self, forKey: .turns) ?? 0,
            words: try container.decodeIfPresent(Int.self, forKey: .words) ?? 0
        )
    }
}

extension MeetingRecord.Decoding {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            decodedYou: try container.decodeIfPresent(Int.self, forKey: .decodedYou) ?? 0,
            decodedThem: try container.decodeIfPresent(Int.self, forKey: .decodedThem) ?? 0,
            failed: try container.decodeIfPresent(Int.self, forKey: .failed) ?? 0,
            mostBehindS: try container.decodeIfPresent(Double.self, forKey: .mostBehindS) ?? 0,
            lastBehindS: try container.decodeIfPresent(Double.self, forKey: .lastBehindS) ?? 0
        )
    }
}

// MARK: - from a meeting

extension MeetingRecord {
    /// the record of a meeting that has ended, worked out from what it left
    /// behind. the turns are counted and let go: nothing of them is kept.
    init(
        _ outcome: Outcome,
        app: String,
        model: MeetingModel,
        startedAt: Date,
        duration: Duration,
        gaps: [MeetingSession.Gap] = [],
        turns: [MeetingTurn] = [],
        toDisk: Duration? = nil,
        recovered: Bool = false,
        events: [Event] = [],
        tally: StretchTally? = nil,
        coverage: Coverage? = nil,
        audioKept: Bool = false,
        audioKeptUntil: Date? = nil
    ) {
        self.init(
            outcome: outcome,
            app: app,
            model: model.rawValue,
            startedAt: startedAt,
            durationS: Self.seconds(duration),
            gaps: gaps.count,
            gapsLostS: Self.seconds(gaps.reduce(.zero) { $0 + $1.duration }),
            you: Self.side(.you, in: turns),
            them: Self.side(.them, in: turns),
            toDiskS: toDisk.map(Self.seconds),
            recovered: recovered,
            events: events,
            decoding: tally.map {
                Decoding(
                    decodedYou: $0.decodedYou,
                    decodedThem: $0.decodedThem,
                    failed: $0.failed,
                    mostBehindS: Self.seconds($0.mostBehind),
                    lastBehindS: Self.seconds($0.lastBehind))
            },
            coverage: coverage,
            audioKept: audioKept,
            audioKeptUntil: audioKeptUntil
        )
    }

    private enum Who {
        case you
        case them
    }

    /// whitespace-separated, the way the transcript's own `words:` counts,
    /// so the two numbers are the same number.
    private static func side(_ who: Who, in turns: [MeetingTurn]) -> Side {
        var side = Side()
        for turn in turns {
            switch (turn.speaker, who) {
            case (.you, .you), (.them, .them):
                side.turns += 1
                side.words += turn.text.split(whereSeparator: \.isWhitespace).count
            case (.you, .them), (.them, .you):
                break
            }
        }
        return side
    }

    /// to a tenth: a gap of four and a half seconds is not four, and a
    /// stored record is not the place for seventeen digits.
    fileprivate static func seconds(_ duration: Duration) -> Double {
        (duration.totalSeconds * 10).rounded() / 10
    }
}

extension MeetingRecord.Coverage {
    /// the check's result, from the reading it settled on: the speech in
    /// the transcriber's count, when it keeps one, and the far side as the
    /// spool heard it.
    init(
        _ result: CoverageCheck.Result,
        reason: String?,
        tally: StretchTally?,
        farSideLoud: Duration
    ) {
        let seconds = MeetingRecord.seconds
        self.init(
            result: result,
            reason: reason,
            speechYouS: tally.map { seconds($0.speechYou) },
            speechThemS: tally.map { seconds($0.speechThem) },
            unreadYouS: tally.map { seconds($0.speechYou - $0.readYou) },
            unreadThemS: tally.map { seconds($0.speechThem - $0.readThem) },
            bleed: tally?.bleed,
            farSideLoudS: seconds(farSideLoud))
    }
}

// MARK: - the meeting as it ends

extension MeetingRecord {
    /// what a meeting jots down about itself, as it runs and as it stops,
    /// for the record it will leave: the things the file has no room for.
    struct Notes: Sendable {
        /// the wall at the stop, for the seconds to the file.
        var stopped: ContinuousClock.Instant?
        /// how far into itself it was when it was let go. a meeting that
        /// kept nothing has no recording to say.
        var ran: Duration = .zero
        var events: [Event] = []

        mutating func note(_ label: Label, at: Duration) {
            events.append(Event(label, atS: MeetingRecord.seconds(at)))
        }
    }
}

// MARK: - names

extension MeetingRecord.Outcome {
    /// the outcome's name in the log, the file and the diagnostics.
    var name: String {
        switch self {
        case .saved: "saved"
        case .savedThin: "saved-thin"
        case .nothingKept: "nothing-kept"
        case .modelFailed: "model-failed"
        case .couldNotWrite: "couldnt-write"
        case .couldNotRecover: "couldnt-recover"
        case .setAside: "set-aside"
        case .spoolUnreadable: "spool-unreadable"
        case .setAsideUnreadable: "set-aside-unreadable"
        case .waitingForModel: "waiting-for-model"
        }
    }

    /// the reason, for the one outcome that carries one.
    var why: String? {
        switch self {
        case .nothingKept(.tapNeverHeard): "tap-never-heard"
        case .nothingKept(.stoppedBeforeCapture): "stopped-before-capture"
        case .nothingKept(.spoolEmpty): "spool-empty"
        case .saved, .savedThin, .modelFailed, .couldNotWrite, .couldNotRecover, .setAside,
             .spoolUnreadable, .setAsideUnreadable, .waitingForModel:
            nil
        }
    }

    init?(name: String, why: String?) {
        switch (name, why) {
        case ("saved", nil): self = .saved
        case ("saved-thin", nil): self = .savedThin
        case ("model-failed", nil): self = .modelFailed
        case ("couldnt-write", nil): self = .couldNotWrite
        case ("couldnt-recover", nil): self = .couldNotRecover
        case ("set-aside", nil): self = .setAside
        case ("spool-unreadable", nil): self = .spoolUnreadable
        case ("set-aside-unreadable", nil): self = .setAsideUnreadable
        case ("waiting-for-model", nil): self = .waitingForModel
        case ("nothing-kept", "tap-never-heard"): self = .nothingKept(.tapNeverHeard)
        case ("nothing-kept", "stopped-before-capture"): self = .nothingKept(.stoppedBeforeCapture)
        case ("nothing-kept", "spool-empty"): self = .nothingKept(.spoolEmpty)
        default: return nil
        }
    }
}

/// one string on disk, `name` or `name:why`, so a record written today
/// still reads after a case is added.
extension MeetingRecord.Outcome: Codable {
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
                debugDescription: "unknown meeting outcome \(raw)"
            )
        }
        self = outcome
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(why.map { "\(name):\($0)" } ?? name)
    }
}
