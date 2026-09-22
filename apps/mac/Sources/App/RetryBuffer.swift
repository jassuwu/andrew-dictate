import Foundation

/// the samples of a dictation the speech model threw on, kept only for as
/// long as "say the whole thing again" is still the wrong answer.
///
/// memory only, and deliberately: nothing is written down, the next take
/// clears it, two minutes clears it, and the process exiting clears it — so
/// this keeps no audio in the sense SPEC §6 means.
struct RetryBuffer {
    static let lifetime: TimeInterval = 120

    private var samples: [Float]?
    private var armedAt: Date?

    var isArmed: Bool {
        samples != nil
    }

    mutating func arm(samples: [Float], at instant: Date) {
        self.samples = samples
        armedAt = instant
    }

    /// takes the samples and disarms, whether or not they were still good:
    /// a second attempt at the same lost sentence is the user's call once.
    mutating func take(at instant: Date) -> [Float]? {
        let samples = samples
        let armedAt = armedAt
        clear()
        guard let samples,
              let armedAt,
              instant.timeIntervalSince(armedAt) < Self.lifetime else {
            return nil
        }
        return samples
    }

    mutating func clear() {
        samples = nil
        armedAt = nil
    }
}
