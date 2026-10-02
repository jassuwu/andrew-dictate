import Foundation

/// one command, run to its end or to its deadline.
struct Command: Equatable, Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
}

struct CommandResult: Equatable, Sendable {
    enum Ending: Equatable, Sendable {
        /// a signal reads as a shell would report it, 128 + the signal.
        case exited(Int32)
        case timedOut
        case couldNotStart
    }

    let ending: Ending
    let stdout: String
    let stderr: String
}

/// runs a command in the background. a protocol so the tests drive
/// success, failure and the timeout without brew.
protocol CommandRunner: Sendable {
    func run(_ command: Command) async -> CommandResult
}
