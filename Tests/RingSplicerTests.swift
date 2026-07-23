import XCTest

final class RingSplicerTests: XCTestCase {
    func testPartialRingReadsAllStoredFramesInOrder() {
        var splicer = RingSplicer(capacity: 5)
        var ring = Array(repeating: 0, count: 5)

        apply(
            splicer.planWrite(frameCount: 3),
            source: [1, 2, 3],
            destination: &ring
        )

        XCTAssertEqual(read(splicer.planRead(), from: ring), [1, 2, 3])
        XCTAssertEqual(splicer.storedFrameCount, 3)
        XCTAssertEqual(splicer.writeOffset, 3)
    }

    func testWrappedRingSplicesOldestToNewest() {
        var splicer = RingSplicer(capacity: 5)
        var ring = Array(repeating: 0, count: 5)

        apply(
            splicer.planWrite(frameCount: 3),
            source: [1, 2, 3],
            destination: &ring
        )
        apply(
            splicer.planWrite(frameCount: 4),
            source: [4, 5, 6, 7],
            destination: &ring
        )

        XCTAssertEqual(
            read(splicer.planRead(), from: ring),
            [3, 4, 5, 6, 7]
        )
        XCTAssertEqual(splicer.storedFrameCount, 5)
        XCTAssertEqual(splicer.writeOffset, 2)
    }

    func testOversizedWriteKeepsOnlyNewestFrames() {
        var splicer = RingSplicer(capacity: 4)
        var ring = Array(repeating: 0, count: 4)

        apply(
            splicer.planWrite(frameCount: 6),
            source: [1, 2, 3, 4, 5, 6],
            destination: &ring
        )

        XCTAssertEqual(read(splicer.planRead(), from: ring), [3, 4, 5, 6])
        XCTAssertEqual(splicer.writeOffset, 0)
    }

    func testResetDiscardsBufferedFrames() {
        var splicer = RingSplicer(capacity: 4)
        _ = splicer.planWrite(frameCount: 3)

        splicer.reset()

        XCTAssertEqual(splicer.planRead().frameCount, 0)
        XCTAssertEqual(splicer.storedFrameCount, 0)
        XCTAssertEqual(splicer.writeOffset, 0)
    }

    private func apply(
        _ plan: RingWritePlan,
        source: [Int],
        destination: inout [Int]
    ) {
        apply(plan.first, source: source, destination: &destination)
        apply(plan.second, source: source, destination: &destination)
    }

    private func apply(
        _ region: FrameCopyRegion,
        source: [Int],
        destination: inout [Int]
    ) {
        for offset in 0..<region.frameCount {
            destination[region.destinationOffset + offset] =
                source[region.sourceOffset + offset]
        }
    }

    private func read(
        _ plan: RingReadPlan,
        from source: [Int]
    ) -> [Int] {
        var result = Array(repeating: 0, count: plan.frameCount)
        copy(plan.first, source: source, destination: &result)
        copy(plan.second, source: source, destination: &result)
        return result
    }

    private func copy(
        _ region: FrameCopyRegion,
        source: [Int],
        destination: inout [Int]
    ) {
        for offset in 0..<region.frameCount {
            destination[region.destinationOffset + offset] =
                source[region.sourceOffset + offset]
        }
    }
}
