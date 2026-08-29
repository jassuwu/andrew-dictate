import Foundation

/// What a hook is told when a meeting has been saved. The transcript path
/// goes in as `$1`, this goes in as json on stdin, and the same facts ride
/// along as `ANDREW_*` for one-line shell hooks (ADR 0040).
struct MeetingSavedEvent: Equatable, Sendable {
    static let name = "meeting-saved"

    let transcript: URL
    let app: String
    let startedAt: Date
    let durationS: Int
    let complete: Bool
    /// `[began_s, ended_s]` pairs.
    let gaps: [[Double]]
    let recovered: Bool

    var folder: URL { transcript.deletingLastPathComponent() }

    func payloadJSON() throws -> Data {
        let object: [String: Any] = [
            "event": Self.name,
            "transcript": transcript.path,
            "folder": folder.path,
            "app": app,
            "started_at": Self.iso8601.string(from: startedAt),
            "duration_s": durationS,
            "complete": complete,
            "gaps": gaps,
            "recovered": recovered,
        ]
        return try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    func environment() -> [String: String] {
        // Formatted by hand: JSONSerialization prints 41.2 as
        // 41.200000000000003, which is true and useless in a shell.
        let gapsJSON = "["
            + gaps.map { pair in
                "[" + pair.map { String(format: "%.1f", $0) }.joined(separator: ",") + "]"
            }.joined(separator: ",")
            + "]"
        return [
            "ANDREW_EVENT": Self.name,
            "ANDREW_TRANSCRIPT": transcript.path,
            "ANDREW_FOLDER": folder.path,
            "ANDREW_APP": app,
            "ANDREW_STARTED_AT": Self.iso8601.string(from: startedAt),
            "ANDREW_DURATION_S": String(durationS),
            "ANDREW_COMPLETE": String(complete),
            "ANDREW_GAPS": gapsJSON,
            "ANDREW_RECOVERED": String(recovered),
        ]
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

enum HookOutcome: Equatable, Codable, Sendable {
    case succeeded
    case failed(exitCode: Int32)
    case couldNotLaunch(String)

    /// The words the settings row shows.
    var label: String {
        switch self {
        case .succeeded: "ok"
        case .failed(let code): "exit \(code)"
        case .couldNotLaunch(let reason): "could not launch: \(reason)"
        }
    }
}

struct HookRun: Equatable, Codable, Sendable {
    let finishedAt: Date
    let outcome: HookOutcome
}

/// Runs the one hook. No timeout, on purpose: a summariser talking to a local
/// model may take minutes, and killing it would be the app deciding how long
/// your script is allowed to take. Everything it prints lands in the log.
struct HookRunner: Sendable {
    let logURL: URL

    static var defaultLogURL: URL {
        AppIdentity.supportDirectory.appendingPathComponent("hooks.log")
    }

    func run(executable: URL, event: MeetingSavedEvent) async -> HookRun {
        let header = "=== \(Self.stamp()) \(MeetingSavedEvent.name) \(event.transcript.path) ===\n"

        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            let reason = FileManager.default.fileExists(atPath: executable.path)
                ? "not executable"
                : "no such file"
            append(header + "could not launch \(executable.path): \(reason)\n=== exit — ===\n")
            return HookRun(finishedAt: Date(), outcome: .couldNotLaunch(reason))
        }

        let payload: Data
        do {
            payload = try event.payloadJSON()
        } catch {
            append(header + "could not encode the event: \(error)\n=== exit — ===\n")
            return HookRun(
                finishedAt: Date(), outcome: .couldNotLaunch("could not encode the event"))
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = [event.transcript.path]
        process.environment = ProcessInfo.processInfo.environment
            .merging(event.environment()) { _, new in new }
        process.currentDirectoryURL = event.folder

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        // Drain stdout/stderr while the hook runs: a pipe holds 64 KB, and a
        // hook that prints more would block on write and never exit — with
        // no timeout, forever.
        let reader = output.fileHandleForReading
        let drained = Task.detached(priority: .utility) {
            (try? reader.readToEnd()) ?? Data()
        }

        let status: Int32? = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                append(header + "could not launch \(executable.path): \(error.localizedDescription)\n=== exit — ===\n")
                continuation.resume(returning: nil)
                return
            }
            // Feed stdin on a background queue so a hook that never reads it
            // cannot stall us, then close so `cat` sees EOF.
            let writer = input.fileHandleForWriting
            DispatchQueue.global(qos: .utility).async {
                try? writer.write(contentsOf: payload)
                try? writer.close()
            }
        }

        guard let status else {
            return HookRun(finishedAt: Date(), outcome: .couldNotLaunch("could not start"))
        }

        let printed = await drained.value
        var text = header
        text += String(decoding: printed, as: UTF8.self)
        if !text.hasSuffix("\n") { text += "\n" }
        text += "=== exit \(status) ===\n"
        append(text)

        return HookRun(
            finishedAt: Date(),
            outcome: status == 0 ? .succeeded : .failed(exitCode: status))
    }

    private func append(_ text: String) {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    private static func stamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
