import Foundation

/// A run of one side's speech, cut out of the meeting to be decoded once.
struct Stretch: Sendable {
    enum Side: Sendable {
        case you
        case them
    }

    let side: Side
    let samples: [Float]
    /// Meeting time of the first sample.
    let at: Duration
    /// Meeting time just past the last sample.
    let end: Duration
}

/// One side of a meeting, cut into stretches as it arrives.
///
/// The detector says where speech begins and ends; this holds the audio
/// those edges point into and hands back each stretch once it has ended. It
/// keeps nothing that has gone into a stretch, and only a couple of seconds
/// of the quiet between them, so what it holds does not grow with the
/// meeting.
struct StretchCutter {
    let side: Stretch.Side

    /// Audio not yet in a stretch. `held[0]` is sample `heldFrom` of this side.
    private var held: [Float] = []
    private var heldFrom = 0
    /// The sample the latest chunk's stamp was taken at, and that stamp.
    /// Everything held is timed from here.
    private var origin: (sample: Int, at: Duration)?
    /// Where the stretch being spoken now begins.
    private var openFrom: Int?

    /// Speech is cut from a little before the detector heard it begin, so
    /// the first word keeps its first consonant.
    static let preRoll = samples(in: .milliseconds(300))
    /// Quiet kept while nobody is speaking: the pre-roll, and room for a
    /// detector that says speech began a little after it did.
    static let keptWhileQuiet = samples(in: .seconds(2))

    init(side: Stretch.Side) {
        self.side = side
    }

    /// Samples of this side heard so far.
    var heard: Int {
        heldFrom + held.count
    }

    /// The next chunk of this side, stamped on the meeting's clock, and the
    /// edges its detector found once it had heard it. Returns the stretches
    /// that ended.
    mutating func take(_ samples: [Float], at: Duration, edges: [SpeechEdge]) -> [Stretch] {
        if origin == nil {
            origin = (heard, at)
        }
        held.append(contentsOf: samples)

        var done: [Stretch] = []
        for edge in edges {
            switch edge {
            case .began(let start):
                guard openFrom == nil else { continue }
                openFrom = max(heldFrom, min(start, heard) - Self.preRoll)
            case .ended(let end):
                guard let from = openFrom else { continue }
                openFrom = nil
                let end = min(end, heard)
                if end > from {
                    done.append(cut(from, end))
                }
            }
        }

        if let openFrom {
            drop(before: openFrom)
        } else {
            drop(before: heard - Self.keptWhileQuiet)
        }
        return done
    }

    /// The meeting is over: whatever is being said now ends here.
    mutating func flush() -> [Stretch] {
        guard let from = openFrom else { return [] }
        openFrom = nil
        let end = heard
        return end > from ? [cut(from, end)] : []
    }

    // MARK: -

    private mutating func cut(_ from: Int, _ end: Int) -> Stretch {
        let stretch = Stretch(
            side: side,
            samples: Array(held[(from - heldFrom)..<(end - heldFrom)]),
            at: time(of: from),
            end: time(of: end))
        drop(before: end)
        return stretch
    }

    private mutating func drop(before sample: Int) {
        let count = min(held.count, sample - heldFrom)
        guard count > 0 else { return }
        held.removeFirst(count)
        heldFrom += count
    }

    private func time(of sample: Int) -> Duration {
        guard let origin else { return .zero }
        return origin.at + Self.duration(of: sample - origin.sample)
    }

    /// Exact: a sample at 16 kHz is 62 500 ns, so sample counts and the
    /// stamps made from them compare equal instead of nearly.
    static func duration(of samples: Int) -> Duration {
        .nanoseconds(Int64(samples) * 1_000_000_000 / Int64(MeetingAudioChunk.sampleRate))
    }

    static func samples(in duration: Duration) -> Int {
        Int((duration.totalSeconds * MeetingAudioChunk.sampleRate).rounded())
    }
}
