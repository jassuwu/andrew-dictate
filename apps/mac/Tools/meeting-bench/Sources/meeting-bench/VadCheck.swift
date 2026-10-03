import FluidAudio
import Foundation

/// `vad-check`: where the VAD cuts, against the turns `make-audio.py` actually put there.
enum VadCheck {
    struct Truth: Decodable {
        struct Turn: Decodable {
            let side: Side
            let voice: String
            let lang: String
            let start: Double
            let end: Double
        }
        let turns: [Turn]
    }

    static func run(_ arguments: [String]) async throws {
        let options = try Options(arguments)
        let sides = try Sides.load(you: options.require("you"), them: options.require("them"))
        let truth = try JSONDecoder().decode(
            Truth.self, from: Data(contentsOf: URL(fileURLWithPath: options.require("truth"))))

        var settings = Segmenter.Settings(cap: try options.double("cap", default: 25))
        settings.minSilence = try options.double("min-silence", default: settings.minSilence)
        settings.threshold = Float(try options.double("threshold", default: Double(settings.threshold)))
        settings.negativeThreshold = max(0.01, settings.threshold - 0.15)
        let vad = try await SileroProbabilities.load()
        print("cap \(settings.cap) s, pause \(settings.minSilence) s, threshold \(settings.threshold) / \(settings.negativeThreshold)")

        for side in [Side.you, .them] {
            let stretches = try await Stretching.cut(sides.samples(side), side: side, vad: vad, settings: settings)
            let turns = truth.turns.filter { $0.side == side }
            let spoken = turns.reduce(0) { $0 + ($1.end - $1.start) }
            let found = stretches.reduce(0) { $0 + $1.seconds }

            // seconds of the synthesized speech that fall inside some stretch, and the reverse
            let covered = overlap(turns.map { ($0.start, $0.end) }, stretches.map { ($0.start, $0.end) })
            let lengths = stretches.map(\.seconds).sorted()
            let merged = stretches.filter { s in turns.filter { $0.start < s.end && $0.end > s.start }.count > 1 }.count
            let split = turns.filter { t in stretches.filter { $0.start < t.end && $0.end > t.start }.count > 1 }.count
            let hindi = turns.filter { $0.lang == "hi" }
            let hindiCovered = overlap(hindi.map { ($0.start, $0.end) }, stretches.map { ($0.start, $0.end) })
            let hindiSpoken = hindi.reduce(0) { $0 + ($1.end - $1.start) }

            print("\(side.rawValue): \(turns.count) turns, \(String(format: "%.0f", spoken)) s spoken; \(stretches.count) stretches, \(String(format: "%.0f", found)) s")
            print(String(format: "   speech inside a stretch %.1f%%, stretch seconds with no speech under them %.1f%% (pad and pauses)",
                         100 * covered / spoken, 100 * (found - covered) / found))
            if hindiSpoken > 0 {
                print(String(format: "   hindi speech inside a stretch %.1f%% of %.0f s", 100 * hindiCovered / hindiSpoken, hindiSpoken))
            }
            print(String(format: "   stretch length min %.1f, median %.1f, p90 %.1f, max %.1f s",
                         lengths.first ?? 0, lengths[lengths.count / 2], lengths[Int(0.9 * Double(lengths.count - 1))], lengths.last ?? 0))
            print("   stretches holding more than one turn: \(merged); turns cut into more than one stretch: \(split)")
        }
    }

    /// seconds that lie in both sets of intervals (each set is non-overlapping within itself).
    static func overlap(_ a: [(Double, Double)], _ b: [(Double, Double)]) -> Double {
        var total = 0.0
        for x in a {
            for y in b where y.0 < x.1 && y.1 > x.0 {
                total += min(x.1, y.1) - max(x.0, y.0)
            }
        }
        return total
    }
}
