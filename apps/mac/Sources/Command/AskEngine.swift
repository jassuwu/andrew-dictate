import Darwin
import Foundation
import OSLog

struct AskInvocation: Equatable, Sendable {
    let cli: AgentCLI
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let promptOnStandardInput: Bool
}

enum AskInvocationCompositionError: Error, Equatable {
    case invalidTemplate
    case unknownAgentCLI
    case standardInputUnsupported
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
        forcedCLI: AgentCLI? = nil,
        imagePath: String? = nil,
        promptOnStandardInput: Bool = false
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
                    resumeSessionID: resumeSessionID,
                    imagePath: imagePath,
                    promptOnStandardInput: promptOnStandardInput
                ),
                environment: [:],
                promptOnStandardInput: promptOnStandardInput
            )
        case .claude:
            return AskInvocation(
                cli: cli,
                executable: executable,
                arguments: claudeArguments(
                    userArguments: userArguments,
                    prompt: prompt,
                    resumeSessionID: resumeSessionID,
                    imagePath: imagePath,
                    promptOnStandardInput: promptOnStandardInput
                ),
                environment: [:],
                promptOnStandardInput: promptOnStandardInput
            )
        case .opencode:
            guard !promptOnStandardInput else {
                // `opencode run` documents positional message arguments but
                // no prompt-on-stdin mode. Do not speculate without a proven
                // side-effect-free hold-open contract.
                throw AskInvocationCompositionError
                    .standardInputUnsupported
            }
            return AskInvocation(
                cli: cli,
                executable: executable,
                arguments: opencodeArguments(
                    userArguments: userArguments,
                    prompt: prompt,
                    resumeSessionID: resumeSessionID,
                    imagePath: imagePath
                ),
                environment: [
                    "OPENCODE_PERMISSION": opencodePermissions,
                    "OPENCODE_DISABLE_AUTOUPDATE": "true",
                ],
                promptOnStandardInput: false
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
        resumeSessionID: String?,
        imagePath: String?,
        promptOnStandardInput: Bool
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
        if let imagePath {
            arguments += ["-i", imagePath]
        }
        if let resumeSessionID {
            arguments += [resumeSessionID]
        }
        // Codex 0.144 documents `-` for both fresh and resumed exec as
        // "read the prompt from stdin". Keeping the marker explicit also
        // prevents future changes to implicit piped-stdin behavior.
        arguments += [promptOnStandardInput ? "-" : prompt]
        return arguments
    }

    private static func claudeArguments(
        userArguments: [String],
        prompt: String,
        resumeSessionID: String?,
        imagePath: String?,
        promptOnStandardInput: Bool
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
            "stream-json",
            "--verbose",
            "--include-partial-messages",
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
        if !promptOnStandardInput {
            arguments += [
                imagePath.map {
                    "Inspect the image at this path when answering: \($0)"
                        + "\n\n"
                        + prompt
                } ?? prompt,
            ]
        }
        return arguments
    }

    private static func opencodeArguments(
        userArguments: [String],
        prompt: String,
        resumeSessionID: String?,
        imagePath: String?
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
        if let imagePath {
            arguments += ["--file", imagePath]
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

struct AskStreamUpdate: Equatable, Sendable {
    let answer: String
    let sessionID: String?
}

/// Deliberately simple streaming speech segmentation. A sentence completes at
/// `. `, `? `, `! `, or a newline. Abbreviation detection is intentionally out
/// of scope: voice answers already ask the agent for two short sentences.
enum SentenceBoundarySplitter {
    struct Split: Equatable, Sendable {
        let sentences: [String]
        let remainder: String
    }

    static func split(_ text: String) -> Split {
        var sentences: [String] = []
        var sentenceStart = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            let punctuationBoundary =
                (character == "." || character == "?"
                    || character == "!")
                && next < text.endIndex
                && text[next] == " "
            let newlineBoundary = character == "\n"

            guard punctuationBoundary || newlineBoundary else {
                index = next
                continue
            }

            let sentenceEnd = newlineBoundary ? index : next
            appendNonempty(
                text[sentenceStart..<sentenceEnd],
                to: &sentences
            )

            var nextStart = next
            while nextStart < text.endIndex,
                  text[nextStart] == " " || text[nextStart] == "\n" {
                nextStart = text.index(after: nextStart)
            }
            sentenceStart = nextStart
            index = nextStart
        }

        return Split(
            sentences: sentences,
            remainder: String(text[sentenceStart...])
        )
    }

    private static func appendNonempty(
        _ substring: Substring,
        to sentences: inout [String]
    ) {
        let sentence = substring.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !sentence.isEmpty {
            sentences.append(sentence)
        }
    }
}

struct StreamingSentenceAccumulator: Sendable {
    private(set) var observedText = ""
    private(set) var remainder = ""

    mutating func ingest(_ answer: String) -> [String] {
        guard answer.hasPrefix(observedText) else {
            // A provider may replace its final snapshot after streaming. Text
            // that was already spoken cannot be corrected without repetition,
            // so discard the changed unsaid tail.
            observedText = answer
            remainder = ""
            return []
        }

        remainder += answer.dropFirst(observedText.count)
        observedText = answer
        let split = SentenceBoundarySplitter.split(remainder)
        remainder = split.remainder
        return split.sentences
    }

    mutating func finish(with answer: String) -> [String] {
        var sentences = ingest(answer)
        let trailing = remainder.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !trailing.isEmpty {
            sentences.append(trailing)
        }
        remainder = ""
        return sentences
    }
}

protocol SpeculativeProcessHandle: AnyObject {
    func commit(prompt: String) throws
    func kill()
}

struct SpeculativeProcessMetrics: Equatable, Sendable {
    private(set) var hits = 0
    private(set) var misses = 0
    private(set) var kills = 0

    fileprivate mutating func recordHit() {
        hits += 1
    }

    fileprivate mutating func recordMiss() {
        misses += 1
    }

    fileprivate mutating func recordKill() {
        kills += 1
    }
}

/// Owns at most one prompt-less process. The handle is injectable so lifecycle
/// semantics can be tested without launching an agent CLI.
struct SpeculativeProcessLifecycle<Handle: SpeculativeProcessHandle> {
    private(set) var activeHandle: Handle?
    private(set) var metrics = SpeculativeProcessMetrics()

    mutating func spawn(_ handle: Handle) {
        kill()
        activeHandle = handle
    }

    mutating func commit(
        prompt: String,
        if matches: (Handle) -> Bool
    ) -> Handle? {
        guard let handle = activeHandle else {
            metrics.recordMiss()
            return nil
        }
        guard matches(handle) else {
            kill()
            metrics.recordMiss()
            return nil
        }

        do {
            try handle.commit(prompt: prompt)
            activeHandle = nil
            metrics.recordHit()
            return handle
        } catch {
            kill()
            metrics.recordMiss()
            return nil
        }
    }

    @discardableResult
    mutating func kill() -> Bool {
        guard let handle = activeHandle else {
            return false
        }
        activeHandle = nil
        handle.kill()
        metrics.recordKill()
        return true
    }

    mutating func recordMiss() {
        metrics.recordMiss()
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

    var onThreadExpired: (() -> Void)?

    private struct ActiveRun {
        let id: UUID
        let process: LaunchedAskProcess
    }

    private enum StopReason {
        case cancelled
        case timedOut
    }

    private let askLogger = Logger(
        subsystem: "gg.jass.dictate",
        category: "ask"
    )
    private let settings: AppSettings
    private var threadWindow = AskThreadWindow()
    private var reservedThread: AskThreadHandle?
    private var threadExpiryTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var activeRun: ActiveRun?
    private var stoppedRuns: [UUID: StopReason] = [:]
    private var speculative =
        SpeculativeProcessLifecycle<LaunchedAskProcess>()

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

    /// Starts a read-only CLI with an open stdin before transcription knows the
    /// route. No prompt is sent here, so a discarded process cannot create an
    /// agent turn. Screen asks intentionally cannot reuse this process because
    /// their image flag is only known after capture.
    func prepareSpeculativeAsk() {
        discardSpeculativeAsk(reason: "replace")

        let priorThread = reservedThread ?? threadWindow.current()
        let requestedCLI = priorThread?.cli
        let template = selectedTemplate(for: requestedCLI)
        guard !template.isEmpty else {
            return
        }

        do {
            let invocation = try AskInvocationComposer.compose(
                template: template,
                prompt: "",
                resumeSessionID: priorThread?.sessionID,
                forcedCLI: requestedCLI,
                promptOnStandardInput: true
            )
            let process = try LaunchedAskProcess(invocation: invocation)
            speculative.spawn(process)
            logSpeculative(event: "spawn")
        } catch AskInvocationCompositionError.standardInputUnsupported {
            // OpenCode documents raw JSON output, but not prompt-on-stdin.
            // Skipping speculation is safer than sending an empty turn.
        } catch {
            askLogger.error(
                "speculative launch failed: \(error.localizedDescription)"
            )
        }
    }

    func discardSpeculativeAsk(reason: String = "route") {
        guard speculative.kill() else {
            return
        }
        logSpeculative(event: "kill-\(reason)")
    }

    func ask(
        prompt: String,
        voiceAnswersEnabled: Bool,
        imagePath: String? = nil,
        onUpdate: @escaping @MainActor @Sendable (
            AskStreamUpdate
        ) -> Void = { _ in }
    ) async throws -> AskResult {
        let priorThread = reservedThread ?? threadWindow.consume()
        reservedThread = nil
        threadExpiryTask?.cancel()
        threadExpiryTask = nil

        let requestedCLI = priorThread?.cli
        let template = selectedTemplate(for: requestedCLI)

        guard !template.isEmpty else {
            discardSpeculativeAsk(reason: "invalid-template")
            throw AskEngineError.unknownAgentCLI
        }

        let composedPrompt = AskPromptComposer.compose(
            prompt,
            voiceAnswersEnabled: voiceAnswersEnabled
        )
        let argumentInvocation: AskInvocation
        do {
            argumentInvocation = try AskInvocationComposer.compose(
                template: template,
                prompt: composedPrompt,
                resumeSessionID: priorThread?.sessionID,
                forcedCLI: requestedCLI,
                imagePath: imagePath
            )
        } catch AskInvocationCompositionError.unknownAgentCLI {
            discardSpeculativeAsk(reason: "unknown-cli")
            throw AskEngineError.unknownAgentCLI
        } catch {
            discardSpeculativeAsk(reason: "invalid-invocation")
            throw AskEngineError.unknownAgentCLI
        }

        let process: LaunchedAskProcess
        if imagePath == nil,
           let standardInputInvocation =
            try? AskInvocationComposer.compose(
                template: template,
                prompt: composedPrompt,
                resumeSessionID: priorThread?.sessionID,
                forcedCLI: requestedCLI,
                promptOnStandardInput: true
            ),
           let committed = speculative.commit(
                prompt: composedPrompt,
                if: { $0.invocation == standardInputInvocation }
           ) {
            process = committed
            logSpeculative(event: "hit")
        } else {
            if imagePath != nil {
                discardSpeculativeAsk(reason: "screen-flags")
                speculative.recordMiss()
            } else if argumentInvocation.cli == .opencode {
                speculative.recordMiss()
            }
            logSpeculative(event: "miss")
            do {
                process = try LaunchedAskProcess(
                    invocation: argumentInvocation
                )
            } catch {
                throw AskEngineError.unableToLaunch
            }
        }

        let parsed = try await run(process, onUpdate: onUpdate)
        let answer = parsed.answer.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !answer.isEmpty else {
            throw AskEngineError.emptyAnswer
        }

        let sessionID = parsed.sessionID ?? priorThread?.sessionID
        if let sessionID {
            threadWindow.open(
                cli: argumentInvocation.cli,
                sessionID: sessionID,
                answerVisibleDuration: Self.answerVisibilityDuration
            )
            scheduleThreadExpiry()
        }

        return AskResult(
            answer: answer,
            cli: argumentInvocation.cli,
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
        discardSpeculativeAsk(reason: "cancel")
        stopActiveRun(reason: .cancelled)
    }

    private func selectedTemplate(
        for requestedCLI: AgentCLI?
    ) -> String {
        let configuredTemplate = settings.agentCommandTemplate
        if let requestedCLI,
           AskInvocationComposer.cli(forTemplate: configuredTemplate)
                != requestedCLI {
            return requestedCLI.commandTemplate
        }
        return configuredTemplate
    }

    private func run(
        _ process: LaunchedAskProcess,
        onUpdate: @escaping @MainActor @Sendable (
            AskStreamUpdate
        ) -> Void
    ) async throws -> AskOutputParser.Parsed {
        let runID = process.id
        activeRun = ActiveRun(id: runID, process: process)
        process.setStreamHandler { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self,
                      self.activeRun?.id == runID else {
                    return
                }
                onUpdate(update)
            }
        }
        scheduleTimeout(for: runID)

        let status: Int32
        status = await withTaskCancellationHandler {
            await process.waitForExit()
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }

        timeoutTask?.cancel()
        timeoutTask = nil
        if activeRun?.id == runID {
            activeRun = nil
        }

        let parsed = process.finishOutput()
        let errorData = process.standardErrorData

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

        return parsed
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

        // Barge-in and Esc are hard cancellation boundaries. SIGKILL avoids
        // leaving a CLI's shutdown hooks or queued stream output alive.
        activeRun.process.kill()
    }

    private func logSpeculative(event: String) {
        let metrics = speculative.metrics
        askLogger.notice(
            "speculative \(event, privacy: .public) hits=\(metrics.hits) misses=\(metrics.misses) kills=\(metrics.kills)"
        )
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

private enum AskProcessLaunchConfiguration {
    struct Configuration {
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]
    }

    static func compose(
        _ invocation: AskInvocation
    ) -> Configuration {
        let executableURL: URL
        let arguments: [String]
        if invocation.executable.contains("/") {
            executableURL = URL(
                fileURLWithPath: invocation.executable
            )
            arguments = invocation.arguments
        } else if let detected = AgentCLIDetector.detect().first(
            where: { $0.cli == invocation.cli }
        ) {
            executableURL = detected.executableURL
            arguments = invocation.arguments
        } else {
            executableURL = URL(fileURLWithPath: "/usr/bin/env")
            arguments = [
                invocation.executable,
            ] + invocation.arguments
        }

        // GUI apps inherit a minimal PATH. CLIs installed via nvm are node
        // scripts whose `#!/usr/bin/env node` shebang needs node on PATH.
        // Normal and speculative launches both use this exact composition.
        var environment = ProcessInfo.processInfo.environment
            .merging(invocation.environment) { _, invocationValue in
                invocationValue
            }
        let executableDirectory = executableURL
            .deletingLastPathComponent()
            .path
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin"
        if !inheritedPath.split(separator: ":").map(String.init)
            .contains(executableDirectory) {
            environment["PATH"] = executableDirectory + ":" + inheritedPath
        }

        return Configuration(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment
        )
    }
}

private enum SpeculativeCommitError: Error {
    case unavailable
}

private final class LaunchedAskProcess:
    SpeculativeProcessHandle,
    @unchecked Sendable {
    let id = UUID()
    let invocation: AskInvocation

    private let process = Process()
    private let standardInputPipe: Pipe?
    private let standardOutput: ProcessPipeCapture
    private let standardError: ProcessPipeCapture
    private let streamAccumulator: AskStreamAccumulator
    private let exitWaiter = ProcessExitWaiter()

    init(invocation: AskInvocation) throws {
        self.invocation = invocation
        let accumulator = AskStreamAccumulator(cli: invocation.cli)
        streamAccumulator = accumulator
        standardOutput = ProcessPipeCapture {
            [accumulator] data in
            accumulator.consume(data)
        }
        standardError = ProcessPipeCapture()

        let standardInputPipe: Pipe?
        if invocation.promptOnStandardInput {
            standardInputPipe = Pipe()
        } else {
            standardInputPipe = nil
        }
        self.standardInputPipe = standardInputPipe

        let configuration = AskProcessLaunchConfiguration.compose(
            invocation
        )
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.environment = configuration.environment
        if let standardInputPipe {
            process.standardInput = standardInputPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        process.standardOutput = standardOutput.pipe
        process.standardError = standardError.pipe
        process.terminationHandler = { [exitWaiter] finishedProcess in
            exitWaiter.complete(
                status: finishedProcess.terminationStatus
            )
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw error
        }
    }

    func commit(prompt: String) throws {
        guard let standardInputPipe, process.isRunning else {
            throw SpeculativeCommitError.unavailable
        }

        let writer = standardInputPipe.fileHandleForWriting
        do {
            try writer.write(contentsOf: Data(prompt.utf8))
            try writer.close()
        } catch {
            try? writer.close()
            throw error
        }
    }

    func kill() {
        if let writer = standardInputPipe?.fileHandleForWriting {
            try? writer.close()
        }
        guard process.isRunning else {
            return
        }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    func setStreamHandler(
        _ handler: @escaping @Sendable (AskStreamUpdate) -> Void
    ) {
        streamAccumulator.setHandler(handler)
    }

    func waitForExit() async -> Int32 {
        await exitWaiter.wait()
    }

    func finishOutput() -> AskOutputParser.Parsed {
        standardOutput.finish()
        standardError.finish()
        return streamAccumulator.finish(
            fallback: standardOutput.data
        )
    }

    var standardErrorData: Data {
        standardError.data
    }
}

private final class ProcessExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuations:
        [CheckedContinuation<Int32, Never>] = []

    func complete(status: Int32) {
        let pending: [CheckedContinuation<Int32, Never>] =
            lock.withLock {
                guard self.status == nil else {
                    return []
                }
                self.status = status
                defer { continuations.removeAll() }
                return continuations
            }
        for continuation in pending {
            continuation.resume(returning: status)
        }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let completedStatus: Int32? = lock.withLock {
                if let status {
                    return status
                }
                continuations.append(continuation)
                return nil
            }
            if let completedStatus {
                continuation.resume(returning: completedStatus)
            }
        }
    }
}

private final class ProcessPipeCapture: @unchecked Sendable {
    let pipe = Pipe()

    private let lock = NSLock()
    private var storage = Data()
    private let onChunk: (@Sendable (Data) -> Void)?

    init(
        onChunk: (@Sendable (Data) -> Void)? = nil
    ) {
        self.onChunk = onChunk
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
        onChunk?(data)
    }
}

private final class AskStreamAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var parser: AskStreamEventParser
    private var handler: (@Sendable (AskStreamUpdate) -> Void)?

    init(cli: AgentCLI) {
        parser = AskStreamEventParser(cli: cli)
    }

    func consume(_ data: Data) {
        let delivery: (
            [AskStreamUpdate],
            (@Sendable (AskStreamUpdate) -> Void)?
        ) = lock.withLock {
            (parser.consume(data), handler)
        }
        guard let handler = delivery.1 else {
            return
        }
        for update in delivery.0 {
            handler(update)
        }
    }

    func setHandler(
        _ handler: @escaping @Sendable (AskStreamUpdate) -> Void
    ) {
        let currentUpdate: AskStreamUpdate? = lock.withLock {
            self.handler = handler
            return parser.currentUpdate
        }
        if let currentUpdate {
            handler(currentUpdate)
        }
    }

    func finish(fallback data: Data) -> AskOutputParser.Parsed {
        let parsed: AskOutputParser.Parsed = lock.withLock {
            _ = parser.finish()
            return parser.parsed
        }
        guard parsed.answer.isEmpty else {
            return parsed
        }
        return AskOutputParser.parse(data, cli: parser.cli)
    }
}

enum AskOutputParser {
    struct Parsed: Equatable, Sendable {
        var answer = ""
        var sessionID: String?
    }

    static func parse(_ data: Data, cli: AgentCLI) -> Parsed {
        var parser = AskStreamEventParser(cli: cli)
        _ = parser.consume(data)
        _ = parser.finish()
        var parsed = parser.parsed
        if parsed.answer.isEmpty {
            parsed.answer = String(decoding: data, as: UTF8.self)
        }
        return parsed
    }
}

struct AskStreamEventParser: Sendable {
    let cli: AgentCLI
    private var lineBuffer = Data()
    private(set) var parsed = AskOutputParser.Parsed()

    var currentUpdate: AskStreamUpdate? {
        guard !parsed.answer.isEmpty else {
            return nil
        }
        return AskStreamUpdate(
            answer: parsed.answer,
            sessionID: parsed.sessionID
        )
    }

    init(cli: AgentCLI) {
        self.cli = cli
    }

    mutating func consume(_ data: Data) -> [AskStreamUpdate] {
        lineBuffer.append(data)
        var updates: [AskStreamUpdate] = []

        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[..<newline]
            lineBuffer.removeSubrange(...newline)
            if let update = parseLine(Data(line)) {
                updates.append(update)
            }
        }
        return updates
    }

    mutating func finish() -> [AskStreamUpdate] {
        guard !lineBuffer.isEmpty else {
            return []
        }
        let line = lineBuffer
        lineBuffer.removeAll(keepingCapacity: false)
        return parseLine(line).map { [$0] } ?? []
    }

    private mutating func parseLine(
        _ data: Data
    ) -> AskStreamUpdate? {
        guard let object = try? JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any] else {
            return nil
        }

        let priorAnswer = parsed.answer
        switch cli {
        case .codex:
            parseCodex(object)
        case .claude:
            parseClaude(object)
        case .opencode:
            parseOpenCode(object)
        }

        guard parsed.answer != priorAnswer,
              !parsed.answer.isEmpty else {
            return nil
        }
        return AskStreamUpdate(
            answer: parsed.answer,
            sessionID: parsed.sessionID
        )
    }

    private mutating func parseCodex(
        _ object: [String: Any]
    ) {
        let type = Self.string(in: object, keys: ["type"])
        if type == "thread.started" {
            parsed.sessionID = Self.string(
                in: object,
                keys: ["thread_id", "threadID", "session_id"]
            )
        }

        if type == "item.updated" || type == "item.completed",
           let item = object["item"] as? [String: Any],
           Self.string(in: item, keys: ["type"]) == "agent_message",
           let answer = Self.string(in: item, keys: ["text"]) {
            parsed.answer = answer
            return
        }

        // Codex exec 0.144 publishes growing agent-message snapshots as
        // item.updated. These delta-shaped cases also tolerate older/future
        // builds that expose the internal content delta directly.
        if type == "item.delta"
            || type == "agent_message.delta"
            || type == "agent_message_content_delta" {
            if let delta = Self.string(
                in: object,
                keys: ["delta", "text"]
            ) {
                parsed.answer += delta
            } else if let item = object["item"] as? [String: Any],
                      let delta = Self.string(
                        in: item,
                        keys: ["delta", "text"]
                      ) {
                parsed.answer += delta
            }
        }
    }

    private mutating func parseClaude(
        _ object: [String: Any]
    ) {
        if let sessionID = Self.string(
            in: object,
            keys: ["session_id", "sessionID", "sessionId"]
        ) {
            parsed.sessionID = sessionID
        }

        let type = Self.string(in: object, keys: ["type"])
        if type == "stream_event",
           let event = object["event"] as? [String: Any],
           Self.string(in: event, keys: ["type"])
                == "content_block_delta",
           let delta = event["delta"] as? [String: Any],
           Self.string(in: delta, keys: ["type"]) == "text_delta",
           let text = Self.string(in: delta, keys: ["text"]) {
            parsed.answer += text
            return
        }

        if type == "result",
           let answer = Self.string(in: object, keys: ["result"]) {
            parsed.answer = answer
            return
        }

        if type == "assistant",
           parsed.answer.isEmpty,
           let message = object["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            parsed.answer = content.compactMap { block in
                guard Self.string(in: block, keys: ["type"]) == "text"
                else {
                    return nil
                }
                return Self.string(in: block, keys: ["text"])
            }.joined()
        }
    }

    private mutating func parseOpenCode(
        _ object: [String: Any]
    ) {
        if parsed.sessionID == nil {
            parsed.sessionID = Self.recursiveString(
                in: object,
                keys: ["sessionID", "session_id", "sessionId"]
            )
        }

        guard Self.string(in: object, keys: ["type"]) == "text"
        else {
            return
        }
        if let part = object["part"] as? [String: Any],
           let answer = Self.string(in: part, keys: ["text"]) {
            parsed.answer += answer
        } else if let answer = Self.string(
            in: object,
            keys: ["text"]
        ) {
            parsed.answer += answer
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
