/// A take longer than a model reads at once, cut where it is quietest.
///
/// Whisper reads 30 s at a time and parakeet cuts long audio into windows
/// of its own. A model that does not is handed the take in pieces, and a
/// cut through a word loses it, so each cut goes at the quietest moment in
/// the last stretch before the limit: between sentences, usually, or at a
/// breath.
enum QuietSplit {
    /// 16 kHz mono, the only rate any engine here is handed.
    static let sampleRate = 16_000
    /// How far back from the limit a cut may go looking for quiet.
    static let lookBack = 5 * sampleRate
    /// The length of audio one loudness reading covers: 50 ms, shorter than
    /// the gap between two words.
    static let frame = sampleRate / 20

    static func pieces(of samples: [Float], longest: Duration) -> [[Float]] {
        let seconds = Double(longest.components.seconds)
            + Double(longest.components.attoseconds) / 1e18
        return pieces(of: samples, longest: Int(seconds * Double(sampleRate)))
    }

    /// Every sample, in order, in pieces of at most `longest` samples. A
    /// take that fits is one piece, untouched.
    static func pieces(of samples: [Float], longest: Int) -> [[Float]] {
        precondition(longest > frame, "a piece must be longer than one frame")
        var pieces: [[Float]] = []
        var start = 0
        while samples.count - start > longest {
            let cut = quietestCut(in: samples, from: start, limit: start + longest)
            pieces.append(Array(samples[start..<cut]))
            start = cut
        }
        pieces.append(Array(samples[start...]))
        return pieces
    }

    /// The middle of the quietest frame between `limit - lookBack` and
    /// `limit`, never closer to `start` than a third of the way to the
    /// limit, so a piece is never a sliver.
    private static func quietestCut(in samples: [Float], from start: Int, limit: Int) -> Int {
        let earliest = max(start + (limit - start) / 3, limit - lookBack)
        var bestCut = limit
        var bestEnergy = Float.infinity
        var frameStart = earliest
        while frameStart + frame <= limit {
            var energy: Float = 0
            for sample in samples[frameStart..<(frameStart + frame)] {
                energy += sample * sample
            }
            // ties go to the later frame: the longer piece.
            if energy <= bestEnergy {
                bestEnergy = energy
                bestCut = frameStart + frame / 2
            }
            frameStart += frame / 2
        }
        return bestCut
    }
}
