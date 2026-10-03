/// Whether the meeting's mic is muted on the mac itself: its mute switch
/// on, or its input volume dragged all the way down. Either is your side
/// silent on purpose, which the meeting must not take for a mic that has
/// stopped delivering. Told when it changes, not at every read.
///
/// Pure: what the mic's own controls read in, what to tell out. The reads
/// are `CoreAudioMeetingSource`'s, a few seconds apart, on its own queue.
struct MicMute: Equatable, Sendable {
    /// An input volume at or under this is nothing.
    static let nothing: Float = 0.001

    private(set) var muted = false

    /// What the controls read now: nil for one the mic does not have.
    /// Returns what to tell, if it changed.
    mutating func read(mute: Bool?, volume: Float?) -> MeetingSourceEvent.Kind? {
        let now = mute == true || volume.map { $0 <= Self.nothing } == true
        guard now != muted else { return nil }
        muted = now
        return now ? .micMuted : .micUnmuted
    }
}
