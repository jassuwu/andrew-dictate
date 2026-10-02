import XCTest

/// the press log on disk: friends restart the app to make a failure go
/// away, so the evidence has to outlive the process — and stay small, and
/// go when history goes.
final class PressLogStoreTests: XCTestCase {
    private var directory: URL!
    private var store: PressLogStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = PressLogStore(
            fileURL: directory.appendingPathComponent("presses.jsonl")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRecordsComeBackOldestFirst() throws {
        try store.append(press(endingAt: 1))
        try store.append(press(endingAt: 2, outcome: .refused(.meetingRunning)))
        try store.append(press(endingAt: 3, outcome: .leftOnPasteboard(.focusChanged)))

        XCTAssertEqual(try store.all(), [
            press(endingAt: 1),
            press(endingAt: 2, outcome: .refused(.meetingRunning)),
            press(endingAt: 3, outcome: .leftOnPasteboard(.focusChanged)),
        ])
    }

    /// two hundred presses is a few days of evidence and a few dozen
    /// kilobytes. the oldest go first.
    func testOnlyTheLastTwoHundredAreKept() throws {
        for end in 1...205 {
            try store.append(press(endingAt: end))
        }

        let kept = try store.all()
        XCTAssertEqual(kept.count, 200)
        XCTAssertEqual(kept.first?.stages.ended, 6)
        XCTAssertEqual(kept.last?.stages.ended, 205)
    }

    func testTheNewestFewAreTheTail() throws {
        for end in 1...8 {
            try store.append(press(endingAt: end))
        }

        XCTAssertEqual(try store.recent(3).map(\.stages.ended), [6, 7, 8])
        XCTAssertEqual(try store.recent(50).count, 8)
    }

    /// no words in it, but it says when you were at your desk.
    func testTheFileIsTheOwnersAloneThroughATrim() throws {
        try store.append(press(endingAt: 1))
        XCTAssertEqual(try permissions(), 0o600)

        for end in 2...201 {
            try store.append(press(endingAt: end))
        }
        XCTAssertEqual(try permissions(), 0o600)
    }

    /// wiping history takes the press log with it, and leaves no file.
    func testWipingLeavesNothingOnDisk() throws {
        try store.append(press(endingAt: 1))

        try store.deleteAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(try store.all(), [])
        // and a wipe of nothing is not an error.
        XCTAssertNoThrow(try store.deleteAll())
    }

    /// a torn last line, or a record from a newer build, costs only itself.
    func testALineThatWillNotReadCostsOnlyItself() throws {
        try store.append(press(endingAt: 1))
        let handle = try FileHandle(forWritingTo: store.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"outcome":"teleported","#.utf8) + Data([0x0A]))
        try handle.close()
        try store.append(press(endingAt: 2))

        XCTAssertEqual(try store.all().map(\.stages.ended), [1, 2])
    }

    /// a record written before the mic-change flag existed still reads,
    /// with the flag off.
    func testARecordFromBeforeTheMicChangeFlagStillReads() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let older = #"{"capped":false,"engine":"v2","mic":{"name":"MacBook Pro Microphone","transport":"built-in"},"outcome":"delivered","peak":0.25,"retry":false,"samples":16000,"stages":{"ended":7,"firstBuffer":40,"keyUp":900},"startedAt":"2026-10-02T06:52:31Z","words":3}"#
        try Data((older + "\n").utf8).write(to: store.fileURL)

        XCTAssertEqual(try store.all(), [press(endingAt: 7)])
    }

    // MARK: - helpers

    private func press(
        endingAt end: Int,
        outcome: PressRecord.Outcome = .delivered
    ) -> PressRecord {
        PressRecord(
            outcome: outcome,
            startedAt: Date(timeIntervalSince1970: 1_790_923_951),
            mic: MicDescription(name: "MacBook Pro Microphone", transport: .builtIn),
            samples: 16_000,
            peak: 0.25,
            words: 3,
            stages: PressRecord.Stages(firstBuffer: 40, keyUp: 900, ended: end),
            engine: "v2",
            capped: false,
            retry: false,
            mainStallMs: nil
        )
    }

    private func permissions() throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: store.fileURL.path
        )
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
