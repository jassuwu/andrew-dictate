import Accelerate
import AVFoundation
import os
import Synchronization

/// file scope because the tap, the storage and the engine all run off the
/// main actor, where there is no `self` to log through.
private let recorderLogger = Logger(
    subsystem: AppIdentity.loggingSubsystem,
    category: "audio"
)

enum AudioRecorderError: LocalizedError {
    case alreadyRecording
    case conversionFailed(Error?)
    case invalidInputFormat
    case notRecording
    case oversizedCaptureBuffer
    case unavailableBuffer
    /// thrown away: whatever was asked of it after that is not done.
    case discarded

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "audio capture is already running"
        case let .conversionFailed(error):
            if let error {
                "audio conversion failed: \(error.localizedDescription)"
            } else {
                "audio conversion failed"
            }
        case .invalidInputFormat:
            "the microphone input format is unavailable"
        case .notRecording:
            "audio capture is not running"
        case .oversizedCaptureBuffer:
            "an audio buffer arrived larger than the capture pool"
        case .unavailableBuffer:
            "an audio buffer could not be allocated"
        case .discarded:
            "audio capture was thrown away"
        }
    }
}

/// one capture, from the press that first needs it to the moment it is
/// thrown away: one `AVAudioEngine`, and one serial queue every call into
/// that engine runs on.
///
/// the main actor never touches the engine. it asks, and awaits the
/// answer, and the utterance machine stops waiting after a moment of its
/// own. a device change used to be answered by rebuilding the engine in
/// place on the main thread while Core Audio was still tearing down its
/// default-device aggregate — the way an `AVAudioEngine` spins the main
/// thread for good, and the hourglass after a monitor or the lid. now a
/// stale or wedged capture is thrown away whole: its teardown is queued
/// behind whatever it is stuck in, and the next press builds a new capture
/// with a new queue, so a wedged queue can never wedge the next engine.
@MainActor
final class AudioRecorder: DisposableMicCapture {
    private let capture: CaptureEngine
    /// the main actor's view of whether a take is running, for the hops
    /// that land after it.
    private var isRecording = false
    /// bumped by every ending, so a start that answers after its utterance
    /// was cancelled does not count it as running.
    private var utteranceSequence: UInt64 = 0
    private var isDiscarded = false

    /// the engine reconfigured itself underneath: it has stopped, and what
    /// it is bound to is anyone's guess.
    var onConfigurationChange: (() -> Void)?
    var onCapReached: (() -> Void)?
    var onCapApproaching: (() -> Void)?

    var currentLevel: Float {
        capture.levelStorage.currentLevel
    }

    /// the device the engine's input is actually bound to, which is not
    /// necessarily the system default — the gap the press log exists to
    /// show. read on the capture's queue when it starts; this is the copy.
    var deviceDescription: MicDescription? {
        capture.boundDevice
    }

    /// one atomic, set from the audio thread (`AudioSoundFlag`).
    var hasHeardSound: Bool {
        capture.soundFlag.hasHeardSound
    }

    /// cheap: nothing is opened until the capture is started or prepared.
    init(preRollEnabled: Bool) {
        capture = CaptureEngine(preRollEnabled: preRollEnabled)

        // armed once and left armed: the storage guarantees one trip per
        // utterance.
        capture.capNotifier.setCallback { [weak self] in
            self?.handleCapReached()
        }
        capture.capApproachingNotifier.setCallback { [weak self] in
            self?.handleCapApproaching()
        }
        capture.configurationChangeNotifier.setCallback { [weak self] in
            // a capture already thrown away has nothing left to say: its
            // engine moving must not end a take on the one that replaced it.
            guard let self, !self.isDiscarded else {
                return
            }
            self.onConfigurationChange?()
        }
    }

    deinit {
        capture.discard()
    }

    func start(
        onFirstBuffer: @escaping @MainActor @Sendable (
            ContinuousClock.Instant
        ) -> Void
    ) async throws {
        utteranceSequence &+= 1
        let utterance = utteranceSequence
        try await ask { try $0.start(onFirstBuffer: onFirstBuffer) }
        if utterance == utteranceSequence {
            isRecording = true
        }
    }

    func stop() async throws -> [Float] {
        endUtterance()
        return try await ask { try $0.stop() }
    }

    func cancel() {
        endUtterance()
        capture.enqueue { $0.cancel() }
    }

    func prepare() {
        capture.enqueue { $0.prepare() }
    }

    func discard() {
        endUtterance()
        isDiscarded = true
        capture.discard()
    }

    private func endUtterance() {
        utteranceSequence &+= 1
        isRecording = false
    }

