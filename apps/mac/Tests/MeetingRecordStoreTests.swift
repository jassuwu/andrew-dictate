import XCTest

/// the meeting records on disk: a meeting lost on Tuesday is looked into on
/// Friday, so the evidence has to outlive the process — and stay small, and
/// go when it is asked to.
final class MeetingRecordStoreTests: XCTestCase {
    private var directory: URL!
    private var store: MeetingRecordStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = MeetingRecordStore(
            fileURL: directory.appendingPathComponent("meeting-records.jsonl")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRecordsComeBackOldestFirst() throws {
        try store.append(meeting(lasting: 1))
        try store.append(meeting(lasting: 2, outcome: .nothingKept(.tapNeverHeard)))
        try store.append(meeting(lasting: 3, outcome: .couldNotRecover))

        XCTAssertEqual(try store.all(), [
            meeting(lasting: 1),
            meeting(lasting: 2, outcome: .nothingKept(.tapNeverHeard)),
            meeting(lasting: 3, outcome: .couldNotRecover),
        ])
    }

    /// two hundred meetings is weeks of evidence and a few dozen kilobytes.
    /// the oldest go first.
    func testOnlyTheLastTwoHundredAreKept() throws {
        for seconds in 1...205 {
            try store.append(meeting(lasting: Double(seconds)))
        }

        let kept = try store.all()
        XCTAssertEqual(kept.count, 200)
        XCTAssertEqual(kept.first?.durationS, 6)
        XCTAssertEqual(kept.last?.durationS, 205)
    }

    func testTheNewestFewAreTheTail() throws {
        for seconds in 1...8 {
            try store.append(meeting(lasting: Double(seconds)))
        }

        XCTAssertEqual(try store.recent(3).map(\.durationS), [6, 7, 8])
        XCTAssertEqual(try store.recent(20).count, 8)
    }

    /// no words in it, but it says when you were on a call.
    func testTheFileIsTheOwnersAloneThroughATrim() throws {
        try store.append(meeting(lasting: 1))
        XCTAssertEqual(try permissions(), 0o600)

        for seconds in 2...201 {
            try store.append(meeting(lasting: Double(seconds)))
        }
        XCTAssertEqual(try permissions(), 0o600)
    }

    /// removing your data takes the records with it, and leaves no file.
    func testWipingLeavesNothingOnDisk() throws {
        try store.append(meeting(lasting: 1))

        try store.deleteAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(try store.all(), [])
        // and a wipe of nothing is not an error.
        XCTAssertNoThrow(try store.deleteAll())
    }

    /// a torn last line, or a record from a newer build with an ending this
    /// one does not know, costs only itself.
    func testALineThatWillNotReadCostsOnlyItself() throws {
        try store.append(meeting(lasting: 1))
        let handle = try FileHandle(forWritingTo: store.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"outcome":"teleported","#.utf8) + Data([0x0A]))
        try handle.close()
        try store.append(meeting(lasting: 2))

        XCTAssertEqual(try store.all().map(\.durationS), [1, 2])
    }

    /// every ending comes back from the file as the ending it was.
    func testEveryEndingComesBackAsItself() throws {
        let endings: [MeetingRecord.Outcome] = [
            .saved,
            .nothingKept(.tapNeverHeard),
            .nothingKept(.stoppedBeforeCapture),
            .modelFailed,
            .couldNotWrite,
            .couldNotRecover,
            .setAside,
            .spoolUnreadable,
        ]
        for outcome in endings {
            try store.append(meeting(lasting: 1, outcome: outcome))
        }

        XCTAssertEqual(try store.all().map(\.outcome), endings)
    }

    // MARK: - older and newer records

    /// a record written before a field existed still reads, with the field
    /// as it would be had nothing happened. this one has only what the first
    /// build wrote, and says nothing of the gaps, the talk, the events, the
    /// wait or the decoding.
    func testARecordFromBeforeALaterFieldStillReads() throws {
        let older = #"{"app":"zoom","durationS":3728,"model":"whisperLargeV3Turbo","outcome":"saved","startedAt":"2026-10-02T06:52:31Z"}"#
        try writeLine(older)

        XCTAssertEqual(try store.all(), [
            MeetingRecord(
                outcome: .saved,
                app: "zoom",
                model: "whisperLargeV3Turbo",
                startedAt: Date(timeIntervalSince1970: 1_790_923_951),
                durationS: 3_728
            ),
        ])
    }

    /// the same, one level down: a side, an event or the decoding written
    /// before one of their own fields existed.
    func testANestedPartFromBeforeALaterFieldStillReads() throws {
        let older = #"{"app":"zoom","decoding":{"decodedYou":4},"durationS":60,"events":[{"atS":10,"label":"gap-began"}],"model":"m","outcome":"saved","startedAt":"2026-10-02T06:52:31Z","them":{"turns":2},"you":{"words":9}}"#
        try writeLine(older)

        let record = try XCTUnwrap(try store.all().first)
        XCTAssertEqual(record.you, .init(turns: 0, words: 9))
        XCTAssertEqual(record.them, .init(turns: 2, words: 0))
        XCTAssertEqual(record.decoding, .init(decodedYou: 4))
        XCTAssertEqual(record.events, [.init(.gapBegan, atS: 10)])
    }

    /// and a record from a newer build, with fields and labels this build
    /// has never heard of, reads as far as it goes.
    func testARecordFromANewerBuildStillReads() throws {
        let newer = #"{"app":"zoom","coverage":{"verdict":"thin"},"durationS":60,"events":[{"atS":10,"label":"mic-changed","to":"AirPods"}],"model":"m","outcome":"saved","startedAt":"2026-10-02T06:52:31Z","you":{"turns":1,"words":3,"speechS":41.5}}"#
        try writeLine(newer)

        let record = try XCTUnwrap(try store.all().first)
        XCTAssertEqual(record.outcome, .saved)
        XCTAssertEqual(record.you, .init(turns: 1, words: 3))
        XCTAssertEqual(record.events.map(\.label.rawValue), ["mic-changed"])
        XCTAssertEqual(record.events.map(\.atS), [10])
    }

    /// a newer build's append must not rewrite an older line it cannot read:
    /// the lines are kept as they were written.
    func testALineFromANewerBuildSurvivesAnAppend() throws {
        let newer = #"{"app":"zoom","coverage":{"verdict":"thin"},"durationS":60,"model":"m","outcome":"saved","startedAt":"2026-10-02T06:52:31Z"}"#
        try writeLine(newer)

        try store.append(meeting(lasting: 2))

        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(newer + "\n"), text)
    }

    // MARK: - helpers

    private func writeLine(_ line: String) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data((line + "\n").utf8).write(to: store.fileURL)
    }

    private func permissions() throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: store.fileURL.path
        )
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func meeting(
        lasting seconds: Double,
        outcome: MeetingRecord.Outcome = .saved
    ) -> MeetingRecord {
        MeetingRecord(
            outcome: outcome,
            app: "zoom",
            model: "whisperLargeV3Turbo",
            startedAt: Date(timeIntervalSince1970: 1_790_923_951),
            durationS: seconds,
            gaps: 1,
            gapsLostS: 2.5,
            you: .init(turns: 2, words: 5),
            them: .init(turns: 2, words: 3),
            toDiskS: 4.2,
            recovered: false,
            events: [.init(.gapBegan, atS: 10), .init(.gapEnded, atS: 12.5)],
            decoding: .init(decodedYou: 2, decodedThem: 2, failed: 0, mostBehindS: 1.5, lastBehindS: 0.5)
        )
    }
}
