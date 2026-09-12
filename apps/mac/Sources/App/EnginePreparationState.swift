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
