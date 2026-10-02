import Foundation

/// When the call reader asks Core Audio which apps hold the mic, and when it
/// stops asking (ADR 0047). Nobody on a call costs nothing: a listener says
/// when the mic is taken, and only then does anything read.
///
/// - While anyone holds the default mic, a meeting records, or the watcher
///   is following a call, it reads every two seconds and feeds the call
///   watcher what it read. A call goes on while its app holds the mic or
///   plays audio, so a participant whose app closed the mic on mute is still
///   on it, and only a read can say so: the free mic alone would end the
///   call and offer it again at the unmute.
/// - While the mic is held by us alone (pre-roll keeps it open for as long as
///   the app runs, and every dictation takes it), with nothing recording and
///   no call followed, it reads every ten. Nothing tells the listener that a
///   second app took a mic that was already in use, so it cannot stop; it
///   reads rarely, and a call that starts under it is a few seconds later to
///   be noticed.
/// - Otherwise it stops, until the mic is taken again.
///
/// Time is passed in. Asked early it says when to ask again; a change of what
/// to do acts at once, without waiting out the last interval.
struct CallReadingSchedule {
    static let readEvery = Duration.seconds(2)
    static let readRarelyEvery = Duration.seconds(10)

    enum Step: Equatable, Sendable {
        /// Read the processes and feed the watcher what they say.
        case read
    }

    struct Plan: Equatable, Sendable {
        /// What to do now, if anything.
        let step: Step?
        /// When to ask again. Nil: not until something changes.
        let next: Duration?
    }

    private var last: (step: Step, at: Duration)?

    mutating func plan(
        at now: Duration,
        micInUse: Bool,
        isRecording: Bool,
        followingACall: Bool,
        othersOnTheMic: Bool
    ) -> Plan {
        let every: Duration
        if isRecording || followingACall {
            every = Self.readEvery
        } else if micInUse {
            every = othersOnTheMic ? Self.readEvery : Self.readRarelyEvery
        } else {
            last = nil
            return Plan(step: nil, next: nil)
        }

        if let last, now - last.at < every {
            return Plan(step: nil, next: last.at + every)
        }
        last = (.read, now)
        return Plan(step: .read, next: now + every)
    }
}
