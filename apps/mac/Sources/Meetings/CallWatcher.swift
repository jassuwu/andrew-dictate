import Foundation

/// Decides when a call has begun and when it has ended, so the app can say so.
///
/// It suggests; it never acts. Nothing starts a recording but you and nothing
/// stops one but you (ADR 0023), so the watcher's whole output is a sentence
/// for the menu bar to say — `record(zoom)` when a call begins with nothing
/// recording, `stop(zoom)` once when it ends with a recording still running —
/// and what happens next is the user's. A suggestion nobody answers is not
/// repeated; it is just over.
///
/// A call is one app that holds the mic *and* plays audio, for a while. Either
/// alone is not a call: the mic is dictation, a screen recorder, a voice memo,
/// and audio is a video or music. Once it is a call it carries on while either
/// half is there, because a participant who mutes still hears everyone else —
/// audio alone for ten minutes after the app was last on the mic, since a
/// call that ended and a video that plays after it look just the same — and
/// ends when the app has done neither for long enough that nobody is coming
/// back.
///
/// Time is whatever the caller passes in, never a clock of the watcher's own,
/// and observations may arrive at any cadence. Between two of them the watcher
/// assumes nothing changed, so a state has lasted from the first observation
/// that showed it. The thresholds are provisional until real calls have been
/// watched.
struct CallWatcher {
    /// One call app that is doing anything. An app that is doing neither is
    /// simply left out of the list, so the watcher never has to be told that
    /// something went quiet. There is one entry per app, however many
    /// processes it plays and listens through.
    struct App: Equatable, Sendable {
        /// The short display name (`zoom`), which is also how the watcher
        /// tells one app from another.
        let name: String
        let holdsMic: Bool
        let playsAudio: Bool

        /// Only both together look like a call.
        var looksLikeACall: Bool { holdsMic && playsAudio }
    }

    enum Suggestion: Equatable, Sendable {
        /// A call began and nothing is recording it. Made once per call.
        case record(String)
        /// A call ended and a recording is still running. Made once per call.
        case stop(String)
    }

    /// How long one app must hold the mic and play audio, without a break,
    /// before it is a call. Long enough that a notification chime or a
    /// browser tab grabbing the mic for a moment is not.
    let startAfter: Duration
    /// How long the call's app must do neither before the call is over. Long
    /// enough that a dropped connection that comes back, or a long silence in
    /// a meeting nobody has left, does not end it.
    let endAfter: Duration

    /// How long the call's app playing audio, off the mic, keeps the call
    /// going, from the first observation that showed it off the mic. A
    /// participant on mute still hears everyone else, but an app whose call
    /// ended and that now plays a video looks just the same, and only time
    /// tells them apart. Provisional, like the rest.
    static let audioAloneKeepsACallFor: Duration = .seconds(600)

    init(startAfter: Duration = .seconds(3), endAfter: Duration = .seconds(30)) {
        self.startAfter = startAfter
        self.endAfter = endAfter
    }

    private struct Call {
        let app: String
        /// The first observation that showed the app doing nothing that
        /// keeps the call going, if it still is. Cleared the moment it does.
        var quietSince: Duration?
        /// The first observation that showed the app off the mic, if it
        /// still is. Cleared the moment it takes the mic again.
        var offTheMicSince: Duration?
    }

    private struct Candidate {
        let app: String
        let since: Duration
    }

    private var call: Call?
    /// Apps that look like a call right now and are being timed, oldest
    /// first. Empty while a call is on: a second app is ignored until the
    /// first call ends, and then it starts from nothing.
    private var candidates: [Candidate] = []
    /// As of the last observation. The watcher has no other way to know.
    private var recording = false

    /// The app whose call is on now, recorded or not. The recording's file is
    /// named after it.
    var currentCall: String? { call?.app }

    /// The app whose call is on while nothing is recording it: what the menu
    /// bar icon shows to say there is a call you could be keeping.
    var unrecordedCall: String? { recording ? nil : call?.app }

    /// The user said no to the record suggestion.
    ///
    /// There is nothing to remember. The watcher asks once per call and never
    /// again, so a no is final for that call without any state of its own,
    /// and the next call asks afresh — a no said when there is no call on
    /// does not carry over to one. `currentCall` and `unrecordedCall` go on
    /// reporting the call: a no is not the call ending.
    ///
    /// Stopping is a separate question and is still asked: someone who said no
    /// and then pressed record by hand has a recording that outlives its call
    /// like any other.
    func dismissRecordSuggestion() {}

    /// What the call apps are doing right now, whether a meeting is being
    /// recorded, and when. Our own app, and dictation, are not call apps and
    /// have been filtered out before this.
    ///
    /// Zero or more suggestions, though the rules as they stand never make
    /// two at once: a stop needs a recording and a record needs none.
    mutating func observe(
        _ apps: [App],
        isRecording: Bool,
        at now: Duration
    ) -> [Suggestion] {
        recording = isRecording
        var suggestions: [Suggestion] = []

        if let ended = advanceTheCall(apps, at: now), isRecording {
            suggestions.append(.stop(ended))
        }
        if call == nil, let began = lookForACall(apps, at: now), !isRecording {
            suggestions.append(.record(began))
        }
        return suggestions
    }

    /// Carries the call that is on forward by one observation. Returns its
    /// app if it ended just now.
    private mutating func advanceTheCall(_ apps: [App], at now: Duration) -> String? {
        guard var current = call else {
            return nil
        }
        let app = apps.first { $0.name == current.app }
        if app?.holdsMic == true {
            current.offTheMicSince = nil
        } else if current.offTheMicSince == nil {
            current.offTheMicSince = now
        }
        if let app, keepsTheCallGoing(app, offTheMicSince: current.offTheMicSince, at: now) {
            current.quietSince = nil
            call = current
            return nil
        }
        let quietSince = current.quietSince ?? now
        guard now - quietSince >= endAfter else {
            current.quietSince = quietSince
            call = current
            return nil
        }
        call = nil
        return current.app
    }

    /// The mic keeps a call going: losing it alone is the most ordinary thing
    /// that happens in one. Audio alone keeps it going too, until the app
    /// has been off the mic for `audioAloneKeepsACallFor`.
    private func keepsTheCallGoing(
        _ app: App,
        offTheMicSince: Duration?,
        at now: Duration
    ) -> Bool {
        if app.holdsMic {
            return true
        }
        guard app.playsAudio, let offTheMicSince else {
            return false
        }
        return now - offTheMicSince < Self.audioAloneKeepsACallFor
    }

    /// Times every app that looks like a call, and begins the call of the one
    /// that has looked like one longest, once that has lasted long enough.
    /// Returns its app if a call began just now.
    private mutating func lookForACall(_ apps: [App], at now: Duration) -> String? {
        let looking = apps.filter(\.looksLikeACall).map(\.name)
        candidates.removeAll { !looking.contains($0.app) }
        for app in looking where !candidates.contains(where: { $0.app == app }) {
            candidates.append(Candidate(app: app, since: now))
        }
        guard let first = candidates.first, now - first.since >= startAfter else {
            return nil
        }
        call = Call(app: first.app, quietSince: nil)
        candidates = []
        return first.app
    }
}
