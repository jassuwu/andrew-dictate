import Darwin
import Foundation

struct AskInvocation: Equatable, Sendable {
    let cli: AgentCLI
    let executable: String
    let arguments: [String]
    let environment: [String: String]
}

enum AskInvocationCompositionError: Error, Equatable {
    case invalidTemplate
    case unknownAgentCLI
}

enum AskPromptComposer {
    static let spokenBrevityInstruction =
        "answer in at most two short spoken sentences."

    static func compose(
        _ prompt: String,
        voiceAnswersEnabled: Bool
    ) -> String {
        guard voiceAnswersEnabled else {
            return prompt
        }
        return spokenBrevityInstruction + "\n\n" + prompt
    }
}

enum AskInvocationComposer {
    private static let claudeReadTools =
        "Read,Glob,Grep,WebFetch,WebSearch"
    private static let opencodePermissions =
        #"{"*":"deny","read":"allow","glob":"allow","grep":"allow","list":"allow","webfetch":"allow","websearch":"allow"}"#

    static func compose(
        template: String,
        prompt: String,
        resumeSessionID: String? = nil,
        forcedCLI: AgentCLI? = nil
    ) throws -> AskInvocation {
        let parsed: AgentCommandTemplate.Parsed
        do {
            parsed = try AgentCommandTemplate.parse(template)
        } catch {
            throw AskInvocationCompositionError.invalidTemplate
        }

        guard let executable = parsed.arguments.first else {
            throw AskInvocationCompositionError.invalidTemplate
        }
        let recognizedCLI = cli(forExecutable: executable)
        guard let cli = forcedCLI ?? recognizedCLI,
              forcedCLI == nil || recognizedCLI == forcedCLI else {
            throw AskInvocationCompositionError.unknownAgentCLI
        }

        let userArguments = parsed.arguments.enumerated().compactMap {
            index, argument in
            index == 0 || index == parsed.promptArgumentIndex
                ? nil
                : argument
        }

        switch cli {
        case .codex:
            return AskInvocation(
                cli: cli,
                executable: executable,
                arguments: codexArguments(
                    userArguments: userArguments,
                    prompt: prompt,
                    resumeSessionID: resumeSessionID
                ),
                environment: [:]
            )
        case .claude:
            return AskInvocation(
                cli: cli,
                executable: executable,
                arguments: claudeArguments(
                    userArguments: userArguments,
                    prompt: prompt,
                    resumeSessionID: resumeSessionID
                ),
                environment: [:]
            )
        case .opencode:
            return AskInvocation(
                cli: cli,
                executable: executable,
                arguments: opencodeArguments(
                    userArguments: userArguments,
                    prompt: prompt,
                    resumeSessionID: resumeSessionID
                ),
                environment: [
                    "OPENCODE_PERMISSION": opencodePermissions,
                    "OPENCODE_DISABLE_AUTOUPDATE": "true",
                ]
            )
        }
    }

    static func cli(forTemplate template: String) -> AgentCLI? {
        guard let executable = try? AgentCommandTemplate
            .parse(template)
            .arguments
            .first else {
            return nil
        }
        return cli(forExecutable: executable)
    }

    private static func cli(forExecutable executable: String) -> AgentCLI? {
        let name = URL(fileURLWithPath: executable)
            .lastPathComponent
            .lowercased()
        return AgentCLI(rawValue: name)
    }

    private static func codexArguments(
        userArguments: [String],
        prompt: String,
        resumeSessionID: String?
    ) -> [String] {
        var arguments = retainedOptionPairs(
            from: userArguments,
            allowed: [
                "-m",
                "--model",
                "-p",
                "--profile",
                "--local-provider",
            ]
        )
        arguments += [
            "-s",
            "read-only",
            "-a",
            "never",
            "exec",
        ]
        if resumeSessionID != nil {
            arguments += ["resume"]
        }
        arguments += [
            "--skip-git-repo-check",
            "--json",
        ]
        if let resumeSessionID {
            arguments += [resumeSessionID]
        }
        arguments += [prompt]
        return arguments
    }

    private static func claudeArguments(
        userArguments: [String],
        prompt: String,
        resumeSessionID: String?
    ) -> [String] {
        var arguments = [
            "-p",
            "--safe-mode",
            "--permission-mode",
            "plan",
            "--tools",
            claudeReadTools,
            "--disallowedTools",
            "mcp__*",
            "--strict-mcp-config",
            "--output-format",
            "json",
        ]
        arguments += retainedOptionPairs(
            from: userArguments,
            allowed: [
                "--model",
                "--effort",
                "--fallback-model",
            ]
        )
        if let resumeSessionID {
            arguments += ["--resume", resumeSessionID]
        }
        arguments += [prompt]
        return arguments
    }

