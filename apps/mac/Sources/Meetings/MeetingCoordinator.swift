import Foundation
import os

/// The two knobs and the three timeouts a meeting runs on. Provisional
/// (ADR 0023): all of them need a real meeting to tune against.
struct MeetingThresholds: Sendable {
    let probeTimeout: Duration
    let silenceTimeout: Duration
    let silenceFloor: Float
    let quietNudgeAfter: Duration

    static let provisional = MeetingThresholds(
        probeTimeout: .seconds(1.5),
        silenceTimeout: .seconds(120),
        silenceFloor: 0.001,
        quietNudgeAfter: .seconds(3_600)
    )
}

/// What the app needs from settings to record a meeting, handed in as values
/// so this file does not care where they are stored.
struct MeetingPreferences: Sendable {
    let folder: URL
    let hook: URL?
    let model: MeetingModel
    /// How long its audio waits once its file is written.
    var keepAudio: KeepMeetingAudio = .default
}

/// The moments the rest of the app shows. The HUD says these in words; the
/// notifier turns `.nudge` into a question with buttons.
enum MeetingEvent: Equatable, Sendable {
    case started
    case cannotHear
    /// A spool the app died on is being written out, unasked, at launch. It
    /// loads a 2.9 gb model and can run for a quarter of an hour: the lamp
    /// stays quiet for successes, and this is not one.
    case recovering(app: String)
    case gapBegan
    case gapEnded
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
        case .nudge: nil
        case .recovering(let app): "found an unsaved \(app) recording — writing it out…"
        case .writingItOut: "writing it out…"
        case .readingAgain: "the transcript looked thin — reading the audio again…"
        case .saved(let summary): Self.savedText(summary)
        case .nothingToKeep: "nothing was heard, nothing kept"
        case .hookFailed(let label): "hook failed (\(label))"
        case .engineFailed(let reason): "meeting model failed — \(reason)"
        case .saveFailed(let reason): "couldn't save the transcript — \(reason). kept for next launch"
        }
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
    @Published private(set) var elapsed: Duration = .zero
    @Published private(set) var liveLines: [LiveLine] = []
    /// The app of the spool being written out at launch, while it runs. The
    /// menu draws it; the pill only says it once.
    @Published private(set) var recovering: String?

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
    private var nudgePending = false
    /// The tap hears this app too, so the start sound it plays to prove
    /// itself lands in the far channel a moment after every rebuild. Until
    /// this mark passes, audio is proof the tap works and nothing more —
    /// counting our own chirp as the room speaking is what kept the quiet
    /// hour from ever coming round.
    private var probeUntil: Duration = .zero
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
        self.preferences = preferences
        session = MeetingSession(quietNudgeAfter: thresholds.quietNudgeAfter)
        health = Self.freshMonitor(thresholds)
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
    func start(name: String? = nil) {
        guard session.state == .idle else { return }
        let meeting = Meeting(
            app: name ?? Self.unnamed, started: date(),
            preferences: preferences())
        current = meeting

        session.start()
        health = Self.freshMonitor(thresholds)
        elapsed = .zero
        liveLines = []
        startedOn = now()
        lastChunkArrived = now()
        nudgePending = false
        probeUntil = thresholds.probeTimeout
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
                meeting.audioFile = try SpoolAudioFile(url: handle.audioURL)
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
                }
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
            gaps: recording?.gaps ?? [], events: meeting.notes.events))
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
    /// and this takes the same route a zero-sample buffer would (SPEC §11).
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
        session.tapWentSilent(at: elapsed)
        meeting.notes.note(.gapBegan, at: elapsed)
        elapsed = max(elapsed, wallElapsed)
        publish()
        onEvent?(.gapBegan)
        rebuildTap(meeting)
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
    /// success, it is a job nobody asked for.
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
        if let audioFile = meeting.audioFile {
            try? await audioFile.append(chunk)
        }
        // stopped while the chunk was being written: everything below is the
        // meeting being recorded, and this one no longer is.
        guard current === meeting else { return }

        // What the source last heard from the HAL, asked on its own queue:
        // a round trip from here would be one on the main actor, ten times
        // a second.
        health.observe(
            rms: chunk.themRMS, elapsed: elapsed,
            anythingIsPlaying: source.anythingIsPlaying)
        switch health.verdict {
        case .waitingForProbeTone:
            break
        case .capturing:
            let wasRebuilding = session.state == .rebuilding
            if session.state == .provingItCanHear {
                session.heardTheProbe()
                publish()
                onEvent?(.started)
            }
            session.tapRecovered(at: elapsed)
            if wasRebuilding {
                meeting.notes.note(.gapEnded, at: elapsed)
                onEvent?(.gapEnded)
                publish()
            }
            // A working tap is not the same thing as a room with people
            // talking in it: the verdict stays `.capturing` through every
            // pause. Only a chunk with sound in it, and only past the probe
            // window, moves the quiet clock — otherwise silence resets the
            // clock that is meant to be measuring it.
            if chunk.themRMS > thresholds.silenceFloor, elapsed > probeUntil {
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
        case .wentSilent:
            if session.state == .recording {
                session.tapWentSilent(at: elapsed)
                meeting.notes.note(.gapBegan, at: elapsed)
                publish()
                onEvent?(.gapBegan)
                rebuildTap(meeting)
            }
        }

        if session.state == .recording || session.state == .rebuilding {
            await meeting.transcriber?.feed(chunk)
        }
        guard current === meeting else { return }

        if !nudgePending, session.shouldNudge(at: elapsed) {
            nudgePending = true
            onEvent?(.nudge)
        }
    }

    private func rebuildTap(_ meeting: Meeting) {
        guard meeting.rebuild == nil else { return }
        meeting.rebuild = Task { [weak self] in
            defer { meeting.rebuild = nil }
            // stopped before the rebuild began: there is no tap of its own
            // left to rebuild.
            guard let self, current === meeting else { return }
            do {
                // Set before the rebuild, not after: the tone can be heard
                // the instant the tap is back.
                probeUntil = elapsed + thresholds.probeTimeout
                try await source.rebuild()
                // A rebuilt tap must hear something before it is trusted
                // again; a rebuild that produces silence is just a new gap.
            } catch {
                logger.error("tap rebuild failed: \(error.localizedDescription, privacy: .public)")
                guard current === meeting else { return }
                session.rebuildFailed()
                meeting.notes.note(.rebuildFailed, at: elapsed)
                publish()
                onEvent?(.cannotHear)
                // Most of a meeting is on the spool; write what there is.
                stop(announcingNothingKept: false)
            }
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
                events: meeting.notes.events))
            writingOut.removeAll { $0 === meeting }
            if announcingNothingKept { onEvent?(.nothingToKeep) }
            return
        }

        onEvent?(.writingItOut)
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
            notes: meeting.notes)
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
        let url = handle.audioURL
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
                turns: Self.onTheMeetingsClock(turns, gaps: gaps),
                tally: await transcriber.decodeTally())
        } catch {
            logger.error("could not read a thin meeting again: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A spool has nothing in it for a gap, so a turn read from it is
    /// stamped on the spool's clock. Moved on over every gap that began
    /// before it, it is back on the meeting's — the reverse of what
    /// `splitSpeakers` does for the diarizer.
    private static func onTheMeetingsClock(
        _ turns: [MeetingTurn],
        gaps: [MeetingSession.Gap]
    ) -> [MeetingTurn] {
        guard !gaps.isEmpty else { return turns }
        return turns.map { turn in
            var at = turn.at
            for gap in gaps where at >= gap.began {
                at += gap.duration
            }
            return MeetingTurn(speaker: turn.speaker, at: at, text: turn.text)
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
    /// written.
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
        notes: MeetingRecord.Notes = .init()
    ) async -> Saved? {
        let turns = covered.reading.turns
        let tally = covered.reading.tally
        let them = (try? SpoolAudioFile.read(handle.audioURL))?.them ?? []
        let split = them.isEmpty
            ? turns
            : await splitSpeakers(in: turns, them: them, gaps: recording.gaps)

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
                audioKept: audioKept, audioKeptUntil: until)
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

    /// The diarizer hears the spool, and a gap is time nothing was written to
    /// it: after one, a turn stamped on the meeting's clock sits past the end
    /// of the audio and every speaker after it would be guessed from the last
    /// segment. So the lookup gets times shifted back over the gaps before
    /// them, and the file keeps the stamps the meeting actually had.
    private func splitSpeakers(
        in turns: [MeetingTurn],
        them: [Float],
        gaps: [MeetingSession.Gap]
    ) async -> [MeetingTurn] {
        guard !gaps.isEmpty else {
            return await diarizer.split(them: them, turns: turns)
        }
        let shifted = turns.map { turn in
            MeetingTurn(
                speaker: turn.speaker,
                at: max(.zero, turn.at - Self.lost(before: turn.at, in: gaps)),
                text: turn.text)
        }
        let split = await diarizer.split(them: them, turns: shifted)
        guard split.count == turns.count else { return split }
        return zip(turns, split).map {
            MeetingTurn(speaker: $1.speaker, at: $0.at, text: $0.text)
        }
    }

    private static func lost(
        before at: Duration,
        in gaps: [MeetingSession.Gap]
    ) -> Duration {
        gaps.reduce(.zero) { total, gap in
            guard at > gap.began else { return total }
            return total + (min(at, gap.ended) - gap.began)
        }
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
                // launch with a model on this mac writes it out.
                logger.error("no meeting model is installed, so a spool waits")
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
            // spool is set aside — kept, never retried, and said out loud in
            // settings › history.
            logger.error("could not recover a spool: \(error.localizedDescription, privacy: .public)")
            let noted = spool.noteAttempt(handle, manifest: manifest)
            let setAside = (noted.attempts ?? 0) >= MeetingSpool.attemptsBeforeSettingAside
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

    private static func freshMonitor(_ t: MeetingThresholds) -> TapHealthMonitor {
        TapHealthMonitor(
            probeTimeout: t.probeTimeout,
            silenceTimeout: t.silenceTimeout,
            silenceFloor: t.silenceFloor)
    }
}

extension MeetingCoordinator {
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
        var audioFile: SpoolAudioFile?
        var transcriber: (any MeetingTranscriber)?
        /// Opens the tap, then reads it until the meeting stops.
        var capture: Task<Void, Never>?
        var lines: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        /// A rebuild of its tap, while one is in flight.
        var rebuild: Task<Void, Never>?
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
