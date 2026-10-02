import Accelerate
import Foundation
import OSLog

/// file scope, under the categories these failures have always logged to:
/// the recorder's lines and the pipeline's.
private let audioLogger = Logger(
    subsystem: AppIdentity.loggingSubsystem,
    category: "audio"
)
private let pipelineLogger = Logger(
    subsystem: AppIdentity.loggingSubsystem,
    category: "pipeline"
)

/// What one utterance did that the rest of the app shows, plays or keeps.
/// The coordinator turns these into the HUD, the sounds, the archive and the
/// menu, the way it turns `MeetingEvent` into them.
enum UtteranceEvent: Equatable, Sendable {
    /// `fastDismiss` is a brush, a cancel or a failure: a flicker, not the
    /// afterglow's slow cut.
    case state(UtteranceMachine.State, fastDismiss: Bool)
    /// the take's first audio landed: the mic is hearing you. a recording
    /// lamp is warming until this, and lit from it.
    case hearing
    case chime(UtteranceMachine.Chime)
    /// an exceptional message, and how long it stays.
    case pill(String, duration: TimeInterval)
    case locked(Bool)
    /// whether the display has to stay awake: true while the mic is live,
    /// false the moment it is asked to stop or is thrown away. a long
    /// dictation is minutes of talking with no hand on anything, and an
    /// idle display that sleeps under it locks the mac.
    case keepAwake(Bool)
    /// one utterance's stage timings, finished or cancelled.
    case timelineCompleted(UtteranceTimeline)
    /// a dictation worth keeping, for whoever keeps dictations.
    case archiveRecord(UtteranceTimeline, heard: String, inserted: String)
    /// words that went out to you, for the running count.
    case dictated(String)
    /// the engine's own words, and what the cleaner made of them.
    case transcribed(heard: String, inserted: String)
    /// whether the dictation the engine threw on can still be tried again.
    case retryOffered(Bool)
    /// the mic would not start; the next press must build a fresh one.
    case microphoneDropped
    /// a take the engine never answered: a slow moment or a wedge, and
    /// only the engine's keeper can ask it which, without waiting on it.
    case engineSuspect
    /// takes in a row the engine never answered: it has stopped, and only
    /// a restart brings it back.
    case engineUnresponsive
    /// how one press ended, whatever the ending: exactly one per press.
    case pressEnded(PressRecord)
}

/// One utterance at a time, from key-down to its outcome: idle → recording →
/// transcribing → delivered, left on the pasteboard, or a pill saying why.
/// Holds locked recording, the capture ceiling, `esc`, the transcribing
/// repress rule, the retry buffer and the interruption path.
///
/// Everything with a system in it — the mic, the engine, AX and the
/// pasteboard, the clock — is injected, and every effect leaves through
/// `onEvent`, so a press can be driven to its end in a test with fakes
/// (`MeetingCoordinator` is the pattern). The engine's lifecycle is the
/// coordinator's; the state it shows is this machine's, so every rule below
/// reads one value.
@MainActor
final class UtteranceMachine {
    enum State: Equatable, Sendable {
        case idle
        case prewarming
        case recording
        case transcribing

        var displayName: String {
            switch self {
            // Said the way a person would say it. "prewarming" and "idle" are
            // words for whoever wrote the state machine — the menu is read by
            // someone who wants to know whether they can talk yet.
            case .idle:
                "ready"
            case .prewarming:
                "loading the speech model…"
            case .recording:
                "listening"
            case .transcribing:
                "writing it out…"
            }
        }

        /// the panel's view of it: to the layout engine idle and recording
        /// are both a wave, and the panel has to tell them apart.
        var lamp: HUDLampState {
            switch self {
            case .idle:
                .idle
            case .prewarming:
                .prewarming
            case .recording:
                .recording
            case .transcribing:
                .transcribing
            }
        }
    }

    enum Chime: Equatable, Sendable {
        case start
        case end
    }

    /// the app's half of a press: a mic to record with, or why not.
    enum MicrophoneAnswer {
        case ready(any MicCapture)
        /// the app has already said why, in a pill of its own; the machine
        /// only writes it down.
        case refused(PressRecord.Refusal)
    }

    private(set) var state: State = .idle

    var onEvent: (@MainActor (UtteranceEvent) -> Void)?
    /// asked once per press, after the machine's own answers to it (a retry
    /// on offer, a sentence still being written out). it is the app's say —
    /// a speech model still loading, a missing grant, no input device.
    var microphoneForPress: (@MainActor () -> MicrophoneAnswer)?
    /// whether a pill is on screen right now. only the HUD knows: its own
    /// timing, the setup window and the next state change all clear it.
    var isPillShowing: (@MainActor () -> Bool)?
    /// which speech model is answering, for the press log. the engine's
    /// lifecycle is the coordinator's, so is the name.
    var engineVersion: (@MainActor () -> String)?

    /// One cleaner, kept. Its nineteen regexes — plus one per taught word —
    /// compile on construction, and that used to happen on the main actor
    /// between transcript and paste, growing with the dictionary. Rebuilt
    /// only when the dictionary or the cleanup toggle changes.
    var cleaner = DeterministicCleaner(entries: [], fullCleanup: true)

    private let engine: any TranscriptionEngine
    private let inserter: any Inserter
    private let clock: any UtteranceClock
    /// how long the mic gets to start, or to stop, before the press stops
    /// waiting on it. a healthy one answers in tens of milliseconds.
    static let microphoneDeadline = Duration.milliseconds(1_500)
    /// how long a mic that answered gets to send its first audio. a
    /// healthy one is heard within a tap buffer, about a tenth of that. a
    /// bluetooth headset is the exception: macOS moves it to its call
    /// profile only once it is opened, and that switch alone can run past
    /// a second — a second of silence there is the switch, not a dead mic.
    static func firstAudioDeadline(
        for transport: MicDescription.Transport?
    ) -> Duration {
        switch transport {
        case .bluetooth, .continuity:
            .seconds(3)
        default:
            .seconds(1)
        }
    }
    /// the least a take must hand back to be one: a tenth of a second at
    /// 16 kHz.
    static let usableSamples = 1_600
    /// a key let go inside this asked no question: the pipeline's own
    /// threshold for an empty transcript that ends in silence.
    private static let brushLimit = Duration.milliseconds(300)
    private let dictionary: @MainActor () -> [DictionaryEntry]
    private let ownBundleIdentifier: String?
    /// how long the lamp's afterglow runs (`HUDWaveMotion.coolDuration`).
    private let coolDuration: TimeInterval

