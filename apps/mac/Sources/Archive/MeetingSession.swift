import Foundation

/// One meeting recording, from the moment you start it to the moment you stop.
///
/// ADR 0023. Every design choice here is a refusal to be clever:
///
/// - **Nothing starts a recording but you.** There is deliberately no event for
///   "a meeting app took the microphone". The app does not observe which
///   processes hold the mic, in either direction. A false start records
///   something the user never meant to record, which is not an ordinary bug,
///   and avoiding it entirely is worth more than saving a menu click.
/// - **Nothing stops it but you**, except a nudge when it has been quiet for a
///   long time — and a nudge asks, it does not act. A recording that stops on
///   its own is a recording that stopped without anyone knowing.
/// - **Dictation is refused while a meeting runs, and says so.** Refusing
///   silently would leave the hotkey apparently dead for two hours, which is
///   SPEC §4's forbidden shape: a failure indistinguishable from nothing
///   happening.
struct MeetingSession {
    enum State: Equatable, Sendable {
        case idle
        /// Capture is open and the start sound is playing (ADR 0021). Nothing
        /// is trusted until the tap has heard it.
        case provingItCanHear
        case recording
        /// The tap went all-zero after having worked (002 §6). Still a live
        /// meeting; audio during this window is lost.
        case rebuilding
        /// The probe was never heard at the start: nothing was ever captured
        /// and there is no meeting to keep running. A tap lost later is a
        /// `Problem`, never this.
        case cannotHear
    }

    /// Something wrong that the meeting records through rather than ends
    /// on, named so it can be shown until it clears. Several can stand at
    /// once, one of each kind.
    enum Problem: Equatable, Sendable {
        /// The tap could not be rebuilt: the far side is not being heard,
        /// and the gap stays open while it is not. Your side still is.
        case cannotHearTheCall
        /// The same, and the mic could not be kept going on its own
        /// either: nothing is being recorded while the tap is tried again.
        case cannotHearAnything
        /// The mic has handed over nothing but silence while the far side
        /// talked. Named, when the source knows which mic it is.
        case cannotHearYourMic(String?)
        /// The audio could not be written to the spool. The live
        /// transcript still runs; it is the audio that is not being kept.
        case cannotSaveTheAudio
        /// The disk the spool is on is nearly full.
        case diskNearlyFull

        /// Which problem it is, whatever it names. In order of how much
        /// of the meeting each costs, the worst first.
        enum Kind: Comparable, Sendable {
            case cannotHearTheCall
            case cannotHearYourMic
            case cannotSaveTheAudio
            case diskNearlyFull
        }

        var kind: Kind {
            switch self {
            case .cannotHearTheCall, .cannotHearAnything: .cannotHearTheCall
            case .cannotHearYourMic: .cannotHearYourMic
            case .cannotSaveTheAudio: .cannotSaveTheAudio
            case .diskNearlyFull: .diskNearlyFull
            }
        }
    }

    enum DictationResponse: Equatable, Sendable {
        case allow
        case refuseAndSayWhy
    }

    /// A stretch of the meeting that was not captured.
    struct Gap: Equatable, Sendable {
        let began: Duration
        let ended: Duration

        var duration: Duration { ended - began }
    }

    struct Recording: Equatable, Sendable {
        let duration: Duration
        let gaps: [Gap]

        /// SPEC §4 extended to recordings: one with holes in it must never be
        /// handed back looking whole.
        var isComplete: Bool { gaps.isEmpty }
    }

    /// How long the tap may hear nothing before the user is asked whether this
    /// meeting is still happening. Long, because the answer to "are you still
    /// there" being wrong is an interruption in a real meeting.
    let quietNudgeAfter: Duration

    private(set) var state: State = .idle
    /// Only ever while recording or rebuilding, one of each kind, the
    /// worst first; cleared by the stop.
    private(set) var problems: [Problem] = []

    /// The worst of them, for wherever there is room to say one.
    var problem: Problem? {
        problems.first
    }
    /// A meeting stopped before the probe was heard has nothing worth
    /// keeping; one that has heard anything at all has a recording, holes
    /// and all. This is the same "has it ever delivered audio" signal ADR
    /// 0021 uses to tell a denied grant from a dead tap, doing the same job
    /// one layer up.
    private var everCaptured = false
    private var gaps: [Gap] = []
    private var silenceBegan: Duration?
    private var lastActivity: Duration = .zero