    private static func opencodeArguments(
        userArguments: [String],
        prompt: String,
        resumeSessionID: String?
    ) -> [String] {
        var arguments = ["--pure", "run", "--format", "json"]
        arguments += retainedOptionPairs(
            from: userArguments,
            allowed: [
                "-m",
                "--model",
                "--variant",
            ]
        )
        if let resumeSessionID {
            arguments += ["--session", resumeSessionID]
        }
        arguments += [prompt]
        return arguments
    }

    private static func retainedOptionPairs(
        from arguments: [String],
        allowed: Set<String>
    ) -> [String] {
        var retained: [String] = []
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard allowed.contains(option),
                  index + 1 < arguments.count else {
                index += 1
                continue
            }
            retained += [option, arguments[index + 1]]
            index += 2
        }
        return retained
    }
}

struct AskThreadHandle: Equatable, Sendable {
    let cli: AgentCLI
    let sessionID: String
    let expiresAt: TimeInterval
}

struct AskThreadWindow {
    static let followUpGraceDuration: TimeInterval = 12

    private(set) var handle: AskThreadHandle?
    private let now: () -> TimeInterval

    init(
        now: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.now = now
    }

    mutating func open(
        cli: AgentCLI,
        sessionID: String,
        answerVisibleDuration: TimeInterval
    ) {
        handle = AskThreadHandle(
            cli: cli,
            sessionID: sessionID,
            expiresAt: now()
                + max(0, answerVisibleDuration)
                + Self.followUpGraceDuration
        )
    }

    mutating func current() -> AskThreadHandle? {
        expireIfNeeded()
        return handle
    }

    mutating func consume() -> AskThreadHandle? {
        guard let current = current() else {
            return nil
        }
        handle = nil
        return current
    }

    mutating func expireIfNeeded() {
        guard let handle, now() >= handle.expiresAt else {
            return
        }
        self.handle = nil
    }

    mutating func clear() {
        handle = nil
    }

    func remainingTime() -> TimeInterval? {
        guard let handle else {
            return nil
        }
        return max(0, handle.expiresAt - now())
    }
}

struct AskResult: Equatable, Sendable {
    let answer: String
    let cli: AgentCLI
    let sessionID: String?

    var hasOpenThread: Bool {
        sessionID != nil
    }
}

enum AskEngineError: Error, Equatable {
    case unknownAgentCLI
    case unableToLaunch
    case failed(String)
    case emptyAnswer
    case cancelled
    case timedOut
}

@MainActor
final class AskEngine {
    static let answerVisibilityDuration: TimeInterval = 8
    static let timeout: TimeInterval = 60
    static let forceKillDelay: TimeInterval = 2

    var onThreadExpired: (() -> Void)?

    private struct ActiveRun {
        let id: UUID
        let process: Process
        let standardOutput: ProcessPipeCapture
        let standardError: ProcessPipeCapture
    }

    private enum StopReason {
        case cancelled
        case timedOut
    }

    private let settings: AppSettings
    private var threadWindow = AskThreadWindow()
    private var reservedThread: AskThreadHandle?
    private var threadExpiryTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var activeRun: ActiveRun?
    private var stoppedRuns: [UUID: StopReason] = [:]

    init(settings: AppSettings) {
        self.settings = settings
    }

    var hasOpenThread: Bool {
        reservedThread != nil || threadWindow.current() != nil
    }

    func reserveThreadForUtterance() {
        guard reservedThread == nil,
              let handle = threadWindow.consume() else {
            return
        }
        reservedThread = handle
        threadExpiryTask?.cancel()
        threadExpiryTask = nil
    }

