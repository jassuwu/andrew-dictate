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

    /// The tap is stereo (`stereoGlobalTapButExcludeProcesses`), and its
    /// channels come after the mic's in every buffer (002 §4).
    static let tapChannels = 2

    /// How many of a buffer's channels, from the first, are the mic's: what
    /// the mic said it has, unless the buffer carried fewer. The tap's come
    /// last, so a short buffer is short of the mic's: what is missing is
    /// missing from `you`, and the far side is never read as it. `tap` is
    /// none for a rig with the mic alone.
    static func micChannels(said: Int, carried: Int, tap: Int = tapChannels) -> Int {
        min(said, max(0, carried - tap))
    }

    /// The same for a buffer from a rig whose first buffer carried `first`
    /// channels. One like the first is read as the first was. One with the
    /// tap's channels alone is a rig whose mic went from under it: they are
    /// still the far side, and none of them is `you`. Any other change
    /// leaves which channel is whose a guess, and nil: it is not read.
    static func micChannels(said: Int, first: Int, carried: Int, tap: Int = tapChannels) -> Int? {
        if carried == first {
            return micChannels(said: said, carried: carried, tap: tap)
        }
        return tap > 0 && carried == tap ? 0 : nil
    }

    /// A buffer's flat channels, each `frames` long, down to the two
    /// sides: the first `mic` are the mic's (002 §4), mixed by `mono`, and
    /// the rest the tap's, averaged. Without the one, its side is silence as
    /// long as the other, so a chunk always has both.
    static func sides(_ channels: [[Float]], mic: Int, frames: Int) -> (you: [Float], them: [Float]) {
        let mic = min(max(0, mic), channels.count)
        let you = mic == 0 ? [Float](repeating: 0, count: frames) : mono(Array(channels[..<mic]))
        var them = [Float](repeating: 0, count: frames)
        let tap = channels[mic...]
        for channel in tap {
            for (f, sample) in channel.enumerated() where f < frames {
                them[f] += sample
            }
        }
        if tap.count > 1 {
            let count = Float(tap.count)
            for f in them.indices {
                them[f] /= count
            }
        }
        return (you, them)
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }
}
