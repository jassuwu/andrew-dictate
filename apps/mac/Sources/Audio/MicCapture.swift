/// the microphone, as one utterance needs it: start listening and say when
/// the first buffer lands, stop and hand over what was heard, or cancel and
/// keep nothing. `AudioRecorder` is the real one; the utterance machine
/// never sees AVFoundation, so a test can stand a fake in its place.
@MainActor
protocol MicCapture: AnyObject {
    func start(
        onFirstBuffer: @escaping @MainActor @Sendable (
            ContinuousClock.Instant
        ) -> Void
    ) throws
    /// 16 kHz mono float, the shape the engine takes.
    func stop() throws -> [Float]
    func cancel()
}
