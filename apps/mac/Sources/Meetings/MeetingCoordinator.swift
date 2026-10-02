import Foundation
import os

/// Every number a meeting's health runs on, in one place. Each default is
/// provisional (ADR 0023): all of them need real meetings to tune against.
struct MeetingThresholds: Sendable {
    /// How long the start sound gets to come back through the tap — at the
    /// start, and after every rebuild. Provisional.
    var probeTimeout: Duration = .seconds(1.5)
    /// How long the far side may be silent, while something plays, before
    /// the tap is asked with the quiet probe. Silence alone is never damage.
    /// Provisional.
    var silenceTimeout: Duration = .seconds(120)
    /// RMS at or below this is silence.
    var silenceFloor: Float = 0.001
    /// An hour of nobody speaking asks `still recording?`. Provisional.
    var quietNudgeAfter: Duration = .seconds(3_600)
    /// How long the quiet probe gets to come back through the tap.
    /// Provisional.
    var quietProbeWindow: Duration = .seconds(2)
    /// How long a dead tap is left before it is rebuilt, so a rebuild at
    /// wake does not race the hardware coming back. Provisional.
    var settleBeforeRebuild: Duration = .seconds(1.5)
    /// A rebuild that throws is tried again after each of these: three
    /// tries in a row, two seconds then five apart. Provisional.
    var rebuildSpacing: [Duration] = [.seconds(2), .seconds(5)]
    /// Once those are used up the meeting has a problem, and the tap is
    /// tried once every this long until it is back. Provisional.
    var retryWhileTheProblemStands: Duration = .seconds(30)

    /// How long the mic may hand over nothing but silence, while the far
    /// side talks, before the meeting says it cannot hear you. Provisional.
    var micSilentFor: Duration = .seconds(10)
    /// RMS under this, on the mic, is silence: far below any real room,
    /// whose hiss alone is louder, so only a mic that is not delivering
    /// reads as it.
    var micSilenceFloor: Float = 0.0001

    /// Tries in a row before the meeting stops waiting on the tap.
    var rebuildAttempts: Int { rebuildSpacing.count + 1 }

    static let provisional = MeetingThresholds()
}

/// What the app needs from settings to record a meeting, handed in as values
/// so this file does not care where they are stored.
struct MeetingPreferences: Sendable {
    let folder: URL
    let hook: URL?
    var model: MeetingModel
    /// How long its audio waits once its file is written.
    var keepAudio: KeepMeetingAudio = .default
}

/// The moments the rest of the app shows. The HUD says these in words; the
/// notifier turns `.nudge` into a question with buttons.
enum MeetingEvent: Equatable, Sendable {
    case started
    /// The start sound never came back: the meeting ends before it began.
    /// Only ever at the start — what goes wrong once recording has begun is
    /// a problem, and never opens a window over the call.
    case cannotHear
    /// A spool the app died on is being written out, unasked, at launch. It
    /// loads a 2.9 gb model and can run for a quarter of an hour: the lamp
    /// stays quiet for successes, and this is not one.
    case recovering(app: String)
    case gapBegan
    case gapEnded
    /// Something is wrong that the meeting records through: said on the
    /// lamp, and in the menu until it clears.
    case problemBegan(MeetingSession.Problem)
    /// Over. A mic problem a mute ends is not this: `micMuted` says it,
    /// because "hearing your mic again" would not be true.
    case problemCleared(MeetingSession.Problem)
    /// The mac's input was muted, or turned all the way down: your side is
    /// silent, on purpose as far as anyone can tell. Not a problem, but it
    /// is said, because it is also what a mute nobody meant looks like.
    case micMuted
    case micUnmuted
    case nudge
    case writingItOut
    /// The coverage check found the transcript thin, and the meeting is
    /// being read again from its audio before anything is written. An hour
    /// of it takes minutes, so the lamp says why it is still working.
    case readingAgain
    case saved(MeetingSummary)
    case nothingToKeep
    case hookFailed(String)
    /// The model would not load. The recording stops; the spool stays for
    /// recovery, so the audio is not lost with it.
    case engineFailed(String)
    /// The transcript could not be written where it was asked to go. The
    /// spool stays; the next launch tries again.
    case saveFailed(String)
    /// A meeting's transcript is being made again from its kept audio, with
    /// the model you picked. It loads that model and reads the whole
    /// meeting, minutes for an hour of one, so the lamp says what it is
    /// doing.
    case transcribingAgain(MeetingModel)
    /// The new reading is the file, in the same place.
    case transcribedAgain(MeetingSummary, MeetingModel)
    /// It did not happen — the model failed, or what it read was thin over
    /// a whole transcript, or the audio was gone — and the file is as it
    /// was. The audio is still there for another try.
    case couldNotTranscribeAgain(String)

    /// The words on the lamp. `nil` means the HUD stays quiet.
    var hudText: String? {
        switch self {
        case .started: "recording a meeting"
        // it names the fix and hands you to the one surface allowed to ask
        // for it, rather than naming a switch you then have to go and find.
        // the tap is the whole mac, so the mac is what it cannot hear.
        case .cannotHear: "can't hear the mac — opening setup"
        case .gapBegan: "lost \(Self.themWord) — rebuilding"
        case .gapEnded: "hearing them again"
        case .problemBegan(let problem): Self.began(problem)
        case .problemCleared(let problem): Self.cleared(problem)
        case .micMuted: "your mic is muted"
        // you did it, and you know.
        case .micUnmuted: nil
        case .nudge: nil
        case .recovering(let app): "found an unsaved \(app) recording — writing it out…"
        case .writingItOut: "writing it out…"
        case .readingAgain: "the transcript looked thin — reading the audio again…"
        case .saved(let summary): Self.savedText(summary)
        case .nothingToKeep: "nothing was heard, nothing kept"
        case .hookFailed(let label): "hook failed (\(label))"
        case .engineFailed(let reason): "meeting model failed — \(reason)"
        case .saveFailed(let reason): "couldn't save the transcript — \(reason). kept for next launch"
        case .transcribingAgain(let model): "transcribing again with \(model.shortName)…"
        case .transcribedAgain(let summary, let model): Self.againText(summary, model)
        case .couldNotTranscribeAgain(let reason):
            "couldn't transcribe again — \(reason). the transcript is as it was"
        }
    }

    /// `saved`, said for a file that was replaced: the model that wrote it
    /// now, and the same two ways it can fall short of whole.
    private static func againText(_ summary: MeetingSummary, _ model: MeetingModel) -> String {
        let said = "transcribed again · \(model.shortName)"
        if summary.gapCount > 0 {
            return "\(said) · \(summary.gapCount) \(summary.gapCount == 1 ? "gap" : "gaps")"
        }
        return summary.complete ? said : "\(said) · incomplete, audio kept"
    }

    /// A recovery nobody asked for is about a meeting they had yesterday, so
    /// it does not get the words a live stop gets — it gets the word the
    /// history row already uses.
    private static func savedText(_ summary: MeetingSummary) -> String {
        if summary.recovered {
            return "recovered \(summary.app) — saved · \(summary.duration.spoken)"
        }
        // not whole with no gap in it is a transcript the coverage check
        // found thin, and that one keeps its audio.
        if summary.gapCount == 0, !summary.complete {
            return "saved · incomplete, audio kept"
        }
        if summary.gapCount == 0 {
            return "saved · \(summary.duration.spoken)"
        }
        let word = summary.gapCount == 1 ? "gap" : "gaps"
        return "saved · \(summary.gapCount) \(word)"
    }

    /// What is lost, and what is not: it is mid-call, and whether your side
    /// is still being recorded is the part that decides whether to do
    /// anything.
    private static func began(_ problem: MeetingSession.Problem) -> String {
        switch problem {
        case .cannotHearTheCall: "can't hear the call — still recording your side"
        case .cannotHearAnything: "can't hear the call or your mic — still trying"
        // the mac's name for it, which is what the sound settings list.
        case .cannotHearYourMic(let mic?): "can't hear your mic — \(mic.lowercased())"
        case .cannotHearYourMic(nil): "can't hear your mic"
        case .cannotSaveTheAudio: "can't save the audio — still transcribing"
        case .diskNearlyFull: "disk nearly full"
        }
    }

    private static func cleared(_ problem: MeetingSession.Problem) -> String {
        switch problem {
        case .cannotHearTheCall, .cannotHearAnything: "hearing the call again"
        case .cannotHearYourMic: "hearing your mic again"
        case .cannotSaveTheAudio: "saving the audio again"
        case .diskNearlyFull: "the disk has room again"
        }
    }

    private static let themWord = "the other side"
}

/// Meetings, start to file. Holds the state machine (`MeetingSession`), the
/// tap watchdog (`TapHealthMonitor`) and the live lines of the one being
/// recorded, and the finish sequence: turns → coverage check (and a reading
/// again when thin) → diarize → write → keep or delete the audio → hook. A
/// stopped meeting is written out while the next one records; each has its
/// own spool, engine, start and settings (`Meeting`), and the two share
/// nothing but the tap, which is closed for one before it is opened for the
/// other.
///
/// Everything with a system in it — Core Audio, whisper, notifications — is
/// injected, so this can be driven to the end in a test with fakes.
@MainActor
final class MeetingCoordinator: ObservableObject {
    @Published private(set) var state: MeetingSession.State = .idle
    /// What is wrong while the meeting goes on, for as long as it is: one
    /// of each kind, the worst first.
    @Published private(set) var problems: [MeetingSession.Problem] = []

