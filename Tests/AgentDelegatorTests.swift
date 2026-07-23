import XCTest

final class AgentDelegatorTests: XCTestCase {
    func testShellEscapeSingleQuotedEscapesQuotes() {
        XCTAssertEqual(
            shellEscapeSingleQuoted("it's Andrew's"),
            "'it'\\''s Andrew'\\''s'"
        )
    }

    func testShellEscapeSingleQuotedPreservesBackslashes() {
        XCTAssertEqual(
            shellEscapeSingleQuoted(#"C:\Users\andrew"#),
            #"'C:\Users\andrew'"#
        )
    }

    func testShellEscapeSingleQuotedPreservesNewlines() {
        XCTAssertEqual(
            shellEscapeSingleQuoted("first\nsecond"),
            "'first\nsecond'"
        )
    }

    func testShellEscapeSingleQuotedPreservesUnicode() {
        XCTAssertEqual(
            shellEscapeSingleQuoted("नमस्ते 👋"),
            "'नमस्ते 👋'"
        )
    }

    func testShellEscapeSingleQuotedHandlesEmptyPrompt() {
        XCTAssertEqual(shellEscapeSingleQuoted(""), "''")
    }

    func testTemplateCompositionReplacesEveryPromptPlaceholder() throws {
        XCTAssertEqual(
            try AgentCommandTemplate.compose(
                "codex exec {prompt} && echo {prompt}",
                prompt: "it's ready"
            ),
            "codex exec 'it'\\''s ready' && echo 'it'\\''s ready'"
        )
    }

    func testTemplateCompositionRejectsMissingPromptPlaceholder() {
        XCTAssertFalse(
            AgentCommandTemplate.isValid("codex exec without placeholder")
        )
        XCTAssertThrowsError(
            try AgentCommandTemplate.compose(
                "codex exec without placeholder",
                prompt: "hello"
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentDelegationError,
                .templateMissingPrompt
            )
        }
    }
}
