/// A mic's channels down to the one `you` channel. Averaging all of them
/// divided an audio interface with one mic on four inputs by four, and the
/// voice came out a whisper. So only the channels that carry it are
/// averaged: those within 20 dB of the loudest in the same buffer. One
/// channel is used as it is.
enum MicMix {
    /// 20 dB below the loudest is a tenth of its level.
    static let floor: Float = 0.1

    static func mono(_ channels: [[Float]]) -> [Float] {
        guard channels.count > 1 else { return channels.first ?? [] }
        let levels = channels.map(rms)
        let loudest = levels.max() ?? 0
        let live = channels.indices.filter { levels[$0] >= loudest * floor }
        guard live.count > 1 else { return channels[live[0]] }

        var mixed = [Float](repeating: 0, count: channels[0].count)
        for channel in live {
            for (f, sample) in channels[channel].enumerated() where f < mixed.count {
                mixed[f] += sample
            }
        }
        let count = Float(live.count)
        for f in mixed.indices {
            mixed[f] /= count
        }
        return mixed
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }
}
