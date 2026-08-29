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
}

/// The moments the rest of the app shows. The HUD says these in words; the
/// notifier turns `.nudge` into a question with buttons.
enum MeetingEvent: Equatable, Sendable {
    case started(app: String)
    case cannotHear(app: String)
    case gapBegan
    case gapEnded
    case nudge
    case writingItOut
    case saved(MeetingSummary)
    case nothingToKeep
    case hookFailed(String)

    /// The words on the lamp. `nil` means the HUD stays quiet.
    var hudText: String? {
        switch self {
        case .started(let app): "recording \(app)"
        case .cannotHear(let app): "can't hear \(app) — allow system audio recording in privacy settings"
        case .gapBegan: "lost \(Self.themWord) — rebuilding"
        case .gapEnded: "hearing them again"
        case .nudge: nil
        case .writingItOut: "writing it out…"
        case .saved(let summary):
            summary.gapCount == 0
                ? "saved · \(Self.clock(summary.duration))"
                : "saved · \(summary.gapCount) \(summary.gapCount == 1 ? "gap" : "gaps")"
        case .nothingToKeep: "nothing was heard, nothing kept"
        case .hookFailed(let label): "hook failed (\(label))"
        }
    }

    private static let themWord = "the other side"

    static func clock(_ duration: Duration) -> String {
        let s = duration.components.seconds
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

/// One meeting, start to file. Holds the state machine (`MeetingSession`),
/// the tap watchdog (`TapHealthMonitor`), the spool, the live lines, and the
/// finish sequence: turns → diarize → write → delete spool → hook.
///
/// Everything with a system in it — Core Audio, whisper, notifications — is
/// injected, so this can be driven to the end in a test with fakes.
@MainActor
final class MeetingCoordinator: ObservableObject {
    @Published private(set) var state: MeetingSession.State = .idle
    @Published private(set) var app: RunningApp?
    @Published private(set) var elapsed: Duration = .zero
    @Published private(set) var liveLines: [LiveLine] = []

    var onEvent: (@MainActor (MeetingEvent) -> Void)?
    var recordHookRun: (@MainActor (HookRun) -> Void)?

    private let source: any MeetingAudioSource
    private let transcriber: any MeetingTranscriber
    private let diarizer: any MeetingDiarizer
    private let spool: MeetingSpool
    private let preferences: @MainActor () -> MeetingPreferences
    private let hookRunner: HookRunner
    private let thresholds: MeetingThresholds
    private let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "meeting")

    private var session: MeetingSession
    private var health: TapHealthMonitor
    private var handle: MeetingSpool.Handle?
    private var audioFile: SpoolAudioFile?
    private var startedAt = Date()
    private var captureTask: Task<Void, Never>?
    private var linesTask: Task<Void, Never>?
    private var nudgePending = false
    private var isRebuilding = false

    init(
        source: any MeetingAudioSource,
        transcriber: any MeetingTranscriber,
        diarizer: any MeetingDiarizer,
        spool: MeetingSpool = MeetingSpool(),
        hookRunner: HookRunner = HookRunner(logURL: HookRunner.defaultLogURL),
        thresholds: MeetingThresholds = .provisional,
        preferences: @escaping @MainActor () -> MeetingPreferences
    ) {
        self.source = source
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.spool = spool
        self.hookRunner = hookRunner
        self.thresholds = thresholds
        self.preferences = preferences
        session = MeetingSession(quietNudgeAfter: thresholds.quietNudgeAfter)
        health = Self.freshMonitor(thresholds)
    }

    var isRecording: Bool {
        state != .idle
    }

    /// ADR 0023: refused while recording or rebuilding, and it says why.
    var dictationResponse: MeetingSession.DictationResponse {
        session.dictationRequest()
    }

    // MARK: - the user's two buttons

    func start(tapping app: RunningApp) {
        guard session.state == .idle else { return }
        let prefs = preferences()

        session.start()
        health = Self.freshMonitor(thresholds)
        self.app = app
        elapsed = .zero
        liveLines = []
        startedAt = Date()
        nudgePending = false
        publish()

        let appName = MeetingApps.displayName(app)
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let handle = try spool.begin(.init(
                    app: appName, started: startedAt,
                    engine: prefs.model.rawValue, model: prefs.model))
                self.handle = handle
                audioFile = try SpoolAudioFile(url: handle.audioURL)
                try await transcriber.begin()
                listenForLines()
                let chunks = try await source.start(tapping: app)
                for await chunk in chunks {
                    guard !Task.isCancelled else { break }
                    await ingest(chunk)
                }
            } catch {
                logger.error("meeting capture failed: \(error.localizedDescription, privacy: .public)")
                session.neverHeardTheProbe()
                session.rebuildFailed()
                publish()
                if session.state == .cannotHear {
                    onEvent?(.cannotHear(app: appName))
                }
            }
        }
    }

    func stop() {
        guard session.state != .idle, let app else { return }
        captureTask?.cancel()
        captureTask = nil
        linesTask?.cancel()
        linesTask = nil
        let appName = MeetingApps.displayName(app)

        Task { [weak self] in
            guard let self else { return }
            await source.stop()
            let recording = session.finish(at: elapsed)
            publish()

            guard let recording, let handle else {
                if let handle { spool.discard(handle) }
                self.handle = nil
                audioFile = nil
                onEvent?(.nothingToKeep)
                return
            }

            onEvent?(.writingItOut)
            let turns = await transcriber.finish()
            audioFile = nil
            await finish(
                turns: turns, recording: recording, handle: handle,
                app: appName, started: startedAt, model: preferences().model,
                recovered: false)
        }
    }

    /// The nudge asked; the user said yes.
    func keepGoing() {
        session.keepGoing(at: elapsed)
        nudgePending = false
    }

    // MARK: - launch

    /// Spools that outlived the app. Each becomes a transcript flagged
    /// `recovered`, in the background, in order.
    func recoverOrphans() {
        let orphans = spool.orphans()
        guard !orphans.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            for orphan in orphans {
                await recover(orphan.handle, manifest: orphan.manifest)
            }
        }
    }

    // MARK: - audio

    private func ingest(_ chunk: MeetingAudioChunk) async {
        elapsed = chunk.at + chunk.duration
        if let audioFile {
            try? await audioFile.append(chunk)
        }

        health.observe(rms: chunk.themRMS, elapsed: elapsed)
        switch health.verdict {
        case .waitingForProbeTone:
            break
        case .capturing:
            let wasRebuilding = session.state == .rebuilding
            if session.state == .provingItCanHear {
                session.heardTheProbe()
                publish()
                if let app { onEvent?(.started(app: MeetingApps.displayName(app))) }
            }
            session.tapRecovered(at: elapsed)
            if wasRebuilding { onEvent?(.gapEnded); publish() }
            session.heardAudio(at: elapsed)
            nudgePending = false
        case .neverHeardTheProbeTone:
            if session.state == .provingItCanHear {
                session.neverHeardTheProbe()
                publish()
                if let app { onEvent?(.cannotHear(app: MeetingApps.displayName(app))) }
            }
        case .wentSilent:
            if session.state == .recording {
                session.tapWentSilent(at: elapsed)
                publish()
                onEvent?(.gapBegan)
                rebuildTap()
            }
        }

        if session.state == .recording || session.state == .rebuilding {
            await transcriber.feed(chunk)
        }

        if !nudgePending, session.shouldNudge(at: elapsed) {
            nudgePending = true
            onEvent?(.nudge)
        }
    }

    private func rebuildTap() {
        guard !isRebuilding else { return }
        isRebuilding = true
        Task { [weak self] in
            guard let self else { return }
            defer { isRebuilding = false }
            do {
                try await source.rebuild()
                // A rebuilt tap must hear something before it is trusted
                // again; a rebuild that produces silence is just a new gap.
            } catch {
                logger.error("tap rebuild failed: \(error.localizedDescription, privacy: .public)")
                session.rebuildFailed()
                publish()
                if let app { onEvent?(.cannotHear(app: MeetingApps.displayName(app))) }
            }
        }
    }

    private func listenForLines() {
        linesTask = Task { [weak self] in
            guard let self else { return }
            for await line in transcriber.lines {
                guard !Task.isCancelled else { break }
                if let i = liveLines.firstIndex(where: { $0.id == line.id }) {
                    liveLines[i] = line
                } else {
                    liveLines.append(line)
                }
            }
        }
    }

    // MARK: - the end

    private func finish(
        turns: [MeetingTurn],
        recording: MeetingSession.Recording,
        handle: MeetingSpool.Handle,
        app: String,
        started: Date,
        model: MeetingModel,
        recovered: Bool
    ) async {
        let them = (try? SpoolAudioFile.read(handle.audioURL))?.them ?? []
        let split = them.isEmpty ? turns : await diarizer.split(them: them, turns: turns)

        let transcript = MeetingTranscript(
            app: app,
            started: started,
            duration: recording.duration,
            engine: model.rawValue,
            gaps: recording.gaps,
            recovered: recovered,
            turns: split
        )

        let prefs = preferences()
        let url: URL
        do {
            url = try MeetingTranscriptFile.write(transcript, in: prefs.folder)
        } catch {
            // The spool stays: it is the only copy, and next launch will
            // find it and try again.
            logger.error("could not write the transcript: \(error.localizedDescription, privacy: .public)")
            self.handle = nil
            return
        }
        try? spool.finish(handle)
        self.handle = nil

        let summary = (try? MeetingTranscriptFile.summary(of: url)) ?? MeetingSummary(
            fileURL: url, app: app, started: started, duration: recording.duration,
            complete: recording.isComplete, gapCount: recording.gaps.count,
            recovered: recovered)
        onEvent?(.saved(summary))

        guard let hook = prefs.hook else { return }
        let event = MeetingSavedEvent(
            transcript: url,
            app: app,
            startedAt: started,
            durationS: Int(recording.duration.components.seconds),
            complete: recording.isComplete,
            gaps: recording.gaps.map { [Self.seconds($0.began), Self.seconds($0.ended)] },
            recovered: recovered
        )
        let run = await hookRunner.run(executable: hook, event: event)
        recordHookRun?(run)
        if run.outcome != .succeeded {
            onEvent?(.hookFailed(run.outcome.label))
        }
    }

    private func recover(_ handle: MeetingSpool.Handle, manifest: MeetingSpool.Manifest) async {
        guard let audio = try? SpoolAudioFile.read(handle.audioURL),
              !audio.them.isEmpty || !audio.you.isEmpty
        else {
            spool.discard(handle)
            return
        }
        let duration = Duration.seconds(
            Double(max(audio.you.count, audio.them.count)) / MeetingAudioChunk.sampleRate)
        do {
            let turns = try await transcriber.transcribe(you: audio.you, them: audio.them)
            await finish(
                turns: turns,
                recording: .init(duration: duration, gaps: []),
                handle: handle,
                app: manifest.app,
                started: manifest.started,
                model: manifest.model,
                recovered: true)
        } catch {
            logger.error("could not recover a spool: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: -

    private func publish() {
        state = session.state
    }

    private static func freshMonitor(_ t: MeetingThresholds) -> TapHealthMonitor {
        TapHealthMonitor(
            probeTimeout: t.probeTimeout,
            silenceTimeout: t.silenceTimeout,
            silenceFloor: t.silenceFloor)
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
