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

    // MARK: - the clipboard read ahead

    /// nothing copied since key-up: the clipboard read while the engine
    /// worked is the one put back.
    func testAReadAheadStillCurrentIsTheOneRestored() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("what you had", forType: .string)
        let early = try XCTUnwrap(Paster.snapshot(of: pasteboard))

        let restored = Paster.snapshotToRestore(early: early, on: pasteboard)

        XCTAssertEqual(restored?.changeCount, early.changeCount)
        XCTAssertEqual(text(in: restored), ["what you had"])
    }

    /// a ⌘C while the engine worked — or the menu's copy timings — moved
    /// the change count: the read ahead is stale, and the clipboard is read
    /// again at the paste.
    func testAReadAheadIsDroppedOnceAnythingIsCopiedOverIt() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("what you had", forType: .string)
        let early = try XCTUnwrap(Paster.snapshot(of: pasteboard))

        pasteboard.clearContents()
        pasteboard.setString("copied since", forType: .string)
        let restored = Paster.snapshotToRestore(early: early, on: pasteboard)

        XCTAssertEqual(restored?.changeCount, pasteboard.changeCount)
        XCTAssertEqual(text(in: restored), ["copied since"])
    }

    // MARK: - a copy you asked for

    /// the menu's copy timings and copy diagnostics: a plain write you can
    /// paste and your clipboard manager can keep — not the paste's relay.
    func testACopyYouAskedForIsAPlainWrite() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("what you had", forType: .string)

        await Paster().copy("app 0.9.4 · mac 26.0", to: pasteboard)

        let types = pasteboard.types ?? []
        XCTAssertEqual(pasteboard.string(forType: .string), "app 0.9.4 · mac 26.0")
        XCTAssertFalse(types.contains(Paster.transientType), "\(types)")
        XCTAssertFalse(types.contains(Paster.concealedType), "\(types)")
    }

    /// two copies asked at once land one after the other, in order.
    func testCopiesTakeTheirTurn() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let paster = Paster()

        let first = Task { await paster.copy("timings", to: pasteboard) }
        let second = Task { await paster.copy("diagnostics", to: pasteboard) }
        await first.value
        await second.value

        XCTAssertEqual(pasteboard.string(forType: .string), "diagnostics")
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    }

    private func text(in snapshot: Paster.Snapshot?) -> [String] {
        (snapshot?.items ?? []).flatMap { item in
            item.representations
                .filter { $0.type == NSPasteboard.PasteboardType.string.rawValue }
                .compactMap { String(data: $0.data, encoding: .utf8) }
        }
    }
}
