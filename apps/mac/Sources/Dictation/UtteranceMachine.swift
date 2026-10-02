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
    case chime(UtteranceMachine.Chime)
    /// an exceptional message, and how long it stays.
    case pill(String, duration: TimeInterval)
    case locked(Bool)
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

    private(set) var state: State = .idle

    var onEvent: (@MainActor (UtteranceEvent) -> Void)?
    /// asked once per press, after the machine's own answers to it (a retry
    /// on offer, a sentence still being written out). it is the app's say —
    /// a speech model still loading, a missing grant, no input device — and
    /// nil means the app has already answered the press itself.
    var microphoneForPress: (@MainActor () -> (any MicCapture)?)?
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
    private let dictionary: @MainActor () -> [DictionaryEntry]
    private let ownBundleIdentifier: String?
    /// how long the lamp's afterglow runs (`HUDWaveMotion.coolDuration`).
    private let coolDuration: TimeInterval

    private var microphone: (any MicCapture)?
    /// a double-tapped key leaves nothing to hold, so nothing to feel. the
    /// HUD has to carry the difference for as long as the capture runs.
    private var isRecordingLocked = false
    private var activeFocusAnchor: (any InsertionAnchor)?
    private var pipelineTask: Task<Void, Never>?
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
        capForcedEnd = false
        // the pill still says the last one failed and the samples are still
        // here: this press means "that one", not "a new one". keyUp's state
        // guard makes the eventual key release a no-op.
        if isPillShowing?() == true, canRetryLastFailure {
            retryLastFailure()
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
                return
            case .dropAndRestart:
                invalidatePipeline()
                setState(.idle)
            }
        }

        guard let microphone = microphoneForPress?(),
              state == .idle else {
            return
        }

        // a new take is the sentence you care about now; the lost one stops
        // being offered.
        clearRetry()
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
        let focusAnchor = inserter.captureAnchor()

        do {
            try microphone.start { [weak self] instant in
                self?.recordFirstBuffer(
                    at: instant,
                    timelineID: timelineID
                )
            }
            self.microphone = microphone
            press?.mic = microphone.deviceDescription
            activeFocusAnchor = focusAnchor
            // the mic and the lamp start at key-down; only the chime waits,
            // long enough to know the key is being held rather than caught.
            // a brush of fn should make no sound at all.
            startCueTask?.cancel()
            startCueTask = Task { @MainActor [weak self, clock] in
                try? await clock.sleep(for: .milliseconds(120))
                guard !Task.isCancelled,
                      let self else {
                    return
                }
                self.emit(.chime(.start))
            }
            setState(.recording)
        } catch {
            audioLogger.error(
                """
                audio recording failed to start: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            activeFocusAnchor = nil
            activeTimeline = nil
            // the device may have been yanked between the check and the tap.
            // drop it so the next press rebuilds instead of retrying a corpse.
            microphone.cancel()
            self.microphone = nil
            emit(.microphoneDropped)
            setState(.idle)
            flashNotice("couldn't start recording")
        }
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
    func keyUp() {
        guard state == .recording,
              let microphone else {
            return
        }

        setRecordingLocked(false)

        do {
            let keyUp = clock.now
            activeTimeline?.keyUp = keyUp
            press?.keyUp = keyUp
            press?.capped = capForcedEnd
            let samples = try microphone.stop()
            press?.samplesReady = clock.now
            press?.samples = samples
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
        } catch {
            audioLogger.error(
                """
                audio recording failed to stop: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            activeFocusAnchor = nil
            activeTimeline = nil
            setState(.idle, fastHUDDismiss: true)
            // they spoke and there is nothing to show for it. say so.
            flashNotice("recording was lost")
        }
    }

    /// the hotkey's own cancel: a brush too short to be a hold, or a lock
    /// the detector gave up on.
    func keyCancelled() {
        // a discarded capture must not leave a chime in flight behind it
        startCueTask?.cancel()
        guard state == .recording,
              let microphone else {
            return
        }

        microphone.cancel()
        setRecordingLocked(false)
        activeFocusAnchor = nil
        activeTimeline = nil
        // a brush of the key should read as a flicker, not a cut
        setState(.idle, fastHUDDismiss: true)
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

    // MARK: - the mic, from underneath

    func captureInterrupted(_ reason: CaptureInterruption) {
        switch state {
        case .recording:
            microphone?.cancel()
            setRecordingLocked(false)
            activeFocusAnchor = nil
            activeTimeline = nil
            setState(.idle, fastHUDDismiss: true)
            // they are still holding the key and still talking, and the
            // whole sentence is gone. the one loss path that used to say
            // nothing at all.
            if let notice = CaptureInterruptionNotice.message(for: reason) {
                flashNotice(notice, duration: 2)
            }
        case .idle, .prewarming, .transcribing:
            break
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
        guard state == .recording else {
            return false
        }

        capForcedEnd = true
        keyUp()
        return true
    }

    // MARK: - the app pulling the rug

    /// a setting that rebuilds the capture path (pre-roll) cannot do it
    /// under a live take.
    func abandonRecording() {
        guard state == .recording else {
            return
        }

        microphone?.cancel()
        setRecordingLocked(false)
        activeFocusAnchor = nil
        activeTimeline = nil
        setState(.idle)
    }

    /// the speech model is being taken away: whatever is in flight goes,
    /// silently, and the lamp settles.
    func abandon() {
        invalidatePipeline()
        if state == .recording {
            microphone?.cancel()
            setRecordingLocked(false)
            activeFocusAnchor = nil
            activeTimeline = nil
        }
        setState(.idle)
    }

    // MARK: - retry

    /// re-runs the samples that were thrown on, delivered wherever the
    /// cursor is *now* — the failure may have sent them to another window.
    func retryLastFailure() {
        guard let samples = retryBuffer.take(at: Date()) else {
            clearRetry()
            return
        }
        clearRetry()

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
        setState(.transcribing)
        startPipeline(samples, focusAnchor: inserter.captureAnchor())
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

        pipelineTask = Task { [weak self] in
            await self?.transcribeAndInsert(
                samples,
                focusAnchor: focusAnchor,
                generation: generation
            )
        }
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
            let transcript = try await engine.transcribe(samples)
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
            let textAtCaret = focusAnchor?.textBeforeCursor()
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
                    return
                }
                // silence must not wear the success afterglow.
                reportPipelineFailure(
                    "heard nothing",
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
            let outcome = await inserter.insert(
                pasteTranscript,
                at: focusAnchor
            )
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
        generation: Int,
        duration: TimeInterval = 2.4
    ) {
        guard generation == pipelineGeneration,
              state == .transcribing else {
            return
        }

        setState(.idle, fastHUDDismiss: true)
        flashFeedback(message, duration: duration)
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
            microphone?.cancel()
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

    /// a pill that answers an input lands a run-loop turn after it, as it
    /// always has: the state change before it reaches the panel first.
    private func flashNotice(
        _ message: String,
        duration: TimeInterval = 1.6
    ) {
        Task { @MainActor [weak self] in
            self?.emit(.pill(message, duration: duration))
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
        emit(.pill(message, duration: duration))
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
