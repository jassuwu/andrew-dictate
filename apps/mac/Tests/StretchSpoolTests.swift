import XCTest

/// A spool read back by the stretch transcriber a block at a time, as it
/// comes off the disk, rather than both sides whole: an hour of a meeting
/// is about 460 mb of them, and reading it again held all of it.
///
/// Speech is a tone and silence is zeros. The engine says what it was
/// handed — how many samples, how loud — so a spool cut anywhere other than
/// where the whole one was comes back as other words.
final class StretchSpoolTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stretch-spool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// However the spool comes off the disk — a second at a time, a few
    /// hundredths, or blocks of no size in particular — it is heard in the
    /// 100 ms steps the meeting was, and comes to the same turns as the two
    /// sides handed over whole.
    func testASpoolInBlocksComesToTheSameTurnsAsBothSidesWhole() async throws {
        let (you, them) = sides(of: Self.said, seconds: 12)
        let whole = try await stretches().transcribe(you: you, them: them)
        XCTAssertEqual(whole.count, 4, "\(whole)")

        for sizes in [[16_000], [1_000], [2_500, 700, 16_000, 1_601, 3]] {
            let turns = try await stretches().transcribe(blocks: blocks(you, them, sizes: sizes))
            XCTAssertEqual(turns, whole, "blocks of \(sizes)")
        }
    }

    /// A spool with one channel has your side and no far side at all.
    func testASpoolWithNoFarSideInBlocksComesToTheSameTurns() async throws {
        let (you, _) = sides(of: Self.said, seconds: 12)
        let whole = try await stretches().transcribe(you: you, them: [])
        XCTAssertEqual(whole.count, 2, "\(whole)")

        let turns = try await stretches().transcribe(blocks: blocks(you, [], sizes: [2_500, 700]))
        XCTAssertEqual(turns, whole)
    }

    /// Off the disk: the spool as the meeting wrote it, read in blocks, is
    /// the spool read whole.
    func testASpoolOnDiskReadInBlocksComesToTheSameTurnsAsReadWhole() async throws {
        let url = dir.appendingPathComponent("audio.caf")
        let file = try SpoolAudioFile(url: url)
        let (you, them) = sides(of: Self.said, seconds: 12)
        for start in stride(from: 0, to: you.count, by: 1_600) {
            try await file.append(MeetingAudioChunk(
                you: Array(you[start..<(start + 1_600)]),
                them: Array(them[start..<(start + 1_600)]),
                at: StretchCutter.duration(of: start)))
        }

        let read = try SpoolAudioFile.read(url)
        let whole = try await stretches().transcribe(you: read.you, them: read.them)
        let turns = try await stretches().transcribe(blocks: SpoolAudioFile.blocks(url, frames: 4_000))

        XCTAssertEqual(turns, whole)
        XCTAssertEqual(whole.count, 4)
    }

    /// Each stretch is decoded once it is cut, and the next block is read
    /// after: the first is decoded long before the spool's last block has
    /// come off the disk, so no more of it is held than the meeting held.
    func testASpoolInBlocksIsDecodedAsItIsRead() async throws {
        let (you, them) = sides(of: Self.said, seconds: 12)
        let read = Counter()
        let engine = SizeEngine()
        engine.onFirstDecode = { read.value }

        _ = try await stretches(engine).transcribe(
            blocks: blocks(you, them, sizes: [1_600], counting: read))

        XCTAssertEqual(read.value, 120)
        // "the deploy is blocked" ends at 2.5 s and is cut once the half
        // second of quiet after it has been heard: thirty-odd blocks in.
        let atFirst = try XCTUnwrap(engine.blocksReadAtFirstDecode)
        XCTAssertLessThan(atFirst, 40)
    }

    // MARK: - building a spool

    /// Two phrases each side, the far side's second over the end of yours.
    private static let said: [Said] = [
        .init(side: .you, from: 1.3, to: 2.5, loudness: 0.3),
        .init(side: .them, from: 3.3, to: 4.0, loudness: 0.2),
        .init(side: .you, from: 5.3, to: 7.0, loudness: 0.4),
        .init(side: .them, from: 6.5, to: 9.1, loudness: 0.1),
    ]

    private struct Said {
        let side: Stretch.Side
        let from: Double
        let to: Double
        let loudness: Float
    }

    private func stretches(_ engine: SizeEngine = SizeEngine()) -> StretchTranscriber {
        StretchTranscriber(
            engine: engine,
            ceiling: .seconds(25),
            detector: { LoudnessDetector(threshold: 0.02, hangover: .milliseconds(500)) })
    }

    private func sides(of said: [Said], seconds: Int) -> ([Float], [Float]) {
        let n = seconds * 16_000
        var you = [Float](repeating: 0, count: n)
        var them = [Float](repeating: 0, count: n)
        for line in said {
            for i in Int((line.from * 16_000).rounded())..<Int((line.to * 16_000).rounded()) {
                let sample = sin(Float(i) * 0.05) * line.loudness
                switch line.side {
                case .you: you[i] += sample
                case .them: them[i] += sample
                }
            }
        }
        return (you, them)
    }

    /// The two sides cut into blocks of `sizes`, round and round, each
    /// handed over only when it is asked for, and counted as it is.
    private func blocks(
        _ you: [Float], _ them: [Float], sizes: [Int], counting read: Counter = Counter()
    ) -> AsyncThrowingStream<SpoolBlock, any Error> {
        let next = Counter()
        return AsyncThrowingStream(unfolding: {
            let (start, size) = next.take(sizes)
            guard start < max(you.count, them.count) else { return nil }
            read.value += 1
            func slice(_ side: [Float]) -> [Float] {
                start < side.count ? Array(side[start..<min(start + size, side.count)]) : []
            }
            return (slice(you), slice(them))
        })
    }
}

// MARK: - fakes

/// A number shared with the stream's closure; the stream asks for one block
/// at a time.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var position = 0
    private var turn = 0

    var value: Int {
        get { lock.withLock { count } }
        set { lock.withLock { count = newValue } }
    }

    /// Where the next block starts, and how long it is.
    func take(_ sizes: [Int]) -> (start: Int, size: Int) {
        lock.withLock {
            let size = sizes[turn % sizes.count]
            defer {
                position += size
                turn += 1
            }
            return (position, size)
        }
    }
}

/// Says what it was handed: how many samples, and how loud at the loudest.
private final class SizeEngine: StretchEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var first: Int?
    var onFirstDecode: (@Sendable () -> Int)?

    var blocksReadAtFirstDecode: Int? {
        lock.withLock { first }
    }

    func load() async throws {}

    func text(of samples: [Float]) async throws -> String {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        lock.withLock {
            if first == nil { first = onFirstDecode?() }
        }
        return "\(samples.count) samples at \(String(format: "%.2f", peak))"
    }
}
