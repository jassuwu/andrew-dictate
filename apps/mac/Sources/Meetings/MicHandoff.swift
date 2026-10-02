/// When a meeting moves to another mic. The mic is whatever the mac says
/// the default input is; airpods connecting, a usb mic plugged in, or a
/// pick in control centre each move it, and airpods leaving take the
/// meeting's mic away. Each arrives as a burst of changes over a second or
/// two, and a rig built in the middle of one can bind to a device already
/// going away, so the move waits for the hardware to settle.
///
/// Pure: instants and what the mac says about its mics in, steps out. The
/// rig itself is `CoreAudioMeetingSource`'s.
struct MicHandoff: Equatable, Sendable {
    typealias Instant = ContinuousClock.Instant

    /// A mic as the mac knows it: the uid to find it by, the name to tell.
    struct Mic: Equatable, Sendable {
        let uid: String
        let name: String
    }

    /// What the mac says about its mics, read once the hardware has settled.
    struct Mics: Equatable, Sendable {
        /// The default input, when it is one a meeting can use.
        var defaultInput: Mic?
        var builtIn: Mic?
        /// The uid of every input there is right now.
        var present: Set<String>
    }

    /// The two device uids a meeting's rig is built under, in turn: the
    /// next rig comes up beside the last, and the HAL will not have two
    /// devices under one uid.
    enum Slot: Equatable, Sendable {
        case first
        case second

        var other: Slot {
            switch self {
            case .first: .second
            case .second: .first
            }
        }
    }

    enum Step: Equatable, Sendable {
        /// Build a rig on this mic under this slot's uid, beside the live
        /// one, and say when it is up.
        case bringUp(Mic, Slot)
        /// The standby never delivered: tear it down. The live rig stays.
        case dropStandby
        /// For the meeting's record.
        case tell(MeetingSourceEvent.Kind, Mic?)
    }

    /// How long nothing may move after the last change in a burst.
    static let quiet = Duration.milliseconds(1_500)
    /// How long a burst that keeps going is waited out, from its first change.
    static let longest = Duration.seconds(3)
    /// How long a standby has, once it is up, to deliver its first buffer.
    static let patience = Duration.seconds(5)

    private struct Rig: Equatable, Sendable {
        let mic: Mic
        let slot: Slot
    }

    private struct Burst: Equatable, Sendable {
        let first: Instant
        var last: Instant

        var settlesAt: Instant {
            min(last + MicHandoff.quiet, first + MicHandoff.longest)
        }
    }

    /// A rig brought up beside the live one, until it delivers or is given up.
    private struct Standby: Equatable, Sendable {
        let mic: Mic
        let slot: Slot
        let fellBack: Bool
        /// When it was built and started; nil while it is still building.
        var upSince: Instant?
    }

    private var rig: Rig?
    private var burst: Burst?
    private var standby: Standby?

    /// The mic the meeting is on.
    var mic: Mic? {
        rig?.mic
    }

    /// A rig is up on `mic` under `slot`'s uid, and nothing is pending: the
    /// meeting started, or the tap was rebuilt.
    mutating func began(on mic: Mic, slot: Slot) {
        rig = Rig(mic: mic, slot: slot)
        burst = nil
        standby = nil
    }

    /// Something moved: the default input, or the list of devices.
    mutating func changed(at instant: Instant) {
        if burst == nil {
            burst = Burst(first: instant, last: instant)
        } else {
            burst?.last = instant
        }
    }

    /// When `look` next has something to decide, if anything is waiting.
    /// One move at a time: changes that come while a standby is out wait
    /// for it to deliver or be given up. A standby still building is not
    /// timed here: its build has a deadline of its own, in the source.
    var nextLook: Instant? {
        if let standby {
            return standby.upSince.map { $0 + Self.patience }
        }
        return burst?.settlesAt
    }

    /// What to do now: give up on a standby that has had its time, or
    /// decide on a burst that has settled.
    mutating func look(at now: Instant, mics: Mics) -> [Step] {
        if let standby {
            guard standbyIsOverdue(at: now) else { return [] }
            self.standby = nil
            return [.dropStandby, .tell(.micHandoffFailed, standby.mic)]
                + afterFailing(standby, mics: mics)
        }
        guard let burst, now >= burst.settlesAt else { return [] }
        self.burst = nil
        return decide(mics)
    }

    /// The standby is built and started.
    mutating func standbyUp(at instant: Instant) {
        standby?.upSince = instant
    }

    /// The standby is up and has had its five seconds.
    func standbyIsOverdue(at now: Instant) -> Bool {
        guard let upSince = standby?.upSince else { return false }
        return now >= upSince + Self.patience
    }

    /// The standby delivered its first buffer and the source has switched
    /// to it: it is the meeting's rig now, and the old one goes.
    mutating func standbyDelivered() -> [Step] {
        guard let standby else { return [] }
        self.standby = nil
        rig = Rig(mic: standby.mic, slot: standby.slot)
        return [.tell(standby.fellBack ? .micFellBack : .micChanged, standby.mic)]
    }

    /// The standby could not be built or started. The source has nothing of
    /// it left to tear down.
    mutating func standbyFailed(mics: Mics) -> [Step] {
        guard let standby else { return [] }
        self.standby = nil
        return [.tell(.micHandoffFailed, standby.mic)] + afterFailing(standby, mics: mics)
    }

    /// A rig still delivering keeps the meeting. One whose mic went has
    /// nothing to deliver, so the meeting tries the built-in mic, unless
    /// that is what just failed.
    private mutating func afterFailing(_ standby: Standby, mics: Mics) -> [Step] {
        guard let rig, !mics.present.contains(rig.mic.uid),
              let builtIn = mics.builtIn, builtIn != standby.mic
        else { return [] }
        return bringUp(builtIn, after: rig, fellBack: true)
    }

    private mutating func decide(_ mics: Mics) -> [Step] {
        guard let rig else { return [] }
        let isThere = mics.present.contains(rig.mic.uid)
        guard let target = mics.defaultInput else {
            // nothing the mac names will do. a mic still there keeps the
            // meeting; one that went leaves the built-in mic, and a mac
            // without one (a mini, a studio) nowhere at all.
            guard !isThere else { return [] }
            guard let builtIn = mics.builtIn else { return [.tell(.micHandoffFailed, nil)] }
            return bringUp(builtIn, after: rig, fellBack: true)
        }
        // a monitor, the rig's own device coming and going: the list moved
        // and the mic did not.
        if target == rig.mic, isThere { return [] }
        return bringUp(target, after: rig, fellBack: false)
    }

    private mutating func bringUp(_ mic: Mic, after rig: Rig, fellBack: Bool) -> [Step] {
        let slot = rig.slot.other
        standby = Standby(mic: mic, slot: slot, fellBack: fellBack)
        return [.bringUp(mic, slot)]
    }
}
