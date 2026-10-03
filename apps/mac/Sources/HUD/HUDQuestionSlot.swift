import Foundation

/// whose the pill is while there are questions (ADR 0047). a pill with a
/// button is a question, and a question is the one pill that waits its turn:
/// it goes up only on a pill nothing else is using, and gives way the moment
/// a take or a sentence needs it, unanswered. dictation wins, and so does
/// every sentence the app owes you, because a failure must never be hidden
/// behind a question about a call.
///
/// a question that had to wait goes up once the pill is free, if it is still
/// worth asking. one that was taken off the pill does not come back: the
/// menu still has it.
struct HUDQuestionSlot<Question: Equatable> {
    /// on the pill now.
    private(set) var asked: Question?
    /// asked while the pill was busy.
    private(set) var waiting: Question?

    /// a question arrives. true when it goes up now, in place of any
    /// question already up; false when it waits, in place of any question
    /// already waiting. `pillIsFree` is about everything but questions.
    mutating func ask(_ question: Question, pillIsFree: Bool) -> Bool {
        guard pillIsFree else {
            waiting = question
            return false
        }
        asked = question
        waiting = nil
        return true
    }

    /// a take or a sentence took the pill. the question on it is gone.
    mutating func pillTaken() {
        asked = nil
    }

    /// the pill is free again: the question that waited goes up, unless the
    /// moment it was about has passed.
    mutating func pillFreed(stillWorthAsking: (Question) -> Bool) -> Question? {
        guard asked == nil, let next = waiting else {
            return nil
        }
        waiting = nil
        guard stillWorthAsking(next) else {
            return nil
        }
        asked = next
        return next
    }

    /// the question on the pill was answered, or ran out of time. true only
    /// the first time, and only while it is still the one up, so a click
    /// and the countdown that both arrive are one answer.
    mutating func answer(_ question: Question) -> Bool {
        guard asked == question else {
            return false
        }
        asked = nil
        return true
    }

    /// answered somewhere else: it leaves the pill without being acted on,
    /// or stops waiting for it. true when it was on the pill.
    mutating func withdraw(_ question: Question) -> Bool {
        if waiting == question {
            waiting = nil
        }
        guard asked == question else {
            return false
        }
        asked = nil
        return true
    }
}
