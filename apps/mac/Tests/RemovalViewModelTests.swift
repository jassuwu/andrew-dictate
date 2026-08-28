import XCTest

@MainActor
final class RemovalViewModelTests: XCTestCase {
    private var root: URL!
    private var support: URL!
    private var models: URL!
    private var defaults: UserDefaults!
    private var domain: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        models = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: support, withIntermediateDirectories: true
        )
        domain = "removal-vm-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func model() -> RemovalViewModel {
        RemovalViewModel(
            remover: Remover(
                supportDirectory: support,
                modelDirectory: models,
                preferencesDomain: domain,
                userDefaults: defaults
            )
        )
    }

    private func write(_ name: String) throws {
        try Data(repeating: 0x41, count: 2_048).write(
            to: support.appendingPathComponent(name)
        )
    }

    /// The user asked to leave. Making them tick five boxes is how "no traces"
    /// quietly becomes "some traces".
    func testEverythingPresentStartsSelected() throws {
        try write("dictations.jsonl")
        try write("dictionary.json")

        let model = model()

        XCTAssertTrue(model.selection.contains(.dictations))
        XCTAssertTrue(model.selection.contains(.dictionary))
    }

    func testNothingAbsentIsSelected() {
        XCTAssertTrue(model().selection.isEmpty)
        XCTAssertFalse(model().hasAnythingToRemove)
    }

    func testTrashingTheAppIsOptedInToRatherThanOutOf() {
        XCTAssertFalse(
            model().alsoTrashTheApp,
            "a reset and an uninstall are different intentions"
        )
    }

    func testUntickingSomethingRemovesItFromTheTotal() throws {
        try write("dictations.jsonl")
        try write("dictionary.json")
        let model = model()
        let both = model.selectedBytes

        model.toggle(.dictionary)

        XCTAssertLessThan(model.selectedBytes, both)
        XCTAssertFalse(model.selection.contains(.dictionary))
    }

    func testTogglingTwicePutsItBack() throws {
        try write("dictations.jsonl")
        let model = model()

        model.toggle(.dictations)
        model.toggle(.dictations)

        XCTAssertTrue(model.selection.contains(.dictations))
    }

    func testRemovingReportsSuccessAndLeavesNothingSelected() throws {
        try write("dictations.jsonl")
        let model = model()

        let failed = model.removeSelected()

        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(model.outcome, "removed. quitting.")
        XCTAssertFalse(model.hasAnythingToRemove)
    }

    func testAnAbsentItemReportsThatRatherThanZeroBytes() {
        let entry = model().entries.first { $0.item == .dictations }!

        XCTAssertEqual(model().sizeText(for: entry), "nothing kept")
    }
}
