@preconcurrency import AVFoundation
import Foundation

enum Wav {
    static let sampleRate = 16_000.0

    /// 16 kHz mono 32-bit float, the format the models take, so a recording
    /// goes to disk without a single sample being rounded.
    static func write(_ samples: [Float], to url: URL) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: true
            ),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            throw FidelityError("could not make an audio buffer for \(samples.count) samples")
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress, let destination = buffer.floatChannelData?[0] else { return }
            destination.update(from: base, count: samples.count)
        }

        // the file is complete when the AVAudioFile goes out of scope.
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: true
            )
            try file.write(from: buffer)
        }
    }
}