    /// `work` on the capture's queue, and its answer. the continuation is
    /// made here, on the main actor, so the work is queued before this
    /// first suspends: a cancel asked after a start always lands after it.
    /// (a nonisolated async helper would hop off the main actor first, and
    /// an esc in that gap left the mic open.)
    private func ask<Answer: Sendable>(
        _ work: @escaping @Sendable (CaptureEngine) throws -> Answer
    ) async throws -> Answer {
        try await withCheckedThrowingContinuation { continuation in
            capture.submit(work) { continuation.resume(with: $0) }
        }
    }

    private func handleCapApproaching() {
        // a hop that lands after the take is over is about a finger that
        // has already lifted; the countdown is news only while recording.
        guard isRecording else {
            return
        }

        onCapApproaching?()
    }

    private func handleCapReached() {
        // a hop that lands after stop or cancel is about a take the user has
        // already let go of, so say nothing.
        guard isRecording else {
            return
        }

        // capture is sealed; a live meter would claim otherwise. `isRecording`
        // stays true so the eventual `stop` still returns the five minutes.
        capture.levelStorage.reset()
        onCapReached?()
    }
}

/// the off-main half of one capture. the engine, its format, its storage
/// and whether a take is running are touched only on `queue`; the level,
/// the bound device and the notifiers are lock-guarded and read from
/// anywhere.
private final class CaptureEngine: @unchecked Sendable {
    private static let targetSampleRate = 16_000.0
    private static let tapDuration = 0.1
    private static let preRollDuration = 0.3
    // one utterance is capped at 5 minutes. the buffer pool is allocated up
    // front from this number, so it is resident memory, not a soft limit.
    // past it capture seals and keeps the take instead of dropping it.
    // "five minutes" is spelled out in three other places — readme's
    // `## limits`, SPEC §3, and the pill "five minutes — that's the cap" —
    // so tuning the number here means editing all three.
    private static let maximumUtteranceDuration = 5.0 * 60.0
    // said out loud before the cap arrives, so the take ending under the
    // user's finger is something they saw coming.
    private static let capWarningLead = 30.0
    private static let conversionBufferCapacity: AVAudioFrameCount = 16_384

    let levelStorage = AudioLevelStorage()
    let soundFlag = AudioSoundFlag()
    let capNotifier = AudioEventNotifier()
    let capApproachingNotifier = AudioEventNotifier()
    let configurationChangeNotifier = AudioEventNotifier()

    private let queue: DispatchQueue
    private let preRollEnabled: Bool
    private let firstBufferNotifier = AudioFirstBufferNotifier()
    private let bound = OSAllocatedUnfairLock<MicDescription?>(initialState: nil)
    private let discarded = OSAllocatedUnfairLock(initialState: false)

    // on `queue` only.
    /// the system default input when the engine was built, which is the
    /// device it was told to open.
    private var requestedDevice: AudioObjectID?
    private var engine: AVAudioEngine?
    /// says when the mic first delivers, an I/O cycle (~10 ms) after it
    /// starts. the tap hands audio over a tenth of a second at a time, so
    /// its first buffer is that late; the take itself is still the tap's.
    private var firstAudioSink: AVAudioSinkNode?
    private var inputFormat: AVAudioFormat?
    private var captureStorage: AudioCaptureStorage?
    private var isRecording = false
    /// started and not paused since: pre-roll listening, or a take.
    private var isListening = false
    /// the engine reconfigured itself for real, so it is not asked to
    /// pause again: only what it already heard is taken from it.
    private var reconfigured = false
    private var configurationObserver: NSObjectProtocol?

    init(preRollEnabled: Bool) {
        self.preRollEnabled = preRollEnabled
        queue = DispatchQueue(
            label: "\(AppIdentity.bundleID).capture",
            qos: .userInteractive
        )
    }

    var boundDevice: MicDescription? {
        bound.withLock { $0 }
    }

    private var isDiscarded: Bool {
        discarded.withLock { $0 }
    }

    // MARK: - asked from the main actor

    /// runs `work` on the queue and hands its answer back. queued before
    /// this returns. a capture that has been thrown away does nothing more
    /// and says so.
    func submit<Answer: Sendable>(
        _ work: @escaping @Sendable (CaptureEngine) throws -> Answer,
        answer: @escaping @Sendable (Result<Answer, any Error>) -> Void
    ) {
        queue.async { [self] in
            guard !isDiscarded else {
                answer(.failure(AudioRecorderError.discarded))
                return
            }
            answer(Result { try work(self) })
        }
    }

    /// fire-and-forget, in order behind whatever was asked before it.
    func enqueue(_ work: @escaping @Sendable (CaptureEngine) -> Void) {
        queue.async { [self] in
            guard !isDiscarded else {
                return
            }
            work(self)
        }
    }

