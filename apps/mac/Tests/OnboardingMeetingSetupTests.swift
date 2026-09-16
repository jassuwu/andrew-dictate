import XCTest

@MainActor
final class OnboardingMeetingSetupTests: XCTestCase {
    /// The folder is made during setup so macOS asks for ~/Documents here,
    /// beside the other asks, instead of interrupting the first save.
    func testTheConsentClickMakesTheTranscriptsFolder() async throws {
        let parent = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        )
        .appendingPathComponent(
            "andrew-dictate-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let folder = parent.appendingPathComponent(
            MeetingTranscriptFile.folderName,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }

        let setup = OnboardingMeetingSetup(
            prepareMeetingsFolder: {
                OnboardingMeetingSetup.createFolder(at: folder)
            }
        )

        setup.begin()
        try await settle { setup.folderStatus == .ready }

        XCTAssertEqual(setup.folderStatus, .ready)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: folder.path(percentEncoded: false)
            )
        )
    }

    /// A refused folder is the one case the checklist has to mention, and
    /// the only case: nothing new appears in the happy path.
    func testAFolderItCannotMakeAsksForAnother() async throws {
        let setup = OnboardingMeetingSetup(prepareMeetingsFolder: { false })

        XCTAssertEqual(setup.folderStatus, .pending)

        setup.begin()
        try await settle { setup.folderStatus == .actionRequired }

        XCTAssertEqual(setup.folderStatus, .actionRequired)
    }

    /// The jobs run in tasks, so the assertion has to wait for the one it is
    /// about rather than for the slowest stub in `begin()`.
    private func settle(
        until isDone: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if isDone() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
