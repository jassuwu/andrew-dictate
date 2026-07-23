import Accelerate
import AVFoundation
import os

enum AudioRecorderError: LocalizedError {
    case alreadyRecording
    case captureCapacityExceeded
    case conversionFailed(Error?)
    case invalidInputFormat
    case notRecording
    case unavailableBuffer

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "audio capture is already running"
        case .captureCapacityExceeded:
            "audio capture exceeded the five-minute buffer"
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
        case .unavailableBuffer:
            "an audio buffer could not be allocated"
        }
    }
}

@MainActor
final class AudioRecorder {
    private static let targetSampleRate = 16_000.0
    private static let tapDuration = 0.1
    private static let preRollDuration = 0.3
    private static let maximumUtteranceDuration = 5.0 * 60.0
    private static let conversionBufferCapacity: AVAudioFrameCount = 16_384

    private let engine: AVAudioEngine
    private let levelStorage: AudioLevelStorage
    private let firstBufferNotifier: AudioFirstBufferNotifier
    private var inputFormat: AVAudioFormat
    private var captureStorage: AudioCaptureStorage
    private var hasInstalledTap = false
    private var isRecording = false
    private var configurationChangeObserver: NSObjectProtocol?

    private(set) var isPreRollEnabled: Bool
    var onInterruption: (() -> Void)?

    var currentLevel: Float {
        levelStorage.currentLevel
    }

    init(preRollEnabled: Bool = false) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.invalidInputFormat
        }

        let levelStorage = AudioLevelStorage()
        let firstBufferNotifier = AudioFirstBufferNotifier()
        let captureStorage = try Self.makeCaptureStorage(
            format: inputFormat,
            preRollEnabled: preRollEnabled
        )

        self.engine = engine
        self.inputFormat = inputFormat
        self.captureStorage = captureStorage
        self.levelStorage = levelStorage
        self.firstBufferNotifier = firstBufferNotifier
        isPreRollEnabled = preRollEnabled

        installCaptureTap(
            storage: captureStorage,
            format: inputFormat,
            firstBufferNotifier: firstBufferNotifier
        )
        engine.prepare()

        if preRollEnabled,
           AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            try engine.start()
        }

        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleConfigurationChange()
            }
        }
    }

    func requestMicrophoneAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)

        if granted {
            print("microphone permission granted")
            do {
                try startContinuousCaptureIfNeeded()
            } catch {
                print(
                    "pre-roll audio capture failed to start: "
                        + error.localizedDescription
                )
            }
        } else {
            print("microphone permission denied")
        }

        return granted
    }

    func applyPreRoll(_ enabled: Bool) throws {
        guard enabled != isPreRollEnabled else {
            try startContinuousCaptureIfNeeded()
            return
        }

        if isRecording {
            captureStorage.discard()
            isRecording = false
            levelStorage.reset()
        }

        let previousMode = isPreRollEnabled

        do {
            try rebuildCapturePath(preRollEnabled: enabled)
        } catch {
            do {
                try rebuildCapturePath(preRollEnabled: previousMode)
            } catch {
                print(
                    "audio capture rollback failed: "
                        + error.localizedDescription
                )
            }
            throw error
        }
    }

    func start(
        onFirstBuffer: @escaping @MainActor @Sendable (
            ContinuousClock.Instant
        ) -> Void
    ) throws {
        guard !isRecording else {
            throw AudioRecorderError.alreadyRecording
        }

        firstBufferNotifier.arm(onFirstBuffer)
        captureStorage.begin()
        levelStorage.reset()

        do {
            if !engine.isRunning {
                try engine.start()
            }
            isRecording = true
        } catch {
            firstBufferNotifier.disarm()
            captureStorage.discard()
            levelStorage.reset()
            throw error
        }
    }

    func stop() throws -> [Float] {
        guard isRecording else {
            throw AudioRecorderError.notRecording
        }

        if !isPreRollEnabled {
            engine.pause()
        }
        firstBufferNotifier.disarm()
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

        if !isPreRollEnabled {
            engine.pause()
        }
        firstBufferNotifier.disarm()
        isRecording = false
        captureStorage.discard()
        levelStorage.reset()
    }

    private static func makeCaptureStorage(
        format: AVAudioFormat,
        preRollEnabled: Bool
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
            preRollFrameCapacity: preRollFrameCapacity
        )
    }

    private func installCaptureTap(
        storage: AudioCaptureStorage,
        format: AVAudioFormat,
        firstBufferNotifier: AudioFirstBufferNotifier
    ) {
        let tapFrameCapacity = AVAudioFrameCount(
            max(1_024, ceil(format.sampleRate * Self.tapDuration))
        )

        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: tapFrameCapacity,
            format: format
        ) { [storage, levelStorage, firstBufferNotifier] buffer, _ in
            if storage.appendCopy(of: buffer) {
                levelStorage.update(from: buffer)
                firstBufferNotifier.notify(at: ContinuousClock.now)
            }
        }
        hasInstalledTap = true
    }

    private func rebuildCapturePath(
        preRollEnabled: Bool
    ) throws {
        let inputNode = engine.inputNode
        let newInputFormat = inputNode.outputFormat(forBus: 0)

        guard newInputFormat.sampleRate > 0,
              newInputFormat.channelCount > 0 else {
            throw AudioRecorderError.invalidInputFormat
        }

        let newStorage = try Self.makeCaptureStorage(
            format: newInputFormat,
            preRollEnabled: preRollEnabled
        )

        engine.stop()
        if hasInstalledTap {
            inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }

        inputFormat = newInputFormat
        captureStorage = newStorage
        isPreRollEnabled = preRollEnabled
        levelStorage.reset()

        installCaptureTap(
            storage: newStorage,
            format: newInputFormat,
            firstBufferNotifier: firstBufferNotifier
        )
        engine.prepare()
        try startContinuousCaptureIfNeeded()
    }

    private func handleConfigurationChange() {
        firstBufferNotifier.disarm()
        isRecording = false
        captureStorage.discardAndClearPreRoll()
        levelStorage.reset()

        do {
            try rebuildCapturePath(preRollEnabled: isPreRollEnabled)
        } catch {
            print(
                "audio capture rebuild failed after configuration change: "
                    + error.localizedDescription
            )
        }

        onInterruption?()
    }

    private func startContinuousCaptureIfNeeded() throws {
        guard isPreRollEnabled,
              !engine.isRunning,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return
        }

        try engine.start()
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

