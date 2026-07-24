import XCTest

final class BrandLineMathTests: XCTestCase {
    func testEmptyRingReadsAsSilence() {
        let ring = BrandLineLevelRing()

        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.latestLevel, 0)
        XCTAssertEqual(ring.level(delayedBy: 20), 0)
    }

    func testRingKeepsNewestSamplesInDelayOrder() {
        var ring = BrandLineLevelRing(
            capacity: 3,
            smoothingFactor: 1
        )

        for level: Float in [0.1, 0.2, 0.3, 0.4] {
            ring.push(level)
        }

        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring.level(delayedBy: 0), 0.4)
        XCTAssertEqual(ring.level(delayedBy: 1), 0.3)
        XCTAssertEqual(ring.level(delayedBy: 2), 0.2)
        XCTAssertEqual(ring.level(delayedBy: 99), 0.2)
    }

    func testRingSmoothsAndClampsLevels() {
        var ring = BrandLineLevelRing(
            capacity: 4,
            smoothingFactor: 0.5
        )

        ring.push(2)
        ring.push(-1)

        XCTAssertEqual(ring.level(delayedBy: 1), 1)
        XCTAssertEqual(ring.latestLevel, 0.5)
    }

    func testResetReturnsRingToSilence() {
        var ring = BrandLineLevelRing()
        ring.push(0.8)

        ring.reset()

        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.latestLevel, 0)
    }

    func testJointMappingUsesOneFrameOfDelayPerJoint() {
        var ring = BrandLineLevelRing(
            capacity: 5,
            smoothingFactor: 1
        )
        for level: Float in [0.2, 0.4, 0.6, 0.8, 0.1] {
            ring.push(level)
        }

        let delayedLevels = BrandLineJointMapper.delayedLevels(
            in: ring,
            jointCount: 5
        )
        let offsets = BrandLineJointMapper.verticalOffsets(
            in: ring,
            jointCount: 5,
            maximumAmplitude: 10
        )

        assertEqual(
            delayedLevels,
            [0.1, 0.8, 0.6, 0.4, 0.2]
        )
        assertEqual(
            offsets,
            [-1, 5.6, -5.4, 2.6, -1.6]
        )
    }

    private func assertEqual(
        _ values: [Float],
        _ expected: [Float],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(values.count, expected.count, file: file, line: line)

        for (value, expectedValue) in zip(values, expected) {
            XCTAssertEqual(
                value,
                expectedValue,
                accuracy: 0.0001,
                file: file,
                line: line
            )
        }
    }
}
