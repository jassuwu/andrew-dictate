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
}
