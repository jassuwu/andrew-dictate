import XCTest

final class AskEngineTests: XCTestCase {
    func testCodexFreshInvocationIsReadOnlyAndStructured() throws {
        let invocation = try AskInvocationComposer.compose(
            template: "codex exec --model gpt-5 {prompt}",
            prompt: "explain actors"
        )

        XCTAssertEqual(invocation.cli, .codex)
        XCTAssertEqual(invocation.executable, "codex")
        XCTAssertEqual(
            invocation.arguments,
            [
                "--model",
                "gpt-5",
                "-s",
                "read-only",
                "-a",
                "never",
                "exec",
                "--skip-git-repo-check",
                "--json",
                "explain actors",
            ]
        )
        XCTAssertEqual(invocation.environment, [:])
    }

    func testCodexResumeKeepsReadOnlyBeforeSubcommands() throws {
        let invocation = try AskInvocationComposer.compose(
            template: "codex exec --skip-git-repo-check {prompt}",
            prompt: "and what about tasks",
            resumeSessionID: "codex-session"
        )

        XCTAssertEqual(
            invocation.arguments,
            [
                "-s",
                "read-only",
                "-a",
                "never",
                "exec",
                "resume",
                "--skip-git-repo-check",
                "--json",
                "codex-session",
                "and what about tasks",
            ]
        )
    }

    func testClaudeInvocationRestrictsToolsAndSupportsResume() throws {
        let invocation = try AskInvocationComposer.compose(
            template: "claude --model sonnet -p {prompt}",
            prompt: "explain actors",
            resumeSessionID: "claude-session"
        )

        XCTAssertEqual(invocation.cli, .claude)
        XCTAssertEqual(
            invocation.arguments,
            [
                "-p",
                "--safe-mode",
                "--permission-mode",
                "plan",
                "--tools",
                "Read,Glob,Grep,WebFetch,WebSearch",
                "--disallowedTools",
                "mcp__*",
                "--strict-mcp-config",
                "--output-format",
                "stream-json",
                "--verbose",
                "--include-partial-messages",
                "--model",
                "sonnet",
                "--resume",
                "claude-session",
                "explain actors",
            ]
        )
    }

    func testOpenCodeInvocationUsesPureModeInlineDeniesAndSession()
        throws {
        let invocation = try AskInvocationComposer.compose(
            template: "opencode run --model openai/gpt-5 {prompt}",
            prompt: "explain actors",
            resumeSessionID: "opencode-session"
        )

        XCTAssertEqual(invocation.cli, .opencode)
        XCTAssertEqual(
            invocation.arguments,
            [
                "--pure",
                "run",
                "--format",
                "json",
                "--model",
                "openai/gpt-5",
                "--session",
                "opencode-session",
                "explain actors",
            ]
        )
        XCTAssertEqual(
            invocation.environment["OPENCODE_PERMISSION"],
            #"{"*":"deny","read":"allow","glob":"allow","grep":"allow","list":"allow","webfetch":"allow","websearch":"allow"}"#
        )
        XCTAssertEqual(
            invocation.environment["OPENCODE_DISABLE_AUTOUPDATE"],
            "true"
        )
    }

    func testCodexScreenAskUsesImageFlagForFreshAndResumedCalls()
        throws {
        let fresh = try AskInvocationComposer.compose(
            template: "codex exec {prompt}",
            prompt: "explain this",
            imagePath: "/tmp/screen.png"
        )
        let resumed = try AskInvocationComposer.compose(
            template: "codex exec {prompt}",
            prompt: "look again",
            resumeSessionID: "codex-session",
            imagePath: "/tmp/next-screen.png"
        )

        XCTAssertEqual(
            fresh.arguments,
            [
                "-s",
                "read-only",
                "-a",
                "never",
                "exec",
                "--skip-git-repo-check",
                "--json",
                "-i",
                "/tmp/screen.png",
                "explain this",
            ]
        )
        XCTAssertEqual(
            resumed.arguments,
            [
                "-s",
                "read-only",
                "-a",
                "never",
                "exec",
                "resume",
                "--skip-git-repo-check",
                "--json",
                "-i",
                "/tmp/next-screen.png",
                "codex-session",
                "look again",
            ]
        )
    }

