import FluidAudio
import Foundation

/// how long the engine takes to answer a take, release build, by length:
/// cold (the ANE left idle), warm (it just ran), and woken at key-down (a
/// short pass of silence, then the real take a moment later, which is what
/// the app now does). the clips are synthesized with `say`, so nobody's
/// voice is involved and anyone can make the same set.
enum Bench {
    /// the word-count buckets the press log is read by, too.
    static let buckets: [ClosedRange<Int>] = [1...5, 6...20, 21...60, 61...150]
    /// per bucket, the lengths synthesized: a spread, not one size.
    private static let lengths: [[Int]] = [
        [2, 3, 4, 5],
        [8, 12, 16, 20],
        [26, 36, 48, 60],
        [70, 95, 120, 150],
    ]
    /// the app's own key-down wake: half a second of silence.
    static let wakeSamples = 8_000

    struct Settings {
        var folder = Folders.recordings.appendingPathComponent("bench", isDirectory: true)
        var make = false
        var idleSeconds = 60.0
        var gapSeconds = 1.0
        var warmRepeats = 3
        var skipCold = false
        var decay = false
    }

    static func run(_ arguments: [String]) async throws {
        let settings = try parse(arguments)
        if settings.make {
            try synthesize(into: settings.folder)
        }
        let clips = try clips(in: settings.folder)
        guard !clips.isEmpty else {
            throw FidelityError("no bench clips in \(settings.folder.path). run `fidelity bench --make` first.")
        }

        print("loading the Parakeet v2 models from \(Folders.parakeetV2.path)")
        let models = try await Batch.loadModels()
        let batch = try await Batch(models: models)
        print("\(clips.count) clips in \(settings.folder.path)")

        var results = Results()

        // warm: the engine just ran. one pass first so the clip's own first
        // run doesn't count, then each repeat straight after the last.
        print("")
        print("warm: back to back, \(settings.warmRepeats) runs a clip")
        for clip in clips {
            _ = try await batch.transcribe(clip.samples)
            for _ in 0..<settings.warmRepeats {
                let seconds = try await timed { _ = try await batch.transcribe(clip.samples) }
                results.add(.warm, clip: clip, seconds: seconds)
            }
            let wake = try await timed { _ = try await batch.transcribe(silence) }
            results.wakes[.warm, default: []].append(wake)
        }
        results.printTable(.warm)

        if settings.decay {
            try await measureDecay(batch: batch, clips: clips, settings: settings)
        }

        guard !settings.skipCold else {
            results.printWakes()
            return
        }

        // cold, and woken at key-down, alternating per clip so the two see
        // the same machine. both start from the same idle.
        let idle = format(settings.idleSeconds, places: 0)
        print("")
        print("cold and woken at key-down: \(idle) s idle before each, \(clips.count * 2) waits")
        for (index, clip) in clips.enumerated() {
            try await Task.sleep(for: .seconds(settings.idleSeconds))
            let cold = try await timed { _ = try await batch.transcribe(clip.samples) }
            results.add(.cold, clip: clip, seconds: cold)

            try await Task.sleep(for: .seconds(settings.idleSeconds))
            let wake = try await timed { _ = try await batch.transcribe(silence) }
            results.wakes[.cold, default: []].append(wake)
            try await Task.sleep(for: .seconds(settings.gapSeconds))
            let woken = try await timed { _ = try await batch.transcribe(clip.samples) }
            results.add(.wokenAtKeyDown, clip: clip, seconds: woken)

            print(
                "  \(index + 1)/\(clips.count)  \(clip.words) words, \(format(clip.seconds)) s  "
                    + "cold \(ms(cold))  wake \(ms(wake))  woken \(ms(woken))"
            )
        }
        results.printTable(.cold)
        results.printTable(.wokenAtKeyDown)
        results.printWakes()
    }

    /// how fast the ANE forgets: one mid-length clip after a warm pass and
    /// a growing idle. the key-down wake is skipped inside the window this
    /// says is still warm.
    private static func measureDecay(batch: Batch, clips: [Clip], settings: Settings) async throws {
        guard let clip = clips.first(where: { buckets[1].contains($0.words) }) ?? clips.first else {
            return
        }
        print("")
        print("decay: \(clip.words) words, a warm pass, then idle")
        for idle in [0.0, 2, 5, 10, 20, 40] {
            var runs: [Double] = []
            for _ in 0..<3 {
                _ = try await batch.transcribe(silence)
                if idle > 0 {
                    try await Task.sleep(for: .seconds(idle))
                }
                runs.append(try await timed { _ = try await batch.transcribe(clip.samples) })
            }
            print("  idle \(format(idle, places: 0).padding(toLength: 3, withPad: " ", startingAt: 0)) s  p50 \(ms(percentile(runs, 0.5)))  runs \(runs.map(ms).joined(separator: " "))")
        }
    }

    // MARK: - the clips

    struct Clip {
        let url: URL
        let words: Int
        let samples: [Float]

        var seconds: Double {
            Double(samples.count) / Wav.sampleRate
        }
    }

    private static var silence: [Float] {
        [Float](repeating: 0, count: wakeSamples)
    }

