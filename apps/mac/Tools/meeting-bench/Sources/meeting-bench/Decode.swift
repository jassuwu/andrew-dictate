import FluidAudio
import Foundation

/// one stretch and what decoding it cost.
struct Measured: Codable, Sendable {
    let side: Side
    let start: Double
    let end: Double
    let detectedAt: Double
    var decodeSeconds: Double
    var language: String?
    var text: String
    /// paced run only, seconds on the wall clock since the audio began to be fed: when the stretch
    /// was queued, when the decoder picked it up, when it finished.
    var queuedAt: Double?
    var startedAt: Double?
    var finishedAt: Double?

    init(_ stretch: Stretch, decodeSeconds: Double, decoded: Decoded) {
        side = stretch.side
        start = stretch.start
        end = stretch.end
        detectedAt = stretch.detectedAt
        self.decodeSeconds = decodeSeconds
        language = decoded.language
        text = decoded.text
    }
}

/// everything a run measured, saved so `simulate` and the report can be redone without decoding again.
struct RunFile: Codable {
    var kind: String
    var engine: String
    var audio: [String]
    var audioSeconds: Double
    var cap: Double
    var minSilence: Double
    var threshold: Float
    var date: String
    var machine: String
    var hygiene: Hygiene.Start
    var hygieneDuring: Hygiene.During?
    var modelLoadSeconds: Double
    var warmupSeconds: Double
    var wallSeconds: Double
    var stretches: [Measured]

    static func read(_ path: String) throws -> RunFile {
        try JSONDecoder().decode(RunFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    func write(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: URL(fileURLWithPath: path))
    }

    /// the transcript each side produced, in time order, for reading by eye.
    func writeTranscript(to path: String) throws {
        func clock(_ s: Double) -> String { String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60) }
        let lines = stretches.sorted { ($0.start, $0.side.rawValue) < ($1.start, $1.side.rawValue) }.map {
            "\($0.side.rawValue.padding(toLength: 4, withPad: " ", startingAt: 0)) "
                + "\(clock($0.start))-\(clock($0.end)) [\($0.language ?? "-")] \($0.text)"
        }
        try lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

func segmenterSettings(_ options: Options, engine: any StretchDecoder) throws -> Segmenter.Settings {
    var settings = Segmenter.Settings(cap: try options.double("cap", default: engine.defaultCap))
    settings.minSilence = try options.double("min-silence", default: settings.minSilence)
    settings.threshold = Float(try options.double("threshold", default: Double(settings.threshold)))
    settings.negativeThreshold = max(0.01, settings.threshold - 0.15)
    return settings
}

/// `decode`: cut each side with the VAD, decode every stretch once, one decoder, one after another.
enum Decode {
    static func run(_ arguments: [String]) async throws {
        let options = try Options(arguments)
        let engine = try Engine(rawValue: options.require("engine")).orThrow("unknown --engine")
        let outPath = try options.require("out")

        let hygiene = await Hygiene.begin()
        let sides = try Sides.load(you: options.require("you"), them: options.require("them"))
            .prefix(seconds: options.double("seconds", default: .infinity))
        print("audio: \(Int(sides.seconds)) s per side")

        let loadStart = ContinuousClock.now
        let decoder = try await engine.load()
        let loadSeconds = (ContinuousClock.now - loadStart).seconds
        print(String(format: "%@ loaded in %.1f s", decoder.name, loadSeconds))

        let settings = try segmenterSettings(options, engine: decoder)
        let vad = try await SileroProbabilities.load()
        var stretches: [Stretch] = []
        for side in [Side.you, .them] {
            let cut = try await Stretching.cut(sides.samples(side), side: side, vad: vad, settings: settings)
            let seconds = cut.reduce(0) { $0 + $1.seconds }
            print(String(format: "%@: %d stretches, %.0f s of speech, longest %.1f s", side.rawValue, cut.count, seconds, cut.map(\.seconds).max() ?? 0))
            stretches += cut
        }
        stretches.sort { ($0.end, $0.side.rawValue) < ($1.end, $1.side.rawValue) }
        guard let first = stretches.first else { throw BenchError("the VAD found no speech") }

        // the first decode of a loaded model is not the steady one; the app's model has been decoding
        // all meeting. warm it on the first stretch and keep that time apart.
        let warmStart = ContinuousClock.now
        _ = try await decoder.decode(Stretching.samples(of: first, in: sides.samples(first.side)))
        let warmupSeconds = (ContinuousClock.now - warmStart).seconds
        print(String(format: "warm-up decode %.1f s (not counted)", warmupSeconds))

        let watch = Hygiene.Watch()
        let began = ContinuousClock.now
        var measured: [Measured] = []
        for (index, stretch) in stretches.enumerated() {
            let samples = Stretching.samples(of: stretch, in: sides.samples(stretch.side))
            let t = ContinuousClock.now
            let decoded = try await decoder.decode(samples)
            let seconds = (ContinuousClock.now - t).seconds
            measured.append(Measured(stretch, decodeSeconds: seconds, decoded: decoded))
            if (index + 1) % 20 == 0 || index + 1 == stretches.count {
                let spent = (ContinuousClock.now - began).seconds
                print(String(format: "%d of %d stretches, %.0f s spent, about %.0f s to go", index + 1, stretches.count,
                             spent, spent / Double(index + 1) * Double(stretches.count - index - 1)))
            }
        }
        let wall = (ContinuousClock.now - began).seconds
        let during = watch.stop()

        let run = RunFile(
            kind: "offline", engine: decoder.name,
            audio: [options.string("you")!, options.string("them")!], audioSeconds: sides.seconds,
            cap: settings.cap, minSilence: settings.minSilence, threshold: settings.threshold,
            date: ISO8601DateFormatter().string(from: Date()), machine: Hygiene.machine,
            hygiene: hygiene, hygieneDuring: during, modelLoadSeconds: loadSeconds,
            warmupSeconds: warmupSeconds, wallSeconds: wall, stretches: measured)
        try run.write(to: outPath)
        try run.writeTranscript(to: outPath.replacingOccurrences(of: ".json", with: ".txt"))
        print("saved \(outPath)")
        try Simulate.run([outPath])
    }
}

extension Optional {
    func orThrow(_ message: String) throws -> Wrapped {
        guard let self else { throw BenchError(message) }
        return self
    }
}