    func ask(
        prompt: String,
        voiceAnswersEnabled: Bool
    ) async throws -> AskResult {
        let priorThread = reservedThread ?? threadWindow.consume()
        reservedThread = nil
        threadExpiryTask?.cancel()
        threadExpiryTask = nil

        let requestedCLI = priorThread?.cli
        let configuredTemplate = settings.agentCommandTemplate
        let template: String
        if let requestedCLI,
           AskInvocationComposer.cli(forTemplate: configuredTemplate)
                != requestedCLI {
            template = requestedCLI.commandTemplate
        } else {
            template = configuredTemplate
        }

        guard !template.isEmpty else {
            throw AskEngineError.unknownAgentCLI
        }

        let composedPrompt = AskPromptComposer.compose(
            prompt,
            voiceAnswersEnabled: voiceAnswersEnabled
        )
        let invocation: AskInvocation
        do {
            invocation = try AskInvocationComposer.compose(
                template: template,
                prompt: composedPrompt,
                resumeSessionID: priorThread?.sessionID,
                forcedCLI: requestedCLI
            )
        } catch AskInvocationCompositionError.unknownAgentCLI {
            throw AskEngineError.unknownAgentCLI
        } catch {
            throw AskEngineError.unknownAgentCLI
        }

        let output = try await run(invocation)
        let parsed = AskOutputParser.parse(
            output.standardOutput,
            cli: invocation.cli
        )
        let answer = parsed.answer.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !answer.isEmpty else {
            throw AskEngineError.emptyAnswer
        }

        let sessionID = parsed.sessionID ?? priorThread?.sessionID
        if let sessionID {
            threadWindow.open(
                cli: invocation.cli,
                sessionID: sessionID,
                answerVisibleDuration: Self.answerVisibilityDuration
            )
            scheduleThreadExpiry()
        }

        return AskResult(
            answer: answer,
            cli: invocation.cli,
            sessionID: sessionID
        )
    }

    func clearThread() {
        threadExpiryTask?.cancel()
        threadExpiryTask = nil
        threadWindow.clear()
        reservedThread = nil
    }

    func cancel() {
        clearThread()
        stopActiveRun(reason: .cancelled)
    }

    private func run(
        _ invocation: AskInvocation
    ) async throws -> (
        standardOutput: Data,
        standardError: Data
    ) {
        let process = Process()
        let standardOutput = ProcessPipeCapture()
        let standardError = ProcessPipeCapture()
        let runID = UUID()

        let executableURL: URL
        if invocation.executable.contains("/") {
            executableURL = URL(fileURLWithPath: invocation.executable)
            process.arguments = invocation.arguments
        } else if let detected = AgentCLIDetector.detect().first(where: {
            $0.cli == invocation.cli
        }) {
            executableURL = detected.executableURL
            process.arguments = invocation.arguments
        } else {
            executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                invocation.executable,
            ] + invocation.arguments
        }

        process.executableURL = executableURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput.pipe
        process.standardError = standardError.pipe
        if !invocation.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(invocation.environment) { _, invocationValue in
                    invocationValue
                }
        }

        let status: Int32
        do {
            status = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Int32, Error>) in
                    process.terminationHandler = { finishedProcess in
                        continuation.resume(
                            returning: finishedProcess.terminationStatus
                        )
                    }

                    do {
                        try process.run()
                        activeRun = ActiveRun(
                            id: runID,
                            process: process,
                            standardOutput: standardOutput,
                            standardError: standardError
                        )
                        scheduleTimeout(for: runID)
                    } catch {
                        process.terminationHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancel()
                }
            }
        } catch {
            standardOutput.finish()
            standardError.finish()
            throw AskEngineError.unableToLaunch
        }

        timeoutTask?.cancel()
        timeoutTask = nil
        if activeRun?.id == runID {
            activeRun = nil
        }

        standardOutput.finish()
        standardError.finish()
        let outputData = standardOutput.data
        let errorData = standardError.data

        if let stopReason = stoppedRuns.removeValue(forKey: runID) {
            switch stopReason {
            case .cancelled:
                throw AskEngineError.cancelled
            case .timedOut:
                throw AskEngineError.timedOut
            }
        }

        guard status == 0 else {
            let errorText = String(
                decoding: errorData,
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AskEngineError.failed(
                errorText.isEmpty ? "agent cli failed" : errorText
            )
        }

        return (outputData, errorData)
    }

    private func scheduleTimeout(for runID: UUID) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.timeout))
            guard !Task.isCancelled,
                  let self,
                  self.activeRun?.id == runID else {
                return
            }
            self.stopActiveRun(reason: .timedOut)
        }
    }

    private func stopActiveRun(reason: StopReason) {
        guard let activeRun else {
            return
        }

        self.activeRun = nil
        stoppedRuns[activeRun.id] = reason
        timeoutTask?.cancel()
        timeoutTask = nil

        let process = activeRun.process
        if process.isRunning {
            process.terminate()
        }

        Task { @MainActor in
            try? await Task.sleep(
                for: .seconds(Self.forceKillDelay)
            )
            guard process.isRunning else {
                return
            }
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private func scheduleThreadExpiry() {
        threadExpiryTask?.cancel()
        guard let remainingTime = threadWindow.remainingTime() else {
            return
        }

        threadExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remainingTime))
            guard !Task.isCancelled, let self else {
                return
            }
            self.threadWindow.expireIfNeeded()
            if self.threadWindow.handle == nil {
                self.threadExpiryTask = nil
                self.onThreadExpired?()
            } else {
                self.scheduleThreadExpiry()
            }
        }
    }
}

