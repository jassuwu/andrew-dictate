import Foundation

/// the level arrives already mapped linearly across the speech dB window
/// (-50…-12 dBFS), which IS the perceptual scale — so shaping here is nearly
/// identity: a small gate absorbs residual hum, and a gentle 1.15 exponent
/// keeps the low end tidy without crushing dynamics.
enum WaveLevelShaper {
    static let gate: Float = 0.05
    static let gamma: Float = 1.15

    static func shape(_ raw: Float) -> Float {
        let bounded = min(max(raw, 0), 1)
        guard bounded > gate else { return 0 }
        let x = (bounded - gate) / (1 - gate)
        return pow(x, gamma)
    }
}
