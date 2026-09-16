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
    /// nil means stay silent. sleeping is not a failure to explain — the pill
    /// would be gone before the screen came back — but a microphone that
    /// vanished mid-sentence is a loss, and losses speak (SPEC §4).
    static func message(for reason: CaptureInterruption) -> String? {
        switch reason {
        case .deviceChanged:
            "the microphone changed — say that again"
        case .systemPaused:
            nil
        }
    }
}
