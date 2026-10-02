import Foundation

/// Decides which of three things is true about a system-audio tap: it is
/// working, it never worked, or it stopped working.
///
/// The distinction matters because the two failures need opposite responses —
/// one is a permission the user has to grant, the other is 002 §6's teardown
/// and rebuild — and because at the Core Audio level they are identical. Every
/// call returns `noErr`, and the IOProc delivers buffers of zeroes either way.
///
/// Three observations make them separable:
///
/// 1. **A dead tap always worked first.** The failure report behind 002 §6 is
///    explicit — *"always occurs after extended uptime; first few minutes are
///    consistently clean"*. So "has this tap ever delivered a non-zero sample"
///    splits denied-from-birth off from died-in-service.
/// 2. **Silence is only ambiguous when we do not control the source.** ADR 0021
///    starts capture by playing a known sound, so silence during the probe
///    window is not "nobody spoke" — it is "we made a noise and the tap did not
///    hear it". That is the whole reason this can be decided at all.
/// 3. **So silence later is never the answer, only the question.** A working
///    tap in a room of muted people delivers what a dead one does. Past the
///    timeout, and only while something is playing, the tap is asked again
///    the same way — a quiet tone of our own — and only a tone it does not
///    hear makes it dead.
///
/// `kAudioProcessPropertyIsRunningOutput` is never taken as proof. It reports
/// that a process has active output IO, not that it is contributing
/// non-zero samples, so a room of muted participants satisfies it (002 §6,
/// correcting its own earlier draft). It decides whether a silence is worth
/// asking about, and nothing more.
struct TapHealthMonitor {
    enum Verdict: Equatable, Sendable {
        /// The probe tone is playing and nothing has been heard yet. Not a
        /// failure — it is the first few hundred milliseconds of every capture.
        case waitingForProbeTone
        case capturing
        /// The tone played and the tap heard nothing. Permission denied, or
        /// the tap was dead on arrival; the two are indistinguishable and the
        /// user is told the same thing either way.
        case neverHeardTheProbeTone
        /// It was working, and has been silent past the timeout while the
        /// mac says something is playing. Not a dead tap yet: you presenting
        /// to a muted room sounds exactly like this.
        case silentWhileSomethingPlays
        /// The quiet probe is playing and the tap has not heard it yet.
        case waitingForQuietProbe
        /// We played the quiet probe and the tap did not hear it. This, and
        /// not the silence before it, is a dead tap.
        case missedTheQuietProbe

        var response: Response? {
            switch self {
            case .waitingForProbeTone, .capturing, .waitingForQuietProbe: nil
            case .neverHeardTheProbeTone: .tellTheUser
            case .silentWhileSomethingPlays: .askWithTheQuietProbe
            case .missedTheQuietProbe: .rebuildTheTap
            }
        }
    }

    enum Response: Equatable, Sendable {
        case tellTheUser
        case askWithTheQuietProbe
        case rebuildTheTap
    }

    /// How long after capture starts the probe tone gets to arrive.
    let probeTimeout: Duration
    /// How long a working tap may deliver silence, while something plays,
    /// before it is asked whether it still hears. Long enough that an
    /// ordinary pause in conversation does not trip it.
    let silenceTimeout: Duration
    /// How long the quiet probe gets to come back through the tap.
    let quietProbeWindow: Duration
    /// RMS at or below this counts as silence. A tap delivering literal zeroes
    /// is the documented failure, but floating-point noise floors are not
    /// exactly zero.
    let silenceFloor: Float

    private(set) var verdict: Verdict = .waitingForProbeTone
    /// Where the silence being timed began: the last audio heard, and
    /// `nil` until the tap has heard anything at all.
    private var quietSince: Duration?
    private var quietProbeAskedAt: Duration?

    init(
        probeTimeout: Duration,
        silenceTimeout: Duration,
        quietProbeWindow: Duration,
        silenceFloor: Float
    ) {
        self.probeTimeout = probeTimeout
        self.silenceTimeout = silenceTimeout
        self.quietProbeWindow = quietProbeWindow
        self.silenceFloor = silenceFloor
    }

    /// `elapsed` is measured from the start of capture, which is also when the
    /// probe tone starts playing.
    ///
    /// `anythingIsPlaying` is the one thing that can tell a quiet room from
    /// a dead tap, and only in one direction: a mac putting nothing out
    /// cannot be misheard, so its silence is never a verdict. `nil` means
    /// the question could not be asked at all, and an unanswered question
    /// is not a yes: it accuses nothing either. `true` is still not proof —
    /// see the note above about muted participants.
    mutating func observe(
        rms: Float,
        elapsed: Duration,
        anythingIsPlaying: Bool? = nil
    ) {
        guard rms <= silenceFloor else {
            // Real audio outranks every guess made before it, including a
            // never-heard verdict — that only ever meant the probe window was
            // too short. It answers a quiet probe too, and the silence is
            // timed afresh from here.
            quietSince = elapsed
            quietProbeAskedAt = nil
            verdict = .capturing
            return
        }

        guard let quietSince else {
            // Nothing has ever arrived, so the probe window is what applies.
            verdict = elapsed > probeTimeout
                ? .neverHeardTheProbeTone
                : .waitingForProbeTone
            return
        }

        if let askedAt = quietProbeAskedAt {
            if elapsed - askedAt > quietProbeWindow {
                quietProbeAskedAt = nil
                verdict = .missedTheQuietProbe
            }
            return
        }

        // A question already raised, or a tap already found dead, stands
        // until something is heard.
        guard verdict == .capturing else {
            return
        }

        // Nothing is playing, or nobody can say, so there is nothing known
        // to have been missed: the recording carries on through the quiet,
        // no gap, no rebuild, no start sound in the middle of a call.
        guard anythingIsPlaying == true else {
            return
        }

        if elapsed - quietSince > silenceTimeout {
            verdict = .silentWhileSomethingPlays
        }
    }

    /// The quiet probe has been asked for, at `elapsed`: the tap has the
    /// window from here to hear it in.
    mutating func askedWithTheQuietProbe(at elapsed: Duration) {
        guard verdict == .silentWhileSomethingPlays else {
            return
        }
        quietProbeAskedAt = elapsed
        verdict = .waitingForQuietProbe
    }

    /// The quiet probe could not be played at all, so the tap was asked
    /// nothing: it is neither cleared nor accused, and the silence is timed
    /// afresh from `elapsed`.
    mutating func quietProbeCouldNotPlay(at elapsed: Duration) {
        guard verdict == .waitingForQuietProbe else {
            return
        }
        quietProbeAskedAt = nil
        quietSince = elapsed
        verdict = .capturing
    }
}
