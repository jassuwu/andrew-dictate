import Foundation

/// How loud one side of a meeting was, 50 ms at a time: the RMS of each
/// frame, for the last minute and no longer, so what it holds does not grow
/// with the meeting.
///
/// Frames are counted on the meeting's clock — frame n is samples n × 800 up
/// to the next — so two sides fed the same chunks hold the same instants
/// under the same numbers.
struct LoudnessTrail: Sendable {
    /// 50 ms: long enough to be a measure of loudness, short enough that the
    /// delay of sound crossing a room is a few of them.
    static let frame = StretchCutter.samples(in: .milliseconds(50))
    /// A minute of frames. A stretch is at most 25 s, and is judged the
    /// moment it is cut.
    static let kept = 1_200

    /// RMS of every whole frame held; `held[0]` is frame `firstFrame`.
    private var held: [Float] = []
    private var firstFrame = 0
    /// The frame being filled: its sum of squares and how many samples have
    /// gone into it.
    private var energy: Float = 0
    private var counted = 0
    /// The sample the next one lands at on the meeting's clock.
    private var next: Int?

    /// The next chunk of this side, stamped on the meeting's clock.
    mutating func hear(_ samples: [Float], at: Duration) {
        guard !samples.isEmpty else { return }
        var position = StretchCutter.samples(in: at)
        if let next {
            if abs(position - next) <= StretchCutter.samples(in: StretchCutter.gapTolerance) {
                position = next
            } else {
                // The clock moved on over a gap, or went back. What was held
                // is not the moment before this one: forget it, rather than
                // have a stretch compare across the hole.
                held = []
                energy = 0
                counted = 0
            }
        }
        if held.isEmpty, counted == 0 {
            firstFrame = position / Self.frame
        }
        for sample in samples {
            energy += sample * sample
            counted += 1
            position += 1
            if position % Self.frame == 0 {
                close()
            }
        }
        next = position
    }

    /// The loudness of frames `range`, or nil unless every one of them is
    /// still held — and has been heard whole.
    func frames(in range: Range<Int>) -> [Float]? {
        guard range.lowerBound >= firstFrame, range.upperBound <= firstFrame + held.count else {
            return nil
        }
        return Array(held[(range.lowerBound - firstFrame)..<(range.upperBound - firstFrame)])
    }

    private mutating func close() {
        held.append((energy / Float(counted)).squareRoot())
        energy = 0
        counted = 0
        if held.count > Self.kept {
            let extra = held.count - Self.kept
            held.removeFirst(extra)
            firstFrame += extra
        }
    }
}

/// Whether a stretch of the mic is only the far side coming back through it.
///
/// On the mac's own speakers what the far side says leaves them, crosses the
/// room, and comes in through the mic a little late and quieter. Decoded with
/// the two sides apart it is said twice, once as them, which is right, and
/// once as you, which is not. There is no echo canceller here. This is a
/// decision about a whole stretch, made from how loud each side was from one
/// moment to the next: if the mic's loudness rises and falls as the far
/// side's did, a moment before, it is theirs.
///
/// When it is not clear, the stretch is kept. Two lines of the same words are
/// a nuisance; a line that is gone is a loss.
enum BleedJudge {
    enum Verdict: Equatable, Sendable {
        case keep
        case drop
    }

    // These numbers are provisional: worked out from how speech and rooms
    // behave, and tried on synthetic speech. They want a real call or two on
    // the mac's own speakers before anyone trusts them.

    /// Quieter than this, a side is not talking: the room, not a voice.
    static let quiet: Float = 0.01
    /// The share of a stretch's frames the far side must have been talking
    /// in, to have been talking through it.
    static let talkingShare = 0.7
    /// How far behind the far side the mic may run: the speakers, the air,
    /// the input buffer.
    static let reach = Duration.milliseconds(300)
    /// How closely the mic's loudness must follow the far side's, at the
    /// best delay, for the stretch to be theirs. -1 to 1.
    static let agreement = 0.6

    /// `from` and `to` are the stretch's span on the meeting's clock, and
    /// `mic` and `far` how loud each side was over it.
    static func verdict(
        mic: LoudnessTrail, far: LoudnessTrail, from: Duration, to: Duration
    ) -> Verdict {
        let frame = LoudnessTrail.frame
        let lead = StretchCutter.samples(in: reach) / frame
        // Whole frames inside the span: the ones either end splits are
        // measuring something else too.
        let first = (StretchCutter.samples(in: from) + frame - 1) / frame
        let end = StretchCutter.samples(in: to) / frame
        guard end > first,
              let heard = mic.frames(in: first..<end),
              let played = far.frames(in: (first - lead)..<end)
        else {
            return .keep
        }
        // played[lead + i] is the far side when heard[i] was the mic; the
        // `lead` before it are what the mic may be hearing late.
        let talking = played.suffix(heard.count).filter { $0 > quiet }.count
        guard Double(talking) >= talkingShare * Double(heard.count) else { return .keep }
        let best = (0...lead).map { delay in
            correlation(heard[...], played[(lead - delay)..<(lead - delay + heard.count)])
        }.max() ?? 0
        return best >= agreement ? .drop : .keep
    }

    /// Pearson's: how closely `a` rises and falls with `b`, -1 to 1, and 0
    /// where one of them is the same loudness throughout.
    private static func correlation(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Double {
        let n = Double(a.count)
        let meanA = a.reduce(0) { $0 + Double($1) } / n
        let meanB = b.reduce(0) { $0 + Double($1) } / n
        var together = 0.0
        var spreadA = 0.0
        var spreadB = 0.0
        for (x, y) in zip(a, b) {
            let dx = Double(x) - meanA
            let dy = Double(y) - meanB
            together += dx * dy
            spreadA += dx * dx
            spreadB += dy * dy
        }
        guard spreadA > 0, spreadB > 0 else { return 0 }
        return together / (spreadA * spreadB).squareRoot()
    }
}