private final class AudioFirstBufferNotifier: @unchecked Sendable {
    typealias Callback = @MainActor @Sendable (
        ContinuousClock.Instant
    ) -> Void

    private let lock = NSLock()
    private var callback: Callback?

    func arm(_ callback: @escaping Callback) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func disarm() {
        lock.lock()
        callback = nil
        lock.unlock()
    }

    func notify(at instant: ContinuousClock.Instant) {
        lock.lock()
        let callback = callback
        self.callback = nil
        lock.unlock()

        guard let callback else {
            return
        }

        Task { @MainActor in
            callback(instant)
        }
    }
}

private final class AudioLevelStorage: @unchecked Sendable {
    private static let minimumDecibels: Float = -50

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
            max((decibels - Self.minimumDecibels) / -Self.minimumDecibels, 0),
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

    private var captured: [AVAudioPCMBuffer] = []
    private var nextPoolIndex = 0
    private var utteranceFrameCount = 0
    private var preRollPrefixFrameCount = 0
    private var isAcceptingAudio = false
    private var captureError: AudioRecorderError?
    private var ringSplicer: RingSplicer?

    init(
        format: AVAudioFormat,
        frameCapacity: AVAudioFrameCount,
        poolCount: Int,
        maximumFrameCount: Int,
        preRollFrameCapacity: Int
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
        self.bytesPerFrame = bytesPerFrame
        self.preRollBuffer = preRollBuffer
        self.preRollPrefixBuffer = preRollPrefixBuffer
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
            failCapture(with: .captureCapacityExceeded)
            return false
        }
        guard nextPoolIndex < pool.count else {
            failCapture(with: .captureCapacityExceeded)
            return false
        }

        let destination = pool[nextPoolIndex]
        guard source.frameLength <= destination.frameCapacity else {
            failCapture(with: .captureCapacityExceeded)
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

    func discardAndClearPreRoll() {
        lock.lock()
        defer { lock.unlock() }

        isAcceptingAudio = false
        resetUtterance()
        preRollPrefixBuffer?.frameLength = 0
        ringSplicer?.reset()
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
