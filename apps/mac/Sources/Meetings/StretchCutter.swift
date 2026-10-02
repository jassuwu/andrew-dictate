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
    /// The longest stretch the engine is handed, in samples. Whisper reads
    /// 30 s at a time and parakeet about 15; past that a model either drops
    /// words or has to be fed in windows of its own.
    let ceiling: Int

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
    /// Stamps are sample counts, so a chunk that follows on is off by
    /// rounding at most; the capture layer only moves the clock on for an
    /// outage of a second or more.
    static let gapTolerance = Duration.milliseconds(10)
    /// Talk cut at the ceiling is cut in the quietest of these, looking back
    /// this far from it.
    static let quietFrame = samples(in: .milliseconds(50))
    static let quietLookBack = samples(in: .seconds(4))

    init(side: Stretch.Side, ceiling: Duration) {
        precondition(ceiling > .zero, "a stretch must be allowed some length")
        self.side = side
        self.ceiling = max(1, Self.samples(in: ceiling))
    }

    /// Samples of this side heard so far.
    var heard: Int {
        heldFrom + held.count
    }

    /// The next chunk of this side, stamped on the meeting's clock, and the
    /// edges its detector found once it had heard it. Returns the stretches
    /// that ended.
    mutating func take(_ samples: [Float], at: Duration, edges: [SpeechEdge]) -> [Stretch] {
        var done: [Stretch] = []
        // A stamp ahead of where the last chunk ended is a gap: the tap was
        // gone and the capture layer moved the clock on over it. What was
        // being said is closed where the audio stopped, nothing from before
        // is pre-roll for what comes after, and the clock starts again here.
        // Speech the detector still hears goes on in a new stretch.
        if origin != nil, at - time(of: heard) > Self.gapTolerance {
            if let from = openFrom {
                if heard > from { done.append(cut(from, heard)) }
                openFrom = heard
            }
            drop(before: heard)
            origin = nil
        }
        if origin == nil {
            origin = (heard, at)
        }
        held.append(contentsOf: samples)

        for edge in edges {
            switch edge {
            case .began(let start):
                guard openFrom == nil else { continue }
                openFrom = max(heldFrom, min(start, heard) - Self.preRoll)
            case .ended(let end):
                guard openFrom != nil else { continue }
                let end = min(end, heard)
                done += cutAtTheCeiling(before: end)
                if let from = openFrom, end > from {
                    done.append(cut(from, end))
                }
                openFrom = nil
            }
        }
        done += cutAtTheCeiling(before: heard)

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

    /// Talk that runs past the ceiling is cut at a quiet moment shortly
    /// before it, and carries on in a new stretch from the very next sample:
    /// no pre-roll, nothing between.
    private mutating func cutAtTheCeiling(before limit: Int) -> [Stretch] {
        var done: [Stretch] = []
        while let from = openFrom, from + ceiling <= limit {
            let end = quietestCut(from: from)
            done.append(cut(from, end))
            openFrom = end
        }
        return done
    }

    /// Where to cut talk that began at `from` and has reached the ceiling.
    /// Cut at the ceiling itself, a word is split between two stretches and
    /// neither half decodes; a breath or the gap between two words a little
    /// earlier splits nothing. So: the middle of the quietest 50 ms in the
    /// last four seconds, the later one on a tie, as long as it has under
    /// half the energy of the 50 ms at the ceiling. Talk as loud all the way
    /// is cut at the ceiling, where it always was.
    ///
    /// The look back stops at half the ceiling, so a short ceiling never
    /// finds its quiet in the pre-roll at the start of the stretch.
    private func quietestCut(from: Int) -> Int {
        let ceilingAt = from + ceiling
        let frame = Self.quietFrame
        let earliest = max(from, ceilingAt - min(Self.quietLookBack, ceiling / 2))
        guard ceilingAt - frame >= earliest else { return ceilingAt }

        let atCeiling = energy(ceilingAt - frame, ceilingAt)
        var quietest = (energy: atCeiling, cut: ceilingAt)
        var start = ceilingAt - 2 * frame
        while start >= earliest {
            let energy = energy(start, start + frame)
            if energy < quietest.energy {
                quietest = (energy, start + frame / 2)
            }
            start -= frame
        }
        return quietest.energy < atCeiling / 2 ? quietest.cut : ceilingAt
    }

    /// Sum of squares of the held samples from `from` up to `end`.
    private func energy(_ from: Int, _ end: Int) -> Float {
        var sum: Float = 0
        for sample in held[(from - heldFrom)..<(end - heldFrom)] {
            sum += sample * sample
        }
        return sum
    }

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
