import XCTest

final class RemovalPlanTests: XCTestCase {
    private var root: URL!
    private var support: URL!
    private var models: URL!
    private var defaults: UserDefaults!
    private var domain: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        support = root.appendingPathComponent("Andrew Dictate Dev", isDirectory: true)
        models = root.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: support, withIntermediateDirectories: true
        )
        domain = "removal-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func remover() -> Remover {
        Remover(
            supportDirectory: support,
            modelDirectory: models,
            preferencesDomain: domain,
            userDefaults: defaults,
            // never `tccutil` against the author's own machine from a test
            resetPermissions: { _ in }
        )
    }

    private func write(_ name: String, bytes: Int = 64) throws {
        try Data(repeating: 0x41, count: bytes).write(
            to: support.appendingPathComponent(name)
        )
    }

    // MARK: - what it finds

    func testAFreshMachineHasNothingToRemove() {
        let plan = remover().plan()

        XCTAssertTrue(plan.entries.allSatisfy { !$0.exists })
        XCTAssertEqual(plan.totalBytes, 0)
    }

    func testItFindsEachFileAndItsRealSize() throws {
        try write("dictations.jsonl", bytes: 128)
        try write("dictionary.json", bytes: 64)

        let plan = remover().plan()
        let byItem = Dictionary(
            uniqueKeysWithValues: plan.entries.map { ($0.item, $0) }
        )

        XCTAssertTrue(byItem[.dictations]!.exists)
        XCTAssertGreaterThan(byItem[.dictations]!.bytes, 0)
        XCTAssertTrue(byItem[.dictionary]!.exists)
        XCTAssertFalse(byItem[.labLog]!.exists)
    }

    /// The models are a directory somewhere else entirely, and they are the
    /// largest thing on disk by far — a plan that missed them would leave
    /// hundreds of megabytes behind while claiming to have cleaned up.
    func testItFindsTheSharedModelDirectoryOutsideTheAppsOwnFolder() throws {
        try FileManager.default.createDirectory(
            at: models, withIntermediateDirectories: true
        )
        try Data(repeating: 0x42, count: 4_096).write(
            to: models.appendingPathComponent("weights.bin")
        )

        let entry = remover().plan().entries.first { $0.item == .speechModels }
        XCTAssertEqual(entry?.exists, true)
        XCTAssertGreaterThan(entry?.bytes ?? 0, 0)
    }

    func testSettingsCountAsPresentOnlyWhenSomethingIsStored() {
        XCTAssertFalse(
            remover().plan().entries.first { $0.item == .settings }!.exists
        )

        defaults.set(true, forKey: "anything")
        XCTAssertTrue(
            remover().plan().entries.first { $0.item == .settings }!.exists
        )
    }

    // MARK: - what it removes

    func testItRemovesOnlyWhatWasChosen() throws {
        try write("dictations.jsonl")
        try write("dictionary.json")

        let failed = remover().remove([.dictations])

        XCTAssertTrue(failed.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: support.appendingPathComponent("dictations.jsonl").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: support.appendingPathComponent("dictionary.json").path
            ),
            "an unchosen item must survive"
        )
    }

    func testRemovingSettingsEmptiesThePreferencesDomain() {
        defaults.set(true, forKey: "keepDictations")

        remover().remove([.settings])

        XCTAssertNil(defaults.persistentDomain(forName: domain)?["keepDictations"])
    }

    /// "No traces" has to include the folder itself, or an uninstalled app
    /// still shows up in Application Support.
    func testTheAppsFolderGoesOnceItIsEmpty() throws {
        try write("dictations.jsonl")
        try write("dictionary.json")
        try write("cleanup-lab.jsonl")

        remover().remove([.dictations, .dictionary, .labLog])

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: support.path),
            "the empty folder is a trace too"
        )
    }

    /// Something the plan did not know about is not something it may delete.
    func testAnUnknownFileKeepsTheFolderAlive() throws {
        try write("dictations.jsonl")
        try write("something-we-added-later.json")

        remover().remove([.dictations])

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: support.path),
            "an unrecognised file must not be removed unseen"
        )
    }

    func testRemovingSomethingAlreadyGoneIsNotAFailure() {
        XCTAssertTrue(remover().remove(Set(RemovalPlan.Item.allCases)).isEmpty)
    }

    // MARK: - the copy that stops a default being a surprise

    func testTheSharedModelsCarryAWarningAndTheDictationsSayTheyAreGone() {
        XCTAssertNotNil(RemovalPlan.Item.speechModels.caveat)
        XCTAssertTrue(
            RemovalPlan.Item.speechModels.caveat!.contains("FluidAudio")
        )
        XCTAssertNotNil(RemovalPlan.Item.dictations.caveat)
        XCTAssertNil(RemovalPlan.Item.dictionary.caveat)
    }
}

extension RemovalPlanTests {
    func testPermissionsAreAlwaysOfferedAndResetByBundleID() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("removal-permissions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        nonisolated(unsafe) var resetFor: [String] = []
        let remover = Remover(
            supportDirectory: dir.appendingPathComponent("support"),
            modelDirectory: dir.appendingPathComponent("models"),
            preferencesDomain: "gg.jass.dictate.test",
            userDefaults: UserDefaults(suiteName: "gg.jass.dictate.test-\(UUID().uuidString)")!,
            resetPermissions: { resetFor.append($0) }
        )

        XCTAssertEqual(
            remover.plan().entries.first { $0.item == .permissions }?.exists, false,
            "nothing was ever asked for on a fresh machine")
        remover.userDefaults.setPersistentDomain(
            ["AndrewDictate.onboardingCompleted": true], forName: "gg.jass.dictate.test")
        XCTAssertEqual(remover.plan().entries.first { $0.item == .permissions }?.exists, true)

        let failed = remover.remove([.permissions])
        XCTAssertEqual(failed, [])
        XCTAssertEqual(resetFor, ["gg.jass.dictate.test"])
    }

    func testAPermissionResetThatFailsIsReported() {
        struct Nope: Error {}
        let remover = Remover(
            supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            modelDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            preferencesDomain: "gg.jass.dictate.test",
            userDefaults: UserDefaults(suiteName: "gg.jass.dictate.test-\(UUID().uuidString)")!,
            resetPermissions: { _ in throw Nope() }
        )
        XCTAssertEqual(remover.remove([.permissions]), [.permissions])
    }
}
