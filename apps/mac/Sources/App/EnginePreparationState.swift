enum EnginePreparationState: Equatable, Sendable {
    case notStarted
    case downloading(progress: Double)
    case warmingUp
    case ready
    case failed

    var isReady: Bool {
        self == .ready
    }
}

extension EnginePreparationState {
    /// what the pill says when the dictation key is pressed before the
    /// speech model can honour it. nil means the press needs no answer:
    /// `.ready` is not early, and `.failed` already speaks for itself.
    func pressedEarlyNotice(downloadSize: String) -> String? {
        switch self {
        case .notStarted:
            "downloading the speech model — \(downloadSize)"
        case let .downloading(progress):
            """
            downloading the speech model — \
            \(Int((min(max(progress, 0), 1) * 100).rounded()))%
            """
        case .warmingUp:
            "loading the speech model…"
        case .ready, .failed:
            nil
        }
    }
}

extension EnginePreparationState {
    /// what a press of the dictation key does about a speech model that
    /// can't take it yet.
    enum EarlyPress: Equatable, Sendable {
        /// nothing has asked for one: the press is the ask.
        case startPreparing
        /// the last load failed. usually a blip, so try again, out loud —
        /// the alternative is a key that never answers again.
        case retryPreparing
        /// already on its way.
        case wait
    }

    var earlyPress: EarlyPress {
        switch self {
        case .notStarted:
            .startPreparing
        case .failed:
            .retryPreparing
        case .downloading, .warmingUp, .ready:
            .wait
        }
    }
}
