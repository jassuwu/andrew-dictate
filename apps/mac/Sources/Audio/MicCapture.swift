/// the microphone, as one utterance needs it: start listening and say when
/// the first buffer lands, stop and hand over what was heard, or cancel and
/// keep nothing. `AudioRecorder` is the real one; the utterance machine
/// never sees AVFoundation, so a test can stand a fake in its place.
///
/// start and stop are awaited, never blocked on: a device that is slow to
/// open, or wedged, must not hold the main thread, and the machine stops
/// waiting on it after a moment of its own.
@MainActor
protocol MicCapture: AnyObject {
    func start(
        onFirstBuffer: @escaping @MainActor @Sendable (
            ContinuousClock.Instant
        ) -> Void
    ) async throws
    /// 16 kHz mono float, the shape the engine takes.
    func stop() async throws -> [Float]
    /// keep nothing. fire-and-forget: it lands after whatever start or stop
    /// is still under way.
    func cancel()
    /// the device this capture is bound to, if it will say. read for the
    /// press log, never to decide anything.
    var deviceDescription: MicDescription? { get }
}

/// a capture the app can throw away whole. a device change, a wedge or the
/// mac going to sleep is answered with a new one, never by rebuilding this
/// one in place.
@MainActor
protocol DisposableMicCapture: MicCapture {
    /// ready ahead of a press, off the main thread: the graph built, and
    /// with pre-roll on, the mic already listening.
    func prepare()
    /// gone for good: it tears itself down on its own and is never asked
    /// anything again.
    func discard()
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
