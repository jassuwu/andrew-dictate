struct FrameCopyRegion: Equatable, Sendable {
    let sourceOffset: Int
    let destinationOffset: Int
    let frameCount: Int

    static let empty = FrameCopyRegion(
        sourceOffset: 0,
        destinationOffset: 0,
        frameCount: 0
    )
}

struct RingWritePlan: Equatable, Sendable {
    let first: FrameCopyRegion
    let second: FrameCopyRegion
}

struct RingReadPlan: Equatable, Sendable {
    let first: FrameCopyRegion
    let second: FrameCopyRegion
    let frameCount: Int
}

struct RingSplicer: Sendable {
    let capacity: Int

    private(set) var storedFrameCount = 0
    private(set) var writeOffset = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    mutating func planWrite(frameCount: Int) -> RingWritePlan {
        precondition(frameCount >= 0)

        guard frameCount > 0 else {
            return RingWritePlan(first: .empty, second: .empty)
        }

        if frameCount >= capacity {
            storedFrameCount = capacity
            writeOffset = 0
            return RingWritePlan(
                first: FrameCopyRegion(
                    sourceOffset: frameCount - capacity,
                    destinationOffset: 0,
                    frameCount: capacity
                ),
                second: .empty
            )
        }

        let firstFrameCount = min(frameCount, capacity - writeOffset)
        let secondFrameCount = frameCount - firstFrameCount
        let plan = RingWritePlan(
            first: FrameCopyRegion(
                sourceOffset: 0,
                destinationOffset: writeOffset,
                frameCount: firstFrameCount
            ),
            second: FrameCopyRegion(
                sourceOffset: firstFrameCount,
                destinationOffset: 0,
                frameCount: secondFrameCount
            )
        )

        writeOffset = (writeOffset + frameCount) % capacity
        storedFrameCount = min(capacity, storedFrameCount + frameCount)
        return plan
    }

    func planRead() -> RingReadPlan {
        guard storedFrameCount > 0 else {
            return RingReadPlan(
                first: .empty,
                second: .empty,
                frameCount: 0
            )
        }

        let oldestFrameOffset = storedFrameCount == capacity
            ? writeOffset
            : 0
        let firstFrameCount = min(
            storedFrameCount,
            capacity - oldestFrameOffset
        )
        let secondFrameCount = storedFrameCount - firstFrameCount

        return RingReadPlan(
            first: FrameCopyRegion(
                sourceOffset: oldestFrameOffset,
                destinationOffset: 0,
                frameCount: firstFrameCount
            ),
            second: FrameCopyRegion(
                sourceOffset: 0,
                destinationOffset: firstFrameCount,
                frameCount: secondFrameCount
            ),
            frameCount: storedFrameCount
        )
    }

    mutating func reset() {
        storedFrameCount = 0
        writeOffset = 0
    }
}