    /// the mic of the press in flight, from key-down until it has been
    /// told to stop or cancel. every ending goes through here — stopped,
    /// cancelled or given up on — so the display's keep-awake follows it
    /// and no ending can forget to let the display sleep.
    private var capture: Capture? {
        didSet {
            keepDisplayAwake(capture.map { !$0.isEnding } ?? false)
        }
    }
    private var isKeepingDisplayAwake = false
    private var captureSequence: UInt64 = 0
    /// the start still out, whichever press asked for it, and the deadline
    /// it has to meet.
    private var pendingStart: UInt64?
    private var startDeadline: Task<Void, Never>?
    private var stopDeadline: Task<Void, Never>?
    /// the live mic of the press in flight, not heard yet.
    private var firstAudioWait: Task<Void, Never>?
    /// a double-tapped key leaves nothing to hold, so nothing to feel. the
    /// HUD has to carry the difference for as long as the capture runs.
    private var isRecordingLocked = false
    private var activeFocusAnchor: (any InsertionAnchor)?
    private var pipelineTask: Task<Void, Never>?
    /// how long the engine has left to answer the take in flight
    /// (`TranscriptionDeadline`).
    private var transcriptionDeadline: Task<Void, Never>?
    /// takes in a row the engine never answered. one is worth a check; a
    /// second, with nothing answered in between, is an engine that stopped.
    private var unansweredTakes = 0
    /// the start chime, held back 120 ms so a discarded capture can cancel it
    private var startCueTask: Task<Void, Never>?
    private var retryBuffer = RetryBuffer()
    private var retryExpiryTask: Task<Void, Never>?
    private var canRetryLastFailure = false
    private var pipelineGeneration = 0
    private var stateGeneration: UInt64 = 0
    private var transcribingBeganAt: ContinuousClock.Instant?
    /// the cap ended this take, not the user's finger. the pill that says
    /// so has to ride the paste, so the fact outlives the stop.
    private var capForcedEnd = false
    /// the lock came down on this take, recording or transcribing: what it
    /// heard is copied when it is written out, never pasted.
    private var copiesInsteadOfPasting = false
    /// asleep or locked: nobody is there to read a pill, so the last one
    /// said waits for `systemResumed`, and no deadline runs out meanwhile.
    private var isSystemPaused = false
    /// the deadlines' view of it. settable so a test can send the mac away
    /// without a lock screen.
    var isAway: Bool {
        get { isSystemPaused }
        set { isSystemPaused = newValue }
    }
    private var heldPill: (message: String, duration: TimeInterval)?
    private var timelineSequence: UInt64 = 0
    private var activeTimeline: UtteranceTimelineBuilder?
    /// Held between delivery and the timeline completing, because that is the
    /// one place that knows whether anything actually reached the page.
    private var pendingArchiveText: (heard: String, inserted: String)?
    /// the press in flight, for its record. apart from the timeline, which
    /// only finished or cancelled takes complete: every ending gets one of
    /// these, and `endPress` is the only way out of it.
    private var press: PressRecord.Draft?

    init(
        engine: any TranscriptionEngine,
        inserter: any Inserter,
        clock: any UtteranceClock = ContinuousUtteranceClock(),
        dictionary: @escaping @MainActor () -> [DictionaryEntry],
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        coolDuration: TimeInterval
    ) {
        self.engine = engine
        self.inserter = inserter
        self.clock = clock
        self.dictionary = dictionary
        self.ownBundleIdentifier = ownBundleIdentifier
        self.coolDuration = coolDuration
    }

    // MARK: - the engine's say over the lamp

    /// the speech model is loading: the ember.
    func enginePreparing() {
        setState(.prewarming)
    }

    /// the speech model is ready, failed, or was never asked for.
    func engineSettled() {
        setState(.idle)
    }

    // MARK: - the key

    func keyDown() {
        // keys only reach the app from a session someone is sitting at:
        // a press is proof the mac is back, even if the unlock never said.
        systemResumed()
        // a take already running is the same hold arriving twice, not a new
        // press, and the mic it holds is not the app's to hand out again.
        // one whose mic is still being stopped is the last sentence on its
        // way to the page, and the key says why it is deaf.
        if state == .recording {
            if capture?.isEnding == true {
                flashNotice("still finishing the last one", duration: 1.4)
                refuse(.stillFinishing)
            }
            return
        }
        capForcedEnd = false
        // the pill still says the last one failed and the samples are still
        // here: this press means "that one", not "a new one". keyUp's state
        // guard makes the eventual key release a no-op.
        if isPillShowing?() == true, canRetryLastFailure {
            if !retryLastFailure() {
                // the pill still offered it, but the samples had lapsed
                // under it: the press is spent and nothing answers it.
                refuse(.retryLapsed)
            }
            return
        }
        if state == .transcribing {
            let elapsed = transcribingBeganAt.map {
                seconds($0.duration(to: clock.now))
            } ?? .infinity
            switch TranscribingRepress.response(transcribingFor: elapsed) {
            case .refuseAndSayWhy:
                // the sentence is still on its way to the page. discarding
                // it silently left no text, no pill and no history row —
                // spec §4's forbidden shape, wearing nothing at all.
                flashNotice("still finishing the last one", duration: 1.4)
                refuse(.stillFinishing)
                return
            case .dropAndRestart:
                invalidatePipeline()
                setState(.idle)
                endPress(.droppedAsHung)
                // the same evidence a timeout leaves.
                emit(.engineSuspect)
            }
        }

        let microphone: any MicCapture
        switch microphoneForPress?() ?? .refused(.modelNotReady) {
        case let .ready(answer):
            microphone = answer
        case let .refused(why):
            refuse(why)
            return
        }
        guard state == .idle else {
            // a model still loading is the app's to answer.
            if state == .prewarming {
                refuse(.modelNotReady)
            }
            return
        }

        // a new take is the sentence you care about now; the lost one stops
        // being offered.
        clearRetry()
        copiesInsteadOfPasting = false
        timelineSequence &+= 1
        let timelineID = timelineSequence
        let keyDown = clock.now
        activeTimeline = UtteranceTimelineBuilder(
            id: timelineID,
            keyDown: keyDown
        )
        press = PressRecord.Draft(keyDown: keyDown, startedAt: Date())
        // the standby anchor. the one that decides the paste is taken at
        // key-up; this is what stands in if AX hands back nothing then, or
        // if by then the frontmost window is one of ours.
        activeFocusAnchor = inserter.captureAnchor()
        captureSequence &+= 1
        let captureID = captureSequence
        capture = Capture(id: captureID, microphone: microphone)
        // the lamp before the mic: a device slow to open, or one still
        // settling after a monitor or the lid, must never make the press
        // look dead.
        setState(.recording)
        startMicrophone(microphone, id: captureID, timelineID: timelineID)
    }