    func testClaudeScreenAskMentionsImagePathInPromptAndResumes()
        throws {
        let invocation = try AskInvocationComposer.compose(
            template: "claude -p {prompt}",
            prompt: "explain this error",
            resumeSessionID: "claude-session",
            imagePath: "/tmp/screen with space.png"
        )

        XCTAssertEqual(
            Array(invocation.arguments.suffix(3)),
            [
                "--resume",
                "claude-session",
                "Inspect the image at this path when answering: "
                    + "/tmp/screen with space.png"
                    + "\n\nexplain this error",
            ]
        )
    }

    func testOpenCodeScreenAskUsesDocumentedFileFlagAndSession()
        throws {
        let invocation = try AskInvocationComposer.compose(
            template: "opencode run {prompt}",
            prompt: "explain everything",
            resumeSessionID: "opencode-session",
            imagePath: "/tmp/screen.png"
        )

        XCTAssertEqual(
            invocation.arguments,
            [
                "--pure",
                "run",
                "--format",
                "json",
                "--session",
                "opencode-session",
                "--file",
                "/tmp/screen.png",
                "explain everything",
            ]
        )
    }

    func testSpeculativeInvocationsUseVerifiedStandardInputMechanics()
        throws {
        let codex = try AskInvocationComposer.compose(
            template: "codex exec --model gpt-5 {prompt}",
            prompt: "",
            promptOnStandardInput: true
        )
        let resumedCodex = try AskInvocationComposer.compose(
            template: "codex exec {prompt}",
            prompt: "",
            resumeSessionID: "codex-session",
            promptOnStandardInput: true
        )
        let claude = try AskInvocationComposer.compose(
            template: "claude -p {prompt}",
            prompt: "",
            promptOnStandardInput: true
        )

        XCTAssertTrue(codex.promptOnStandardInput)
        XCTAssertEqual(codex.arguments.last, "-")
        XCTAssertEqual(
            Array(resumedCodex.arguments.suffix(2)),
            ["codex-session", "-"]
        )
        XCTAssertTrue(claude.promptOnStandardInput)
        XCTAssertEqual(
            claude.arguments.last,
            "--include-partial-messages"
        )
        XCTAssertThrowsError(
            try AskInvocationComposer.compose(
                template: "opencode run {prompt}",
                prompt: "",
                promptOnStandardInput: true
            )
        ) { error in
            XCTAssertEqual(
                error as? AskInvocationCompositionError,
                .standardInputUnsupported
            )
        }
    }

    func testUnknownCustomTemplateCannotRunUngatedAsk() {
        XCTAssertThrowsError(
            try AskInvocationComposer.compose(
                template: "my-agent --prompt {prompt}",
                prompt: "hello"
            )
        ) { error in
            XCTAssertEqual(
                error as? AskInvocationCompositionError,
                .unknownAgentCLI
            )
        }
    }

    func testSpokenBrevityPrefixIsExactAndConditional() {
        XCTAssertEqual(
            AskPromptComposer.compose(
                "what changed",
                voiceAnswersEnabled: false
            ),
            "what changed"
        )
        XCTAssertEqual(
            AskPromptComposer.compose(
                "what changed",
                voiceAnswersEnabled: true
            ),
            "answer in at most two short spoken sentences."
                + "\n\nwhat changed"
        )
    }

    func testThreadWindowIncludesAnswerVisibilityAndTwelveSecondGrace() {
        var now: TimeInterval = 100
        var window = AskThreadWindow(now: { now })

        window.open(
            cli: .codex,
            sessionID: "thread",
            answerVisibleDuration: 8
        )

        XCTAssertEqual(window.handle?.expiresAt, 120)
        now = 119.999
        XCTAssertEqual(window.current()?.sessionID, "thread")
        now = 120
        XCTAssertNil(window.current())
    }

