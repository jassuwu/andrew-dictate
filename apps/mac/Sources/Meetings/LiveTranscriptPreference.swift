import Foundation

/// Whether the live transcript panel comes back for the next meeting.
///
/// Unset is not "no" — it is "there has not been a meeting yet". The first
/// one is the meeting where the app has earned nothing: a red dot on the
/// badge is the only evidence it is listening at all, for an hour of a real
/// call. So the panel opens for that one, and the first close is what makes
/// it stay away — which is what the preference has always meant for
/// everybody who has one (SPEC §11).
enum LiveTranscriptPreference {
    static let key = "AndrewDictate.liveTranscriptOpen"

    static func wasOpenLastTime(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func remember(_ isOpen: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(isOpen, forKey: key)
    }
}