    private func startMicrophone(
        _ microphone: any MicCapture,
        id: UInt64,
        timelineID: UInt64
    ) {
        pendingStart = id
        startDeadline?.cancel()
        startDeadline = Task { @MainActor [weak self, clock] in
            try? await clock.sleep(for: Self.microphoneDeadline)
            guard !Task.isCancelled else {
                return
            }
            self?.microphoneStartTimedOut(id)
        }
        // immediate: the start is asked for inside this key-down, not a
        // run-loop turn later, and a mic that answers at once is live
        // before key-down returns.
        Task.immediate { @MainActor [weak self] in
            do {
                try await microphone.start { [weak self] instant in
                    self?.firstBufferLanded(
                        id,
                        at: instant,
                        timelineID: timelineID
                    )
                }
                self?.microphoneStarted(id)
            } catch {
                self?.microphoneFailedToStart(id, error: error)
            }
        }
    }

    private func microphoneStarted(_ id: UInt64) {
        guard startAnswered(id) else {
            return
        }
        // a press that ended while its mic was opening asked for the
        // cancel after the start, so the cancel lands after it too.
        guard var capture, capture.id == id else {
            return
        }

        capture.phase = .live
        self.capture = capture
        press?.mic = capture.microphone.deviceDescription
        guard !capture.stopRequested else {
            // let go before the mic answered: the take still counts.
            stopMicrophone()
            return
        }
        if !capture.isHearing {
            awaitFirstAudio(id)
        }
    }

    /// a mic can open and still send nothing — one the phone took for a
    /// call, a driver that wedged — so it gets a second to be heard, or
    /// three if it is a headset still switching profile.
    private func awaitFirstAudio(_ id: UInt64) {
        firstAudioWait?.cancel()
        let deadline = Self.firstAudioDeadline(
            for: capture?.microphone.deviceDescription?.transport
        )
        firstAudioWait = Task { @MainActor [weak self, clock] in
            try? await clock.sleep(for: deadline)
            guard !Task.isCancelled else {
                return
            }
            self?.microphoneStayedSilent(id)
        }
    }

    /// its deadline since it answered, and not a sound.
    private func microphoneStayedSilent(_ id: UInt64) {
        firstAudioWait = nil
        guard let capture,
              capture.id == id,
              capture.phase == .live,
              !capture.isHearing else {
            return
        }

        audioLogger.error("the microphone sent nothing for a second; dropping it")
        cancelCapture()
        endWithNoSound(from: press?.mic)
    }

    /// the mic answered and sent no sound. the pill names it, so you know
    /// which one to look at, and it is dropped, so the next press opens a
    /// fresh one. nothing is kept for a retry: there was nothing to hear,
    /// and pressing again records again.
    private func endWithNoSound(from mic: MicDescription?) {
        setRecordingLocked(false)
        activeFocusAnchor = nil
        activeTimeline = nil
        emit(.microphoneDropped)
        setState(.idle, fastHUDDismiss: true)
        flashFeedback(Self.noSound(from: mic))
        endPress(.noAudio)
    }

    /// a working mic hands back at least a hiss, and a key held past a
    /// brush gives it a few tenths of a second to: a take of exact zeros,
    /// or of less than `usableSamples`, is the mic failing, not you being
    /// quiet.
    private static func sentNoSound(_ samples: [Float]) -> Bool {
        samples.count < usableSamples
            || vDSP.maximumMagnitude(samples) == 0
    }

    /// the mic as it names itself, which is what you would look for in
    /// the menu bar or system settings.
    private static func noSound(from mic: MicDescription?) -> String {
        guard let name = mic?.name.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else {
            return "no sound from the microphone"
        }
        return "no sound from \(name)"
    }

    /// the mic's first audio: it is hearing you. the key only said you
    /// pressed; this is the moment the chime can promise something.
    private func firstBufferLanded(
        _ id: UInt64,
        at instant: ContinuousClock.Instant,
        timelineID: UInt64
    ) {
        recordFirstBuffer(at: instant, timelineID: timelineID)
        guard var capture,
              capture.id == id,
              !capture.isHearing else {
            return
        }
        capture.isHearing = true
        self.capture = capture
        firstAudioWait?.cancel()
        firstAudioWait = nil
        guard !capture.isEnding else {
            // let go before it was heard: lighting the lamp, or a start
            // chime, after the release would be noise.
            return
        }
        emit(.hearing)
        scheduleStartChime()
    }

    /// the mic and the lamp start at key-down; the chime waits for the
    /// mic's first audio, and then long enough to know the key is being
    /// held rather than caught. a brush of fn should make no sound at all.
    /// a mic slow to be heard has already spent some of that wait.
    private func scheduleStartChime() {
        let held = press.map { $0.keyDown.duration(to: clock.now) } ?? .zero
        let wait = Duration.milliseconds(120) - held
        startCueTask?.cancel()
        guard wait > .zero else {
            startCueTask = nil
            emit(.chime(.start))
            return
        }
        startCueTask = Task { @MainActor [weak self, clock] in
            try? await clock.sleep(for: wait)
            guard !Task.isCancelled,
                  let self else {
                return
            }
            self.emit(.chime(.start))
        }
    }

    /// the start answered. false when the deadline got there first: that
    /// mic has already been given up on, and its late answer means nothing.
    private func startAnswered(_ id: UInt64) -> Bool {
        guard pendingStart == id else {
            return false
        }
        pendingStart = nil
        startDeadline?.cancel()
        startDeadline = nil
        return true
    }

