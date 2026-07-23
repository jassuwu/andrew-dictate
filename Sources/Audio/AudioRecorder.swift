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
    private static let maximumUtteranceDuration = 5.0 * 60.0
    private static let conversionBufferCapacity: AVAudioFrameCount = 16_384

    private let engine: AVAudioEngine
    private let inputFormat: AVAudioFormat
    private let captureStorage: AudioCaptureStorage
    private let levelStorage: AudioLevelStorage
    private var isRecording = false

    var currentLevel: Float {
        levelStorage.currentLevel
    }

    init() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.invalidInputFormat
        }

        let tapFrameCapacity = AVAudioFrameCount(
            max(1_024, ceil(inputFormat.sampleRate * Self.tapDuration))
        )
        let maximumFrameCount = inputFormat.sampleRate * Self.maximumUtteranceDuration
        let poolCount = Int(ceil(maximumFrameCount / Double(tapFrameCapacity))) + 1
        let captureStorage = try AudioCaptureStorage(
            format: inputFormat,
            frameCapacity: tapFrameCapacity,
            poolCount: poolCount
        )
        let levelStorage = AudioLevelStorage()

        self.engine = engine
        self.inputFormat = inputFormat
        self.captureStorage = captureStorage
        self.levelStorage = levelStorage

        inputNode.installTap(
            onBus: 0,
            bufferSize: tapFrameCapacity,
            format: inputFormat
        ) { [captureStorage, levelStorage] buffer, _ in
            captureStorage.appendCopy(of: buffer)
            levelStorage.update(from: buffer)
        }
        engine.prepare()

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if granted {
                print("microphone permission granted")
            } else {
                print("microphone permission denied")
            }
        }
    }

    func start() throws {
        guard !isRecording else {
            throw AudioRecorderError.alreadyRecording
        }

        captureStorage.begin()
        levelStorage.reset()

        do {
            try engine.start()
            isRecording = true
        } catch {
            captureStorage.discard()
            levelStorage.reset()
            throw error
        }
    }

    func stop() throws -> [Float] {
        guard isRecording else {
            throw AudioRecorderError.notRecording
        }

        engine.pause()
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

        engine.pause()
        isRecording = false
        captureStorage.discard()
        levelStorage.reset()
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
    private var captured: [AVAudioPCMBuffer] = []
    private var nextPoolIndex = 0
    private var isAcceptingAudio = false
    private var didOverflow = false

    init(
        format: AVAudioFormat,
        frameCapacity: AVAudioFrameCount,
        poolCount: Int
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

        self.pool = pool
        captured.reserveCapacity(poolCount)
    }

    func begin() {
        lock.lock()
        defer { lock.unlock() }

        captured.removeAll(keepingCapacity: true)
        nextPoolIndex = 0
        didOverflow = false
        isAcceptingAudio = true
    }

    func appendCopy(of source: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard isAcceptingAudio else {
            return
        }
        guard nextPoolIndex < pool.count else {
            didOverflow = true
            isAcceptingAudio = false
            return
        }

        let destination = pool[nextPoolIndex]
        guard source.frameLength <= destination.frameCapacity else {
            didOverflow = true
            isAcceptingAudio = false
            return
        }

        destination.frameLength = source.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList
        )

        guard sourceBuffers.count == destinationBuffers.count else {
            didOverflow = true
            isAcceptingAudio = false
            return
        }

        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffers[index].mData,
                  sourceBuffer.mDataByteSize <= destinationBuffers[index].mDataByteSize else {
                didOverflow = true
                isAcceptingAudio = false
                return
            }

            memcpy(
                destinationData,
                sourceData,
                Int(sourceBuffer.mDataByteSize)
            )
            destinationBuffers[index].mDataByteSize = sourceBuffer.mDataByteSize
        }

        captured.append(destination)
        nextPoolIndex += 1
    }

    func finish() throws -> [AVAudioPCMBuffer] {
        lock.lock()
        defer { lock.unlock() }

        isAcceptingAudio = false

        guard !didOverflow else {
            captured.removeAll(keepingCapacity: true)
            nextPoolIndex = 0
            didOverflow = false
            throw AudioRecorderError.captureCapacityExceeded
        }

        let result = captured
        captured = []
        captured.reserveCapacity(pool.count)
        nextPoolIndex = 0
        return result
    }

    func discard() {
        lock.lock()
        defer { lock.unlock() }

        isAcceptingAudio = false
        captured.removeAll(keepingCapacity: true)
        nextPoolIndex = 0
        didOverflow = false
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
