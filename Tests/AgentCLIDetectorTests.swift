import XCTest

final class AgentCLIDetectorTests: XCTestCase {
    func testTemplateRequiresLiteralPromptPlaceholder() {
        XCTAssertTrue(
            AgentCommandTemplate.isValid("codex exec {prompt}")
        )
        XCTAssertFalse(
            AgentCommandTemplate.isValid("codex exec prompt")
        )
        XCTAssertFalse(
            AgentCommandTemplate.isValid("codex exec {PROMPT}")
        )
    }

    func testTokenizerRespectsQuotedAndEscapedSegments() throws {
        XCTAssertEqual(
            try AgentCommandTemplate.tokenize(
                #"agent --label "two words" 'three words' escaped\ word {prompt}"#
            ),
            [
                "agent",
                "--label",
                "two words",
                "three words",
                "escaped word",
                "{prompt}",
            ]
        )
    }

    func testTemplateRejectsQuotedOrConcatenatedPlaceholder() {
        let templates = [
            #"codex exec "{prompt}""#,
            "codex exec '{prompt}'",
            "codex exec prefix{prompt}",
            "codex exec {prompt}suffix",
        ]

        for template in templates {
            XCTAssertFalse(
                AgentCommandTemplate.isValid(template),
                template
            )
            XCTAssertThrowsError(
                try AgentCommandTemplate.parse(template)
            ) { error in
                XCTAssertEqual(
                    error as? AgentCommandTemplate.ValidationError,
                    .promptMustBeStandaloneWord
                )
            }
        }
    }

    func testTemplateRejectsMultiplePlaceholders() {
        let template = "codex exec {prompt} --also {prompt}"

        XCTAssertFalse(AgentCommandTemplate.isValid(template))
        XCTAssertThrowsError(
            try AgentCommandTemplate.parse(template)
        ) { error in
            XCTAssertEqual(
                error as? AgentCommandTemplate.ValidationError,
                .promptMustBeStandaloneWord
            )
        }
    }

    func testTemplateRejectsPromptAsExecutable() {
        XCTAssertFalse(
            AgentCommandTemplate.isValid("{prompt} --version")
        )
    }

    func testTokenizerRejectsUnterminatedQuoting() {
        XCTAssertThrowsError(
            try AgentCommandTemplate.tokenize(#"codex exec "unfinished"#)
        ) { error in
            XCTAssertEqual(
                error as? AgentCommandTemplate.ValidationError,
                .invalidShellQuoting
            )
        }
    }

    func testCandidatePathsIncludeCommonNVMAndWhichLocations() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let which = URL(fileURLWithPath: "/custom/bin/codex")

        let paths = AgentCLIDetector.candidatePaths(
            for: .codex,
            homeDirectory: home,
            nvmNodeVersions: ["v22.1.0", "v20.2.0"],
            pathFromWhich: which
        ).map(\.path)

        XCTAssertTrue(paths.contains("/opt/homebrew/bin/codex"))
        XCTAssertTrue(paths.contains("/usr/local/bin/codex"))
        XCTAssertTrue(
            paths.contains(
                "/Users/tester/.nvm/versions/node/v22.1.0/bin/codex"
            )
        )
        XCTAssertEqual(paths.last, "/custom/bin/codex")
    }

    func testCandidatePathsRemoveDuplicateWhichResult() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let which = URL(fileURLWithPath: "/opt/homebrew/bin/claude")

        let paths = AgentCLIDetector.candidatePaths(
            for: .claude,
            homeDirectory: home,
            nvmNodeVersions: [],
            pathFromWhich: which
        ).map(\.path)

        XCTAssertEqual(
            paths.filter { $0 == "/opt/homebrew/bin/claude" }.count,
            1
        )
    }
}
