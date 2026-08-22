import Foundation

/// Decides which of three things is true about a system-audio tap: it is
/// working, it never worked, or it stopped working.
///
/// The distinction matters because the two failures need opposite responses —
/// one is a permission the user has to grant, the other is 002 §6's teardown
/// and rebuild — and because at the Core Audio level they are identical. Every
/// call returns `noErr`, and the IOProc delivers buffers of zeroes either way.
///
/// Two observations make them separable:
///
/// 1. **A dead tap always worked first.** The failure report behind 002 §6 is
///    explicit — *"always occurs after extended uptime; first few minutes are
///    consistently clean"*. So "has this tap ever delivered a non-zero sample"
///    splits denied-from-birth off from died-in-service.
/// 2. **Silence is only ambiguous when we do not control the source.** ADR 0021
///    starts capture by playing a known sound, so silence during the probe
///    window is not "nobody spoke" — it is "we made a noise and the tap did not
///    hear it". That is the whole reason this can be decided at all.
///
/// `kAudioProcessPropertyIsRunningOutput` is deliberately not consulted. It
/// reports that a process has active output IO, not that it is contributing
/// non-zero samples, so a room of muted participants satisfies it (002 §6,
/// correcting its own earlier draft).
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
        /// It was working and has now been silent past the timeout.
        case wentSilent

        var response: Response? {
            switch self {
            case .waitingForProbeTone, .capturing: nil
            case .neverHeardTheProbeTone: .tellTheUser
            case .wentSilent: .rebuildTheTap
            }
        }
    }

    enum Response: Equatable, Sendable {
        case tellTheUser
        case rebuildTheTap
    }

    /// How long after capture starts the probe tone gets to arrive.
    let probeTimeout: Duration
    /// How long a working tap may deliver silence before it is presumed dead.
    /// Long enough that an ordinary pause in conversation does not trip it.
    let silenceTimeout: Duration
    /// RMS at or below this counts as silence. A tap delivering literal zeroes
    /// is the documented failure, but floating-point noise floors are not
    /// exactly zero.
    let silenceFloor: Float

    private(set) var verdict: Verdict = .waitingForProbeTone
    private var lastHeardAudio: Duration?

    init(
        probeTimeout: Duration,
        silenceTimeout: Duration,
        silenceFloor: Float
    ) {
        self.probeTimeout = probeTimeout
        self.silenceTimeout = silenceTimeout
        self.silenceFloor = silenceFloor
    }

    /// `elapsed` is measured from the start of capture, which is also when the
    /// probe tone starts playing.
    mutating func observe(rms: Float, elapsed: Duration) {
        guard rms <= silenceFloor else {
            // Real audio outranks every guess made before it, including a
            // never-heard verdict — that only ever meant the probe window was
            // too short.
            lastHeardAudio = elapsed
            verdict = .capturing
            return
        }

        guard let lastHeardAudio else {
            // Nothing has ever arrived, so the probe window is what applies.
            verdict = elapsed > probeTimeout
                ? .neverHeardTheProbeTone
                : .waitingForProbeTone
            return
        }

        if elapsed - lastHeardAudio > silenceTimeout {
            verdict = .wentSilent
        }
    }
}