    /// never asked anything again. the teardown waits behind whatever the
    /// queue is stuck in, and runs if that ever lets go.
    func discard() {
        let first = discarded.withLock { wasDiscarded in
            defer { wasDiscarded = true }
            return !wasDiscarded
        }
        guard first else {
            return
        }
        queue.async { [self] in
            tearDown()
        }
    }

    // MARK: - on the queue

    func start(
        onFirstBuffer: @escaping AudioFirstBufferNotifier.Callback
    ) throws {
        guard !isRecording else {
            throw AudioRecorderError.alreadyRecording
        }

        rebuildIfTheMicChangedRate()
        let (engine, storage) = try built()
        // armed once the storage is taking the take: with pre-roll on the
        // engine is already running, and the first audio it reports must
        // be audio the take keeps.
        storage.begin()
        levelStorage.reset()
        soundFlag.listen(
            judgingSamples: inputFormat?.commonFormat == .pcmFormatFloat32
        )
        firstBufferNotifier.arm(onFirstBuffer)

        do {
            if !engine.isRunning {
                try start(engine)
            }
            isRecording = true
            isListening = true
        } catch {
            firstBufferNotifier.disarm()
            soundFlag.stopListening()
            storage.discard()
            levelStorage.reset()
            throw error
        }
        noteBoundDevice()
    }

    func stop() throws -> [Float] {
        guard isRecording,
              let engine,
              let captureStorage,
              let inputFormat else {
            throw AudioRecorderError.notRecording
        }

        if !preRollEnabled {
            if !reconfigured {
                engine.pause()
            }
            isListening = false
        }
        firstBufferNotifier.disarm()
        soundFlag.stopListening()
        isRecording = false
        levelStorage.reset()

        let buffers = try captureStorage.finish()
        return try Self.convertToTranscriptionFormat(
            buffers,
            from: inputFormat
        )
    }

    func cancel() {
        guard isRecording else {
            return
        }

        if !preRollEnabled {
            if !reconfigured {
                engine?.pause()
            }
            isListening = false
        }
        firstBufferNotifier.disarm()
        soundFlag.stopListening()
        isRecording = false
        captureStorage?.discard()
        levelStorage.reset()
    }

