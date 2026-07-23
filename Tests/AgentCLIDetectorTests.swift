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
