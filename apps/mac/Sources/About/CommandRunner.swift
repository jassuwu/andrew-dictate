import Foundation
import os

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

/// the real runner: one `Process`. stdin is /dev/null, so nothing can wait
/// on a terminal that is not there. output goes to two temporary files,
/// not pipes: brew can print more than a pipe holds, and a child that
/// outlives brew would hold a pipe open past brew's exit.
struct ProcessRunner: CommandRunner {
    func run(_ command: Command) async -> CommandResult {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appending(
            path: "andrew-dictate-run-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer {
            try? fileManager.removeItem(at: folder)
        }
        let outURL = folder.appending(path: "stdout")
        let errURL = folder.appending(path: "stderr")
        guard (try? fileManager.createDirectory(
                  at: folder,
                  withIntermediateDirectories: true
              )) != nil,
              fileManager.createFile(atPath: outURL.path, contents: nil),
              fileManager.createFile(atPath: errURL.path, contents: nil),
              let out = try? FileHandle(forWritingTo: outURL),
              let err = try? FileHandle(forWritingTo: errURL)
        else {
            return CommandResult(ending: .couldNotStart, stdout: "", stderr: "")
        }

        let ending = await Self.ending(of: command, stdout: out, stderr: err)
        try? out.close()
        try? err.close()
        return CommandResult(
            ending: ending,
            stdout: Self.text(at: outURL),
            stderr: Self.text(at: errURL)
        )
    }

    private static func ending(
        of command: Command,
        stdout: FileHandle,
        stderr: FileHandle
    ) async -> CommandResult.Ending {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = command.executable
            process.arguments = command.arguments
            process.environment = command.environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout
            process.standardError = stderr

            let deadlinePassed = OSAllocatedUnfairLock(initialState: false)
            process.terminationHandler = { finished in
                let status = finished.terminationReason == .uncaughtSignal
                    ? 128 + finished.terminationStatus
                    : finished.terminationStatus
                let timedOut = deadlinePassed.withLock { $0 }
                continuation.resume(
                    returning: timedOut ? .timedOut : .exited(status)
                )
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: .couldNotStart)
                return
            }

            DispatchQueue.global().asyncAfter(
                deadline: .now() + command.timeout
            ) {
                guard process.isRunning else {
                    return
                }
                deadlinePassed.withLock { $0 = true }
                process.terminate()
                // a command that shrugs off SIGTERM gets the one it cannot.
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
    }

    private static func text(at url: URL) -> String {
        String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
    }
}