    /// built ahead of a press, and with pre-roll on, listening. built
    /// means the engine made, the default mic bound and the graph prepared
    /// — the audio unit initialized, no I/O started — so with pre-roll off
    /// the mic is not live and its indicator stays dark. a mic not yet
    /// granted is left alone entirely: onboarding is the only place that
    /// asks, and the grant prepares it.
    func prepare() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return
        }
        do {
            let (engine, _) = try built()
            guard preRollEnabled,
                  !engine.isRunning else {
                return
            }
            try start(engine)
            isListening = true
            noteBoundDevice()
        } catch {
            recorderLogger.error(
                """
                audio capture failed to get ready: \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
    }

    /// the engine, its tap and its storage, built the first time they are
    /// needed and kept until the capture is thrown away.
    private func built() throws -> (AVAudioEngine, AudioCaptureStorage) {
        if let engine, let captureStorage {
            return (engine, captureStorage)
        }

        guard let device = MicDescription.defaultInputDevice() else {
            throw MicCaptureError.noInputDevice
        }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        Self.bind(inputNode, to: device)
        // read after the binding, and from the input side: that is the
        // bound device's. the output side still says the rate of the
        // default output the engine started on, and a mic running at
        // another rate (speakers at 44.1 kHz, the mic at 48) tapped at
        // that rate never sends a frame.
        let format = inputNode.inputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioRecorderError.invalidInputFormat
        }

        let storage = try Self.makeCaptureStorage(
            format: format,
            preRollEnabled: preRollEnabled,
            capNotifier: capNotifier,
            capApproachingNotifier: capApproachingNotifier
        )
        installCaptureTap(on: inputNode, storage: storage, format: format)
        attachFirstAudioSink(to: engine, format: format)
        engine.prepare()

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.engineReconfigured()
        }

        self.engine = engine
        requestedDevice = device
        inputFormat = format
        captureStorage = storage
        return (engine, storage)
    }

    /// the press records through the mic the mac says is the mic right
    /// now, told to the engine's input unit before anything reads its
    /// format. left to itself the unit can race Core Audio through a device
    /// change and settle on another input — the iphone's continuity mic
    /// after a call took the airpods — and stay there.
    private static func bind(
        _ inputNode: AVAudioInputNode,
        to device: AudioObjectID
    ) {
        guard let unit = inputNode.audioUnit else {
            recorderLogger.error("the input has no audio unit to bind the default mic to")
            return
        }
        var device = device
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        if status != noErr {
            recorderLogger.error(
                "couldn't bind the input to the default mic: \(status, privacy: .public)"
            )
        }
    }

    private func installCaptureTap(
        on inputNode: AVAudioInputNode,
        storage: AudioCaptureStorage,
        format: AVAudioFormat
    ) {
        let tapFrameCapacity = AVAudioFrameCount(
            max(1_024, ceil(format.sampleRate * Self.tapDuration))
        )

        inputNode.installTap(
            onBus: 0,
            bufferSize: tapFrameCapacity,
            format: format
        ) { [storage, levelStorage, soundFlag, firstBufferNotifier] buffer, _ in
            if storage.appendCopy(of: buffer) {
                levelStorage.update(from: buffer)
                // frames, not loudness: a device that delivers is alive,
                // even if its first frames are zeros. an empty buffer
                // delivered nothing, and the chime must not promise it did.
                // whether the frames were sound is the deadline's question.
                if buffer.frameLength > 0 {
                    soundFlag.hear(buffer.audioBufferList)
                    firstBufferNotifier.notify(at: ContinuousClock.now)
                }
            }
        }
    }

    /// called on the audio thread every I/O cycle while the engine runs,
    /// so it reads atomics until an utterance is waiting to be heard. the
    /// cycle that hears it wins a compare-exchange and pokes a dispatch
    /// source built ahead (`AudioFirstBufferNotifier`), and until one
    /// sample of the utterance is not exactly zero each cycle's samples
    /// get one vDSP pass (`AudioSoundFlag`): no lock, no allocation,
    /// nothing that can make the audio thread wait.
    private func attachFirstAudioSink(
        to engine: AVAudioEngine,
        format: AVAudioFormat
    ) {
        let sink = AVAudioSinkNode {
            [soundFlag, firstBufferNotifier] _, frameCount, buffers in
            if frameCount > 0 {
                soundFlag.hear(buffers)
                firstBufferNotifier.notify(at: ContinuousClock.now)
            }
            return noErr
        }
        engine.attach(sink)
        engine.connect(engine.inputNode, to: sink, format: format)
        firstAudioSink = sink
    }

    /// a device that won't start with the sink in the graph still starts
    /// without it: its first audio is then the tap's, a tenth of a second
    /// later, as it always was.
    private func start(_ engine: AVAudioEngine) throws {
        do {
            try engine.start()
        } catch {
            guard let sink = firstAudioSink else {
                throw error
            }
            recorderLogger.error(
                """
                the input wouldn't start with the first-audio sink, starting \
                without it: \(error.localizedDescription, privacy: .public)
                """
            )
            engine.detach(sink)
            firstAudioSink = nil
            engine.prepare()
            try engine.start()
        }
    }

    /// posted on whatever thread the engine likes, and looked at on the
    /// queue. binding the input to a device by name makes the engine let go
    /// of its own default-device aggregate, and it says so once, just after
    /// it first starts, still running on the mic it was given: that is the
    /// binding's echo, not news. an engine that stopped under a take, or
    /// moved to another device, is — and the main actor decides what that
    /// means for a take.
    private func engineReconfigured() {
        queue.async { [self] in
            guard !isDiscarded, let engine else {
                return
            }
            if engine.isRunning == isListening,
               let requestedDevice,
               boundDeviceID() == requestedDevice {
                recorderLogger.info("audio capture's engine settled on the bound mic")
                return
            }
            reconfigured = true
            recorderLogger.notice("audio capture's engine reconfigured itself")
            configurationChangeNotifier.notify()
        }
    }

    /// a stopped engine was built at the rate its mic ran at then, and
    /// says nothing when the mic changes rate under it — a call app, audio
    /// midi setup. tapped at the old rate it never sends a frame, so the
    /// press would end in no sound. one read of the mic's rate, and a
    /// fresh engine if it moved. a running one reconfigures out loud and
    /// is answered there.
    private func rebuildIfTheMicChangedRate() {
        guard engine?.isRunning == false,
              let requestedDevice,
              let builtAt = inputFormat?.sampleRate,
              let now = Self.nominalRate(of: requestedDevice),
              now != builtAt else {
            return
        }
        recorderLogger.notice(
            "the mic moved from \(builtAt, privacy: .public) Hz to \(now, privacy: .public) Hz; rebuilding the capture"
        )
        tearDown()
    }

    private static func nominalRate(of device: AudioObjectID) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &size,
            &rate
        ) == noErr, rate > 0 else {
            return nil
        }
        return rate
    }

    private func boundDeviceID() -> AudioObjectID? {
        guard let unit = engine?.inputNode.audioUnit else {
            return nil
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            &size
        ) == noErr else {
            return nil
        }
        return device
    }

    /// the device the engine's input unit actually opened, read back once
    /// it is running. one that is not the device it was told to open is
    /// the evidence of a race the binding lost.
    private func noteBoundDevice() {
        guard let device = boundDeviceID() else {
            return
        }
        let description = MicDescription(device: device)
        bound.withLock { $0 = description }

        if let requestedDevice, device != requestedDevice {
            let wanted = MicDescription(device: requestedDevice)
            recorderLogger.notice(
                """
                the input opened \(description?.name ?? "an unnamed device", privacy: .public) \
                but the default mic was \(wanted?.name ?? "an unnamed device", privacy: .public)
                """
            )
        }
    }

    private func tearDown() {
        firstBufferNotifier.disarm()
        soundFlag.stopListening()
        levelStorage.reset()
        isRecording = false
        isListening = false
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard let engine else {
            return
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        firstAudioSink = nil
        self.engine = nil
        captureStorage = nil
        inputFormat = nil
    }

    private static func makeCaptureStorage(
        format: AVAudioFormat,
        preRollEnabled: Bool,
        capNotifier: AudioEventNotifier,
        capApproachingNotifier: AudioEventNotifier
    ) throws -> AudioCaptureStorage {
        let tapFrameCapacity = AVAudioFrameCount(
            max(1_024, ceil(format.sampleRate * tapDuration))
        )
        let maximumFrameCount = Int(
            ceil(format.sampleRate * maximumUtteranceDuration)
        )
        let poolCount = Int(
            ceil(Double(maximumFrameCount) / Double(tapFrameCapacity))
        ) + 1
        let preRollFrameCapacity = preRollEnabled
            ? Int(ceil(format.sampleRate * preRollDuration))
            : 0

        return try AudioCaptureStorage(
            format: format,
            frameCapacity: tapFrameCapacity,
            poolCount: poolCount,
            maximumFrameCount: maximumFrameCount,
            capWarningLeadFrameCount: Int(
                ceil(format.sampleRate * capWarningLead)
            ),
            preRollFrameCapacity: preRollFrameCapacity,
            capNotifier: capNotifier,
            capApproachingNotifier: capApproachingNotifier
        )
    }

    private static func convertToTranscriptionFormat(
        _ buffers: [AVAudioPCMBuffer],
        from inputFormat: AVAudioFormat
    ) throws -> [Float] {
        guard !buffers.isEmpty else {
            return []
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat),
        let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: conversionBufferCapacity
        ) else {
            throw AudioRecorderError.unavailableBuffer
        }

        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let sourceFrameCount = buffers.reduce(into: 0) {
            $0 += Int($1.frameLength)
        }
        let estimatedOutputCount = Int(
            ceil(Double(sourceFrameCount) * targetSampleRate / inputFormat.sampleRate)
        )
        var samples: [Float] = []
        samples.reserveCapacity(estimatedOutputCount)

        let source = AudioConversionSource(buffers: buffers)
        var reachedEnd = false

        while !reachedEnd {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, inputStatus in
                guard let buffer = source.next() else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                inputStatus.pointee = .haveData
                return buffer
            }

            if outputBuffer.frameLength > 0 {
                guard let channel = outputBuffer.floatChannelData?[0] else {
                    throw AudioRecorderError.unavailableBuffer
                }

                samples.append(
                    contentsOf: UnsafeBufferPointer(
                        start: channel,
                        count: Int(outputBuffer.frameLength)
                    )
                )
            }

            switch status {
            case .haveData:
                break
            case .endOfStream:
                reachedEnd = true
            case .error:
                throw AudioRecorderError.conversionFailed(conversionError)
            case .inputRanDry:
                throw AudioRecorderError.conversionFailed(conversionError)
            @unknown default:
                throw AudioRecorderError.conversionFailed(conversionError)
            }
        }

        return samples
    }
}

/// one answer per utterance: the sink's or the tap's, whichever lands
/// first. `notify` is called from the audio thread every I/O cycle, so it
/// takes no lock and allocates nothing. until an utterance is armed it
/// reads one atomic and returns; the one call that wins a compare-exchange
/// on the utterance's token stores the instant and pokes a dispatch source
/// built ahead of time — once per utterance — and the main queue does the
/// rest. the instant is handed over only if its token is still the armed
/// one: a disarm and a re-arm between the audio thread and the main queue
/// drop a stale instant instead of giving it to the next utterance.
private final class AudioFirstBufferNotifier: @unchecked Sendable {
    typealias Callback = @MainActor @Sendable (
        ContinuousClock.Instant
    ) -> Void

    /// instants cross the threads as nanoseconds past this one: a word an
    /// atomic can hold, where an `Instant` is not.
    private let origin = ContinuousClock.now
    /// the token of the utterance waiting to be heard; zero when none is.
    private let waiting = Atomic<UInt64>(0)
    /// the token the audio thread heard, and when. written by the winner
    /// only, the instant before the token, so a token read is never ahead
    /// of its instant.
    private let heardToken = Atomic<UInt64>(0)
    private let heardAt = Atomic<Int64>(0)
    private let delivery: any DispatchSourceUserDataAdd

    // under `lock`: the capture's queue arms and disarms, the main queue
    // delivers. the audio thread never touches either.
    private let lock = NSLock()
    private var armed: (token: UInt64, callback: Callback)?
    private var lastToken: UInt64 = 0

    init() {
        delivery = DispatchSource.makeUserDataAddSource(queue: .main)
        delivery.setEventHandler { [weak self] in
            self?.deliver()
        }
        delivery.activate()
    }

    deinit {
        delivery.cancel()
    }

    func arm(_ callback: @escaping Callback) {
        let token = lock.withLock {
            lastToken &+= 1
            if lastToken == 0 {
                lastToken = 1
            }
            armed = (lastToken, callback)
            return lastToken
        }
        waiting.store(token, ordering: .releasing)
    }

    func disarm() {
        waiting.store(0, ordering: .releasing)
        lock.withLock {
            armed = nil
        }
    }

    /// the audio thread's half: atomics and a poke, nothing that waits.
    func notify(at instant: ContinuousClock.Instant) {
        let token = waiting.load(ordering: .relaxed)
        guard token != 0,
              waiting.compareExchange(
                  expected: token,
                  desired: 0,
                  ordering: .acquiringAndReleasing
              ).exchanged else {
            return
        }
        heardAt.store(
            Self.nanoseconds(origin.duration(to: instant)),
            ordering: .relaxed
        )
        heardToken.store(token, ordering: .releasing)
        delivery.add(data: 1)
    }

    /// the main queue's half. pokes that land together are one call, and
    /// the newest token is the only one that can still be armed.
    private func deliver() {
        let token = heardToken.load(ordering: .acquiring)
        let nanoseconds = heardAt.load(ordering: .relaxed)
        let callback: Callback? = lock.withLock {
            guard let armed, armed.token == token else {
                return nil
            }
            self.armed = nil
            return armed.callback
        }
        guard let callback else {
            return
        }
        let instant = origin + .nanoseconds(nanoseconds)
        MainActor.assumeIsolated {
            callback(instant)
        }
    }

    private static func nanoseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds &* 1_000_000_000 &+ attoseconds / 1_000_000_000
    }
}

/// something the capture says on the main actor: the cap, the warning
/// before it, the engine reconfiguring. set once and left set for the
/// capture's whole life, unlike the one-shot first-buffer notifier.
private final class AudioEventNotifier: @unchecked Sendable {
    typealias Callback = @MainActor @Sendable () -> Void

    private let lock = NSLock()
    private var callback: Callback?

    func setCallback(_ callback: Callback?) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func notify() {
        lock.lock()
        let callback = callback
        lock.unlock()

        guard let callback else {
            return
        }

        Task { @MainActor in
            callback()
        }
    }
}

private final class AudioLevelStorage: @unchecked Sendable {
    // standard speech-meter window: silence below the floor reads zero and a
    // raised voice reaches the top. dB is already perceptual — map it linearly.
    private static let minimumDecibels: Float = -50
    private static let maximumDecibels: Float = -12

    private let level = OSAllocatedUnfairLock(initialState: Float.zero)

    var currentLevel: Float {
        level.withLock { $0 }
    }

    func update(from buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0,
              let channel = buffer.floatChannelData?[0] else {
            reset()
            return
        }

        let channelMultiplier = buffer.format.isInterleaved
            ? Int(buffer.format.channelCount)
            : 1
        let sampleCount = Int(buffer.frameLength) * channelMultiplier
        var rms: Float = 0
        vDSP_rmsqv(
            channel,
            1,
            &rms,
            vDSP_Length(sampleCount)
        )

        let decibels = 20 * log10f(max(rms, Float.leastNonzeroMagnitude))
        let normalized = min(
            max(
                (decibels - Self.minimumDecibels)
                    / (Self.maximumDecibels - Self.minimumDecibels),
                0
            ),
            1
        )
        level.withLock { $0 = normalized }
    }

    func reset() {
        level.withLock { $0 = 0 }
    }
}

private final class AudioCaptureStorage: @unchecked Sendable {
    private let lock = NSLock()
    private let pool: [AVAudioPCMBuffer]
    private let maximumFrameCount: Int
    private let bytesPerFrame: Int
    private let preRollBuffer: AVAudioPCMBuffer?
    private let preRollPrefixBuffer: AVAudioPCMBuffer?
    private let capNotifier: AudioEventNotifier
    private let capApproachingNotifier: AudioEventNotifier

    private var captured: [AVAudioPCMBuffer] = []
    private var nextPoolIndex = 0
    private var utteranceFrameCount = 0
    private var preRollPrefixFrameCount = 0
    private var isAcceptingAudio = false
    private var didReachCap = false
    private var capWarning: CaptureCapWarning
    private var captureError: AudioRecorderError?
    private var ringSplicer: RingSplicer?

    init(
        format: AVAudioFormat,
        frameCapacity: AVAudioFrameCount,
        poolCount: Int,
        maximumFrameCount: Int,
        capWarningLeadFrameCount: Int,
        preRollFrameCapacity: Int,
        capNotifier: AudioEventNotifier,
        capApproachingNotifier: AudioEventNotifier
    ) throws {
        var pool: [AVAudioPCMBuffer] = []
        pool.reserveCapacity(poolCount)

        for _ in 0..<poolCount {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCapacity
            ) else {
                throw AudioRecorderError.unavailableBuffer
            }
            pool.append(buffer)
        }

        let bytesPerFrame = Int(
            format.streamDescription.pointee.mBytesPerFrame
        )
        guard bytesPerFrame > 0 else {
            throw AudioRecorderError.invalidInputFormat
        }

        let preRollBuffer: AVAudioPCMBuffer?
        let preRollPrefixBuffer: AVAudioPCMBuffer?
        let ringSplicer: RingSplicer?

        if preRollFrameCapacity > 0 {
            let capacity = AVAudioFrameCount(preRollFrameCapacity)
            guard let ringBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: capacity
            ),
            let prefixBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: capacity
            ) else {
                throw AudioRecorderError.unavailableBuffer
            }

            ringBuffer.frameLength = capacity
            prefixBuffer.frameLength = 0
            preRollBuffer = ringBuffer
            preRollPrefixBuffer = prefixBuffer
            ringSplicer = RingSplicer(capacity: preRollFrameCapacity)
        } else {
            preRollBuffer = nil
            preRollPrefixBuffer = nil
            ringSplicer = nil
        }

        self.pool = pool
        self.maximumFrameCount = maximumFrameCount
        capWarning = CaptureCapWarning(
            maximumFrameCount: maximumFrameCount,
            leadFrameCount: capWarningLeadFrameCount
        )
        self.bytesPerFrame = bytesPerFrame
        self.preRollBuffer = preRollBuffer
        self.preRollPrefixBuffer = preRollPrefixBuffer
        self.capNotifier = capNotifier
        self.capApproachingNotifier = capApproachingNotifier
        self.ringSplicer = ringSplicer
        captured.reserveCapacity(poolCount)
    }

    func begin() {
        lock.lock()
        defer { lock.unlock() }

        captured.removeAll(keepingCapacity: true)
        nextPoolIndex = 0
        utteranceFrameCount = 0
        preRollPrefixFrameCount = 0
        didReachCap = false
        capWarning.reset()
        captureError = nil

        if let ringSplicer,
           let preRollBuffer,
           let preRollPrefixBuffer {
            let plan = ringSplicer.planRead()
            preRollPrefixBuffer.frameLength =
                preRollPrefixBuffer.frameCapacity

            guard copy(
                plan,
                from: preRollBuffer,
                to: preRollPrefixBuffer
            ) else {
                preRollPrefixBuffer.frameLength = 0
                captureError = .unavailableBuffer
                isAcceptingAudio = false
                return
            }

            preRollPrefixBuffer.frameLength = AVAudioFrameCount(
                plan.frameCount
            )
            preRollPrefixFrameCount = plan.frameCount
            utteranceFrameCount = plan.frameCount
        }

        isAcceptingAudio = true
    }

    @discardableResult
    func appendCopy(of source: AVAudioPCMBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if var ringSplicer,
           let preRollBuffer {
            let plan = ringSplicer.planWrite(
                frameCount: Int(source.frameLength)
            )
            preRollBuffer.frameLength = preRollBuffer.frameCapacity

            if copy(plan, from: source, to: preRollBuffer) {
                self.ringSplicer = ringSplicer
            } else {
                ringSplicer.reset()
                self.ringSplicer = ringSplicer
                if isAcceptingAudio {
                    failCapture(with: .unavailableBuffer)
                }
            }
        }

        guard isAcceptingAudio else {
            return false
        }

        let sourceFrameCount = Int(source.frameLength)
        guard sourceFrameCount > 0 else {
            return true
        }
        guard sourceFrameCount <= maximumFrameCount - utteranceFrameCount else {
            sealAtCap()
            return false
        }
        guard nextPoolIndex < pool.count else {
            sealAtCap()
            return false
        }

        let destination = pool[nextPoolIndex]
        guard source.frameLength <= destination.frameCapacity else {
            failCapture(with: .oversizedCaptureBuffer)
            return false
        }

        destination.frameLength = source.frameLength

        guard copyFrames(
            from: source,
            sourceOffset: 0,
            to: destination,
            destinationOffset: 0,
            frameCount: sourceFrameCount
        ) else {
            failCapture(with: .unavailableBuffer)
            return false
        }

        captured.append(destination)
        nextPoolIndex += 1
        utteranceFrameCount += sourceFrameCount

        if capWarning.shouldWarn(at: utteranceFrameCount) {
            // a leaf lock again, so firing under this one is safe.
            capApproachingNotifier.notify()
        }
        return true
    }

    func finish() throws -> [AVAudioPCMBuffer] {
        lock.lock()
        defer { lock.unlock() }

        isAcceptingAudio = false

        if let captureError {
            resetUtterance()
            preRollPrefixBuffer?.frameLength = 0
            throw captureError
        }

        var result: [AVAudioPCMBuffer] = []
        result.reserveCapacity(captured.count + 1)
        if preRollPrefixFrameCount > 0,
           let preRollPrefixBuffer {
            result.append(preRollPrefixBuffer)
        }
        result.append(contentsOf: captured)

        resetUtterance()
        return result
    }

    func discard() {
        lock.lock()
        defer { lock.unlock() }

        isAcceptingAudio = false
        resetUtterance()
        preRollPrefixBuffer?.frameLength = 0
    }

    /// the cap is a ceiling, not a failure: stop taking frames but keep what
    /// was already spoken so `finish` can still hand it to transcription.
    private func sealAtCap() {
        guard !didReachCap else {
            return
        }

        didReachCap = true
        isAcceptingAudio = false
        recorderLogger.notice(
            "capture hit the utterance cap; keeping the take"
        )
        // notifier lock is a leaf, so firing under this one cannot deadlock.
        capNotifier.notify()
    }

    private func failCapture(with error: AudioRecorderError) {
        captureError = error
        isAcceptingAudio = false
    }

    private func resetUtterance() {
        captured.removeAll(keepingCapacity: true)
        nextPoolIndex = 0
        utteranceFrameCount = 0
        preRollPrefixFrameCount = 0
        didReachCap = false
        capWarning.reset()
        captureError = nil
    }

    private func copy(
        _ plan: RingWritePlan,
        from source: AVAudioPCMBuffer,
        to destination: AVAudioPCMBuffer
    ) -> Bool {
        copy(plan.first, from: source, to: destination)
            && copy(plan.second, from: source, to: destination)
    }

    private func copy(
        _ plan: RingReadPlan,
        from source: AVAudioPCMBuffer,
        to destination: AVAudioPCMBuffer
    ) -> Bool {
        copy(plan.first, from: source, to: destination)
            && copy(plan.second, from: source, to: destination)
    }

    private func copy(
        _ region: FrameCopyRegion,
        from source: AVAudioPCMBuffer,
        to destination: AVAudioPCMBuffer
    ) -> Bool {
        copyFrames(
            from: source,
            sourceOffset: region.sourceOffset,
            to: destination,
            destinationOffset: region.destinationOffset,
            frameCount: region.frameCount
        )
    }

    private func copyFrames(
        from source: AVAudioPCMBuffer,
        sourceOffset: Int,
        to destination: AVAudioPCMBuffer,
        destinationOffset: Int,
        frameCount: Int
    ) -> Bool {
        guard frameCount > 0 else {
            return true
        }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList
        )

        guard sourceBuffers.count == destinationBuffers.count else {
            return false
        }

        let sourceByteOffset = sourceOffset * bytesPerFrame
        let destinationByteOffset = destinationOffset * bytesPerFrame
        let byteCount = frameCount * bytesPerFrame

        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            let destinationBuffer = destinationBuffers[index]

            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData,
                  sourceByteOffset + byteCount
                    <= Int(sourceBuffer.mDataByteSize),
                  destinationByteOffset + byteCount
                    <= Int(destinationBuffer.mDataByteSize) else {
                return false
            }

            memcpy(
                destinationData.advanced(by: destinationByteOffset),
                sourceData.advanced(by: sourceByteOffset),
                byteCount
            )
        }

        return true
    }
}

private final class AudioConversionSource: @unchecked Sendable {
    private let buffers: [AVAudioPCMBuffer]
    private var index = 0

    init(buffers: [AVAudioPCMBuffer]) {
        self.buffers = buffers
    }

    func next() -> AVAudioPCMBuffer? {
        guard index < buffers.count else {
            return nil
        }

        defer { index += 1 }
        return buffers[index]
    }
}