    init(quietNudgeAfter: Duration) {
        self.quietNudgeAfter = quietNudgeAfter
    }

    // MARK: - the user's two buttons

    mutating func start() {
        guard state == .idle else {
            return
        }
        state = .provingItCanHear
        problems = []
        everCaptured = false
        gaps = []
        silenceBegan = nil
        lastActivity = .zero
    }

    /// Returns what was captured, or nil if there was never anything to keep.
    mutating func finish(at elapsed: Duration) -> Recording? {
        defer {
            state = .idle
            problems = []
        }
        guard everCaptured else {
            return nil
        }

        var gaps = gaps
        if let silenceBegan {
            gaps.append(Gap(began: silenceBegan, ended: elapsed))
        }
        return Recording(duration: elapsed, gaps: gaps)
    }

    // MARK: - what the tap reports

    mutating func heardTheProbe() {
        guard state == .provingItCanHear else {
            return
        }
        everCaptured = true
        state = .recording
    }

    /// The start sound could not be played — no output device, a player
    /// that would not start — so the tap was never asked, and its silence
    /// proves nothing. "Could not check" is not "cannot hear": the meeting
    /// records, and the tap is checked later the way any quiet one is.
    mutating func couldNotPlayTheProbe() {
        guard state == .provingItCanHear else {
            return
        }
        everCaptured = true
        state = .recording
    }

    mutating func neverHeardTheProbe() {
        guard state == .provingItCanHear else {
            return
        }
        state = .cannotHear
    }

    mutating func heardAudio(at elapsed: Duration) {
        lastActivity = elapsed
    }

    mutating func tapWentSilent(at elapsed: Duration) {
        guard state == .recording else {
            return
        }
        state = .rebuilding
        silenceBegan = elapsed
    }

    /// A recovered tap proves the tap is alive — it is our own probe tone it
    /// heard — not that anyone in the room spoke. So it deliberately does not
    /// touch the quiet clock: `heardAudio` and `keepGoing` are the only two
    /// things that do, or the hour of silence could never come round.
    mutating func tapRecovered(at elapsed: Duration) {
        guard state == .rebuilding, let began = silenceBegan else {
            return
        }
        gaps.append(Gap(began: began, ended: elapsed))
        silenceBegan = nil
        state = .recording
    }

    // MARK: - problems

    /// A problem names what is wrong while the meeting goes on. Before the
    /// tap has been heard there is no meeting to go on with, and after the
    /// stop there is nothing to name. One of a kind already standing gives
    /// way to it. Says whether anything changed: the same problem said
    /// again is not news.
    @discardableResult
    mutating func problemBegan(_ problem: Problem) -> Bool {
        guard state == .recording || state == .rebuilding,
              !problems.contains(problem)
        else {
            return false
        }
        problems.removeAll { $0.kind == problem.kind }
        problems.append(problem)
        problems.sort { $0.kind < $1.kind }
        return true
    }

    /// The problem of this kind is over. Returns the one that stood, or nil
    /// when none did.
    @discardableResult
    mutating func problemCleared(_ kind: Problem.Kind) -> Problem? {
        let standing = problem(kind)
        problems.removeAll { $0.kind == kind }
        return standing
    }

    /// The problem of this kind, while one stands.
    func problem(_ kind: Problem.Kind) -> Problem? {
        problems.first { $0.kind == kind }
    }

    // MARK: - the two interactions the prototype argued about

    func dictationRequest() -> DictationResponse {
        switch state {
        case .recording, .rebuilding: .refuseAndSayWhy
        case .idle, .provingItCanHear, .cannotHear: .allow
        }
    }

    /// Asks; never acts. Answering resets the timer, so an answered nudge does
    /// not come straight back.
    func shouldNudge(at elapsed: Duration) -> Bool {
        guard state == .recording || state == .rebuilding else {
            return false
        }
        return elapsed - lastActivity > quietNudgeAfter
    }

    mutating func keepGoing(at elapsed: Duration) {
        lastActivity = elapsed
    }
}
