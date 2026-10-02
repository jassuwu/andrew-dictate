import Accelerate
import AudioToolbox
import Synchronization

/// whether the utterance in flight has sent anything but exact zeros. a
/// real room never is exact zero; a muted, dead or virtual device can be,
/// and still deliver frames. one atomic: the capture's queue sets it
/// listening at the start and idle at the end, the audio thread looks at
/// samples only while it is listening — a vDSP pass per cycle, no lock,
/// no allocation — and the first sound settles it for the utterance.
final class AudioSoundFlag: @unchecked Sendable {
    private static let idle: UInt8 = 0
    private static let listening: UInt8 = 1
    private static let heard: UInt8 = 2

    private let phase = Atomic<UInt8>(0)

    var hasHeardSound: Bool {
        phase.load(ordering: .relaxed) == Self.heard
    }

    /// a new utterance. samples it cannot read as floats are taken on
    /// trust: only a capture that can see them calls a mic deaf.
    func listen(judgingSamples: Bool) {
        phase.store(
            judgingSamples ? Self.listening : Self.heard,
            ordering: .relaxed
        )
    }

    func stopListening() {
        phase.store(Self.idle, ordering: .relaxed)
    }

    /// the audio thread's half: one load, and while nothing has been
    /// heard, the loudest sample of each channel.
    func hear(_ buffers: UnsafePointer<AudioBufferList>) {
        guard phase.load(ordering: .relaxed) == Self.listening else {
            return
        }
        let list = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffers)
        )
        for buffer in list {
            let count = Int(buffer.mDataByteSize)
                / MemoryLayout<Float>.size
            guard count > 0, let data = buffer.mData else {
                continue
            }
            var loudest: Float = 0
            vDSP_maxmgv(
                data.assumingMemoryBound(to: Float.self),
                1,
                &loudest,
                vDSP_Length(count)
            )
            if loudest > 0 {
                _ = phase.compareExchange(
                    expected: Self.listening,
                    desired: Self.heard,
                    ordering: .relaxed
                )
                return
            }
        }
    }
}
