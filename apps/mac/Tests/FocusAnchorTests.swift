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
