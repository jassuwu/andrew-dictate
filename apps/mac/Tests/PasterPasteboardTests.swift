import AppKit
import XCTest

/// What lands on the clipboard, asserted on a private pasteboard.
///
/// Nothing here posts a synthetic ⌘V: that would type into whatever app the
/// test runner happens to be in front of. The pasteboard write is the part
/// that has to be right whether or not the keystroke reaches anybody.
@MainActor
final class PasterPasteboardTests: XCTestCase {
    func testAPastedTranscriptIsMarkedTransientAndStillPastes() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        XCTAssertNotNil(
            Paster.writeTranscript("sounds good", to: pasteboard)
        )
        XCTAssertNotNil(Paster.markTransient(pasteboard))

        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(.string), "\(types)")
        XCTAssertTrue(types.contains(Paster.transientType), "\(types)")
        XCTAssertEqual(pasteboard.string(forType: .string), "sounds good")
    }

    /// The transient marker must not cost us the ownership check the restore
    /// depends on: it is an additive write to the item we just wrote.
    func testMarkingTransientKeepsTheWriteOurs() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let written = Paster.writeTranscript("one more thing", to: pasteboard)
        let marked = Paster.markTransient(pasteboard)

        XCTAssertEqual(marked ?? written, pasteboard.changeCount)
    }

    func testASecureFieldTranscriptIsMarkedConcealed() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        XCTAssertNotNil(
            Paster.writeTranscript(
                "correct horse battery staple",
                to: pasteboard,
                concealed: true
            )
        )

        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(Paster.concealedType), "\(types)")
        XCTAssertFalse(types.contains(Paster.transientType), "\(types)")
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "correct horse battery staple"
        )
    }
}
