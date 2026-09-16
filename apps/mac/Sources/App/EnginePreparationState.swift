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
