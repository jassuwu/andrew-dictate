import Foundation

/// the meeting coordinator, built the first time something uses it — a
/// meeting starting, or launch finding a spool a crash left behind. until
/// then the menu, the badge and the dictation key are answered from here
/// (not recording, nothing being written out), so a mac that only dictates
/// never builds the tap, the diarizer or the coordinator.
@MainActor
final class LazyMeetings {
    /// told once, the moment the coordinator is built, so its owner wires
    /// the callbacks before anything can fire them.
    var onCoordinatorBuilt: ((MeetingCoordinator) -> Void)?

    private let makeCoordinator: () -> MeetingCoordinator
    private var builtCoordinator: MeetingCoordinator?

    init(coordinator: @escaping () -> MeetingCoordinator) {
        makeCoordinator = coordinator
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

    // MARK: - answered without building

    var isRecording: Bool {
        builtCoordinator?.isRecording ?? false
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

    // MARK: - launch

    /// what launch does about meetings, and all it does. `setUp` is a
    /// meeting model on disk or a folder somebody chose: without either
    /// there are no transcripts to repair. a spool a crash left behind is
    /// written out at every launch, but only a spool folder with something
    /// in it builds the coordinator to do it. the returned task is that
    /// recovery, or nil when there is none.
    @discardableResult
    func launch(
        setUp: Bool,
        transcripts: URL,
        spool: MeetingSpool,
        recoveryDelay: Duration
    ) -> Task<Void, Never>? {
        if setUp {
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
