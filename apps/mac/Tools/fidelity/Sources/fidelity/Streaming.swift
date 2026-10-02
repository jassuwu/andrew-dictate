@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// everything about how audio is cut into windows. starts from FluidAudio's
/// own default layout, 2 s left + 11 s chunk + 2 s right, which fills the
/// model's 15 s input exactly; the flags move it for experiments.
struct StreamingSettings {
    var chunkSeconds: Double
    var hypothesisChunkSeconds: Double
    var leftContextSeconds: Double
    var rightContextSeconds: Double
    var minContextForConfirmation: Double
    var confirmationThreshold: Double
    /// how much audio each `streamAudio` call carries, standing in for the
    /// mic tap's callback size.
    var bufferMilliseconds: Double = 100

    init() {
        let base = SlidingWindowAsrConfig.default
        chunkSeconds = base.chunkSeconds
        hypothesisChunkSeconds = base.hypothesisChunkSeconds
        leftContextSeconds = base.leftContextSeconds
        rightContextSeconds = base.rightContextSeconds
        minContextForConfirmation = base.minContextForConfirmation
        confirmationThreshold = base.confirmationThreshold
    }

    /// v2's blank token is named explicitly, as FluidAudio asks of v2 callers,
    /// rather than left to the manager to correct from the v3 default.
    var config: SlidingWindowAsrConfig {
        SlidingWindowAsrConfig(
            chunkSeconds: chunkSeconds,
            hypothesisChunkSeconds: hypothesisChunkSeconds,
            leftContextSeconds: leftContextSeconds,
            rightContextSeconds: rightContextSeconds,
            minContextForConfirmation: minContextForConfirmation,
            confirmationThreshold: confirmationThreshold,
            tdtConfig: TdtConfig(blankId: AsrModelVersion.v2.blankId)
        )
    }

    var bufferFrames: Int {
        max(1, Int(bufferMilliseconds / 1000 * Wav.sampleRate))
    }

    /// how many windows the manager runs while audio is still arriving, once
    /// `fed` samples are in: a window is cut as soon as the chunk and its
    /// right context are both buffered.
    func windowsRunLive(afterFeeding fed: Int) -> Int {
        // the same truncation to whole samples the manager applies.
        let chunk = Int(chunkSeconds * Wav.sampleRate)
        let needed = chunk + Int(rightContextSeconds * Wav.sampleRate)
        guard fed >= needed else { return 0 }
        return (fed - needed) / chunk + 1
    }

    /// the layout in the words of the call that builds it, so a later ticket
    /// can paste it.
    var swiftLiteral: String {
        """
        SlidingWindowAsrConfig(
            chunkSeconds: \(chunkSeconds),
            hypothesisChunkSeconds: \(hypothesisChunkSeconds),
            leftContextSeconds: \(leftContextSeconds),
            rightContextSeconds: \(rightContextSeconds),
            minContextForConfirmation: \(minContextForConfirmation),
            confirmationThreshold: \(confirmationThreshold),
            tdtConfig: TdtConfig(blankId: \(AsrModelVersion.v2.blankId))
        )
        """
    }
}

struct StreamingResult {
    let text: String
    /// from the last buffer handed over to the final text: what key-up waits for.
    let finalizeSeconds: Double
    /// windows that ran while audio was still arriving, not at key-up.
    let windowsRunLive: Int
    /// false if a live window never reported back, so the finalize time is
    /// not to be trusted.
    let settled: Bool
}

enum Streaming {
    /// feeds `samples` to a SlidingWindowAsrManager the way a live mic tap
    /// would: in short buffers, in order, with `finish()` at the end.
    ///
    /// the buffers go in without sleeping, but the last one only goes in once
    /// every window the earlier audio triggered has come back. on a real
    /// mic those windows run during capture, so only what the last buffer
    /// sets off is left for key-up. without the wait, the whole backlog
    /// would land in the finalize time and flatter batch.
    static func transcribe(
        _ samples: [Float],
        models: AsrModels,
        settings: StreamingSettings
    ) async throws -> StreamingResult {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Wav.sampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            throw FidelityError("could not describe 16 kHz mono float audio")
        }

        let manager = SlidingWindowAsrManager(config: settings.config)
        try await manager.loadModels(models)

        // every window that finishes announces itself on this stream.
        let windowsDone = WindowCounter()
        let updates = await manager.transcriptionUpdates
        let listening = Task {
            for await _ in updates {
                await windowsDone.add()
            }
        }
        try await manager.startStreaming()

        func buffer(_ range: Range<Int>) throws -> AVAudioPCMBuffer {
            guard
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)),
                let channel = buffer.floatChannelData?[0]
            else {
                throw FidelityError("could not make an audio buffer")
            }
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress! + range.lowerBound, count: range.count)
            }
            buffer.frameLength = AVAudioFrameCount(range.count)
            return buffer
        }

        let step = settings.bufferFrames
        let lastStart = max(0, (samples.count - 1) / step * step)

        var position = 0
        while position < lastStart {
            await manager.streamAudio(try buffer(position..<(position + step)))
            position += step
        }

        let expected = settings.windowsRunLive(afterFeeding: lastStart)
        let settled = await windowsDone.waitFor(expected, timeout: .seconds(120))

        let clock = ContinuousClock()
        let start = clock.now
        if lastStart < samples.count {
            await manager.streamAudio(try buffer(lastStart..<samples.count))
        }
        let text = try await manager.finish()
        let finalize = Compare.seconds(start.duration(to: clock.now))

        listening.cancel()
        await manager.cancel()

        return StreamingResult(
            text: text,
            finalizeSeconds: finalize,
            windowsRunLive: expected,
            settled: settled
        )
    }

    /// the manager reports each window on a stream; this counts them so the
    /// feed can wait for the ones it expects.
    private actor WindowCounter {
        private var count = 0

        func add() {
            count += 1
        }

        func waitFor(_ expected: Int, timeout: Duration) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now + timeout
            while count < expected {
                guard clock.now < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return true
        }
    }
}