    /// The worst of them, for wherever there is room to say one.
    var problem: MeetingSession.Problem? {
        problems.first
    }
    @Published private(set) var elapsed: Duration = .zero
    @Published private(set) var liveLines: [LiveLine] = []
    /// The app of the spool being written out at launch, while it runs. The
    /// menu draws it; the pill only says it once.
    @Published private(set) var recovering: String?
    /// The transcript being made again from its kept audio, while one is.
    /// One at a time; history's rows say which.
    @Published private(set) var transcribingAgain: URL?

    var onEvent: (@MainActor (MeetingEvent) -> Void)?
    var onLine: (@MainActor (LiveLine) -> Void)?
    var recordHookRun: (@MainActor (HookRun) -> Void)?
    /// How each meeting ended, once, whatever the ending: the app keeps it
    /// where evidence goes. Never any of the words.
    var keepMeetingRecord: (@MainActor (MeetingRecord) -> Void)?

    let thresholds: MeetingThresholds

    private let source: any MeetingAudioSource
    /// One transcriber per meeting, built for the model chosen at the time —
    /// the setting can change between meetings, not during one.
    private let makeTranscriber: @Sendable (MeetingModel) async throws -> any MeetingTranscriber
    private let diarizer: any MeetingDiarizer
    private let spool: MeetingSpool
    /// Where a meeting's audio goes once its file is written, for as long
    /// as it was meant to stay.
    private let keptAudio: KeptAudio
    private let preferences: @MainActor () -> MeetingPreferences
    private let hookRunner: HookRunner
    private let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "meeting")

    /// The meeting being recorded, from `start` until it stops.
    private var current: Meeting? {
        didSet { wakeWhoeverIsWaiting() }
    }
    /// Meetings that have stopped and are still being written out.
    private var writingOut: [Meeting] = [] {
        didSet { wakeWhoeverIsWaiting() }
    }
    /// Whoever is waiting on the meetings to move on — recovery between
    /// spools, a quit. Each looks again at what it waits for when woken.
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// The last tap being closed, while it still is. One source, one tap:
    /// the next meeting opens it after this, never during it.
    private var tapClosing: Task<Void, Never>?
    /// The last round of recovery, while it still runs. The next waits
    /// behind it, so two never have a meeting model loaded at once.
    private var recovery: Task<Void, Never>?
    private var session: MeetingSession
    private var health: TapHealthMonitor
    /// Whether the mic is heard, for the meeting being recorded.
    private var micWatch: MicWatch
    private var nudgePending = false
    /// The tap hears this app too, so the tones it plays to prove itself —
    /// the start sound after every rebuild, the quiet probe when the far
    /// side has gone quiet — land in the far channel a moment later. Until
    /// this mark passes, audio is proof the tap works and nothing more —
    /// counting our own chirp as the room speaking is what kept the quiet
    /// hour from ever coming round.
    private var probeUntil: Duration = .zero
    /// A rebuilt tap's start sound is on its way: the window runs from the
    /// first chunk the tap delivers, wherever the source stamps it.
    private var probeOpensAtNextChunk = false
    /// Every health check in here is driven by a chunk arriving, so a tap
    /// that stops calling back altogether — the mac slept, the screen
    /// locked, the driver died — freezes the clock instead of failing. These
    /// two are the wall the meeting is measured against when that happens.
    private var startedOn: ContinuousClock.Instant?
    private var lastChunkArrived: ContinuousClock.Instant?
    /// injected so a test can move the wall without waiting on it.
    private let now: @Sendable () -> ContinuousClock.Instant
    /// the date a meeting says it started on, in its file name and its front
    /// matter. injected so two meetings in one test can start on two.
    private let date: @Sendable () -> Date
    private let keepAwake: KeepAwake
    /// The spool's audio file, opened for a meeting: injected so a test can
    /// hand it one that refuses what it is given.
    private let openAudioFile: @Sendable (URL) throws -> any MeetingAudioWriter
    #if DEBUG
    /// The loudest far-side chunk since the probe sweep last looked, while
    /// one runs.
    private var sweepPeak: Float?
    #endif

    /// A system event has already proven something happened, so this may be
    /// short: five seconds of a tap that has not called back is a dead tap.
    private static let silentTapOnWaking = Duration.seconds(5)
    /// Unprompted, nothing has proven anything — so the watchdog waits the
    /// full silence timeout before it says the same thing.
    private static let watchdogInterval = Duration.seconds(10)

    init(
        source: any MeetingAudioSource,
        makeTranscriber: @escaping @Sendable (MeetingModel) async throws -> any MeetingTranscriber,
        diarizer: any MeetingDiarizer,
        spool: MeetingSpool = MeetingSpool(),
        hookRunner: HookRunner = HookRunner(logURL: HookRunner.defaultLogURL),
        keptAudio: KeptAudio? = nil,
        thresholds: MeetingThresholds = .provisional,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        date: @escaping @Sendable () -> Date = { Date() },
        keepAwake: KeepAwake = .system,
        openAudioFile: @escaping @Sendable (URL) throws -> any MeetingAudioWriter = {
            try SpoolAudioFile(url: $0)
        },
        preferences: @escaping @MainActor () -> MeetingPreferences
    ) {
        self.source = source
        self.makeTranscriber = makeTranscriber
        self.diarizer = diarizer
        self.spool = spool
        // beside the spool, wherever the spool is: the app's own folder, or
        // a test's, so no meeting's audio lands anywhere else by default.
        self.keptAudio = keptAudio ?? KeptAudio(
            root: spool.root.deletingLastPathComponent()
                .appendingPathComponent(KeptAudio.folderName, isDirectory: true))
        self.hookRunner = hookRunner
        self.thresholds = thresholds
        self.now = now
        self.date = date
        self.keepAwake = keepAwake
        self.openAudioFile = openAudioFile
        self.preferences = preferences
        session = MeetingSession(quietNudgeAfter: thresholds.quietNudgeAfter)
        health = Self.freshMonitor(thresholds)
        micWatch = Self.freshMicWatch(thresholds)
    }

    var isRecording: Bool {
        state != .idle
    }

    /// A meeting has stopped and its file is not on disk yet.
    var isWritingOut: Bool {
        !writingOut.isEmpty
    }

    /// Returns once nothing is being recorded and every meeting that stopped
    /// is on disk, or never will be. A quit waits on this. The hooks run
    /// after and are not waited for: a summariser can take minutes.
    func untilWrittenOut() async {
        await until { current == nil && writingOut.isEmpty }
    }

    /// ADR 0023: refused while recording or rebuilding, and it says why.
    var dictationResponse: MeetingSession.DictationResponse {
        session.dictationRequest()
    }

    // MARK: - the user's two buttons

    /// What a meeting nobody named is called in its file's name, its front
    /// matter and the hook's payload. Nothing picks an app any more (ADR
    /// 0049).
    nonisolated static let unnamed = "meeting"

    /// `name` is the call app's, once something can tell which one held the
    /// mic at the start (ADR 0047); without one the meeting is `unnamed`.
    /// It is a name and nothing more: the tap hears the whole mac either way.
    func start(name: String? = nil, model: MeetingModel? = nil) {
        guard session.state == .idle else { return }
        // `model` is `record with`: this one meeting's model, in its own
        // snapshot, so the spool, the file and a recovery all say the model
        // that heard it. nil is whatever settings say.
        var snapshot = preferences()
        if let model { snapshot.model = model }
        let meeting = Meeting(
            app: name ?? Self.unnamed, started: date(),
            preferences: snapshot)
        current = meeting
        meeting.awake = keepAwake.hold()

        session.start()
        health = Self.freshMonitor(thresholds)
        micWatch = Self.freshMicWatch(thresholds)
        elapsed = .zero
        liveLines = []
        startedOn = now()
        lastChunkArrived = now()
        nudgePending = false
        probeUntil = thresholds.probeTimeout
        probeOpensAtNextChunk = false
        startWatchdog(for: meeting)
        publish()

        let lastTapClosed = tapClosing
        meeting.capture = Task { [weak self] in
            guard let self else { return }

            // Ours to get right: the spool and the engine. A failure here is
            // the app's, not the permission's, and is told as such.
            let transcriber: any MeetingTranscriber
            let model = meeting.preferences.model
            do {
                let handle = try spool.begin(.init(
                    app: meeting.app, started: meeting.started,
                    engine: model.rawValue, model: model))
                meeting.handle = handle
                meeting.audioFile = try openAudioFile(handle.audioURL)
                transcriber = try await makeTranscriber(model)
            } catch {
                logger.error("meeting could not start: \(error.localizedDescription, privacy: .public)")
                abandonKeepingSpool(meeting)
                onEvent?(.engineFailed(error.localizedDescription))
                return
            }
            meeting.transcriber = transcriber
            listenForLines(transcriber, for: meeting)
            // Loading whisper takes ten-odd seconds; the tap opens now and
            // the transcriber buffers what it is fed until ready.
            let loading = Task { try await transcriber.begin() }
            Task { [weak self] in
                do {
                    try await loading.value
                } catch {
                    guard let self else { return }
                    abandonKeepingSpool(meeting)
                    onEvent?(.engineFailed(error.localizedDescription))
                }
            }

            // The last meeting's tap may still be closing on the same
            // source; this one opens after it, and not at all if it was
            // stopped while it waited.
            await lastTapClosed?.value
            guard current === meeting else { return }

            // Theirs: the tap. This is the one that reads as "can't hear".
            let chunks: AsyncStream<MeetingAudioChunk>
            do {
                chunks = try await source.start()
            } catch {
                logger.error("tap failed to open: \(error.localizedDescription, privacy: .public)")
                loading.cancel()
                guard current === meeting else { return }
                session.neverHeardTheProbe()
                publish()
                onEvent?(.cannotHear)
                stop(announcingNothingKept: false)
                return
            }
            // what the source does by itself, a mic it moved to, goes in the
            // record at the meeting time it stamped. it ends with the tap.
            let sourceEvents = source.sourceEvents
            Task { [weak self] in
                for await event in sourceEvents {
                    guard let self, current === meeting else { return }
                    meeting.notes.note(event.label, at: event.at)
                    heard(event, in: meeting)
                }
            }
            // No output to play the start sound on: the tap was given
            // nothing to hear, so silence through the probe window would
            // prove nothing. Could not check is not cannot hear — the
            // meeting records, and the quiet probe asks the tap later.
            if current === meeting, source.startSoundPlayed == false {
                session.couldNotPlayTheProbe()
                health.probeToneCouldNotPlay(at: elapsed)
                meeting.notes.note(.probeUnplayable, at: elapsed)
                publish()
                started(meeting)
            }
            for await chunk in chunks {
                // a chunk that lands after its meeting stopped is dropped,
                // never handed to the next one.
                guard current === meeting else { break }
                await ingest(chunk, into: meeting)
            }
        }
    }

    func stop() {
        stop(announcingNothingKept: true)
    }

    /// `announcingNothingKept` is false when the lamp has just said "can't
    /// hear" — a second line saying nothing was kept would be the same news
    /// twice.
    private func stop(announcingNothingKept: Bool) {
        guard let meeting = current else { return }
        // A tap that never came back leaves an open gap; closing it at the
        // wall makes the file cover the whole call instead of stopping where
        // the audio did.
        let end = max(elapsed, wallElapsed)
        meeting.notes.stopped = now()
        meeting.notes.ran = end
        let recording = letGo(of: meeting, at: end)
        writingOut.append(meeting)
        let tapClosed = closeTheTap(of: meeting)
        Task { [weak self] in
            await tapClosed.value
            await self?.writeOut(
                meeting, recording: recording,
                announcingNothingKept: announcingNothingKept)
        }
    }

    /// The engine is gone but the audio is not: capture ends, the spool
    /// stays on disk, and the next launch finds it and transcribes it as
    /// `recovered`. Nothing is written now, because a transcript with no
    /// words in it would read as a meeting where nobody spoke.
    ///
    /// Only the meeting being recorded is abandoned. One that has already
    /// stopped is being written out with what it has, and the one recording
    /// now is not its failure to end.
    private func abandonKeepingSpool(_ meeting: Meeting) {
        guard current === meeting else { return }
        let recording = letGo(of: meeting, at: elapsed)
        _ = closeTheTap(of: meeting)
        keepMeetingRecord?(MeetingRecord(
            .modelFailed, app: meeting.app, model: meeting.preferences.model,
            startedAt: meeting.started, duration: elapsed,
            gaps: recording?.gaps ?? [], events: meeting.notes.events,
            spoolWriteFailures: meeting.notes.spoolWriteFailures))
    }

    /// The meeting stops being the one recorded, before anything is
    /// awaited: the menu reads idle at once, a second stop finds nothing to
    /// stop, and the next meeting can start while this one is written out.
    /// Returns what it captured, or nil if it never heard anything.
    private func letGo(of meeting: Meeting, at end: Duration) -> MeetingSession.Recording? {
        current = nil
        meeting.capture?.cancel()
        meeting.lines?.cancel()
        meeting.watchdog?.cancel()
        // a rebuild still waiting its turn is cut short; one already
        // talking to the HAL is let finish, and the tap's close waits on it.
        meeting.rebuild?.cancel()
        // every ending comes through here once — a stop, a model that
        // failed, a tap never heard — so this is where the mac is let go.
        if let awake = meeting.awake {
            keepAwake.release(awake)
            meeting.awake = nil
        }
        let recording = session.finish(at: end)
        startedOn = nil
        publish()
        return recording
    }

    /// The source's stop, once the meeting is done with it: an open or a
    /// rebuild it still has in flight lands first, so the stop is the last
    /// word on its tap. Chained behind the last one, and the next meeting
    /// opens its tap behind this.
    private func closeTheTap(of meeting: Meeting) -> Task<Void, Never> {
        let lastTapClosed = tapClosing
        let capture = meeting.capture
        let rebuild = meeting.rebuild
        let closing = Task { [source] in
            await lastTapClosed?.value
            await capture?.value
            await rebuild?.value
            await source.stop()
        }
        tapClosing = closing
        return closing
    }

    // MARK: - the tap that stopped calling back

    /// Called when the mac wakes or the screen unlocks. `TapHealthMonitor`
    /// only ever hears about a tap that is still delivering buffers, so a
    /// sleep — which stops the callback outright — looks like nothing at all
    /// from inside `ingest`. The wall clock is the only witness: if nothing
    /// has arrived for five seconds across a system event, the tap is gone
    /// and this takes the same route as a quiet probe the tap did not hear
    /// (SPEC §11).
    func probeTapIsAlive() {
        noteTheTapStoppedCallingBack(after: Self.silentTapOnWaking)
    }

    /// The machine never slept; the IOProc died anyway (a driver panic, a
    /// device yanked). Nothing will wake us for that, so a timer asks.
    private func startWatchdog(for meeting: Meeting) {
        meeting.watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: MeetingCoordinator.watchdogInterval)
                guard let self, !Task.isCancelled else { return }
                noteTheTapStoppedCallingBack(after: thresholds.silenceTimeout)
            }
        }
    }

    private func noteTheTapStoppedCallingBack(after limit: Duration) {
        guard let meeting = current, session.state == .recording,
              let lastChunkArrived else { return }
        guard now() - lastChunkArrived >= limit else { return }

        // The gap begins where the audio stopped, not where the wall is now
        // — then the clock catches up, so the menu stops counting a meeting
        // in frames that no longer arrive.
        let lost = elapsed
        elapsed = max(elapsed, wallElapsed)
        loseTheTap(meeting, at: lost)
    }

    /// How long the meeting has actually been going. Audio time is a frame
    /// count and frames stop existing when the tap does.
    private var wallElapsed: Duration {
        guard let startedOn else { return elapsed }
        return now() - startedOn
    }

    /// The nudge asked; the user said yes.
    func keepGoing() {
        session.keepGoing(at: elapsed)
        nudgePending = false
    }

    // MARK: - launch

    /// Spools that outlived the app. Each becomes a transcript flagged
    /// `recovered`, in the background, in order — announced, because a
    /// quarter of an hour of the neural engine at login is not a silent
    /// success, it is a job nobody asked for. A crash costs time and never
    /// the meeting: audio that will not read is set aside, never deleted; a
    /// model that is gone is replaced by another that is installed; and with
    /// none installed the spool waits for a launch that has one.
    func recoverOrphans() {
        // a meeting started in the seconds before this runs, or one still
        // being written out, has a spool that looks just like one a crash
        // left behind. it is not one.
        let ours = ([current] + writingOut).compactMap { $0?.handle }
        // a meeting already on disk whose audio was still being kept when
        // the app stopped: its audio is kept now, and it is not written
        // out a second time.
        let left = spool.writtenOut().filter { !ours.contains($0.handle) }
        if !left.isEmpty {
            let keptAudio = keptAudio
            Task.detached(priority: .utility) {
                for (handle, manifest) in left {
                    keptAudio.adopt(handle, manifest: manifest)
                }
            }
        }
        let orphans = spool.orphans().filter { !ours.contains($0.handle) }
        _ = startRecovering(orphans, tryingAgain: false)
    }

    /// Every recording set aside, brought back to the spool with its tries
    /// cleared and written out once more: what history's `try again` does.
    /// Returns when they have been. Only these are tried — a spool that
    /// failed once at this launch keeps the one try it has left for the
    /// next. One that fails again goes straight back aside, not into
    /// another round of tries nobody asked for.
    func tryAgainSetAside() async {
        let back = spool.bringBackSetAside().filter { $0.manifest.transcript == nil }
        await startRecovering(back, tryingAgain: true)?.value
    }

    /// The spools, one after the other, in the background. One meeting model
    /// at a time, whoever asked: a pass starts when the one before it is
    /// done.
    private func startRecovering(
        _ orphans: [(handle: MeetingSpool.Handle, manifest: MeetingSpool.Manifest)],
        tryingAgain: Bool
    ) -> Task<Void, Never>? {
        guard !orphans.isEmpty else { return nil }
        let before = recovery
        let pass = Task { [weak self] in
            await before?.value
            guard let self else { return }
            defer { recovering = nil }
            for orphan in orphans {
                // a spool waits for the meeting being recorded to stop, and
                // is not called recovering until its turn comes.
                if current != nil {
                    recovering = nil
                    await until { self.current == nil }
                }
                await recover(
                    orphan.handle, manifest: orphan.manifest, tryingAgain: tryingAgain)
                recovering = nil
            }
        }
        recovery = pass
        return pass
    }

    // MARK: - audio

    private func ingest(_ chunk: MeetingAudioChunk, into meeting: Meeting) async {
        elapsed = chunk.at + chunk.duration
        lastChunkArrived = now()
        if probeOpensAtNextChunk {
            probeOpensAtNextChunk = false
            probeUntil = max(probeUntil, chunk.at + thresholds.probeTimeout)
        }
        #if DEBUG
        if let peak = sweepPeak {
            sweepPeak = max(peak, chunk.themRMS)
        }
        #endif
        // A chunk the spool will not take is still transcribed: the meeting
        // goes on, and a problem says what is not being kept.
        var refused: (any Error)?
        var written = false
        if let audioFile = meeting.audioFile {
            do {
                try await audioFile.append(chunk)
                written = true
                // what the spool kept, the speaker split hears, as it goes.
                speakers(of: meeting).hear(chunk)
            } catch {
                refused = error
            }
        }
        // stopped while the chunk was being written: everything below is the
        // meeting being recorded, and this one no longer is.
        guard current === meeting else { return }
        if let refused {
            spoolRefused(meeting, refused)
        } else if written {
            clear(.cannotSaveTheAudio, noting: .audioUnsavedCleared, in: meeting)
        }

        // What the source last heard from the HAL, asked on its own queue:
        // a round trip from here would be one on the main actor, ten times
        // a second.
        let asked = health.verdict == .waitingForQuietProbe
        health.observe(
            rms: chunk.themRMS, elapsed: elapsed,
            anythingIsPlaying: source.anythingIsPlaying)
        switch health.verdict {
        case .waitingForProbeTone, .waitingForQuietProbe:
            break
        case .capturing:
            let heard = chunk.themRMS > thresholds.silenceFloor
            if asked {
                meeting.notes.note(.probeHeard, at: elapsed)
            }
            if session.state == .provingItCanHear {
                session.heardTheProbe()
                publish()
                started(meeting)
            }
            // A lost tap is back once it hears something — its own start
            // sound, as a rule. A chunk of nothing proves only that
            // something calls back, and after a rebuild that failed that is
            // your mic alone.
            if heard, session.state == .rebuilding {
                tapIsBack(meeting)
            }
            // A working tap is not the same thing as a room with people
            // talking in it: the verdict stays `.capturing` through every
            // pause. Only a chunk with sound in it, and only past the probe
            // window, moves the quiet clock — otherwise silence resets the
            // clock that is meant to be measuring it.
            if heard, elapsed > probeUntil {
                session.heardAudio(at: elapsed)
                nudgePending = false
            }
        case .neverHeardTheProbeTone:
            if session.state == .provingItCanHear {
                session.neverHeardTheProbe()
                publish()
                onEvent?(.cannotHear)
                // Nothing was ever heard, so there is nothing to keep and no
                // meeting to keep running: the menu must not say "recording".
                stop(announcingNothingKept: false)
            }
        case .silentWhileSomethingPlays:
            if session.state == .recording {
                askWithTheQuietProbe(meeting)
            }
        case .missedTheQuietProbe:
            if session.state == .recording {
                meeting.notes.note(.probeUnheard, at: elapsed)
                loseTheTap(meeting, at: elapsed)
            }
        }

        watchTheMic(chunk, in: meeting)

        if session.state == .recording || session.state == .rebuilding {
            await meeting.transcriber?.feed(withoutOurTones(chunk))
        }
        guard current === meeting else { return }

        if !nudgePending, session.shouldNudge(at: elapsed) {
            nudgePending = true
            onEvent?(.nudge)
        }
    }

    /// The meeting is recording: the tap was heard, or could not be asked.
    /// What was already known about it is said after, so the lamp's
    /// `recording a meeting` does not cover it.
    private func started(_ meeting: Meeting) {
        onEvent?(.started)
        if micWatch.isMuted {
            onEvent?(.micMuted)
        }
    }

    /// What the source did by itself that the meeting answers to, besides
    /// noting it.
    private func heard(_ event: MeetingSourceEvent, in meeting: Meeting) {
        switch event.kind {
        case .micMuted:
            micWatch.muted(true)
            // silent on purpose: a mic problem standing is over, and the
            // lamp says why rather than that the mic is heard again.
            if session.problemCleared(.cannotHearYourMic) != nil {
                meeting.notes.note(.micSilentCleared, at: elapsed)
                publish()
            }
            // said once the meeting is, if it is not yet.
            if session.state == .recording || session.state == .rebuilding {
                onEvent?(.micMuted)
            }
        case .micUnmuted:
            micWatch.muted(false)
            onEvent?(.micUnmuted)
        case .micChanged, .micHandoffFailed, .micFellBack:
            break
        }
    }

    /// Whether you are heard, while there is a meeting to hear you in: a
    /// mic silent while the call talks is a problem naming it, and over the
    /// moment the mic is heard.
    private func watchTheMic(_ chunk: MeetingAudioChunk, in meeting: Meeting) {
        guard session.state == .recording || session.state == .rebuilding else { return }
        // our own tones land in the far side too, and are not the call.
        let theyTalked = chunk.themRMS > thresholds.silenceFloor && chunk.at >= probeUntil
        micWatch.observe(
            you: chunk.youRMS, theyTalked: theyTalked, from: chunk.at, to: elapsed)
        if !micWatch.unheard {
            clear(.cannotHearYourMic, noting: .micSilentCleared, in: meeting)
        } else if session.problem(.cannotHearYourMic) == nil {
            begin(.cannotHearYourMic(source.micName), noting: .micSilent, in: meeting)
        }
    }

    /// Every chunk the spool would not take is counted for the record; the
    /// first of a run is the problem, and the reason goes in the log.
    private func spoolRefused(_ meeting: Meeting, _ error: any Error) {
        meeting.notes.spoolWriteFailures += 1
        guard session.problem(.cannotSaveTheAudio) == nil else { return }
        logger.error("the spool would not take the audio: \(error.localizedDescription, privacy: .public)")
        begin(.cannotSaveTheAudio, noting: .audioUnsaved, in: meeting)
    }

    /// A problem begins: said on the lamp, and noted in the record. One of
    /// its kind already standing gives way to it and is said again in its
    /// new words, but noted once.
    private func begin(
        _ problem: MeetingSession.Problem, noting label: MeetingRecord.Label, in meeting: Meeting
    ) {
        let stood = session.problem(problem.kind) != nil
        guard session.problemBegan(problem) else { return }
        if !stood {
            meeting.notes.note(label, at: elapsed)
        }
        publish()
        onEvent?(.problemBegan(problem))
    }

    /// The problem of this kind is over, if one stood.
    private func clear(
        _ kind: MeetingSession.Problem.Kind, noting label: MeetingRecord.Label, in meeting: Meeting
    ) {
        guard let problem = session.problemCleared(kind) else { return }
        meeting.notes.note(label, at: elapsed)
        publish()
        onEvent?(.problemCleared(problem))
    }

    /// The chunk as the transcriber gets it: while a probe window is open
    /// the far side is ours — the start sound, or the quiet probe — and a
    /// model given it writes it down as somebody speaking. So the far side
    /// up to the end of the window is handed over as silence, the same
    /// length; your side is handed over as it is, and the spool has
    /// already kept both as they were.
    private func withoutOurTones(_ chunk: MeetingAudioChunk) -> MeetingAudioChunk {
        guard chunk.at < probeUntil else { return chunk }
        let ours = Int(((probeUntil - chunk.at).totalSeconds * MeetingAudioChunk.sampleRate).rounded())
        let silenced = min(ours, chunk.them.count)
        var them = chunk.them
        them.replaceSubrange(0..<silenced, with: repeatElement(0, count: silenced))
        return MeetingAudioChunk(you: chunk.you, them: them, at: chunk.at)
    }

    /// The far side has been silent past the timeout while something
    /// plays. That is a question, not a verdict — you presenting to a muted
    /// room sounds the same — so the tap is asked it the way it was asked at
    /// the start: a tone of ours, quiet this time, which it hears if it
    /// hears anything. Heard, nothing happens and nothing is said.
    private func askWithTheQuietProbe(_ meeting: Meeting) {
        health.askedWithTheQuietProbe(at: elapsed)
        // the tone lands in the far channel like the start sound does:
        // proof the tap works, not the room speaking, so it must not buy
        // the quiet hour back.
        probeUntil = max(probeUntil, elapsed + thresholds.quietProbeWindow)
        Task { [weak self, source] in
            do {
                try await source.playQuietProbe()
            } catch {
                self?.quietProbeCouldNotPlay(meeting, error)
            }
        }
    }

    /// No output to play it on, or a player that would not start: the tap
    /// was asked nothing, and is neither cleared nor called dead for it.
    private func quietProbeCouldNotPlay(_ meeting: Meeting, _ error: any Error) {
        logger.error("the quiet probe could not play: \(error.localizedDescription, privacy: .public)")
        guard current === meeting, health.verdict == .waitingForQuietProbe else { return }
        health.quietProbeCouldNotPlay(at: elapsed)
        meeting.notes.note(.probeUnplayable, at: elapsed)
    }

    /// The tap is dead: the gap begins at `lost`, and the tap is rebuilt.
    private func loseTheTap(_ meeting: Meeting, at lost: Duration) {
        session.tapWentSilent(at: lost)
        meeting.notes.note(.gapBegan, at: lost)
        publish()
        onEvent?(.gapBegan)
        rebuildTap(meeting)
    }

    /// The gap closes where the tap was heard again. If it had been gone
    /// long enough to be a problem, the problem is over too, and that is
    /// the one thing the lamp says.
    private func tapIsBack(_ meeting: Meeting) {
        session.tapRecovered(at: elapsed)
        meeting.notes.note(.gapEnded, at: elapsed)
        guard let problem = session.problemCleared(.cannotHearTheCall) else {
            publish()
            onEvent?(.gapEnded)
            return
        }
        meeting.notes.note(.problemCleared, at: elapsed)
        publish()
        onEvent?(.problemCleared(problem))
    }

    private func rebuildTap(_ meeting: Meeting) {
        guard meeting.rebuild == nil else { return }
        meeting.rebuild = Task { [weak self] in
            defer { meeting.rebuild = nil }
            await self?.keepRebuilding(meeting)
        }
    }

    /// 002 §6's answer to a dead tap, made patient and bounded. The
    /// hardware gets a moment first: a rebuild that races a waking device
    /// comes back as dead as the tap it replaced. One that throws is tried
    /// again, a little further apart each time. Stopped meanwhile, or heard
    /// again, and there is nothing of its own left to rebuild.
    ///
    /// When the tries in a row are used up the meeting does not end: most
    /// of it is on the spool and your side is still arriving. It has a
    /// problem instead, said on the lamp — never a window over the call —
    /// and the tap is tried now and then until one works.
    private func keepRebuilding(_ meeting: Meeting) async {
        var wait = thresholds.settleBeforeRebuild
        var failures = 0
        var notedUnplayable = false
        while await pause(wait), isRebuilding(meeting) {
            let failed: MeetingRecord.Label
            // Set before the rebuild, not after: the tone can be heard the
            // instant the tap is back. Where the window ends is only known
            // then, too: the source stamps the rebuilt tap past the outage,
            // settle and rebuild included, so it runs from the first chunk.
            probeOpensAtNextChunk = true
            do {
                try await source.rebuild()
                // No output to play its start sound on: the rebuilt tap was
                // asked nothing, so the try neither worked nor failed. The
                // gap stays open until the far side is heard, and the tap
                // is tried again at the slow pace meanwhile.
                if source.startSoundPlayed == false {
                    if !notedUnplayable, isRebuilding(meeting) {
                        meeting.notes.note(.probeUnplayable, at: elapsed)
                        notedUnplayable = true
                    }
                    wait = thresholds.retryWhileTheProblemStands
                    continue
                }
                // A rebuilt tap must hear its start sound before it is
                // trusted again, and `ingest` closes the gap the moment it
                // does. One that hears nothing came back as dead as the tap
                // it replaced: every call `noErr`, every buffer zero.
                guard await !heardAgain(meeting) else { return }
                failed = .probeUnheard
            } catch {
                logger.error("tap rebuild failed: \(error.localizedDescription, privacy: .public)")
                failed = .rebuildFailed
            }
            guard isRebuilding(meeting) else { return }
            failures += 1
            // with the problem standing, the problem is the record: a try
            // every half minute for an hour is not kept one by one.
            if session.problem(.cannotHearTheCall) == nil {
                meeting.notes.note(failed, at: elapsed)
            }
            if failures < thresholds.rebuildAttempts {
                wait = thresholds.rebuildSpacing[failures - 1]
            } else {
                if session.problem(.cannotHearTheCall) == nil {
                    cannotHearTheCall(meeting)
                }
                wait = thresholds.retryWhileTheProblemStands
            }
        }
    }

    /// Until the rebuilt tap has been heard, or the probe window has passed
    /// on the real clock. True once the meeting no longer waits on it.
    private func heardAgain(_ meeting: Meeting) async -> Bool {
        let step = Duration.milliseconds(50)
        var waited = Duration.zero
        while isRebuilding(meeting), waited < thresholds.probeTimeout {
            guard await pause(step) else { break }
            waited += step
        }
        return !isRebuilding(meeting)
    }

    private func cannotHearTheCall(_ meeting: Meeting) {
        session.problemBegan(.cannotHearTheCall)
        meeting.notes.note(.problemBegan, at: elapsed)
        publish()
        onEvent?(.problemBegan(.cannotHearTheCall))
    }

    /// The meeting is still the one recorded, and its tap is still lost.
    private func isRebuilding(_ meeting: Meeting) -> Bool {
        current === meeting && session.state == .rebuilding
    }

    /// A wait on the real clock — the injected wall only ever moves when a
    /// test moves it. False when the meeting stopped and cut it short.
    private func pause(_ duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return true
        } catch {
            return false
        }
    }

    private func listenForLines(_ transcriber: any MeetingTranscriber, for meeting: Meeting) {
        meeting.lines = Task { [weak self] in
            for await line in transcriber.lines {
                guard let self, !Task.isCancelled else { break }
                if let i = liveLines.firstIndex(where: { $0.id == line.id }) {
                    liveLines[i] = line
                } else {
                    liveLines.append(line)
                }
                onLine?(line)
            }
        }
    }

    // MARK: - the end

    /// A stopped meeting, once its tap is closed and nothing more can be fed
    /// to it: its last decode, then its file. Everything here is its own,
    /// so the next meeting can be recording all the while.
    private func writeOut(
        _ meeting: Meeting,
        recording: MeetingSession.Recording?,
        announcingNothingKept: Bool
    ) async {
        guard let recording, let handle = meeting.handle else {
            if let handle = meeting.handle { spool.discard(handle) }
            keepMeetingRecord?(MeetingRecord(
                .nothingKept(announcingNothingKept ? .stoppedBeforeCapture : .tapNeverHeard),
                app: meeting.app, model: meeting.preferences.model,
                startedAt: meeting.started, duration: meeting.notes.ran,
                events: meeting.notes.events,
                spoolWriteFailures: meeting.notes.spoolWriteFailures))
            writingOut.removeAll { $0 === meeting }
            if announcingNothingKept { onEvent?(.nothingToKeep) }
            return
        }

        onEvent?(.writingItOut)
        // no more audio is coming: the speaker split's last pieces are heard
        // while the transcriber finishes its own.
        meeting.speakers?.close()
        let live = Reading(
            turns: await meeting.transcriber?.finish() ?? [],
            tally: await meeting.transcriber?.decodeTally())
        meeting.transcriber = nil
        // closed before anything reads it back.
        meeting.audioFile = nil
        // the settings as they were at the start: a folder, model or hook
        // changed since is for the next meeting.
        let prefs = meeting.preferences
        let covered = await cover(
            live, handle: handle, model: prefs.model, gaps: recording.gaps)
        let saved = await save(
            covered, recording: recording, handle: handle,
            app: meeting.app, started: meeting.started, model: prefs.model,
            folder: prefs.folder, keepAudio: prefs.keepAudio, recovered: false,
            notes: meeting.notes, speakers: meeting.speakers)
        if let label = saved?.keep {
            await keep(handle, as: label)
        }
        await sweepKeptAudio()
        // written out — or never will be, and the spool waits for the next
        // launch. the hook is not part of it: it can take minutes.
        writingOut.removeAll { $0 === meeting }
        if let saved {
            await runHook(prefs.hook, telling: saved.event)
        }
    }

    /// The spool's audio into kept audio, off the main actor: an hour of it
    /// is a few seconds of compressing.
    private func keep(_ handle: MeetingSpool.Handle, as label: KeptAudio.Label) async {
        let keptAudio = keptAudio
        let kept = await Task.detached(priority: .utility) {
            keptAudio.keep(handle, label: label)
        }.value
        if !kept {
            // the spool stays, marked: the next launch keeps it from there.
            logger.error("a meeting's audio could not be kept yet; its spool stays")
        }
    }

    /// After every meeting, and every recovery: whatever is past its date.
    private func sweepKeptAudio() async {
        let keptAudio = keptAudio
        _ = await Task.detached(priority: .utility) {
            keptAudio.sweep()
        }.value
    }

    /// The coverage check (ADR 0048), before any audio is let go: the
    /// reading held against what was said. A thin one is read again from
    /// the spool by a fresh transcriber for the same model and checked on
    /// its own numbers. Nothing is written until this is done, so the file
    /// is written once, from whichever reading it settles on.
    private func cover(
        _ live: Reading,
        handle: MeetingSpool.Handle,
        model: MeetingModel,
        gaps: [MeetingSession.Gap]
    ) async -> Covered {
        let farSideLoud = await farSideLoud(in: handle)
        guard case .thin(let reason) = live.verdict(farSideLoud: farSideLoud) else {
            return Covered(reading: live, result: .pass, farSideLoud: farSideLoud)
        }
        onEvent?(.readingAgain)
        guard let again = await readAgain(handle, model: model, gaps: gaps) else {
            return Covered(reading: live, result: .thin, reason: reason, farSideLoud: farSideLoud)
        }
        switch again.verdict(farSideLoud: farSideLoud) {
        case .pass:
            return Covered(
                reading: again, result: .passAfterRerun, reason: reason,
                farSideLoud: farSideLoud)
        case .thin(let reasonAgain):
            // still thin: the reading with more of what was said in it, and
            // its own reason, so the file says why of the lines it holds.
            return again.words > live.words
                ? Covered(reading: again, result: .thin, reason: reasonAgain, farSideLoud: farSideLoud)
                : Covered(reading: live, result: .thin, reason: reason, farSideLoud: farSideLoud)
        }
    }

    /// The spool's own word on how long the far side was heard, read a
    /// block at a time off the main actor. A spool it cannot read says
    /// nothing was, and the check goes on the transcriber's numbers.
    private func farSideLoud(in handle: MeetingSpool.Handle) async -> Duration {
        await farSideLoud(at: handle.audioURL)
    }

    /// The same of any audio file in the spool's shape: a meeting's kept
    /// audio, when it is read again.
    private func farSideLoud(at url: URL) async -> Duration {
        let floor = thresholds.silenceFloor
        let loud = Task.detached(priority: .utility) {
            try SpoolAudioFile.farSideLoud(in: url, above: floor)
        }
        return (try? await loud.value) ?? .zero
    }

    /// The whole spool, through a transcriber of its own, or nil when that
    /// could not be done: the model would not come, or it threw.
    private func readAgain(
        _ handle: MeetingSpool.Handle,
        model: MeetingModel,
        gaps: [MeetingSession.Gap]
    ) async -> Reading? {
        let url = handle.audioURL
        do {
            let audio = try await Task.detached(priority: .utility) {
                try SpoolAudioFile.read(url)
            }.value
            let transcriber = try await makeTranscriber(model)
            let turns = try await transcriber.transcribe(you: audio.you, them: audio.them)
            return Reading(
                turns: SpoolClock.onTheMeetingsClock(turns, gaps: gaps),
                tally: await transcriber.decodeTally())
        } catch {
            logger.error("could not read a thin meeting again: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// What a written meeting leaves for after the file: what the hook is
    /// told, and the label its audio is to be kept under, or nil when the
    /// spool is already gone.
    private struct Saved {
        let event: MeetingSavedEvent
        let keep: KeptAudio.Label?
    }

    /// turns → diarize → write → let the spool go, or mark it to be kept.
    /// Returns what comes after the file, or nil when it could not be
    /// written. `speakers` is the split that heard the meeting as it went;
    /// without one, the spool is heard now.
    private func save(
        _ covered: Covered,
        recording: MeetingSession.Recording,
        handle: MeetingSpool.Handle,
        app: String,
        started: Date,
        model: MeetingModel,
        folder: URL,
        keepAudio: KeepMeetingAudio,
        recovered: Bool,
        notes: MeetingRecord.Notes = .init(),
        speakers: SpeakerSplit? = nil
    ) async -> Saved? {
        let turns = covered.reading.turns
        let tally = covered.reading.tally
        let (split, speakersReport) = await splitSpeakers(
            in: turns, heardBy: speakers, spool: handle.audioURL, gaps: recording.gaps)

        let thin = covered.result == .thin
        let transcript = MeetingTranscript(
            app: app,
            started: started,
            duration: recording.duration,
            engine: model.rawValue,
            gaps: recording.gaps,
            recovered: recovered,
            reason: thin ? covered.reason : nil,
            nobodySpoke: !thin && covered.reading.nobodySpoke,
            turns: split
        )
        func record(
            _ outcome: MeetingRecord.Outcome, toDisk: Duration? = nil,
            audioKept: Bool = false, until: Date? = nil
        ) -> MeetingRecord {
            MeetingRecord(
                outcome, app: app, model: model, startedAt: started,
                duration: recording.duration, gaps: recording.gaps, turns: split,
                toDisk: toDisk, recovered: recovered, events: notes.events,
                tally: tally,
                coverage: .init(
                    covered.result, reason: covered.reason, tally: tally,
                    farSideLoud: covered.farSideLoud),
                audioKept: audioKept, audioKeptUntil: until, split: speakersReport,
                spoolWriteFailures: notes.spoolWriteFailures)
        }

        let url: URL
        do {
            url = try MeetingTranscriptFile.write(transcript, in: folder)
        } catch {
            // The spool stays: it is the only copy, and next launch will
            // find it and try again. Said out loud — "writing it out…" was
            // the last thing the lamp showed, and silence after it would
            // read as done (SPEC §4).
            logger.error("could not write the transcript: \(error.localizedDescription, privacy: .public)")
            keepMeetingRecord?(record(.couldNotWrite))
            onEvent?(.saveFailed(error.localizedDescription))
            return nil
        }
        // the audio waits as long as the setting said, and a thin
        // meeting's until you delete it: it is the only way to check the
        // file, or read it again.
        var keep: KeptAudio.Label?
        if thin || keepAudio.keptFor != nil {
            keep = KeptAudio.Label(
                transcript: url, started: started, model: model,
                until: thin ? nil : keepAudio.keptFor.map { keptAudio.now().addingTimeInterval($0) })
            // marked before anything is awaited: from here no launch writes
            // this spool out a second time, whatever happens to the app
            // while its audio is being kept.
            if !spool.keep(handle, writtenTo: url) {
                logger.error("could not mark a written-out spool as kept")
            }
        } else {
            try? spool.finish(handle)
        }
        keepMeetingRecord?(record(
            thin ? .savedThin : .saved, toDisk: notes.stopped.map { now() - $0 },
            audioKept: keep != nil, until: keep?.until))

        let summary = (try? MeetingTranscriptFile.summary(of: url)) ?? MeetingSummary(
            fileURL: url, app: app, started: started, duration: recording.duration,
            complete: transcript.complete, gapCount: recording.gaps.count,
            recovered: recovered)
        onEvent?(.saved(summary))

        return Saved(
            event: MeetingSavedEvent(
                transcript: url,
                app: app,
                startedAt: started,
                durationS: Int(recording.duration.components.seconds),
                complete: transcript.complete,
                gaps: recording.gaps.map { [$0.began.totalSeconds, $0.ended.totalSeconds] },
                recovered: recovered),
            keep: keep)
    }

    private func runHook(_ hook: URL?, telling event: MeetingSavedEvent) async {
        guard let hook else { return }
        let run = await hookRunner.run(executable: hook, event: event)
        recordHookRun?(run)
        if run.outcome != .succeeded {
            onEvent?(.hookFailed(run.outcome.label))
        }
    }

    /// The meeting's speaker split, begun with the first audio the spool
    /// keeps. Nothing waits on it: it hears the far side a piece at a time
    /// off the main actor.
    private func speakers(of meeting: Meeting) -> SpeakerSplit {
        if let speakers = meeting.speakers {
            return speakers
        }
        let speakers = SpeakerSplit(diarizer.hearing(), now: now)
        meeting.speakers = speakers
        return speakers
    }

    /// The far side's speakers, from the split that heard the meeting as it
    /// went — or, for a spool nothing heard (one a crash left), from one
    /// that hears it now, a piece at a time. The split hears the spool, so
    /// it is asked about the turns on the spool's clock, and the file keeps
    /// the stamps the meeting actually had (`SpoolClock`).
    private func splitSpeakers(
        in turns: [MeetingTurn],
        heardBy speakers: SpeakerSplit?,
        spool url: URL,
        gaps: [MeetingSession.Gap]
    ) async -> (turns: [MeetingTurn], report: SpeakerSplit.Report?) {
        let split: SpeakerSplit
        if let speakers {
            split = speakers
        } else {
            split = SpeakerSplit(diarizer.hearing(), now: now)
            await split.hear(spool: url)
        }
        let (found, report) = await split.split(SpoolClock.onTheSpool(turns, gaps: gaps))
        return (SpoolClock.speakers(of: found, onto: turns), report)
    }

    private func recover(
        _ handle: MeetingSpool.Handle,
        manifest: MeetingSpool.Manifest,
        tryingAgain: Bool
    ) async {
        let audio: (you: [Float], them: [Float])
        do {
            audio = try SpoolAudioFile.read(handle.audioURL)
        } catch {
            // audio the app cannot read is still the only copy of the
            // meeting, and the next build or a person with another tool may
            // be able to: it is kept, where settings says it is.
            logger.error("could not read a spool, so it is set aside: \(error.localizedDescription, privacy: .public)")
            spool.setAside(handle)
            keepMeetingRecord?(MeetingRecord(
                .setAsideUnreadable, app: manifest.app, model: manifest.model,
                startedAt: manifest.started, duration: .zero, recovered: true))
            return
        }
        guard !audio.them.isEmpty || !audio.you.isEmpty else {
            // it reads, and there is nothing in it: a meeting that never
            // captured a sample. the only audio recovery lets go.
            spool.discard(handle)
            keepMeetingRecord?(MeetingRecord(
                .nothingKept(.spoolEmpty), app: manifest.app, model: manifest.model,
                startedAt: manifest.started, duration: .zero, recovered: true))
            return
        }
        let duration = Duration.seconds(
            Double(max(audio.you.count, audio.them.count)) / MeetingAudioChunk.sampleRate)
        // the model that actually reads it, which the file and the record
        // name: not always the one the manifest does.
        var model = manifest.model
        do {
            guard let ready = try await transcriberForRecovery(preferring: manifest.model) else {
                // nothing to read it with, which is nothing wrong with the
                // spool: no attempt is counted and it is not set aside. a
                // launch with a model on this mac writes it out. one that
                // was asked for goes back, so the line that counts it does.
                logger.error("no meeting model is installed, so a spool waits")
                if tryingAgain {
                    spool.setAside(handle)
                }
                keepMeetingRecord?(MeetingRecord(
                    .waitingForModel, app: manifest.app, model: manifest.model,
                    startedAt: manifest.started, duration: duration, recovered: true))
                return
            }
            let transcriber = ready.transcriber
            model = ready.model
            // said once it is known to be happening: a spool that waits, or
            // will not read, is not being written out, whatever the lamp says.
            recovering = manifest.app
            onEvent?(.recovering(app: manifest.app))
            let turns = try await transcriber.transcribe(you: audio.you, them: audio.them)
            let reading = Reading(turns: turns, tally: await transcriber.decodeTally())
            // checked like any meeting, and not read again: this was the
            // reading from the spool.
            let covered = Covered(
                checking: reading, farSideLoud: await farSideLoud(in: handle))
            // a spool from a past run has no settings of its own; it goes
            // where meetings go now.
            let prefs = preferences()
            let saved = await save(
                covered,
                recording: .init(duration: duration, gaps: []),
                handle: handle,
                app: manifest.app,
                started: manifest.started,
                model: model,
                folder: prefs.folder,
                keepAudio: prefs.keepAudio,
                recovered: true)
            if let label = saved?.keep {
                await keep(handle, as: label)
            }
            await sweepKeptAudio()
            if let saved {
                await runHook(prefs.hook, telling: saved.event)
            }
        } catch {
            // Only logging it meant the same quarter of an hour was spent on
            // the same failure at every launch, forever. Two tries, then the
            // spool is set aside — kept, out of the retry loop, and said out
            // loud in settings › history, which can try it again. one
            // somebody asked to be tried again has had the one try it was
            // asked for.
            logger.error("could not recover a spool: \(error.localizedDescription, privacy: .public)")
            let noted = spool.noteAttempt(handle, manifest: manifest)
            let setAside = tryingAgain
                || (noted.attempts ?? 0) >= MeetingSpool.attemptsBeforeSettingAside
            if setAside {
                spool.setAside(handle)
            }
            keepMeetingRecord?(MeetingRecord(
                setAside ? .setAside : .couldNotRecover, app: manifest.app,
                model: model, startedAt: manifest.started,
                duration: duration, recovered: true))
        }
    }

    /// The order a spool is read in when the model that recorded it is gone:
    /// the one that translates, then the faster whisper, then parakeet,
    /// which only knows english and the european languages.
    private static let modelsToRecoverWith: [MeetingModel] = [
        .whisperLargeV3, .whisperLargeV3Turbo, .parakeetV3,
    ]

    /// A transcriber for the model a spool was recorded with, or for another
    /// meeting model that is on this mac when that one is not; nil when none
    /// is. Anything but a model missing is the model's failure and is thrown.
    private func transcriberForRecovery(
        preferring model: MeetingModel
    ) async throws -> (transcriber: any MeetingTranscriber, model: MeetingModel)? {
        for candidate in [model] + Self.modelsToRecoverWith.filter({ $0 != model }) {
            do {
                return (try await makeTranscriber(candidate), candidate)
            } catch is MeetingModel.NotInstalled {
                continue
            }
        }
        return nil
    }

    // MARK: -

    private func publish() {
        state = session.state
        problems = session.problems
    }

    /// Returns once `done` is true, looking again each time a meeting starts,
    /// stops or is written out.
    private func until(_ done: () -> Bool) async {
        while !done() {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    private func wakeWhoeverIsWaiting() {
        let woken = waiting
        waiting = []
        for continuation in woken {
            continuation.resume()
        }
    }

    private static func freshMicWatch(_ t: MeetingThresholds) -> MicWatch {
        MicWatch(after: t.micSilentFor, floor: t.micSilenceFloor)
    }

    private static func freshMonitor(_ t: MeetingThresholds) -> TapHealthMonitor {
        TapHealthMonitor(
            probeTimeout: t.probeTimeout,
            silenceTimeout: t.silenceTimeout,
            quietProbeWindow: t.quietProbeWindow,
            silenceFloor: t.silenceFloor)
    }
}

#if DEBUG
extension MeetingCoordinator {
    /// Development only, for measurement 02: during a meeting, the quiet
    /// probe at five levels, two seconds apart, each logged with the
    /// loudest far-side chunk the tap delivered in the second after it,
    /// beside the silence floor. A second with no tone comes first: what
    /// the tap delivers while we play nothing.
    func sweepTheQuietProbe() {
        guard current != nil, let tap = source as? CoreAudioMeetingSource else { return }
        let floor = thresholds.silenceFloor
        Task { [weak self] in
            self?.sweepPeak = 0
            try? await Task.sleep(for: .seconds(1))
            guard let self, current != nil else { return }
            let quiet = sweepPeak ?? 0
            logger.notice("probe sweep: no tone, peak far-side rms \(quiet, format: .fixed(precision: 5), privacy: .public), floor \(floor, format: .fixed(precision: 5), privacy: .public)")
            for level: Float in [-30, -40, -50, -60, -70] {
                guard current != nil else { break }
                sweepPeak = 0
                let began = ContinuousClock.now
                let tone = Task { try await tap.playQuietProbe(dBFS: level) }
                try? await Task.sleep(until: began + .seconds(1))
                let peak = sweepPeak ?? 0
                let played = (try? await tone.value) != nil
                logger.notice("probe sweep: \(level, format: .fixed(precision: 0), privacy: .public) dBFS, played \(played, privacy: .public), peak far-side rms \(peak, format: .fixed(precision: 5), privacy: .public), \(peak / floor, format: .fixed(precision: 1), privacy: .public)x the floor of \(floor, format: .fixed(precision: 5), privacy: .public)")
                try? await Task.sleep(until: began + .seconds(2))
            }
            sweepPeak = nil
        }
    }
}
#endif

extension MeetingCoordinator {
    /// The mac kept out of idle sleep while a meeting records: a quiet
    /// hour is still a meeting, and a mac that sleeps through it ends the
    /// recording by itself. The display may sleep; the mac may not. A pair,
    /// so a test can count what is taken and given back.
    struct KeepAwake {
        let hold: @MainActor () -> any NSObjectProtocol
        let release: @MainActor (any NSObjectProtocol) -> Void

        /// ProcessInfo's activity, like dictation's display assertion: the
        /// same IOKit assertion underneath, listed by `pmset -g assertions`
        /// as "recording a meeting", and dropped by the system if the app
        /// dies.
        static var system: KeepAwake {
            KeepAwake(
                hold: {
                    ProcessInfo.processInfo.beginActivity(
                        options: .idleSystemSleepDisabled,
                        reason: "recording a meeting")
                },
                release: { ProcessInfo.processInfo.endActivity($0) })
        }
    }

    /// One meeting's own things: the spool it writes to, the engine that
    /// listens to it, and what it started as. A meeting that has stopped
    /// keeps them until it is written out, and the next one is handed its
    /// own, so the two have nothing to reach into each other for.
    @MainActor
    private final class Meeting {
        /// What the meeting is called in its file and the hook: the name it
        /// was started with, or `meeting`.
        let app: String
        let started: Date
        /// Read once, at the start: the folder, the model and the hook this
        /// meeting is written out with, whatever settings say by the end.
        let preferences: MeetingPreferences
        /// Set once the spool is open, and nil for good if it never was.
        var handle: MeetingSpool.Handle?
        var audioFile: (any MeetingAudioWriter)?
        /// Its far side's speakers, heard a piece at a time as the spool
        /// keeps it. Begun with the first audio kept.
        var speakers: SpeakerSplit?
        var transcriber: (any MeetingTranscriber)?
        /// Opens the tap, then reads it until the meeting stops.
        var capture: Task<Void, Never>?
        var lines: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        /// A rebuild of its tap, while one is in flight.
        var rebuild: Task<Void, Never>?
        /// The mac kept from idle sleep, from its start until it is let go.
        var awake: (any NSObjectProtocol)?
        /// What its record will say besides what the file does.
        var notes = MeetingRecord.Notes()

        init(app: String, started: Date, preferences: MeetingPreferences) {
            self.app = app
            self.started = started
            self.preferences = preferences
        }
    }

    /// One reading of a meeting: its turns, and the transcriber's count of
    /// its work when it keeps one.
    private struct Reading {
        var turns: [MeetingTurn]
        var tally: StretchTally?

        /// Counted the way the file counts its `words:`.
        var words: Int {
            turns.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        }

        func verdict(farSideLoud: Duration) -> CoverageCheck.Verdict {
            let sides = CoverageCheck.sides(of: turns, tally: tally)
            return CoverageCheck.verdict(you: sides.you, them: sides.them, farSideLoud: farSideLoud)
        }

        var nobodySpoke: Bool {
            let sides = CoverageCheck.sides(of: turns, tally: tally)
            return CoverageCheck.nobodySpoke(you: sides.you, them: sides.them)
        }
    }

    /// The reading a meeting is written from, and how the check came out.
    private struct Covered {
        var reading: Reading
        var result: CoverageCheck.Result
        /// Why the check found it thin — the last time, for one that stayed
        /// thin; the first, for one that passed when it was read again.
        var reason: String?
        var farSideLoud: Duration

        init(
            reading: Reading, result: CoverageCheck.Result, reason: String? = nil,
            farSideLoud: Duration
        ) {
            self.reading = reading
            self.result = result
            self.reason = reason
            self.farSideLoud = farSideLoud
        }

        /// Checked once, with no reading again.
        init(checking reading: Reading, farSideLoud: Duration) {
            switch reading.verdict(farSideLoud: farSideLoud) {
            case .pass:
                self.init(reading: reading, result: .pass, farSideLoud: farSideLoud)
            case .thin(let reason):
                self.init(reading: reading, result: .thin, reason: reason, farSideLoud: farSideLoud)
            }
        }
    }
}

// MARK: - transcribing again

extension MeetingCoordinator {
    /// Why a transcript was left as it was, in the words the lamp uses.
    /// What a model or the disk threw is said as it came.
    private enum AgainFailure: LocalizedError {
        case recording
        case busy
        /// Its front matter would not read: there is nothing to keep the
        /// meeting's facts from.
        case unreadable
        case noAudio
        /// There is a file and nothing in it. Read, it would say nobody
        /// spoke, over a transcript of a meeting where somebody did.
        case emptyAudio
        /// You threw it away while it was being redone.
        case deleted
        /// The new reading did not cover what was said, over a transcript
        /// that did.
        case thin(MeetingModel, String)
        /// It found no speech on either side, over a transcript with words.
        case nobodySpoke(MeetingModel)

        var errorDescription: String? {
            switch self {
            case .recording: "a meeting is being recorded"
            case .busy: "another one is running"
            case .unreadable: "the transcript can't be read"
            case .noAudio: "the audio is gone"
            case .emptyAudio: "the audio is empty"
            case .deleted: "the transcript was deleted"
            case .thin(let model, let reason): "\(model.shortName) read it thin: \(reason)"
            case .nobodySpoke(let model): "\(model.shortName) heard nobody speak"
            }
        }
    }

    /// What one go at it had found out by the time it ended, for the record
    /// it leaves whichever way it ended.
    private struct Attempt {
        var header: MeetingTranscriptFile.Header?
        var entry: KeptAudio.Entry?
        var turns: [MeetingTurn] = []
        var covered: Covered?
    }

    /// A meeting's transcript read again from its kept audio by `model`, and
    /// the file replaced where it is. One at a time, and not while a meeting
    /// is recorded: a second model beside the recording's is the recording's
    /// to pay for. Whatever goes wrong leaves the file as it was, says so on
    /// the lamp, and leaves the audio for another try.
    ///
    /// The kept audio is read whole, not a block at a time:
    /// `transcribe(you:them:)` takes the two sides as arrays, as a
    /// recovery's does, so an hour of the meeting is in memory while it
    /// runs.
    func transcribeAgain(_ transcript: URL, with model: MeetingModel) async {
        if isRecording {
            onEvent?(.couldNotTranscribeAgain(AgainFailure.recording.localizedDescription))
            return
        }
        if transcribingAgain != nil {
            onEvent?(.couldNotTranscribeAgain(AgainFailure.busy.localizedDescription))
            return
        }
        transcribingAgain = transcript
        onEvent?(.transcribingAgain(model))
        let prefs = preferences()
        let asked = now()
        var attempt = Attempt()
        let told: MeetingSavedEvent?
        do {
            told = try await remake(
                transcript, with: model, prefs: prefs, asked: asked, attempt: &attempt)
        } catch {
            told = nil
            logger.error("could not transcribe a meeting again: \(error.localizedDescription, privacy: .public)")
            // a rerun that left the file as it was is still one, and its
            // record says what it got as far as knowing. one that could not
            // even read the file has nothing to say of the meeting.
            if let header = attempt.header {
                let covered = attempt.covered
                keepMeetingRecord?(MeetingRecord(
                    .unchanged, app: header.app, model: model, startedAt: header.started,
                    duration: header.duration, gaps: header.gaps, turns: attempt.turns,
                    recovered: header.recovered, tally: covered?.reading.tally,
                    coverage: covered.map {
                        MeetingRecord.Coverage(
                            $0.result, reason: $0.reason, tally: $0.reading.tally,
                            farSideLoud: $0.farSideLoud)
                    },
                    audioKept: attempt.entry != nil, audioKeptUntil: attempt.entry?.label.until,
                    again: true))
            }
            onEvent?(.couldNotTranscribeAgain(error.localizedDescription))
        }
        // done before the hook, which can take minutes: the next one may go.
        transcribingAgain = nil
        if let told {
            await runHook(prefs.hook, telling: told)
        }
    }

    /// Everything but the hook. Returns what the hook is to be told.
    private func remake(
        _ transcript: URL,
        with model: MeetingModel,
        prefs: MeetingPreferences,
        asked: ContinuousClock.Instant,
        attempt: inout Attempt
    ) async throws -> MeetingSavedEvent {
        let header: MeetingTranscriptFile.Header
        do {
            header = try MeetingTranscriptFile.header(of: transcript)
        } catch {
            throw AgainFailure.unreadable
        }
        attempt.header = header
        guard let entry = keptAudio.entry(for: transcript) else {
            throw AgainFailure.noAudio
        }
        attempt.entry = entry
        let url = entry.audio
        let audio = try await Task.detached(priority: .utility) {
            try SpoolAudioFile.read(url)
        }.value
        guard !audio.you.isEmpty || !audio.them.isEmpty else {
            throw AgainFailure.emptyAudio
        }
        let transcriber = try await makeTranscriber(model)
        let turns = try await transcriber.transcribe(you: audio.you, them: audio.them)
        let reading = Reading(
            turns: SpoolClock.onTheMeetingsClock(turns, gaps: header.gaps),
            tally: await transcriber.decodeTally())
        // checked like any reading, and not read again: this was.
        let covered = Covered(checking: reading, farSideLoud: await farSideLoud(at: url))
        let (split, _) = await splitSpeakers(
            in: reading.turns, heardBy: nil, spool: url, gaps: header.gaps)
        attempt.turns = split
        attempt.covered = covered

        let thin = covered.result == .thin
        // a thin file is the one whose audio is kept until you delete it.
        let wasThin = entry.label.until == nil && !header.complete
        // a thin reading may stand in for a thin one — you asked, and the
        // file says so — but never for a whole transcript, which is lost
        // the moment it is replaced.
        if thin, !wasThin {
            throw AgainFailure.thin(model, covered.reason ?? "")
        }
        // the same for a model that heard nobody: that passes the check, and
        // would say so over a transcript that has words in it.
        if reading.nobodySpoke, header.words > 0 {
            throw AgainFailure.nobodySpoke(model)
        }
        let again = MeetingTranscript(
            app: header.app, started: header.started, duration: header.duration,
            engine: model.rawValue, gaps: header.gaps, recovered: header.recovered,
            reason: thin ? covered.reason : nil,
            nobodySpoke: !thin && reading.nobodySpoke,
            turns: split)
        do {
            try MeetingTranscriptFile.replace(at: transcript, with: again, timeZone: header.timeZone)
        } catch MeetingTranscriptFile.Failure.gone {
            throw AgainFailure.deleted
        }

        // audio kept until you deleted it because the file was thin is an
        // ordinary meeting's once a reading covers it: it waits as long as
        // the setting says, from now. every other date is as it was, and
        // the audio is not deleted here either way.
        var until = entry.label.until
        if wasThin, !thin {
            until = keptAudio.now().addingTimeInterval(prefs.keepAudio.keptFor ?? 0)
        }
        let audioKept = keptAudio.relabel(entry, model: model, until: until)
        if !audioKept {
            logger.error("a meeting's audio could not be relabelled after its transcript was made again")
        }
        keepMeetingRecord?(MeetingRecord(
            thin ? .savedThin : .saved, app: header.app, model: model,
            startedAt: header.started, duration: header.duration, gaps: header.gaps,
            turns: split, toDisk: now() - asked, recovered: header.recovered,
            tally: reading.tally,
            coverage: .init(
                covered.result, reason: covered.reason, tally: reading.tally,
                farSideLoud: covered.farSideLoud),
            audioKept: audioKept, audioKeptUntil: audioKept ? until : nil, again: true))
        onEvent?(.transcribedAgain(
            (try? MeetingTranscriptFile.summary(of: transcript)) ?? MeetingSummary(
                fileURL: transcript, app: header.app, started: header.started,
                duration: header.duration, complete: again.complete,
                gapCount: header.gaps.count, recovered: header.recovered),
            model))
        return MeetingSavedEvent(
            transcript: transcript,
            app: header.app,
            startedAt: header.started,
            durationS: Int(header.duration.components.seconds),
            complete: again.complete,
            gaps: header.gaps.map { [$0.began.totalSeconds, $0.ended.totalSeconds] },
            recovered: header.recovered,
            again: true)
    }
}
