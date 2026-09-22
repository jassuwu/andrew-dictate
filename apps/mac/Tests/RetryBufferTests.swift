import XCTest

final class RetryBufferTests: XCTestCase {
    private let armed = Date(timeIntervalSince1970: 1_000)

    func testAnArmedBufferHandsTheSamplesBack() {
        var buffer = RetryBuffer()
        buffer.arm(samples: [0.1, 0.2, 0.3], at: armed)

        XCTAssertTrue(buffer.isArmed)
        XCTAssertEqual(
            buffer.take(at: armed.addingTimeInterval(4)),
            [0.1, 0.2, 0.3]
        )
    }

    func testTakingItDisarms() {
        var buffer = RetryBuffer()
        buffer.arm(samples: [0.1], at: armed)
        _ = buffer.take(at: armed)

        XCTAssertFalse(buffer.isArmed)
        XCTAssertNil(buffer.take(at: armed))
    }

    /// two minutes and the lost sentence is somebody else's sentence.
    func testItExpires() {
        var buffer = RetryBuffer()
        buffer.arm(samples: [0.1], at: armed)

        XCTAssertNil(
            buffer.take(
                at: armed.addingTimeInterval(RetryBuffer.lifetime + 1)
            )
        )
    }

    func testJustInsideTheLifetimeStillRetries() {
        var buffer = RetryBuffer()
        buffer.arm(samples: [0.1], at: armed)

        XCTAssertEqual(
            buffer.take(
                at: armed.addingTimeInterval(RetryBuffer.lifetime - 0.5)
            ),
            [0.1]
        )
    }

    /// the next take clears it: whatever you are saying now is the sentence
    /// you care about.
    func testClearingForgetsIt() {
        var buffer = RetryBuffer()
        buffer.arm(samples: [0.1], at: armed)
        buffer.clear()

        XCTAssertFalse(buffer.isArmed)
        XCTAssertNil(buffer.take(at: armed))
    }
}
