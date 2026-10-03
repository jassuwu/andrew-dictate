import Foundation

/// Where speech begins or ends on one side of a meeting, as a sample
/// position counted from the first sample that side's detector was fed.
enum SpeechEdge: Equatable, Sendable {
    case began(at: Int)
    case ended(at: Int)
}

/// Tells speech from quiet on one side of a meeting.
///
/// Fed that side's audio in order, a chunk at a time, it answers with the
/// edges it found. An edge may point back into audio from an earlier chunk:
/// a detector only knows speech has ended once it has heard enough quiet
/// after it, and a model that judges a frame at a time knows speech began
/// somewhere in the frame it just judged. Silero's streaming VAD in
/// FluidAudio works exactly this way — consecutive chunks in, start and end
/// events out as sample positions — so it can sit behind this as it is.
///
/// One per side, per meeting: it keeps its state between calls. It does not
/// throw. A detector that cannot tell — its model failed — should say
/// speech: a stretch of silence costs a decode, a missed one costs the words.
protocol SpeechDetector: Sendable {
    func hear(_ samples: [Float]) async -> [SpeechEdge]
}

/// The simplest thing that tells talk from quiet: loudness, judged 20 ms at
/// a time, with a hangover so a breath between two words does not end the
/// speech. For tests, and for a mac the voice model will not load on.
actor LoudnessDetector: SpeechDetector {
    private let threshold: Float
    private let hangover: Int

    /// Samples short of a whole frame, judged when the rest arrives.
    private var pending: [Float] = []
    private var judged = 0
    private var speaking = false
    private var quietSince: Int?

    private static let frame = 320

    init(threshold: Float = 0.01, hangover: Duration = .milliseconds(500)) {
        self.threshold = threshold
        self.hangover = Int(hangover.totalSeconds * MeetingAudioChunk.sampleRate)
    }

    func hear(_ samples: [Float]) -> [SpeechEdge] {
        pending.append(contentsOf: samples)
        var edges: [SpeechEdge] = []
        var offset = 0
        while pending.count - offset >= Self.frame {
            let frameStart = judged
            let isLoud = Self.rms(pending[offset..<(offset + Self.frame)]) > threshold
            offset += Self.frame
            judged += Self.frame

            if isLoud {
                quietSince = nil
                if !speaking {
                    speaking = true
                    edges.append(.began(at: frameStart))
                }
            } else if speaking {
                let since = quietSince ?? frameStart
                quietSince = since
                // the speech ended where the quiet began, not where the
                // hangover ran out.
                if judged - since >= hangover {
                    speaking = false
                    quietSince = nil
                    edges.append(.ended(at: since))
                }
            }
        }
        pending.removeFirst(offset)
        return edges
    }

    private static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
