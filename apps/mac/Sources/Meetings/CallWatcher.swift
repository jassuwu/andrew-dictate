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
    }

    private var call: Call?
    private var qualifyingSince: Duration?

    mutating func observe(
        _ apps: [App],
        isRecording: Bool,
        at now: Duration
    ) -> [Suggestion] {
        guard call == nil else {
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
        call = Call(app: app.name)
        return isRecording ? [] : [.record(app.name)]
    }
}