    /// `say` into 16 kHz mono float, the shape the engine takes.
    private static func synthesize(into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let words = script.split(whereSeparator: \.isWhitespace).map(String.init)
        for count in lengths.flatMap({ $0 }) {
            // a different stretch of the script for each, so no two clips
            // are the same opening read again.
            let start = (count * 7) % max(1, words.count - count)
            let text = words[start..<(start + count)].joined(separator: " ")
            let url = folder.appendingPathComponent(String(format: "bench-%03dw.wav", count))
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", url.path, "--file-format=WAVE", "--data-format=LEF32@16000", text]
            try say.run()
            say.waitUntilExit()
            guard say.terminationStatus == 0 else {
                throw FidelityError("say failed for \(count) words")
            }
        }
        print("synthesized \(lengths.flatMap { $0 }.count) clips into \(folder.path)")
    }

    private static func clips(in folder: URL) throws -> [Clip] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return try names.sorted().compactMap { name -> Clip? in
            guard name.hasPrefix("bench-"), name.hasSuffix("w.wav"),
                  let words = Int(name.dropFirst("bench-".count).dropLast("w.wav".count)) else {
                return nil
            }
            let url = folder.appendingPathComponent(name)
            return Clip(url: url, words: words, samples: try AudioConverter().resampleAudioFile(url))
        }
    }

    /// plain prose with nothing in it worth a second look: the words only
    /// have to be words.
    private static let script = """
        the morning train was late again so we walked along the river and talked about the garden \
        the tomatoes had finally turned red after a slow start and the beans were climbing the fence \
        faster than anyone expected we agreed to build a second trellis before the weekend and to move \
        the herbs closer to the kitchen door where they would get more sun in the afternoon later that day \
        the team met to review the release plan and decided to ship the smaller fix first because it was \
        ready and tested while the larger change still needed another pass through review the build had \
        failed twice that week once because of a missing file and once because the cache was cold and \
        everyone wanted to know why the second failure had taken so long to notice someone suggested a \
        simple check that runs every hour and posts a short message when something looks wrong and the \
        idea was accepted without much debate the rest of the meeting covered hiring travel and the budget \
        for next quarter which looked tighter than last year but still allowed for two new laptops and a \
        better chair for the person who sits by the window in the evening we cooked pasta with fresh basil \
        and lemon and watched the light fade over the hills while the neighbours dog barked at nothing in \
        particular tomorrow will be busy with calls in the morning and a long drive in the afternoon so the \
        plan is to sleep early pack the car tonight and leave the house before the traffic starts to build
        """

    // MARK: - the numbers

    enum Mode: CaseIterable {
        case warm
        case cold
        case wokenAtKeyDown

        var title: String {
            switch self {
            case .warm: "warm (just ran)"
            case .cold: "cold (after idle)"
            case .wokenAtKeyDown: "woken at key-down (wake pass, then the take)"
            }
        }
    }

    struct Results {
        var times: [Mode: [Int: [Double]]] = [:]
        var wakes: [Mode: [Double]] = [:]

        mutating func add(_ mode: Mode, clip: Clip, seconds: Double) {
            let bucket = Bench.buckets.firstIndex { $0.contains(clip.words) } ?? Bench.buckets.count - 1
            times[mode, default: [:]][bucket, default: []].append(seconds)
        }

        func printTable(_ mode: Mode) {
            print("")
            print("ASR time, \(mode.title)")
            print("  words     n    p50      p90")
            for (index, bucket) in Bench.buckets.enumerated() {
                let runs = times[mode]?[index] ?? []
                guard !runs.isEmpty else { continue }
                let label = "\(bucket.lowerBound)–\(bucket.upperBound)".padding(toLength: 8, withPad: " ", startingAt: 0)
                print("  \(label)  \(String(runs.count).padding(toLength: 3, withPad: " ", startingAt: 0))  \(ms(percentile(runs, 0.5)).padding(toLength: 7, withPad: " ", startingAt: 0))  \(ms(percentile(runs, 0.9)))")
            }
        }

        func printWakes() {
            print("")
            print("the wake pass itself (\(Bench.wakeSamples / 16) ms of silence)")
            for mode in [Mode.warm, .cold] {
                guard let runs = wakes[mode], !runs.isEmpty else { continue }
                print("  \(mode == .warm ? "warm" : "cold")  n \(runs.count)  p50 \(ms(percentile(runs, 0.5)))  p90 \(ms(percentile(runs, 0.9)))")
            }
        }
    }

    /// nearest-rank: the value at or above the share asked for.
    static func percentile(_ values: [Double], _ share: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        let rank = Int((share * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    private static func ms(_ seconds: Double) -> String {
        "\(Int((seconds * 1_000).rounded())) ms"
    }

    private static func timed(_ work: () async throws -> Void) async throws -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        try await work()
        return Compare.seconds(start.duration(to: clock.now))
    }

    private static func format(_ value: Double, places: Int = 1) -> String {
        Compare.format(value, places: places)
    }

    private static func parse(_ arguments: [String]) throws -> Settings {
        var settings = Settings()
        var remaining = arguments[...]
        func number(_ flag: String) throws -> Double {
            guard let text = remaining.popFirst(), let value = Double(text), value >= 0 else {
                throw FidelityError("\(flag) takes a number")
            }
            return value
        }
        while let argument = remaining.popFirst() {
            switch argument {
            case "--make": settings.make = true
            case "--dir":
                guard let path = remaining.popFirst() else { throw FidelityError("--dir takes a folder") }
                settings.folder = URL(fileURLWithPath: path, isDirectory: true)
            case "--idle": settings.idleSeconds = try number(argument)
            case "--gap": settings.gapSeconds = try number(argument)
            case "--repeats": settings.warmRepeats = max(1, Int(try number(argument)))
            case "--warm-only": settings.skipCold = true
            case "--decay": settings.decay = true
            default: throw FidelityError("bench doesn't know '\(argument)'")
            }
        }
        return settings
    }
}
