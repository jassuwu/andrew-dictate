import XCTest

/// The spool read a block at a time: what reads a whole meeting without
/// holding one in memory — the far side's loudness for the coverage check.
final class SpoolBlocksTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spool-blocks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Three seconds of them talking, two of nothing, half a second of a hum
    /// just over the floor, and the mic loud throughout: three and a half
    /// seconds of the far side were heard.
    func testTheFarSideIsLoudForTheTimeItWasOverTheFloor() async throws {
        let url = dir.appendingPathComponent("audio.caf")
        let file = try SpoolAudioFile(url: url)
        for s in 0..<3 {
            try await file.append(chunk(at: s, them: { sin(Float($0) * 0.05) * 0.3 }))
        }
        for s in 3..<5 {
            try await file.append(chunk(at: s, them: { _ in 0 }))
        }
        try await file.append(chunk(at: 5, them: { $0 < 8_000 ? 0.002 : 0.0005 }))

        let loud = try SpoolAudioFile.farSideLoud(in: url, above: 0.001)

        XCTAssertEqual(loud, .milliseconds(3_500))
    }

    /// Both sides come back in order, in blocks no longer than asked for,
    /// and all of them.
    func testTheBlocksAreTheWholeSpoolInOrder() async throws {
        let url = dir.appendingPathComponent("audio.caf")
        let file = try SpoolAudioFile(url: url)
        try await file.append(MeetingAudioChunk(
            you: (0..<2_500).map { Float($0) / 10_000 },
            them: (0..<2_500).map { -Float($0) / 10_000 },
            at: .zero))

        var sizes: [Int] = []
        var you: [Float] = []
        var them: [Float] = []
        try SpoolAudioFile.readBlocks(url, frames: 1_000) { y, t in
            sizes.append(y.count)
            you += y
            them += t
        }

        XCTAssertEqual(sizes, [1_000, 1_000, 500])
        XCTAssertEqual(you, (0..<2_500).map { Float($0) / 10_000 })
        XCTAssertEqual(them, (0..<2_500).map { -Float($0) / 10_000 })
    }

    private func chunk(at second: Int, them: (Int) -> Float) -> MeetingAudioChunk {
        MeetingAudioChunk(
            you: Array(repeating: 0.05, count: 16_000),
            them: (0..<16_000).map(them),
            at: .seconds(second))
    }
}
