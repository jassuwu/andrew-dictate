import Foundation

/// the meeting objects, built the first time something uses them — a
/// meeting starting, or launch finding a spool a crash left behind. until
/// then the menu, the badge and the dictation key are answered from here
/// (not recording, nothing being written out), so a mac that only dictates
/// never builds the tap, the diarizer, the coordinator or the notifier.
@MainActor
final class LazyMeetings {
    /// told once each, the moment it is built, so the owner wires the
    /// callbacks before anything can fire them.
    var onCoordinatorBuilt: ((MeetingCoordinator) -> Void)?
    var onNotifierBuilt: ((MeetingNudgeNotifier) -> Void)?

    private let makeCoordinator: () -> MeetingCoordinator
    private let makeNotifier: () -> MeetingNudgeNotifier
    private var builtCoordinator: MeetingCoordinator?
    private var builtNotifier: MeetingNudgeNotifier?

    init(
        coordinator: @escaping () -> MeetingCoordinator,
        notifier: @escaping () -> MeetingNudgeNotifier
    ) {
        makeCoordinator = coordinator
        makeNotifier = notifier
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

    var elapsed: Duration {
        builtCoordinator?.elapsed ?? .zero
    }

    var recovering: String? {
        builtCoordinator?.recovering
    }

    var app: RunningApp? {
        builtCoordinator?.app
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

    // MARK: - launch

    /// what launch does about meetings, and all it does. `setUp` is a
    /// meeting model on disk or a folder somebody chose: without either
    /// there are no transcripts to repair and no banner from a past meeting
    /// to answer. a spool a crash left behind is written out at every
    /// launch, but only a spool folder with something in it builds the
    /// coordinator to do it. the returned task is that recovery, or nil
    /// when there is none.
    @discardableResult
    func launch(
        setUp: Bool,
        transcripts: URL,
        spool: MeetingSpool,
        recoveryDelay: Duration
    ) -> Task<Void, Never>? {
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
        guard spool.mayHoldOrphans() else {
            return nil
        }
        return Task { [weak self] in
            try? await Task.sleep(for: recoveryDelay)
            self?.coordinator.recoverOrphans()
        }
    }
}
