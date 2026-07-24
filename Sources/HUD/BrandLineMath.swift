struct BrandLineLevelRing: Equatable, Sendable {
    let capacity: Int
    let smoothingFactor: Float

    private var samples: [Float] = []
    private var nextWriteIndex = 0

    init(
        capacity: Int = 12,
        smoothingFactor: Float = 0.32
    ) {
        self.capacity = max(1, capacity)
        self.smoothingFactor = min(max(smoothingFactor, 0), 1)
        samples.reserveCapacity(self.capacity)
    }

    var count: Int {
        samples.count
    }

    var latestLevel: Float {
        level(delayedBy: 0)
    }

    mutating func push(_ level: Float) {
        let boundedLevel = min(max(level, 0), 1)
        let smoothedLevel: Float

        if samples.isEmpty {
            smoothedLevel = boundedLevel
        } else {
            smoothedLevel = latestLevel
                + smoothingFactor * (boundedLevel - latestLevel)
        }

        if samples.count < capacity {
            samples.append(smoothedLevel)
            nextWriteIndex = samples.count % capacity
        } else {
            samples[nextWriteIndex] = smoothedLevel
            nextWriteIndex = (nextWriteIndex + 1) % capacity
        }
    }

    func level(delayedBy frameCount: Int) -> Float {
        guard !samples.isEmpty else {
            return 0
        }

        let boundedDelay = min(max(frameCount, 0), samples.count - 1)
        let index = (
            nextWriteIndex - 1 - boundedDelay + capacity
        ) % capacity
        return samples[index]
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        nextWriteIndex = 0
    }
}

enum BrandLineJointMapper {
    private static let directions: [Float] = [
        -1,
        0.7,
        -0.9,
        0.65,
        -0.8,
    ]

    static func delayedLevels(
        in ring: BrandLineLevelRing,
        jointCount: Int
    ) -> [Float] {
        guard jointCount > 0 else {
            return []
        }

        return (0..<jointCount).map {
            ring.level(delayedBy: $0)
        }
    }

    static func verticalOffsets(
        in ring: BrandLineLevelRing,
        jointCount: Int,
        maximumAmplitude: Float
    ) -> [Float] {
        let amplitude = abs(maximumAmplitude)

        return delayedLevels(in: ring, jointCount: jointCount)
            .enumerated()
            .map { index, level in
                level * amplitude * directions[index % directions.count]
            }
    }
}
