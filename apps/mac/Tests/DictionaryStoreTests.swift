import XCTest

@MainActor
final class DictionaryStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("dictionary.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: fileURL.deletingLastPathComponent()
        )
        super.tearDown()
    }

    // MARK: - import adds, and only replaces when you say so

    func testMergeKeepsTheRowsYouHadAndAppendsTheNewOnes() {
        let store = DictionaryStore(fileURL: fileURL)
        store.add(DictionaryEntry(wrong: "darsh", right: "Darsh"))
        store.add(DictionaryEntry(wrong: "jason", right: "JSON"))

        let result = store.merge([
            DictionaryEntry(wrong: "cypher d", right: "CypherD")
        ])

        XCTAssertEqual(result, DictionaryStore.MergeResult(added: 1, updated: 0))
        XCTAssertEqual(
            store.entries.map(\.wrong),
            ["darsh", "jason", "cypher d"],
            "new rows land in file order, behind the ones you taught it"
        )
    }

    /// The merge key is the identity the substitution itself matches on, or a
    /// merge could leave two rows that both fire on the same word.
    func testAWrongSideDifferingOnlyInCaseOrSpacingUpdatesInPlace() {
        let store = DictionaryStore(fileURL: fileURL)
        store.add(DictionaryEntry(wrong: "darsh", right: "Darsh"))

        let result = store.merge([
            DictionaryEntry(wrong: "  DARSH ", right: "Darshan")
        ])

        XCTAssertEqual(result, DictionaryStore.MergeResult(added: 0, updated: 1))
        XCTAssertEqual(store.entries.count, 1, "one row, not two that both fire")
        XCTAssertEqual(store.entries.first?.wrong, "darsh", "your spelling stays")
        XCTAssertEqual(store.entries.first?.right, "Darshan", "the file wins")
    }

    func testTheRowKeepsItsIdWhenTheFileCorrectsIt() {
        let store = DictionaryStore(fileURL: fileURL)
        let mine = DictionaryEntry(wrong: "darsh", right: "Darsh")
        store.add(mine)

        store.merge([DictionaryEntry(wrong: "darsh", right: "Darshan")])

        XCTAssertEqual(store.entries.first?.id, mine.id)
    }

    func testTheSameFileTwiceAddsNothing() {
        let store = DictionaryStore(fileURL: fileURL)
        let file = [DictionaryEntry(wrong: "jason", right: "JSON")]
        store.merge(file)

        let again = store.merge(file)

        XCTAssertEqual(again, DictionaryStore.MergeResult(added: 0, updated: 0))
        XCTAssertEqual(store.entries.count, 1)
    }

    /// The table refuses to empty a working rule. A file someone sent you
    /// does not get to do it through the other door.
    func testAnImportedBlankRightSideIsIgnored() {
        let store = DictionaryStore(fileURL: fileURL)
        store.add(DictionaryEntry(wrong: "darsh", right: "Darsh"))

        let result = store.merge([
            DictionaryEntry(wrong: "darsh", right: ""),
            DictionaryEntry(wrong: "jason", right: "   "),
        ])

        XCTAssertEqual(result, DictionaryStore.MergeResult(added: 0, updated: 0))
        XCTAssertEqual(store.entries.map(\.right), ["Darsh"])
        XCTAssertEqual(store.entries.count, 1, "a rule that could never fire")
    }

    func testReplaceIsStillTheWholesaleThingTheButtonUsedToDo() {
        let store = DictionaryStore(fileURL: fileURL)
        store.add(DictionaryEntry(wrong: "darsh", right: "Darsh"))

        XCTAssertTrue(
            store.replace(with: [DictionaryEntry(wrong: "jason", right: "JSON")])
        )
        XCTAssertEqual(store.entries.map(\.wrong), ["jason"])
    }

    /// SPEC §4. An import that could not reach disk must not look like one
    /// that landed — the words you had are still the words you have.
    func testAnImportThatCannotReachDiskChangesNothing() throws {
        try writeDictionary([DictionaryEntry(wrong: "darsh", right: "Darsh")])
        let store = DictionaryStore(fileURL: fileURL)
        try blockWrites()

        XCTAssertFalse(
            store.replace(with: [DictionaryEntry(wrong: "jason", right: "JSON")])
        )
        XCTAssertNil(
            store.merge([DictionaryEntry(wrong: "jason", right: "JSON")])
        )
        XCTAssertEqual(store.entries.map(\.right), ["Darsh"])
    }

    func testAFileThatIsNotADictionaryIsRefusedWithASentence() throws {
        let store = DictionaryStore(fileURL: fileURL)
        let source = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("notes.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("hello".utf8).write(to: source)

        XCTAssertNil(store.decodeEntries(from: source))
        XCTAssertNotNil(store.lastFailure)
        XCTAssertTrue(store.entries.isEmpty, "nothing was touched")
    }

    func testDecodingAFileDoesNotWriteAnything() throws {
        let store = DictionaryStore(fileURL: fileURL)
        let source = try writeSource([
            DictionaryEntry(wrong: "jason", right: "JSON")
        ])

        XCTAssertEqual(store.decodeEntries(from: source)?.count, 1)
        XCTAssertTrue(store.entries.isEmpty, "asking is not importing")
    }

    // MARK: - a word can never become nothing

    /// Clearing the right side of a working rule used to save, and the rule
    /// then deleted that word from every dictation afterwards.
    func testEmptyingTheRightSideOfAWorkingRuleIsRefused() {
        let store = DictionaryStore(fileURL: fileURL)
        let entry = DictionaryEntry(wrong: "darsh", right: "Darsh")
        store.add(entry)

        XCTAssertFalse(store.updateRight(id: entry.id, right: ""))
        XCTAssertEqual(store.entries.first?.right, "Darsh")
        XCTAssertEqual(
            store.lastFailure,
            "a word has to become something. remove the row to drop the rule."
        )
    }

    func testAWhitespaceOnlyRightSideIsRefusedToo() {
        let store = DictionaryStore(fileURL: fileURL)
        let entry = DictionaryEntry(wrong: "darsh", right: "Darsh")
        store.add(entry)

        XCTAssertFalse(store.updateRight(id: entry.id, right: "   "))
        XCTAssertEqual(store.entries.first?.right, "Darsh")
    }

    /// The + button's empty row, and typing the wrong side first.
    func testAFreshRowStillSavesTheWrongSideOnItsOwn() {
        let store = DictionaryStore(fileURL: fileURL)
        let blank = DictionaryEntry(wrong: "", right: "")
        store.add(blank)

        XCTAssertTrue(store.updateWrong(id: blank.id, wrong: "darsh"))
        XCTAssertEqual(store.entries.first?.wrong, "darsh")
        XCTAssertEqual(store.entries.first?.right, "")
    }

    // MARK: - learned entries

    /// every dictionary.json written before the app could learn has no
    /// word on it: those rows are yours, and they still load.
    func testAFileFromBeforeLearningLoadsAsYourOwnRows() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let old = """
            [{"id":"6B1C1F4E-3F43-4E43-9E0B-7E2A1C9B3D10","wrong":"jason","right":"JSON"}]
            """
        try Data(old.utf8).write(to: fileURL)

        let store = DictionaryStore(fileURL: fileURL)

        XCTAssertEqual(store.entries.map(\.wrong), ["jason"])
        XCTAssertEqual(store.entries.first?.learned, false)
        XCTAssertNil(store.lastFailure)
    }

    func testALearnedEntryIsStillLearnedAfterARelaunch() {
        let store = DictionaryStore(fileURL: fileURL)
        store.add(DictionaryEntry(wrong: "jaz dot dev", right: "jass.dev", learned: true))
        store.add(DictionaryEntry(wrong: "darsh", right: "Darsh"))

        let relaunched = DictionaryStore(fileURL: fileURL)

        XCTAssertEqual(relaunched.entries.map(\.learned), [true, false])
    }

    /// a row you typed is written exactly as before, so an exported file
    /// still reads in an older copy of the app and in anyone's editor.
    func testARowYouTypedIsWrittenWithoutTheLearnedMark() throws {
        let store = DictionaryStore(fileURL: fileURL)
        store.add(DictionaryEntry(wrong: "darsh", right: "Darsh"))

        let written = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertFalse(written.contains("learned"))
    }

    // MARK: - helpers

    private func writeDictionary(_ entries: [DictionaryEntry]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(entries).write(to: fileURL)
    }

    private func writeSource(_ entries: [DictionaryEntry]) throws -> URL {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let source = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("source.json")
        try JSONEncoder().encode(entries).write(to: source)
        return source
    }

    /// A directory where the file needs to be: writes cannot succeed.
    private func blockWrites() throws {
        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(
            at: fileURL,
            withIntermediateDirectories: true
        )
    }
}