    /// the mic never answered. a device still settling after a monitor or
    /// the lid can wedge inside Core Audio for good, and the next press
    /// must not queue behind it: the press ends now, out loud, and the app
    /// throws that capture away whole.
    private func microphoneStartTimedOut(_ id: UInt64) {
        guard pendingStart == id else {
            return
        }
        pendingStart = nil
        startDeadline = nil
        guard let capture, capture.id == id else {
            dropOrphanedMicrophone()
            return
        }

        audioLogger.error("the microphone didn't start in time; dropping it")
        setRecordingLocked(false)
        activeFocusAnchor = nil
        activeTimeline = nil
        press?.mic = capture.microphone.deviceDescription
        // not cancelled: a mic that never answered is asked nothing more.
        self.capture = nil
        emit(.microphoneDropped)
        setState(.idle, fastHUDDismiss: true)
        flashNotice("microphone isn't responding", duration: 2)
        endPress(.micNotResponding)
    }

    /// a press thrown away while its mic was opening, and that mic then
    /// refused or never answered. the press is over, so nothing is said,
    /// but the next one must not queue behind a wedged mic. a press already
    /// holding a mic of its own keeps it: that one answers for itself.
    private func dropOrphanedMicrophone() {
        guard capture == nil else {
            return
        }
        audioLogger.error("a thrown-away take's microphone never started; dropping it")
        emit(.microphoneDropped)
    }

    private func microphoneFailedToStart(_ id: UInt64, error: any Error) {
        guard startAnswered(id) else {
            return
        }
        guard let capture, capture.id == id else {
            dropOrphanedMicrophone()
            return
        }

        audioLogger.error(
            """
            audio recording failed to start: \
            \(error.localizedDescription, privacy: .public)
            """
        )
        setRecordingLocked(false)
        activeFocusAnchor = nil
        activeTimeline = nil
        // read before it is dropped: which mic refused is the evidence.
        press?.mic = capture.microphone.deviceDescription
        // the device may have been yanked between the check and the tap.
        // drop it so the next press rebuilds instead of retrying a corpse.
        cancelCapture()
        emit(.microphoneDropped)
        // the lamp was already up, so a failure takes it down fast.
        setState(.idle, fastHUDDismiss: true)
        if case MicCaptureError.noInputDevice? = error as? MicCaptureError {
            // no mic at all is not one that refused. the next press looks
            // again: the headset may be back on by then.
            flashNotice("no microphone available")
            endPress(.refused(.noMicrophone))
            return
        }
        flashNotice("couldn't start recording")
        endPress(.couldNotStartRecording)
    }

    func doubleTapped() {
        if state == .recording {
            return
        }

        // no discard of its own: a lock that starts mid-transcription is the
        // same repress as any other, and keyDown owns that decision.
        keyDown()

        // only claim the lock if the capture took — a missing mic or a
        // failed engine leaves us idle, and a lamp that says "locked"
        // over nothing is a lie.
        guard state == .recording else {
            return
        }
        setRecordingLocked(true)
        flashNotice("locked — tap to end")
    }

    /// the release of a held key, or the tap that ends a locked recording.
    /// `eventAge` is how long ago the release happened, read off the key
    /// event: the time it spent reaching us is the user's wait, not ours to
    /// leave out of key-up → paste.
    func keyUp(eventAge: Duration = .zero) {
        endTake(releasedAt: clock.now - max(.zero, eventAge))
    }

    /// the take is over — the key came up, the cap sealed it, or the mic
    /// changed under it — and what was heard goes on to the page.
    private func endTake(
        releasedAt released: ContinuousClock.Instant,
        micChanged: Bool = false
    ) {
        guard state == .recording,
              var capture,
              !capture.isEnding else {
            return
        }

        setRecordingLocked(false)
        // let go inside the brush wait: a start chime still due would land
        // after the take's end.
        startCueTask?.cancel()

        // never before key-down: an event clock that disagrees with
        // ours must not make a press end before it began.
        let keyUp = activeTimeline.map { max($0.keyDown, released) }
            ?? released
        activeTimeline?.keyUp = keyUp
        press?.keyUp = keyUp
        press?.capped = capForcedEnd
        press?.micChanged = micChanged

        guard capture.phase == .live else {
            // the mic has not answered yet: stop it the moment it does.
            capture.stopRequested = true
            self.capture = capture
            return
        }
        stopMicrophone()
    }

    private func stopMicrophone() {
        guard var capture, capture.phase == .live else {
            return
        }

        capture.phase = .stopping
        self.capture = capture
        // the take is over: whether it was heard is judged on what the
        // stop hands back.
        firstAudioWait?.cancel()
        firstAudioWait = nil
        let id = capture.id
        let microphone = capture.microphone
        armStopDeadline(id)
        Task.immediate { @MainActor [weak self] in
            do {
                let samples = try await microphone.stop()
                self?.microphoneStopped(id, samples: samples)
            } catch {
                self?.microphoneFailedToStop(id, error: error)
            }
        }
    }

    private func armStopDeadline(_ id: UInt64) {
        stopDeadline?.cancel()
        stopDeadline = Task { @MainActor [weak self, clock] in
            try? await clock.sleep(for: Self.microphoneDeadline)
            guard !Task.isCancelled else {
                return
            }
            self?.microphoneStopTimedOut(id)
        }
    }

    private func microphoneStopped(_ id: UInt64, samples: [Float]) {
        // thrown away while it stopped: what it heard goes nowhere.
        guard stopAnswered(id) else {
            return
        }

        press?.samplesReady = clock.now
        press?.samples = samples
        if press?.micChanged == true, samples.isEmpty {
            // the mic changed before it heard anything: the same answer as
            // any silence, without asking the engine about nothing.
            activeFocusAnchor = nil
            activeTimeline = nil
            setState(.idle, fastHUDDismiss: true)
            flashFeedback("heard nothing")
            endPress(.heardNothing)
            return
        }
        // a brush gets a sliver from any mic, so only a held key's take
        // is judged; a brush goes on to end in silence, as it always has.
        let brushed = activeTimeline?.heldDuration.map {
            $0 < Self.brushLimit
        } ?? false
        if press?.micChanged != true,
           !brushed,
           Self.sentNoSound(samples) {
            audioLogger.error("the microphone sent only silence; dropping it")
            endWithNoSound(from: press?.mic)
            return
        }
        // taken now rather than at key-down: the window worth protecting
        // is key-up → paste, the ~600 ms when nobody is moving anything.
        // key-down → paste spans the whole utterance, which is exactly
        // when aiming at the field you actually want is normal.
        let focusAnchor = inserter.captureAnchorUnlessOurs()
            ?? activeFocusAnchor
        activeFocusAnchor = nil
        emit(.chime(.end))
        setState(.transcribing)
        startPipeline(
            samples,
            focusAnchor: focusAnchor
        )
    }

