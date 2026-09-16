import XCTest

final class FocusAnchorTests: XCTestCase {
    private let anchoredApplication = FocusApplicationIdentity(
        processIdentifier: 42,
        bundleIdentifier: "example.editor"
    )
    private let ownApplication = FocusApplicationIdentity(
        processIdentifier: 7,
        bundleIdentifier: AppIdentity.releaseBundleID
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

    // MARK: - handing the frontmost spot back

    /// The seam this exists for: a locked recording ended while our own
    /// settings window was in front of the app the words were meant for.
    func testOurOwnWindowInFrontYieldsBackToTheAnchoredApp() {
        XCTAssertEqual(
            focusYieldDecision(
                anchor: anchoredApplication,
                frontmost: ownApplication,
                ownBundleIdentifier: AppIdentity.releaseBundleID
            ),
            .activateAnchor(processIdentifier: 42)
        )
    }

    func testAGenuineSwitchToAThirdAppIsLeftAlone() {
        let thirdApplication = FocusApplicationIdentity(
            processIdentifier: 99,
            bundleIdentifier: "example.browser"
        )

        XCTAssertEqual(
            focusYieldDecision(
                anchor: anchoredApplication,
                frontmost: thirdApplication,
                ownBundleIdentifier: AppIdentity.releaseBundleID
            ),
            .leaveFrontmostAlone
        )
        // and the paste still refuses to go there.
        XCTAssertEqual(
            decision(currentApplication: thirdApplication),
            .copyFocusChanged
        )
    }

    /// Dictating into our own fix-a-word window: we are already where the
    /// words are going, so there is nothing to hand back.
    func testAnAnchorInOurOwnWindowIsLeftAlone() {
        XCTAssertEqual(
            focusYieldDecision(
                anchor: ownApplication,
                frontmost: ownApplication,
                ownBundleIdentifier: AppIdentity.releaseBundleID
            ),
            .leaveFrontmostAlone
        )
    }

    // MARK: - our own window

    /// The one destination that runs the dictionary alone: a word dictated
    /// into "fix a word" must not be saved as "Cache."
    func testOnlyOurOwnBundleCountsAsOurOwnUI() {
        XCTAssertTrue(
            pastesIntoOurOwnUI(target: "gg.jass.dictate", own: "gg.jass.dictate")
        )
        XCTAssertFalse(
            pastesIntoOurOwnUI(target: "example.editor", own: "gg.jass.dictate")
        )
    }

    /// A dev run and the test bundle can both have no bundle id, and neither
    /// is our window.
    func testAMissingBundleIdIsNeverOurOwnUI() {
        XCTAssertFalse(pastesIntoOurOwnUI(target: nil, own: "gg.jass.dictate"))
        XCTAssertFalse(pastesIntoOurOwnUI(target: "gg.jass.dictate", own: nil))
        XCTAssertFalse(pastesIntoOurOwnUI(target: nil, own: nil))
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

    /// the same read answers the other question: a word character, or a
    /// comma or semicolon, means the sentence at the caret is still running
    /// and the first word keeps the case it was said in.
    func testACaretInsideASentenceSaysSo() {
        let continuing = [
            "because", "BECAUSE", "chapter 7", "first,", "first;", "café",
        ]

        for text in continuing {
            XCTAssertTrue(
                continuesSentence(after: text),
                "after: \(text)"
            )
        }
    }

    /// the case this exists for: you type a word, you type the space after
    /// it, and only then do you hold fn. the sentence did not end there.
    func testTheSpaceYouTypedDoesNotEndTheSentence() {
        XCTAssertTrue(continuesSentence(after: "failed because "))
        XCTAssertTrue(continuesSentence(after: "failed because   "))
        XCTAssertTrue(continuesSentence(after: "failed because\t"))
    }

    func testAFinishedSentenceOrAnEmptyFieldStartsANewOne() {
        let starting = [
            "done.", "really?", "stop!", "note:", "(", "\"",
            // a new line is a new sentence, and a space after a full stop
            // is still after a full stop
            "first line\n", "done. ", "", "  ",
        ]

        for text in starting {
            XCTAssertFalse(
                continuesSentence(after: text),
                "after: \(text)"
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