private final class ProcessPipeCapture: @unchecked Sendable {
    let pipe = Pipe()

    private let lock = NSLock()
    private var storage = Data()

    init() {
        pipe.fileHandleForReading.readabilityHandler = {
            [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.append(chunk)
        }
    }

    var data: Data {
        lock.withLock { storage }
    }

    func finish() {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = nil
        let remainder = handle.readDataToEndOfFile()
        if !remainder.isEmpty {
            append(remainder)
        }
    }

    private func append(_ data: Data) {
        lock.withLock {
            storage.append(data)
        }
    }
}

private enum AskOutputParser {
    struct Parsed {
        var answer = ""
        var sessionID: String?
    }

    static func parse(_ data: Data, cli: AgentCLI) -> Parsed {
        let text = String(decoding: data, as: UTF8.self)
        switch cli {
        case .codex:
            return parseCodex(text)
        case .claude:
            return parseClaude(data, fallback: text)
        case .opencode:
            return parseOpenCode(text)
        }
    }

    private static func parseCodex(_ text: String) -> Parsed {
        var parsed = Parsed()
        for object in jsonObjects(in: text) {
            if string(in: object, keys: ["type"]) == "thread.started" {
                parsed.sessionID = string(
                    in: object,
                    keys: ["thread_id", "threadID", "session_id"]
                )
            }

            guard string(in: object, keys: ["type"])
                    == "item.completed",
                  let item = object["item"] as? [String: Any],
                  string(in: item, keys: ["type"])
                    == "agent_message",
                  let answer = string(in: item, keys: ["text"]) else {
                continue
            }
            parsed.answer = answer
        }
        if parsed.answer.isEmpty {
            parsed.answer = text
        }
        return parsed
    }

    private static func parseClaude(
        _ data: Data,
        fallback: String
    ) -> Parsed {
        guard let object = try? JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any] else {
            return Parsed(answer: fallback, sessionID: nil)
        }
        return Parsed(
            answer: string(in: object, keys: ["result"]) ?? fallback,
            sessionID: string(
                in: object,
                keys: ["session_id", "sessionID", "sessionId"]
            )
        )
    }

    private static func parseOpenCode(_ text: String) -> Parsed {
        var parsed = Parsed()
        var answerParts: [String] = []
        for object in jsonObjects(in: text) {
            if parsed.sessionID == nil {
                parsed.sessionID = recursiveString(
                    in: object,
                    keys: ["sessionID", "session_id", "sessionId"]
                )
            }

            if string(in: object, keys: ["type"]) == "text",
               let part = object["part"] as? [String: Any],
               let answer = string(in: part, keys: ["text"]) {
                answerParts.append(answer)
            } else if string(in: object, keys: ["type"]) == "text",
                      let answer = string(in: object, keys: ["text"]) {
                answerParts.append(answer)
            }
        }
        parsed.answer = answerParts.isEmpty
            ? text
            : answerParts.joined()
        return parsed
    }

    private static func jsonObjects(
        in text: String
    ) -> [[String: Any]] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = String(line).data(using: .utf8) else {
                return nil
            }
            return try? JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any]
        }
    }

    private static func string(
        in object: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                return value
            }
        }
        return nil
    }

    private static func recursiveString(
        in value: Any,
        keys: Set<String>
    ) -> String? {
        if let object = value as? [String: Any] {
            for key in keys {
                if let result = object[key] as? String {
                    return result
                }
            }
            for nested in object.values {
                if let result = recursiveString(
                    in: nested,
                    keys: keys
                ) {
                    return result
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let result = recursiveString(
                    in: nested,
                    keys: keys
                ) {
                    return result
                }
            }
        }
        return nil
    }
}