    private func microphoneFailedToStop(_ id: UInt64, error: any Error) {
        guard stopAnswered(id) else {
            return
        }

        audioLogger.error(
            """
            audio recording failed to stop: \
            \(error.localizedDescription, privacy: .public)
            """
        )
        loseRecording()
    }

    /// the stop answered. false when the take was thrown away while it
    /// stopped, or the deadline got there first: what it heard goes nowhere.
    private func stopAnswered(_ id: UInt64) -> Bool {
        guard let capture,
              capture.id == id,
              capture.phase == .stopping else {
            return false
        }
        self.capture = nil
        stopDeadline?.cancel()
        stopDeadline = nil
        return true
    }

    private func microphoneStopTimedOut(_ id: UInt64) {
        if isSystemPaused, let capture, capture.id == id,
           capture.phase == .stopping {
            // the mac slept with the stop still out: the time asleep
            // counted against the mic, and its answer can only come once
            // the mac is back. the take is the user's, so it waits for
            // that; `systemResumed` gives the mic its deadline again.
            stopDeadline = nil
            return
        }
        guard stopAnswered(id) else {
            return
        }

        audioLogger.error("the microphone didn't stop in time; dropping it")
        loseRecording()
    }

    /// they spoke and there is nothing to show for it. say so, and drop the
    /// mic: one that would not stop is not trusted with the next take.
    private func loseRecording() {
        activeFocusAnchor = nil
        activeTimeline = nil
        emit(.microphoneDropped)
        setState(.idle, fastHUDDismiss: true)
        flashNotice("recording was lost")
        endPress(.recordingLost)
    }

    /// the hotkey's own cancel: a brush too short to be a hold, or a lock
    /// the detector gave up on.
    func keyCancelled() {
        // a discarded capture must not leave a chime in flight behind it
        startCueTask?.cancel()
        guard state == .recording,
              let capture,
              !capture.isEnding else {
            return
        }

        cancelCapture()
        setRecordingLocked(false)
        activeFocusAnchor = nil
        activeTimeline = nil
        // a brush of the key should read as a flicker, not a cut
        setState(.idle, fastHUDDismiss: true)
        endPress(.brushed)
    }

    /// whether `esc` was ours to take: only while there is something to
    /// throw away.
    func escape() -> Bool {
        guard state != .idle, state != .prewarming else {
            return false
        }

        cancelCurrentInteraction()
        return true
    }

    /// a press the app refused before the machine heard of it (a meeting
    /// owns the mic). it still ends in a record, like every press.
    func refusePress(_ why: PressRecord.Refusal) {
        refuse(why)
    }

    // MARK: - the mic, from underneath

    func captureInterrupted(_ reason: CaptureInterruption) {
        switch reason {
        case .deviceChanged:
            guard state == .recording else {
                // once the words are with the engine, the mic going away
                // costs nothing.
                return
            }
            // the mic moved under the take: airpods taken by a call, a
            // display's audio arriving, the engine rebuilt underneath. what
            // it heard up to the change is the user's sentence, so the take
            // ends the way a release would — kept, written out, pasted —
            // and a pill after the paste says why it ended without them.
            endTake(releasedAt: clock.now, micChanged: true)
        case .systemPaused:
            systemPaused()
        }
    }

    /// the mac is going to sleep, or the screen locked: the lid, ⌃⌘Q, a
    /// hot corner. only you throw an utterance away, so a take in flight
    /// ends the way a release would and is written out — but the field it
    /// was going to is behind the lock screen now, so it is copied, never
    /// pasted. pasting on the way back in could land in whatever you are
    /// typing by then.
    private func systemPaused() {
        isSystemPaused = true
        guard state == .recording || state == .transcribing else {
            return
        }
        copiesInsteadOfPasting = true
        endTake(releasedAt: clock.now)
    }

    /// the mac is back and someone is looking at it: unlocked, or woken
    /// with no lock to get past. what was said while it was away is said
    /// now.
    func systemResumed() {
        guard isSystemPaused else {
            return
        }
        isSystemPaused = false
        if let capture, capture.phase == .stopping, stopDeadline == nil {
            // a stop the sleep outlasted gets the deadline any stop gets,
            // counted from now.
            armStopDeadline(capture.id)
        }
        if let heldPill {
            self.heldPill = nil
            emit(.pill(heldPill.message, duration: heldPill.duration))
        }
    }

    /// thirty seconds of runway. the wave comes back on its own when the
    /// pill clears, so the lamp needs nothing here.
    func capApproaching() {
        guard state == .recording else {
            return
        }

        flashNotice("thirty seconds left", duration: 2)
    }

    /// the recorder sealed the mic at the ceiling, so the take is over
    /// whether the finger knows it or not — end it and deliver the five
    /// minutes. a lamp still saying "listening" over a sealed mic is
    /// spec §4's forbidden shape: a failure wearing the success signal.
    /// true when it ended a take, because the key was never released and
    /// the hotkey has to be told.
    @discardableResult
    func capReached() -> Bool {
        guard state == .recording,
              capture?.isEnding == false else {
            return false
        }

        capForcedEnd = true
        keyUp()
        return true
    }

    // MARK: - the main thread, from outside

    /// the watchdog saw the main thread go unanswered this long. kept on
    /// the press in flight, longest wins; between presses it is only a
    /// line in the log.
    func mainStalled(for duration: Duration) {
        guard var press else {
            return
        }
        press.mainStall = max(press.mainStall ?? .zero, duration)
        self.press = press
    }

    // MARK: - the app pulling the rug

    /// a setting that rebuilds the capture path (pre-roll) cannot do it
    /// under a live take.
    func abandonRecording() {
        guard state == .recording else {
            return
        }

        cancelCapture()
        setRecordingLocked(false)
        activeFocusAnchor = nil
        activeTimeline = nil
        setState(.idle)
        endPress(.abandoned)
    }

    /// the speech model is being taken away: whatever is in flight goes,
    /// silently, and the lamp settles.
    func abandon() {
        invalidatePipeline()
        if state == .recording {
            cancelCapture()
            setRecordingLocked(false)
            activeFocusAnchor = nil
            activeTimeline = nil
        }
        setState(.idle)
        endPress(.abandoned)
    }

    // MARK: - retry

