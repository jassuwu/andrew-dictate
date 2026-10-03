import Foundation

/// the meeting objects, built the first time something uses them — a
/// meeting starting, or launch finding a spool a crash left behind. until
/// then the menu, the badge and the dictation key are answered from here
/// (not recording, nothing being written out, no call), so a mac that only
/// dictates never builds the tap, the diarizer, the coordinator, the
/// notifier or the call watcher.
@MainActor
final class LazyMeetings {
    /// told once each, the moment it is built, so the owner wires the
    /// callbacks before anything can fire them.
    var onCoordinatorBuilt: ((MeetingCoordinator) -> Void)?
    var onNotifierBuilt: ((MeetingNudgeNotifier) -> Void)?
    var onCallMonitorBuilt: ((CallMonitor) -> Void)?

    private let makeCoordinator: () -> MeetingCoordinator
    private let makeNotifier: () -> MeetingNudgeNotifier
    private let makeCallMonitor: () -> CallMonitor
    private var builtCoordinator: MeetingCoordinator?
    private var builtNotifier: MeetingNudgeNotifier?
    private var builtCallMonitor: CallMonitor?
    /// The sweep of kept audio, every so often while the app runs.
    private var sweeping: Task<Void, Never>?

    /// `callMonitor` is only called by `watchForCalls`, so a holder that
    /// never watches for calls never builds the real one.
    init(
        coordinator: @escaping () -> MeetingCoordinator,
        notifier: @escaping () -> MeetingNudgeNotifier,
        callMonitor: @escaping () -> CallMonitor = { CallMonitor() }
    ) {
        makeCoordinator = coordinator
        makeNotifier = notifier
        makeCallMonitor = callMonitor
    }

    /// the coordinator, built now if nothing has needed it yet. only a use
    /// reaches for this; a question goes through the answers below.
    var coordinator: MeetingCoordinator {
        if let builtCoordinator {
            return builtCoordinator
        }
        let built = makeCoordinator()
        builtCoordinator = built
        onCoordinatorBuilt?(built)
        return built
    }

    /// the notifier, built now if nothing has needed it yet.
    var notifier: MeetingNudgeNotifier {
        if let builtNotifier {
            return builtNotifier
        }
        let built = makeNotifier()
        builtNotifier = built
        onNotifierBuilt?(built)
        return built
    }

    // MARK: - answered without building

    var isRecording: Bool {
        builtCoordinator?.isRecording ?? false
    }

    var isWritingOut: Bool {
        builtCoordinator?.isWritingOut ?? false
    }

    /// what the menu, the badge and the lamp read.
    var phase: MeetingPhase {
        builtCoordinator?.phase ?? .idle
    }

    var elapsed: Duration {
        builtCoordinator?.elapsed ?? .zero
    }

    var recovering: String? {
        builtCoordinator?.recovering
    }

    /// the transcript being made again, which only a built coordinator can
    /// be doing.
    var transcribingAgain: URL? {
        builtCoordinator?.transcribingAgain
    }

    var dictationResponse: MeetingSession.DictationResponse {
        builtCoordinator?.dictationResponse ?? .allow
    }

    /// a meeting that was never started has no tap to probe, no nudge to
    /// answer and nothing to stop.
    func probeTapIsAlive() {
        builtCoordinator?.probeTapIsAlive()
    }

    func keepGoing() {
        builtCoordinator?.keepGoing()
    }

    func stop() {
        builtCoordinator?.stop()
    }

    /// nothing recording and nothing to write out, until there is a
    /// coordinator to have either.
    func untilWrittenOut() async {
        await builtCoordinator?.untilWrittenOut()
    }

    /// a notifier that was never built never asked.
    func withdrawNudge() {
        builtNotifier?.withdraw()
    }

    /// a call watcher that was never started has seen no call.
    var currentCall: String? {
        builtCallMonitor?.currentCall
    }

    var unrecordedCall: String? {
        builtCallMonitor?.unrecordedCall
    }

    func recordingChanged() {
        builtCallMonitor?.recordingChanged()
    }

    func declineTheCall() {
        builtCallMonitor?.declineTheCall()
    }

    // MARK: - calls (ADR 0047)

    /// starts listening for the mic being taken, so a call can be offered on
    /// the pill. only for a mac that can record one: the meeting model
    /// settings chose, on disk. not any model — parakeet is on disk for
    /// anyone who dictates with v3. it costs a listener until somebody takes
    /// the mic. called again, it is already listening.
    func watchForCalls() {
        if let builtCallMonitor {
            builtCallMonitor.start()
            return
        }
        let built = makeCallMonitor()
        builtCallMonitor = built
        built.isRecording = { [weak self] in
            self?.isRecording ?? false
        }
        onCallMonitorBuilt?(built)
        built.start()
    }

    /// the model settings chose is not on this mac: no call is offered that
    /// `record` could not start. a watcher that was never built has nothing
    /// to stop, and is not built to stop it.
    func stopWatchingForCalls() {
        builtCallMonitor?.stop()
    }

    // MARK: - launch

    /// what launch does about meetings, and all it does. `setUp` is the
    /// meeting model settings chose, on disk, or a folder somebody chose:
    /// without either there are no transcripts to repair and no banner from
    /// a past meeting to answer. not just any model on disk: parakeet is
    /// there for anyone who dictates with v3. `watchesForCalls` is the
    /// chosen model alone, because a call can only be offered to a mac that
    /// can record it. a spool a crash left
    /// behind is written out at every launch, but only a spool folder with
    /// something in it builds the coordinator to do it. the returned task is
    /// that recovery, or nil when there is none.
    ///
    /// kept audio past its date is deleted now and once every `sweepEvery`
    /// after, for as long as the app runs (ADR 0048): a look at one folder
    /// off the main thread, so a mac that only dictates still builds
    /// nothing.
    @discardableResult
    func launch(
        setUp: Bool,
        watchesForCalls: Bool = false,
        transcripts: URL,
        spool: MeetingSpool,
        recoveryDelay: Duration,
        keptAudio: KeptAudio? = nil,
        sweepEvery: Duration = .seconds(86_400)
    ) -> Task<Void, Never>? {
        if let keptAudio {
            sweeping?.cancel()
            // for as long as there is an app to sweep for, and no longer.
            sweeping = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled, self != nil {
                    keptAudio.sweep()
                    try? await Task.sleep(for: sweepEvery)
                }
            }
        }
        if setUp {
            // the last run's "meeting saved" banner can still be clicked,
            // and the system hands that click only to a delegate that is
            // already there.
            _ = notifier
            // transcripts written before the app started locking them down
            // are still 0644 — other people's words, readable by every
            // account on the machine. repaired once, off the main thread.
            Task.detached(priority: .utility) {
                MeetingTranscriptFile.lockDown(in: transcripts)
            }
        }
        if watchesForCalls {
            watchForCalls()
        }
        guard spool.mayHoldOrphans() else {
            return nil
        }
        return Task { [weak self] in
            try? await Task.sleep(for: recoveryDelay)
            self?.coordinator.recoverOrphans()
        }
    }
}
