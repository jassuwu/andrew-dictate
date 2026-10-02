/// why a capture stopped without the user letting go of the key. the reason
/// lives here rather than in the recorder so the copy can be argued with in
/// a test that links no audio.
enum CaptureInterruption: Equatable, Sendable {
    /// the input route moved under us: airpods connecting, a display's audio
    /// device appearing, another app taking the default input.
    case deviceChanged
    /// the mac went to sleep, or the screen locked.
    case systemPaused
}

enum CaptureInterruptionNotice {
    /// both keep the take, so both say where it went. a microphone that
    /// changed mid-sentence pastes what it had, and the pill rides the
    /// paste in the cap's voice. sleep and the lock leave it on the
    /// clipboard, and the pill waits until you are back, in the voice of
    /// the other copies.
    static func message(for reason: CaptureInterruption) -> String {
        switch reason {
        case .deviceChanged:
            "the mic changed — pasted what i had."
        case .systemPaused:
            "copied — what you said before the lock · ⌘V to paste"
        }
    }
}
