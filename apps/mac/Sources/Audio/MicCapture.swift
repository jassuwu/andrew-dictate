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

/// the mic a press was heard through, as the press log names it: what the
/// device calls itself, and how it is attached — the two facts that tell an
/// airpods failure from a built-in one.
struct MicDescription: Equatable, Sendable, Codable {
    enum Transport: String, Equatable, Sendable, Codable {
        case builtIn = "built-in"
        case bluetooth
        case usb
        case continuity
        case virtual
        case unknown
    }

    let name: String
    let transport: Transport
}
