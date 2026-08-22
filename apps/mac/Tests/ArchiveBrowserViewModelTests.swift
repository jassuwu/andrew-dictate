import XCTest

@MainActor
final class ArchiveBrowserViewModelTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("dictations.jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: fileURL.deletingLastPathComponent()
        )
        super.tearDown()
    }

    private func seed(_ count: Int) throws -> DictationArchive {
        let archive = DictationArchive(fileURL: fileURL)
        for index in 0..<count {
            try archive.append(
                Dictation(
                    startedAt: Date(timeIntervalSince1970: Double(index)),
                    heard: "heard \(index)",
                    inserted: "Inserted \(index).",
                    engine: "v2"
                )
            )
        }
        return archive
    }

    /// Newest first. An archive read in write order would put the thing you
    /// just said at the bottom of a list that grows forever.
    func testTheMostRecentDictationIsAtTheTop() throws {
        let archive = try seed(3)
        let model = ArchiveBrowserViewModel(archive: archive)

        XCTAssertEqual(model.items.map(\.heard), ["heard 2", "heard 1", "heard 0"])
    }

    func testAnEmptyArchiveIsEmptyRatherThanBroken() {
        let model = ArchiveBrowserViewModel(
            archive: DictationArchive(fileURL: fileURL)
        )

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.failure)
    }

    func testDeletingOneRemovesItFromDiskAndFromTheList() throws {
        let archive = try seed(3)
        let model = ArchiveBrowserViewModel(archive: archive)
        let doomed = try XCTUnwrap(model.items.first)

        model.delete(doomed)

        XCTAssertEqual(model.items.map(\.heard), ["heard 1", "heard 0"])
        XCTAssertEqual(
            try archive.all().map(\.heard),
            ["heard 0", "heard 1"],
            "and it is gone from the file, not just the view"
        )
    }

    func testDeletingEverythingOneAtATimeLeavesNothing() throws {
        let archive = try seed(2)
        let model = ArchiveBrowserViewModel(archive: archive)

        while let first = model.items.first {
            model.delete(first)
        }

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(try archive.all().count, 0)
    }

    /// The raw text is what a dictionary entry needs, so the row that offers
    /// "fix a word" has to hand over `heard`, not `inserted`.
    func testARowOffersTheRawTextForCorrection() throws {
        _ = try seed(1)
        let model = ArchiveBrowserViewModel(
            archive: DictationArchive(fileURL: fileURL)
        )

        XCTAssertEqual(model.items.first?.heard, "heard 0")
    }
}