    func testThreadWindowConsumeAndClearNeverStoreTranscriptText() {
        var window = AskThreadWindow(now: { 20 })
        window.open(
            cli: .claude,
            sessionID: "session-only",
            answerVisibleDuration: 4
        )

        XCTAssertEqual(
            window.consume(),
            AskThreadHandle(
                cli: .claude,
                sessionID: "session-only",
                expiresAt: 36
            )
        )
        XCTAssertNil(window.current())

        window.open(
            cli: .opencode,
            sessionID: "next",
            answerVisibleDuration: 0
        )
        window.clear()
        XCTAssertNil(window.current())
    }

    func testSentenceBoundarySplitterUsesSimpleSpokenBoundaries() {
        XCTAssertEqual(
            SentenceBoundarySplitter.split(
                "First sentence. Second question? Third!\nTail"
            ),
            .init(
                sentences: [
                    "First sentence.",
                    "Second question?",
                    "Third!",
                ],
                remainder: "Tail"
            )
        )
        XCTAssertEqual(
            SentenceBoundarySplitter.split("No boundary yet."),
            .init(sentences: [], remainder: "No boundary yet.")
        )
        // Abbreviation tolerance is deliberately not part of this splitter.
        XCTAssertEqual(
            SentenceBoundarySplitter.split("Use e.g. this form. "),
            .init(
                sentences: ["Use e.g.", "this form."],
                remainder: ""
            )
        )
    }

    func testStreamingSentenceAccumulatorQueuesOnlyNewSentences() {
        var accumulator = StreamingSentenceAccumulator()

        XCTAssertEqual(accumulator.ingest("One"), [])
        XCTAssertEqual(
            accumulator.ingest("One. Two"),
            ["One."]
        )
        XCTAssertEqual(
            accumulator.ingest("One. Two? Three"),
            ["Two?"]
        )
        XCTAssertEqual(
            accumulator.finish(with: "One. Two? Three"),
            ["Three"]
        )
    }

    func testCodexJSONLParserStreamsUpdatedAgentMessageSnapshots() {
        let fixture = """
        {"type":"thread.started","thread_id":"codex-thread"}
        {"type":"item.started","item":{"id":"1","type":"agent_message","text":""}}
        {"type":"item.updated","item":{"id":"1","type":"agent_message","text":"Partial"}}
        {"type":"item.updated","item":{"id":"1","type":"agent_message","text":"Partial answer."}}
        {"type":"item.completed","item":{"id":"1","type":"agent_message","text":"Final Codex answer."}}
        {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":2}}

        """
        var parser = AskStreamEventParser(cli: .codex)
        let updates = parser.consume(Data(fixture.utf8))

        XCTAssertEqual(
            updates,
            [
                AskStreamUpdate(
                    answer: "Partial",
                    sessionID: "codex-thread"
                ),
                AskStreamUpdate(
                    answer: "Partial answer.",
                    sessionID: "codex-thread"
                ),
                AskStreamUpdate(
                    answer: "Final Codex answer.",
                    sessionID: "codex-thread"
                ),
            ]
        )
        XCTAssertEqual(
            parser.parsed,
            .init(
                answer: "Final Codex answer.",
                sessionID: "codex-thread"
            )
        )
    }

    func testClaudeStreamJSONParserEmitsTextDeltasAndSession() {
        let fixture = """
        {"type":"system","subtype":"init","session_id":"claude-session"}
        {"type":"stream_event","session_id":"claude-session","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}}
        {"type":"stream_event","session_id":"claude-session","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" world."}}}
        {"type":"result","subtype":"success","result":"Hello world.","session_id":"claude-session"}

        """
        let bytes = Data(fixture.utf8)
        let splitIndex = bytes.count / 2
        var parser = AskStreamEventParser(cli: .claude)
        let first = parser.consume(bytes.prefix(splitIndex))
        let second = parser.consume(bytes.suffix(from: splitIndex))
        let updates = first + second + parser.finish()

        XCTAssertEqual(
            updates.map(\.answer),
            ["Hello", "Hello world."]
        )
        XCTAssertEqual(parser.parsed.sessionID, "claude-session")
        XCTAssertEqual(parser.parsed.answer, "Hello world.")
    }