    /// re-runs the samples that were thrown on, delivered wherever the
    /// cursor is *now* — the failure may have sent them to another window.
    /// false when there was nothing left to re-run.
    @discardableResult
    func retryLastFailure() -> Bool {
        guard let samples = retryBuffer.take(at: Date()) else {
            clearRetry()
            return false
        }
        clearRetry()
        copiesInsteadOfPasting = false

        let now = clock.now
        timelineSequence &+= 1
        var timeline = UtteranceTimelineBuilder(
            id: timelineSequence,
            keyDown: now
        )
        // held ≈ 0 rather than a fabricated hold: this row measures the
        // retry, and nobody held a key for it.
        timeline.micFirstBuffer = now
        timeline.keyUp = now
        activeTimeline = timeline
        // its own press in the log, heard through no mic: no first buffer
        // and no key-up, only the samples it replays.
        press = PressRecord.Draft(keyDown: now, startedAt: Date(), retry: true)
        press?.samplesReady = now
        press?.samples = samples
        setState(.transcribing)
        startPipeline(samples, focusAnchor: inserter.captureAnchor())
        return true
    }

    /// the failed dictation is still recoverable until the next one, and the
    /// menu row plus the pill are the only two places that can say so.
    private func armRetry(_ samples: [Float]) {
        retryBuffer.arm(samples: samples, at: Date())
        offerRetry(true)
        retryExpiryTask?.cancel()
        retryExpiryTask = Task { @MainActor [weak self, clock] in
            try? await clock.sleep(for: .seconds(RetryBuffer.lifetime))
            guard !Task.isCancelled else {
                return
            }
            self?.clearRetry()
        }
    }

    private func clearRetry() {
        retryExpiryTask?.cancel()
        retryExpiryTask = nil
        retryBuffer.clear()
        offerRetry(false)
    }

    private func offerRetry(_ offered: Bool) {
        guard offered != canRetryLastFailure else {
            return
        }
        canRetryLastFailure = offered
        emit(.retryOffered(offered))
    }

    // MARK: - the pipeline

    private func recordFirstBuffer(
        at instant: ContinuousClock.Instant,
        timelineID: UInt64
    ) {
        guard activeTimeline?.id == timelineID,
              activeTimeline?.micFirstBuffer == nil else {
            return
        }
        activeTimeline?.micFirstBuffer = instant
        press?.firstBuffer = instant
    }

    private func startPipeline(
        _ samples: [Float],
        focusAnchor: (any InsertionAnchor)?
    ) {
        pipelineGeneration += 1
        let generation = pipelineGeneration
        armTranscriptionDeadline(for: samples, generation: generation)

        pipelineTask = Task { [weak self] in
            await self?.transcribeAndInsert(
                samples,
                focusAnchor: focusAnchor,
                generation: generation
            )
        }
    }

    /// a wedged engine never answers, and a call into it can't be taken
    /// back. the press stops waiting on it instead.
    private func armTranscriptionDeadline(
        for samples: [Float],
        generation: Int
    ) {
        transcriptionDeadline?.cancel()
        transcriptionDeadline = armDeadline(
            after: TranscriptionDeadline.forSamples(samples.count)
        ) { machine in
            machine.transcriptionTimedOut(samples, generation: generation)
        }
    }

