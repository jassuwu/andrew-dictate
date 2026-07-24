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
                "json",
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
}