    func testOpenCodeRawJSONEventsStreamTextParts() {
        let fixture = """
        {"type":"step_start","sessionID":"open-session","part":{"type":"step-start"}}
        {"type":"text","sessionID":"open-session","part":{"type":"text","text":"Open"}}
        {"type":"text","sessionID":"open-session","part":{"type":"text","text":"Code"}}

        """
        var parser = AskStreamEventParser(cli: .opencode)
        let updates = parser.consume(Data(fixture.utf8))

        XCTAssertEqual(updates.map(\.answer), ["Open", "OpenCode"])
        XCTAssertEqual(parser.parsed.sessionID, "open-session")
    }

    func testSpeculativeLifecycleSpawnCommitKillAndReplace() {
        let first = FakeSpeculativeProcess()
        let second = FakeSpeculativeProcess()
        let third = FakeSpeculativeProcess()
        var lifecycle =
            SpeculativeProcessLifecycle<FakeSpeculativeProcess>()

        lifecycle.spawn(first)
        XCTAssertTrue(lifecycle.activeHandle === first)

        lifecycle.spawn(second)
        XCTAssertTrue(first.wasKilled)
        XCTAssertEqual(lifecycle.metrics.kills, 1)
        XCTAssertTrue(lifecycle.activeHandle === second)

        let committed = lifecycle.commit(
            prompt: "composed prompt",
            if: { $0 === second }
        )
        XCTAssertTrue(committed === second)
        XCTAssertEqual(second.committedPrompt, "composed prompt")
        XCTAssertNil(lifecycle.activeHandle)
        XCTAssertEqual(lifecycle.metrics.hits, 1)

        lifecycle.spawn(third)
        XCTAssertTrue(lifecycle.kill())
        XCTAssertTrue(third.wasKilled)
        XCTAssertEqual(lifecycle.metrics.kills, 2)
    }

    func testSpeculativeLifecycleMismatchKillsAndRecordsMiss() {
        let process = FakeSpeculativeProcess()
        var lifecycle =
            SpeculativeProcessLifecycle<FakeSpeculativeProcess>()
        lifecycle.spawn(process)

        XCTAssertNil(
            lifecycle.commit(prompt: "unused", if: { _ in false })
        )
        XCTAssertTrue(process.wasKilled)
        XCTAssertEqual(
            lifecycle.metrics,
            SpeculativeProcessMetrics(
                hits: 0,
                misses: 1,
                kills: 1
            )
        )
    }

    func testEphemeralScreenCaptureIsPrivateAndDeletedIdempotently()
        throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(
                "AndrewDictateTests.ScreenCapture.\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let pngData = Data([0x89, 0x50, 0x4E, 0x47])
        let capture = try EphemeralScreenCapture.create(
            pngData: pngData,
            temporaryDirectory: temporaryDirectory,
            fileManager: fileManager
        )

        XCTAssertEqual(
            try Data(contentsOf: capture.url),
            pngData
        )
        let attributes = try fileManager.attributesOfItem(
            atPath: capture.url.path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )

        capture.delete(fileManager: fileManager)
        XCTAssertFalse(fileManager.fileExists(atPath: capture.url.path))
        capture.delete(fileManager: fileManager)
        XCTAssertFalse(fileManager.fileExists(atPath: capture.url.path))
    }
}

private final class FakeSpeculativeProcess: SpeculativeProcessHandle {
    private(set) var committedPrompt: String?
    private(set) var wasKilled = false

    func commit(prompt: String) throws {
        committedPrompt = prompt
    }

    func kill() {
        wasKilled = true
    }
}
