import FluidAudio
import Foundation

enum Compare {
    /// returns true when every file came out EQUAL.
    static func run(_ arguments: [String]) async throws -> Bool {
        let files = try parseFiles(arguments)

        print("loading the Parakeet v2 models from \(Folders.parakeetV2.path)")
        let models = try await Batch.loadModels()
        let batch = try await Batch(models: models)
        print("")

        for file in files {
            let samples = try AudioConverter().resampleAudioFile(file)
            let seconds = Double(samples.count) / Wav.sampleRate

            let (text, batchSeconds) = try await timed { try await batch.transcribe(samples) }
            let words = WordDiff.words(text)
            print("\(file.lastPathComponent)  \(format(seconds)) s of audio")
            print("  batch      \(format(batchSeconds, places: 3)) s  \(words.count) words")
        }
        return true
    }

    // MARK: - arguments

    /// `--files a.wav b.wav` takes every path up to the next flag. with no
    /// `--files`, every passage-NN.wav in the recordings folder.
    private static func parseFiles(_ arguments: [String]) throws -> [URL] {
        var explicit: [URL] = []
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
            default:
                throw FidelityError("compare: unknown argument '\(argument)'")
            }
        }

        let files = explicit.isEmpty ? try recordedPassages() : explicit
        for file in files where !FileManager.default.fileExists(atPath: file.path) {
            throw FidelityError("no such file: \(file.path)")
        }
        return files
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
