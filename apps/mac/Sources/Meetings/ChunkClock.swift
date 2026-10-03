/// The chunks' clock, as the source keeps it. A chunk's `at` is a frame
/// count, and frames only exist while a rig calls back — so a lid shut for
/// an hour, or a mic gone for seconds before the next one took over, would
/// have every chunk after it stamped as if it never happened, and the
/// meeting's clock and the spool's would disagree from there on by the time
/// skipped.
///
/// So each buffer says where on the wall it began, and one that begins more
/// than `outage` after the last one ended — whichever rig either came from —
/// is past a time nothing came: the clock skips it, so the chunks after it
/// are stamped where they were heard, and hands it back for the source to
/// tell, so the meeting marks the gap. Less than that — a bluetooth profile
/// switching, the IO queue held up — is a loss nobody can hear, and a file
/// marked incomplete for it would cry wolf: it is left alone.
///
/// Pure: wall instants and frame counts in, stamps and outages out.
struct ChunkClock: Equatable, Sendable {
    typealias Instant = ContinuousClock.Instant

    /// More than this between one buffer's end and the next one's start is
    /// a time nothing came. A buffer is a hundredth of a second, and a
    /// second with none is a mic gone to the next, a lid, a sleep.
    static let outage = Duration.seconds(1)

    /// A time nothing came, on the chunks' clock: from where the chunks had
    /// got to, to where the next one is stamped.
    struct Outage: Equatable, Sendable {
        let from: Duration
        let to: Duration
    }

    /// Frames out in chunks, and frames skipped, at 16 kHz.
    private var frames: Int64 = 0
    /// Frames the live rig has taken in towards its next chunk, at 16 kHz.
    private var held: Double = 0
    /// Where on the wall the last buffer ended. nil before the first.
    private var lastEnded: Instant?

    /// The `at` the next chunk carries.
    var stamp: Duration {
        StretchCutter.duration(of: Int(frames))
    }

    /// A buffer that began at `began` on the wall and lasts `lasting`: the
    /// outage before it, if there was one, skipped already.
    mutating func buffer(began: Instant, lasting: Duration) -> Outage? {
        defer {
            held += lasting.totalSeconds * MeetingAudioChunk.sampleRate
            lastEnded = max(lastEnded ?? began + lasting, began + lasting)
        }
        guard let lastEnded, began - lastEnded > Self.outage else { return nil }
        let from = stamp
        frames += Int64(((began - lastEnded).totalSeconds * MeetingAudioChunk.sampleRate).rounded())
        return Outage(from: from, to: stamp)
    }

    /// A chunk of `count` frames went out.
    mutating func delivered(_ count: Int) {
        frames += Int64(count)
        held = max(0, held - Double(count))
    }

    /// Another rig is the live one: what the last one held towards its
    /// next chunk went with it.
    mutating func newRig() {
        held = 0
    }

    /// Where `wall` is on the chunks' clock: the chunks out, what the live
    /// rig holds towards the next, and, past an outage, the time since the
    /// last buffer, which the next one will skip. For a tone of ours played
    /// then: never later than where it lands.
    func position(at wall: Instant) -> Duration {
        let since = lastEnded.map { wall - $0 } ?? .zero
        return stamp + .seconds(held / MeetingAudioChunk.sampleRate)
            + (since > Self.outage ? since : .zero)
    }

    /// Whether a buffer has ended within `within` of `wall`.
    func delivering(at wall: Instant, within: Duration) -> Bool {
        lastEnded.map { wall - $0 < within } ?? false
    }
}
