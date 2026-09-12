import XCTest

final class FocusAnchorTests: XCTestCase {
    private let anchoredApplication = FocusApplicationIdentity(
        processIdentifier: 42,
        bundleIdentifier: "example.editor"
    )

    func testMatchingApplicationAndFocusedElementPaste() {
        XCTAssertEqual(
            decision(),
            .paste
        )
    }

    func testChangedProcessOrBundleCopiesInstead() {
        XCTAssertEqual(
            decision(
                currentApplication: FocusApplicationIdentity(
                    processIdentifier: 43,
                    bundleIdentifier: "example.editor"
                )
            ),
            .copyFocusChanged
        )
        XCTAssertEqual(
            decision(
                currentApplication: FocusApplicationIdentity(
                    processIdentifier: 42,
                    bundleIdentifier: "example.other"
                )
            ),
            .copyFocusChanged
        )
    }

    func testSecureAnchoredFieldCopiesInstead() {
        XCTAssertEqual(
            decision(anchorIsSecure: true),
            .copySecure
        )
    }

    func testSecureCurrentFieldCopiesInstead() {
        XCTAssertEqual(
            decision(currentIsSecure: true),
            .copySecure
        )
    }

    func testChangedFocusedElementCopiesInstead() {
        XCTAssertEqual(
            decision(focusedElementMatchesAnchor: false),
            .copyFocusChanged
        )
    }

    func testMissingElementAnchorFallsBackToApplicationIdentity() {
        XCTAssertEqual(
            decision(
                hasFocusedElement: false,
                focusedElementMatchesAnchor: false
            ),
            .paste
        )
    }

    // MARK: - the space between two dictations

    /// every "cannot tell" answer arrives here as nil — an empty field, a
    /// caret at offset zero, an app that refused the read — and nil never
    /// adds a space. no leading space is the old behaviour, not a new bug.
    func testNothingToJoinMeansNoSpace() {
        XCTAssertFalse(needsJoinSpace(after: nil))
        XCTAssertFalse(needsJoinSpace(after: " "))
        XCTAssertFalse(needsJoinSpace(after: "\n"))
        XCTAssertFalse(needsJoinSpace(after: "\t"))
    }

    /// a word attaches to these without a space. a straight quote is
    /// genuinely ambiguous — `he said "` or `…said."` — and lands on no
    /// space, because a stray one is litter the user has to delete.
    func testAWordAttachesToAnOpeningDelimiter() {
        let openers: [Character] = [
            "(", "[", "{", "<", "\"", "'", "\u{201C}", "\u{2018}",
            "/", "-", "\u{2014}",
        ]

        for character in openers {
            XCTAssertFalse(
                needsJoinSpace(after: character),
                "after: \(character)"
            )
        }
    }

    func testTextAtTheCaretMeansTheWordsNeedTheirOwnSpace() {
        let joiners: [Character] = [
            "o", "7", ".", "?", "!", ",", ")", "]", "\u{201D}", ":",
        ]

        for character in joiners {
            XCTAssertTrue(
                needsJoinSpace(after: character),
                "after: \(character)"
            )
        }
    }

    /// the same character answers the other question: a word character, or
    /// a comma or semicolon, means the sentence at the caret is still
    /// running and the first word keeps the case it was said in.
    func testACaretInsideASentenceSaysSo() {
        let continuing: [Character] = ["o", "O", "7", ",", ";", "é"]

        for character in continuing {
            XCTAssertTrue(
                continuesSentence(after: character),
                "after: \(character)"
            )
        }
    }

    func testAFinishedSentenceOrAnEmptyFieldStartsANewOne() {
        let starting: [Character] = [".", "?", "!", ":", " ", "\n", ")", "\""]

        for character in starting {
            XCTAssertFalse(
                continuesSentence(after: character),
                "after: \(character)"
            )
        }
        XCTAssertFalse(continuesSentence(after: nil))
    }

    private func decision(
        currentApplication: FocusApplicationIdentity? = nil,
        hasFocusedElement: Bool = true,
        focusedElementMatchesAnchor: Bool = true,
        anchorIsSecure: Bool = false,
        currentIsSecure: Bool = false
    ) -> FocusRevalidationDecision {
        focusRevalidationDecision(
            anchor: AnchoredFocusState(
                application: anchoredApplication,
                hasFocusedElement: hasFocusedElement,
                isSecureTextField: anchorIsSecure
            ),
            current: CurrentFocusState(
                application: currentApplication ?? anchoredApplication,
                focusedElementMatchesAnchor: focusedElementMatchesAnchor,
                isSecureTextField: currentIsSecure
            )
        )
    }
}
