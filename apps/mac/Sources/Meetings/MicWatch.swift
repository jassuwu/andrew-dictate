/// Whether the meeting can hear you. A mic in a real room is never silent:
/// its own hiss is far above the floor this watches for, so a mic handing
/// over nothing but silence is a mic that is not delivering — unplugged in
/// all but name, taken by something else, or broken. That is only worth
/// saying while there is a call to be heard on: the far side talking at
/// some point in the silence. Both sides silent is a quiet room, or no call
/// at all, and nothing is said.
///
/// A mic muted on the mac, or turned all the way down, is silent on
/// purpose: while it is, nothing is held against it, and once it is back
/// its silence is timed afresh.
///
/// Known, and left as it is: an input that gates itself — Krisp and the
/// other noise cancellers that sit between the mic and the app, a headset
/// that gates in hardware — hands over exact zeros while you listen, not a
/// room's hiss. Ten seconds of the far side talking through that read as a
/// mic not delivering, and "can't hear your mic" is said over a mic that is
/// fine; it clears the moment you speak. Telling the two apart would take
/// knowing the input gates, which the mac does not say.
///
/// Pure: each chunk's two loudnesses in, at the meeting time it covers;
/// whether the mic is unheard out.
struct MicWatch: Equatable, Sendable {
    /// How long the mic may be silent, with the far side talking in that
    /// time, before it is unheard.
    let after: Duration
    /// RMS under this is silence.
    let floor: Float

    /// The mic has been silent past `after` while the far side talked. It
    /// stays so until the mic is heard, or muted.
    private(set) var unheard = false
    /// The mac says the mic is muted.
    private(set) var isMuted = false
    private var silentSince: Duration?
    private var theyLastTalked: Duration?

    init(after: Duration, floor: Float) {
        self.after = after
        self.floor = floor
    }

    /// One chunk, from `start` to `end` in meeting time: how loud the mic
    /// was, and whether the far side was talking in it — heard above its
    /// own floor, and not one of our tones.
    mutating func observe(you rms: Float, theyTalked: Bool, from start: Duration, to end: Duration) {
        guard !isMuted else { return }
        if theyTalked {
            theyLastTalked = end
        }
        guard rms < floor else {
            silentSince = nil
            unheard = false
            return
        }
        let since = silentSince ?? start
        silentSince = since
        guard !unheard, end - since >= after, let talked = theyLastTalked else { return }
        // the far side talked in the silence, and within the last stretch
        // of it as long as `after`: a call is on and you are not in it.
        unheard = talked > since && talked >= end - after
    }

    /// The mac says the mic is muted, or is not any more.
    mutating func muted(_ muted: Bool) {
        isMuted = muted
        silentSince = nil
        theyLastTalked = nil
        unheard = false
    }
}
