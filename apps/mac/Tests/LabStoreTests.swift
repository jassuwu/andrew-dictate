import Foundation
import XCTest

final class LabStoreTests: XCTestCase {
    func testJSONLRoundTrip() throws {
        let entries = [
            makeEntry(1),
            makeEntry(2),
        ]

        let data = try LabStore.encodeJSONL(entries)

        XCTAssertEqual(LabStore.decodeJSONL(data), entries)
    }

    func testDecodeSkipsCorruptLines() throws {
        let valid = makeEntry(1)
        var data = try LabStore.encodeJSONL([valid])
        data.append(Data("\nnot-json\n".utf8))

        XCTAssertEqual(LabStore.decodeJSONL(data), [valid])
    }

    func testPureCapKeepsNewestEntriesInFIFOOrder() {
        let entries = (1...5).map(makeEntry)

        XCTAssertEqual(
            LabStore.capped(entries, capacity: 3),
            Array(entries.suffix(3))
        )
    }

    func testAppendRewritesAtCapacityAndClearRemovesData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AndrewDictate-LabStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("lab.jsonl")
        let store = LabStore(fileURL: fileURL, capacity: 3)

        for index in 1...5 {
            try await store.append(makeEntry(index))
        }

        let cappedEntries = try await store.load()
        XCTAssertEqual(cappedEntries, (3...5).map(makeEntry))
        let persisted = try Data(contentsOf: fileURL)
        XCTAssertEqual(persisted.split(separator: 0x0A).count, 3)

        try await store.clear()
        let clearedEntries = try await store.load()
        XCTAssertEqual(clearedEntries, [])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path)
        )
    }

    private func makeEntry(_ index: Int) -> CleanupLabEntry {
        CleanupLabEntry(
            ts: Date(timeIntervalSince1970: TimeInterval(index)),
            backend: "mock",
            latencyMs: Double(index),
            raw: "raw \(index)",
            cleaned: "cleaned \(index)"
        )
    }
}
