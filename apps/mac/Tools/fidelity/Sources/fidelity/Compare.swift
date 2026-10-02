import FluidAudio
import Foundation

enum Compare {
    /// returns true when every file came out EQUAL.
    static func run(_ arguments: [String]) async throws -> Bool {
        let (files, settings) = try parse(arguments)

        print("loading the Parakeet v2 models from \(Folders.parakeetV2.path)")
        let models = try await Batch.loadModels()
        let batch = try await Batch(models: models)
        describe(settings)

        var equalCount = 0
        for (index, file) in files.enumerated() {
            let samples = try AudioConverter().resampleAudioFile(file)
            let seconds = Double(samples.count) / Wav.sampleRate
            print("")
            print("\(file.lastPathComponent)  \(format(seconds)) s of audio")

            if index == 0 {
                // the first pass through any CoreML graph is slower than the
                // rest. the batch path was warmed up with the app's silence;
                // give the streaming path the same courtesy before it is timed.
                _ = try await Streaming.transcribe(Array(samples.prefix(5 * 16_000)), models: models, settings: settings)
            }

            let (batchText, batchSeconds) = try await timed { try await batch.transcribe(samples) }
            let streamed = try await Streaming.transcribe(samples, models: models, settings: settings)

            let batchWords = WordDiff.words(batchText)
            let streamedWords = WordDiff.words(streamed.text)
            print("  batch      \(format(batchSeconds, places: 3)) s              \(batchWords.count) words")
            print(
                "  streaming  \(format(streamed.finalizeSeconds, places: 3)) s to finalize  "
                    + "\(streamedWords.count) words  (\(streamed.windowsRunLive) windows ran live)"
            )
            if !streamed.settled {
                print("  warning: a live window never reported back; the finalize time includes its wait")
            }

            let edits = WordDiff.edits(from: batchWords, to: streamedWords)
            let summary = WordDiff.summary(of: edits)
            if summary.isEqual {
                equalCount += 1
                print("  EQUAL")
            } else {
                print("  DIFFERENT  \(summary.removed) only in batch [-], \(summary.added) only in streaming {+}")
                for line in WordDiff.render(edits) {
                    print("    \(line)")
                }
            }
        }

        print("")
        print("\(equalCount) of \(files.count) EQUAL")
        return equalCount == files.count
    }

    // MARK: - report

    /// the settings used, in prose and as the call that builds them, so the
    /// next ticket can reuse them as they are.
    private static func describe(_ settings: StreamingSettings) {
        let window = settings.leftContextSeconds + settings.chunkSeconds + settings.rightContextSeconds
        print("")
        print("streaming: SlidingWindowAsrManager over the same Parakeet v2 models")
        print(
            "  chunk \(settings.chunkSeconds) s, left context \(settings.leftContextSeconds) s, "
                + "right context \(settings.rightContextSeconds) s  (window \(window) s of the model's 15 s)"
        )
        print(
            "  hypothesis chunk \(settings.hypothesisChunkSeconds) s, "
                + "min context for confirmation \(settings.minContextForConfirmation) s, "
                + "confirmation threshold \(settings.confirmationThreshold)"
        )
        print(
            "  fed in \(settings.bufferMilliseconds) ms buffers "
                + "(\(settings.bufferFrames) samples of 16 kHz mono float), no sleeping"
        )
        for line in settings.swiftLiteral.split(separator: "\n") {
            print("    \(line)")
        }
    }

    // MARK: - arguments

    /// `--files a.wav b.wav` takes every path up to the next flag. with no
    /// `--files`, every passage-NN.wav in the recordings folder.
    private static func parse(_ arguments: [String]) throws -> ([URL], StreamingSettings) {
        var explicit: [URL] = []
        var settings = StreamingSettings()

        func number(_ flag: String, _ remaining: inout ArraySlice<String>) throws -> Double {
            guard let text = remaining.popFirst(), let value = Double(text), value > 0 else {
                throw FidelityError("\(flag) takes a positive number")
            }
            return value
        }

        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--files":
                while let next = remaining.first, !next.hasPrefix("--") {
                    explicit.append(URL(fileURLWithPath: remaining.removeFirst()))
                }
                guard !explicit.isEmpty else {
                    throw FidelityError("--files needs at least one path")
                }
            case "--chunk":
                settings.chunkSeconds = try number(argument, &remaining)
            case "--left":
                settings.leftContextSeconds = try number(argument, &remaining)
            case "--right":
                settings.rightContextSeconds = try number(argument, &remaining)
            case "--buffer-ms":
                settings.bufferMilliseconds = try number(argument, &remaining)
            default:
                throw FidelityError("compare: unknown argument '\(argument)'")
            }
        }
        try settings.config.validate()

        let files = explicit.isEmpty ? try recordedPassages() : explicit
        for file in files where !FileManager.default.fileExists(atPath: file.path) {
            throw FidelityError("no such file: \(file.path)")
        }
        return (files, settings)
    }

    private static func recordedPassages() throws -> [URL] {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: Folders.recordings.path)) ?? []
        let passages =
            names
            .filter { $0.hasPrefix("passage-") && $0.hasSuffix(".wav") }
            .sorted()
            .map { Folders.recordings.appendingPathComponent($0) }
        guard !passages.isEmpty else {
            throw FidelityError(
                "no recordings in \(Folders.recordings.path). run `fidelity record 1`, or pass --files."
            )
        }
        return passages
    }

    // MARK: - timing

    private static func timed<T>(_ work: () async throws -> T) async throws -> (T, Double) {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await work()
        return (value, seconds(start.duration(to: clock.now)))
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func format(_ value: Double, places: Int = 1) -> String {
        String(format: "%.\(places)f", value)
    }
}