    /// a deadline that doesn't run out while the mac is away. one that
    /// comes due asleep or locked waits, and once the mac is back the
    /// thing waited on gets a whole window of its own: nobody was there
    /// to be kept waiting, and a wake is slow for everything.
    private func armDeadline(
        after window: Duration,
        then expire: @escaping @MainActor (UtteranceMachine) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self, clock] in
            var wasAway = false
            while true {
                try? await clock.sleep(for: window)
                guard !Task.isCancelled, let self else {
                    return
                }
                if self.isAway || wasAway {
                    wasAway = self.isAway
                    continue
                }
                expire(self)
                return
            }
        }
    }

    /// the engine's answer. words or an error, either one came in time and
    /// stops the deadline; one that comes after it is about a press that
    /// has already ended.
    private func transcribeInTime(
        _ samples: [Float],
        generation: Int
    ) async throws -> String {
        defer {
            engineAnswered(generation: generation)
        }
        return try await engine.transcribe(samples)
    }

    private func engineAnswered(generation: Int) {
        guard generation == pipelineGeneration else {
            return
        }
        transcriptionDeadline?.cancel()
        transcriptionDeadline = nil
        unansweredTakes = 0
    }

    /// the engine never answered. the press ends now, out loud, with its
    /// samples kept for a tap. it is the same ending as an engine that
    /// threw, and the record says which.
    private func transcriptionTimedOut(_ samples: [Float], generation: Int) {
        guard generation == pipelineGeneration,
              state == .transcribing else {
            return
        }

        transcriptionDeadline = nil
        pipelineLogger.error("the speech model didn't answer in time; giving up on it")
        unansweredTakes += 1
        // the engine after a restart starts with a clean slate.
        let restart = unansweredTakes
            >= TranscriptionDeadline.unansweredBeforeRestart
        if restart {
            unansweredTakes = 0
        }
        activeTimeline = nil
        press?.timedOut = true
        // kept either way: the sentence is no less theirs because the
        // engine is the thing that broke.
        armRetry(samples)
        reportPipelineFailure(
            restart
                ? "speech model isn't responding — restarting it"
                : "couldn't transcribe — tap to try again",
            outcome: .couldNotTranscribe,
            generation: generation,
            duration: 4
        )
        // whatever the engine says later lands nowhere.
        pipelineGeneration += 1
        pipelineTask?.cancel()
        pipelineTask = nil
        emit(restart ? .engineUnresponsive : .engineSuspect)
    }

    private func transcribeAndInsert(
        _ samples: [Float],
        focusAnchor: (any InsertionAnchor)?,
        generation: Int
    ) async {
        defer {
            finishPipeline(generation: generation)
        }

        do {
            let transcript = try await transcribeInTime(
                samples,
                generation: generation
            )
            try Task.checkCancellation()
            guard generation == pipelineGeneration else {
                return
            }
            activeTimeline?.transcriptReady = clock.now
            press?.transcriptReady = clock.now

            // one read of the text at the caret, two decisions: is the
            // sentence there still running (so no capital), and do the words
            // need a space to stand apart from it. read off the held element,
            // the same one the paste decision revalidates.
            // words going to the clipboard have no caret to join: they
            // stand alone, wherever they are pasted later.
            let textAtCaret = copiesInsteadOfPasting
                ? nil
                : focusAnchor?.textBeforeCursor()
            let continuingASentence = continuesSentence(after: textAtCaret)

            // a dictation aimed at our own window is a correction, not a
            // sentence: dictate "cache" into the fixer's "what you meant"
            // field and full cleanup would save it as "Cache." forever. the
            // dictionary still runs — that is the ADR 0038 "cleanup off"
            // path, not a new one. scoped per bundle, not per field, the
            // same way CoreAudioMeetingSource treats our own bundle id: the
            // fixer's field is the only dictation target we own. every
            // other dictation goes through the cleaner built once for the
            // current dictionary and settings.
            let cleanedTranscript = pastesIntoOurOwnUI(
                target: focusAnchor?.targetBundleIdentifier,
                own: ownBundleIdentifier
            )
                ? DeterministicCleaner(
                    entries: dictionary(),
                    fullCleanup: false
                ).clean(transcript, continuingASentence: continuingASentence)
                : cleaner.clean(transcript, continuingASentence: continuingASentence)
            activeTimeline?.cleaned = clock.now
            press?.cleaned = clock.now
            // a count, never the words: the record is what gets sent.
            press?.words = cleanedTranscript.split(
                whereSeparator: \.isWhitespace
            ).count
            guard !cleanedTranscript.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                let held = activeTimeline?.heldDuration
                activeTimeline = nil
                // an accident is neither a success nor a failure. "heard
                // nothing" is an answer, and a key nobody meant to press
                // asked no question. a retry holds no key at all (held is
                // exactly zero), and it did ask.
                if let held,
                   held > .zero,
                   held < Duration.milliseconds(300) {
                    guard generation == pipelineGeneration,
                          state == .transcribing else {
                        return
                    }
                    setState(.idle, fastHUDDismiss: true)
                    endPress(.brushed)
                    return
                }
                // silence must not wear the success afterglow.
                reportPipelineFailure(
                    "heard nothing",
                    outcome: .heardNothing,
                    generation: generation
                )
                return
            }
            // a second dictation into the same field must not weld itself
            // to the first. the space is a delivery detail — the cleaner
            // still renders a flush string and the archive still keeps it.
            let joinsWhatIsThere = needsJoinSpace(after: textAtCaret?.last)
            let pasteTranscript = joinsWhatIsThere
                ? " " + cleanedTranscript
                : cleanedTranscript

            emit(.transcribed(heard: transcript, inserted: cleanedTranscript))
            pendingArchiveText = (
                heard: transcript,
                inserted: cleanedTranscript
            )
            let outcome = if copiesInsteadOfPasting {
                await inserter.copy(cleanedTranscript, because: .locked)
            } else {
                await inserter.insert(pasteTranscript, at: focusAnchor)
            }
            if outcome.result != .leftOnPasteboard(
                .pasteboardUnavailable
            ) {
                emit(.dictated(cleanedTranscript))
            }
            guard generation == pipelineGeneration else {
                return
            }
            press?.pasteCompleted = clock.now

            switch outcome.result {
            case .pasted:
                press?.pastePosted = outcome.insertedAt
                // the paste's own instant, not this one: paste() returns as
                // soon as ⌘V is posted, and that is what "inserted" means.
                completeTimeline(
                    at: outcome.insertedAt,
                    stage: .delivered
                )
                // success is silent, but a take the user did not end is
                // not quite success: say what landed, after it lands. a
                // pill flashed at 5:00 would be wiped by the paste's own
                // return to idle.
                if capForcedEnd {
                    setState(.idle)
                    flashFeedback(
                        "five minutes — that's the cap. pasted what i had.",
                        duration: 2.4
                    )
                } else if press?.micChanged == true {
                    setState(.idle)
                    flashFeedback(
                        CaptureInterruptionNotice.message(for: .deviceChanged),
                        duration: 2.4
                    )
                }
                endPress(.delivered)
            case let .leftOnPasteboard(reason):
                completeTimeline(
                    at: clock.now,
                    stage: reason == .secureField
                        ? .leftOnPasteboardSecure
                        : .leftOnPasteboard
                )
                setState(.idle)
                // 4 s, not the shared default: this pill is the only thing
                // telling them their words are on the clipboard, and it is
                // asking them to do something about it.
                flashFeedback(
                    feedbackMessage(for: reason),
                    duration: 4
                )
                endPress(.leftOnPasteboard(reason))
            }
        } catch is CancellationError {
            return
        } catch {
            pipelineLogger.error(
                "transcription failed: \(error.localizedDescription, privacy: .public)"
            )
            activeTimeline = nil
            guard generation == pipelineGeneration,
                  state == .transcribing else {
                return
            }
            // the samples are still in this frame. "say the whole thing
            // again" is not a recourse for a paragraph, so keep them.
            armRetry(samples)
            reportPipelineFailure(
                "couldn't transcribe — tap to try again",
                outcome: .couldNotTranscribe,
                generation: generation,
                duration: 4
            )
        }
    }

    /// a dictation that produced nothing must not end in the lamp's
    /// afterglow — that glow is the success signal. cut it short and say
    /// what went wrong in the same pill that carries "copied — …".
    private func reportPipelineFailure(
        _ message: String,
        outcome: PressRecord.Outcome,
        generation: Int,
        duration: TimeInterval = 2.4
    ) {
        guard generation == pipelineGeneration,
              state == .transcribing else {
            return
        }

        setState(.idle, fastHUDDismiss: true)
        flashFeedback(message, duration: duration)
        endPress(outcome)
    }

    private func invalidatePipeline() {
        setRecordingLocked(false)
        pipelineGeneration += 1
        pipelineTask?.cancel()
        pipelineTask = nil
        activeTimeline = nil
    }

    /// "copied" is a fact; the user needs the verb. the pill cannot be
    /// clicked (it ignores mouse events), so the recovery has to be
    /// something their hands can already do.
    private func feedbackMessage(
        for reason: LeftOnPasteboardReason
    ) -> String {
        switch reason {
        case .secureField:
            "copied — secure field · ⌘V to paste"
        case .focusChanged:
            "copied — focus changed · ⌘V to paste"
        case .accessibilityUnavailable,
             .shortcutUnavailable,
             .cancelled:
            "copied — couldn't paste it · ⌘V to paste"
        case .pasteboardUnavailable:
            // the only one with no recovery to offer: the clipboard write
            // itself failed, so there is nothing sitting there to paste.
            "the clipboard is busy — nothing was copied"
        case .locked:
            CaptureInterruptionNotice.message(for: .systemPaused)
        }
    }

    private func completeTimeline(
        at instant: ContinuousClock.Instant,
        stage: UtteranceTimeline.CompletionStage
    ) {
        defer {
            activeTimeline = nil
            pendingArchiveText = nil
        }
        guard let timeline = activeTimeline?.complete(stage, at: instant) else {
            return
        }
        emit(.timelineCompleted(timeline))
        // A dictation becomes a kept thing only once it has actually been
        // delivered. A cancelled one produced no text, so there is nothing to
        // keep; one left on the pasteboard reached you by another route and
        // still counts — except the one refused for a secure field, which
        // reached nowhere and is a password.
        guard stage.isKeepable,
              let text = pendingArchiveText else {
            return
        }
        emit(.archiveRecord(timeline, heard: text.heard, inserted: text.inserted))
    }

    private func finishPipeline(generation: Int) {
        guard generation == pipelineGeneration else {
            return
        }

        pipelineTask = nil
        guard state == .transcribing else {
            return
        }

        // success is silent: the lamp's afterglow is the whole goodbye.
        // hold the panel just long enough for the cool-out to finish.
        let elapsed = transcribingBeganAt.map {
            seconds($0.duration(to: clock.now))
        } ?? .infinity
        let remaining = max(
            0,
            coolDuration + 0.05 - elapsed
        )
        let stateToken = stateGeneration
        Task { @MainActor [weak self, clock] in
            if remaining > 0 {
                try? await clock.sleep(for: .seconds(remaining))
            }
            guard let self,
                  stateToken == self.stateGeneration,
                  self.state == .transcribing else {
                return
            }
            self.setState(.idle, fastHUDDismiss: true)
        }
    }

    private func cancelCurrentInteraction() {
        let cancelRequested = clock.now

        if state == .recording {
            cancelCapture()
            setRecordingLocked(false)
            activeFocusAnchor = nil
        }

        pipelineGeneration += 1
        pipelineTask?.cancel()
        pipelineTask = nil
        setState(.idle, fastHUDDismiss: true)
        let idle = clock.now

        if let timeline = activeTimeline?.cancelled(
            requestedAt: cancelRequested,
            idleAt: idle
        ) {
            emit(.timelineCompleted(timeline))
        }
        activeTimeline = nil
        endPress(.cancelled)
    }

    // MARK: - the mic of the press in flight

    /// the press is done with its mic and keeps nothing it heard.
    private func cancelCapture() {
        capture?.microphone.cancel()
        capture = nil
        stopDeadline?.cancel()
        stopDeadline = nil
        firstAudioWait?.cancel()
        firstAudioWait = nil
    }

    // MARK: - effects

    private func setState(
        _ newState: State,
        fastHUDDismiss: Bool = false
    ) {
        stateGeneration += 1
        if newState == .transcribing {
            transcribingBeganAt = clock.now
        }
        state = newState
        emit(.state(newState, fastDismiss: fastHUDDismiss))
    }

    /// the HUD is the only place this fact can live: there is no held
    /// key to look at, and the lamp burns identically either way.
    private func setRecordingLocked(_ locked: Bool) {
        guard locked != isRecordingLocked else {
            return
        }
        isRecordingLocked = locked
        emit(.locked(locked))
    }

    private func keepDisplayAwake(_ awake: Bool) {
        guard awake != isKeepingDisplayAwake else {
            return
        }
        isKeepingDisplayAwake = awake
        emit(.keepAwake(awake))
    }

    /// a pill that answers an input lands a run-loop turn after it, as it
    /// always has: the state change before it reaches the panel first.
    private func flashNotice(
        _ message: String,
        duration: TimeInterval = 1.6
    ) {
        Task { @MainActor [weak self] in
            self?.say(message, duration: duration)
        }
    }

    /// a pill the pipeline owes, said in the same turn as the state change
    /// that ended the lamp, so the panel never dismisses in between.
    ///
    /// 2.4 s, where it used to be 1.2: the pill springs in over 0.32 s and
    /// then sits at bottom-centre while the reader's eyes are on their
    /// cursor. the two call sites that ride this default are both failures,
    /// and one of them ("copied — …") is an instruction.
    private func flashFeedback(
        _ message: String,
        duration: TimeInterval = 2.4
    ) {
        say(message, duration: duration)
    }

    /// a pill said onto a sleeping or locked screen is gone before anyone
    /// sees it: it waits for the mac to come back. one take's ending is
    /// one pill, so the last one said is the one kept.
    private func say(_ message: String, duration: TimeInterval) {
        guard !isSystemPaused else {
            heldPill = (message, duration)
            return
        }
        emit(.pill(message, duration: duration))
    }

    /// a press answered with a pill before anything was recorded. its own
    /// record, apart from any press still in flight.
    private func refuse(_ why: PressRecord.Refusal) {
        let now = clock.now
        emit(.pressEnded(
            PressRecord.Draft(keyDown: now, startedAt: Date()).finished(
                .refused(why),
                at: now,
                engine: engineVersion?() ?? ""
            )
        ))
    }

    /// the one way a press ends: its record leaves once, and a second
    /// ending for the same press finds nothing left to end.
    private func endPress(_ outcome: PressRecord.Outcome) {
        guard let press else {
            return
        }
        self.press = nil
        emit(.pressEnded(press.finished(
            outcome,
            at: clock.now,
            engine: engineVersion?() ?? ""
        )))
    }

    private func emit(_ event: UtteranceEvent) {
        onEvent?(event)
    }

    private func seconds(_ duration: Duration) -> TimeInterval {
        duration.inMilliseconds / 1_000
    }
}

extension UtteranceMachine {
    /// one press's mic. its start and stop are awaited and can take a
    /// moment, and the keys keep arriving meanwhile: the phase is what they
    /// are answered against.
    private struct Capture {
        enum Phase {
            /// asked to start; the lamp is up, the mic has not answered.
            case starting
            case live
            /// asked to stop; what it heard is on its way.
            case stopping
        }

        let id: UInt64
        let microphone: any MicCapture
        var phase = Phase.starting
        /// let go before the mic answered: stopped the moment it does.
        var stopRequested = false
        /// its first audio has landed. the mic answering its start only
        /// says the device opened; this says it is hearing you.
        var isHearing = false

        /// the take is already over, whatever ended it.
        var isEnding: Bool {
            phase == .stopping || stopRequested
        }
    }
}
