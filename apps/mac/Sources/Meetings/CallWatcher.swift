import Foundation

/// Decides when a call has begun and when it has ended, so the app can say so.
///
/// It suggests; it never acts. ADR 0023's refusal stands: nothing starts a
/// recording but you, and nothing stops one but you. The watcher's whole
/// output is a sentence for the menu bar to say — `record(zoom)` when a call
/// begins with nothing recording, `stop(zoom)` once when it ends with a
/// recording still running — and what happens next is the user's.
struct CallWatcher {
    /// One call app that is doing anything. An app that is doing neither is
    /// simply left out of the list, so the watcher never has to be told that
    /// something went quiet.
    struct App: Equatable, Sendable {
        /// The short display name (`zoom`), which is also how the watcher
        /// tells one app from another.
        let name: String
        let holdsMic: Bool
        let playsAudio: Bool

        /// Only both together look like a call. The mic alone is dictation, a
        /// screen recorder, a voice memo; audio alone is a video or music.
        var looksLikeACall: Bool { holdsMic && playsAudio }

        /// Either is enough to keep a call going. A participant who mutes
        /// still hears everyone else, so losing the mic alone is not the end
        /// of anything.
        var keepsACallGoing: Bool { holdsMic || playsAudio }
    }

    enum Suggestion: Equatable, Sendable {
        case record(String)
        case stop(String)
    }

    let startAfter: Duration
    let endAfter: Duration

    init(startAfter: Duration = .seconds(3), endAfter: Duration = .seconds(30)) {
        self.startAfter = startAfter
        self.endAfter = endAfter
    }

    private struct Call {
        let app: String
        var quietSince: Duration?
    }

    private var call: Call?
    private var qualifyingSince: Duration?
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
    /// and the next call asks afresh. `currentCall` and `unrecordedCall` go
    /// on reporting the call: a no is not the call ending.
    func dismissRecordSuggestion() {}

    mutating func observe(
        _ apps: [App],
        isRecording: Bool,
        at now: Duration
    ) -> [Suggestion] {
        recording = isRecording
        if var current = call {
            if apps.contains(where: { $0.name == current.app && $0.keepsACallGoing }) {
                current.quietSince = nil
            } else {
                let since = current.quietSince ?? now
                current.quietSince = since
                if now - since >= endAfter {
                    call = nil
                    return isRecording ? [.stop(current.app)] : []
                }
            }
            call = current
            return []
        }
        guard let app = apps.first(where: \.looksLikeACall) else {
            qualifyingSince = nil
            return []
        }
        let since = qualifyingSince ?? now
        qualifyingSince = since
        guard now - since >= startAfter else {
            return []
        }
        call = Call(app: app.name, quietSince: nil)
        qualifyingSince = nil
        return isRecording ? [] : [.record(app.name)]
    }
}
