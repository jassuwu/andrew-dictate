import AVFoundation
import Foundation

/// A stretch of a spool, both sides, in order. The two are the same length,
/// but for a spool with one channel, which has no far side: its `them` is
/// empty.
typealias SpoolBlock = (you: [Float], them: [Float])

extension SpoolAudioFile {
    /// The spool a block of `frames` at a time, each read only when it is
    /// asked for: for what hears a whole spool more slowly than the disk
    /// reads it — the transcriber, reading a meeting again — and awaits
    /// each block before it wants the next. `readBlocks` cannot be awaited
    /// across, and reading ahead would have the whole meeting waiting in
    /// memory. A file that will not open, or a read that fails, ends the
    /// stream with its error.
    static func blocks(_ url: URL, frames: Int = 16_000) -> AsyncThrowingStream<SpoolBlock, any Error> {
        let reader = BlockReader(url: url, frames: frames)
        return AsyncThrowingStream(unfolding: { try reader.next() })
    }
}

/// The file, opened on the first block asked for and read from there on.
/// Asked by one reader at a time — a stream's blocks are — and locked
/// anyway.
private final class BlockReader: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let frames: AVAudioFrameCount
    private var file: AVAudioFile?
    private var buffer: AVAudioPCMBuffer?

    init(url: URL, frames: Int) {
        self.url = url
        self.frames = AVAudioFrameCount(max(1, frames))
    }

    func next() throws -> SpoolBlock? {
        try lock.withLock {
            if file == nil {
                file = try AVAudioFile(
                    forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            guard let file, file.framePosition < file.length else { return nil }
            if buffer == nil {
                buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
            }
            guard let buffer else { return nil }
            try file.read(into: buffer, frameCount: frames)
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData else { return nil }
            let stereo = file.processingFormat.channelCount > 1
            return (
                Array(UnsafeBufferPointer(start: channels[0], count: count)),
                stereo ? Array(UnsafeBufferPointer(start: channels[1], count: count)) : [])
        }
    }
}
