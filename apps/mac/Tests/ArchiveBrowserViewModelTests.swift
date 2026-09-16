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

    // MARK: - searching, which is how anything is found after week one

    private func seed(
        _ texts: [(heard: String, inserted: String)]
    ) throws -> DictationArchive {
        let archive = DictationArchive(fileURL: fileURL)
        for (index, text) in texts.enumerated() {
            try archive.append(
                Dictation(
                    startedAt: Date(timeIntervalSince1970: Double(index)),
                    heard: text.heard,
                    inserted: text.inserted,
                    engine: "v2"
                )
            )
        }
        return archive
    }

    private func seedTwoKubernetes() throws -> DictationArchive {
        try seed([
            (
                heard: "the coober netties ingress is fine the cert is not",
                inserted: "The Kubernetes ingress is fine; the cert is not."
            ),
            (heard: "ship the tag", inserted: "Ship the tag."),
        ])
    }

    /// The word being hunted for is usually the misheard one, which lives only
    /// in the raw text — the row does not even show it unless the cleaner
    /// changed something.
    func testAWordOnlyTheRawTextHasIsStillFound() throws {
        let archive = try seedTwoKubernetes()
        let model = ArchiveBrowserViewModel(archive: archive)

        model.query = "coober"

        XCTAssertEqual(
            model.filtered.map(\.inserted),
            ["The Kubernetes ingress is fine; the cert is not."]
        )
    }

    func testTheCleanedTextIsSearchedToo() throws {
        let archive = try seedTwoKubernetes()
        let model = ArchiveBrowserViewModel(archive: archive)

        model.query = "kubernetes"

        XCTAssertEqual(model.filtered.count, 1)
    }

    /// Nobody types accents into a search field, or capitals on purpose.
    func testSearchIgnoresCaseAndAccents() throws {
        let archive = try seedTwoKubernetes()
        let model = ArchiveBrowserViewModel(archive: archive)

        model.query = "CÖOBER"

        XCTAssertEqual(model.filtered.count, 1)
    }

    /// A field with nothing but a stray space in it is not a search, and must
    /// not hide the archive.
    func testABlankQueryLeavesTheWholeListNewestFirst() throws {
        let archive = try seed(3)
        let model = ArchiveBrowserViewModel(archive: archive)

        model.query = "   "

        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(
            model.filtered.map(\.heard),
            ["heard 2", "heard 1", "heard 0"]
        )
    }

    /// An empty result is a search that found nothing, not an empty archive —
    /// the pane says a different sentence for each.
    func testAQueryThatMatchesNothingIsStillASearch() throws {
        let archive = try seed(3)
        let model = ArchiveBrowserViewModel(archive: archive)

        model.query = "kubernetes"

        XCTAssertTrue(model.filtered.isEmpty)
        XCTAssertTrue(model.isSearching)
        XCTAssertEqual(model.items.count, 3, "and the archive is untouched")
    }
}
