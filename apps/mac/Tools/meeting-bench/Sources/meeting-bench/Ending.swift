import FluidAudio
import Foundation

/// `ending`: what `MeetingCoordinator` does between stop and the file, one step at a time.
///
/// in the app's order: the transcriber's last pass decodes what is left in its buffer (3), then the
/// model is let go, then `finish` reads the whole spool back (1) and hands the far side to the
/// diarizer (2). the numbers keep the plan's numbering, so the table reads 1, 2, 3.
///
/// run it under `/usr/bin/time -l` for the whole run's peak memory. the tool also prints the
/// process's peak after each step, so a step that raised it can be told from one that did not.
enum Ending {
    static func run(_ arguments: [String]) async throws {
        let options = try Options(arguments, flags: ["no-whisper"])
        let spool = URL(fileURLWithPath: try options.require("spool"))
        let tailURL = URL(fileURLWithPath: try options.require("tail"))
        let skipWhisper = options.has("no-whisper")

        _ = await Hygiene.begin()
        let watch = Hygiene.Watch()
        func peaks(_ after: String) {
            print("   after \(after): resident now \(gigabytes(currentResidentBytes())), peak so far \(gigabytes(peakResidentBytes()))")
        }
        let bytes = (try FileManager.default.attributesOfItem(atPath: spool.path)[.size] as? Int) ?? 0
        print("spool \(spool.lastPathComponent), \(gigabytes(bytes)) on disk")
        peaks("start")

        // 3: the last stretch at stop, 20 seconds, with the model loaded and warm.
        var tailSeconds: Double?
        if !skipWhisper {
            let tail = try readMono(tailURL)
            let loadStart = ContinuousClock.now
            var decoder: (any StretchDecoder)? = try await Engine.whisperLargeV3.load()
            print(String(format: "whisper large-v3 loaded in %.1f s (not a step: the app loads it when the meeting starts)",
                         (ContinuousClock.now - loadStart).seconds))
            let warmStart = ContinuousClock.now
            _ = try await decoder!.decode(tail)
            print(String(format: "warm-up decode of the tail %.2f s (not counted: the model has been decoding all meeting)",
                         (ContinuousClock.now - warmStart).seconds))
            peaks("model loaded and warm")

            let t = ContinuousClock.now
            let decoded = try await decoder!.decode(tail)
            tailSeconds = (ContinuousClock.now - t).seconds
            print(String(format: "step 3, decode of a %.0f s tail: %.2f s   language %@",
                         Double(tail.count) / Double(sampleRate), tailSeconds!, (decoded.language ?? "-") as NSString))
            print("   text: \(decoded.text)")
            decoder = nil  // the transcriber sets `whisper = nil` after its last pass
            peaks("step 3")
        }

        // 1: read the whole spool back.
        let readStart = ContinuousClock.now
        let audio = try SpoolRead.read(spool)
        let readSeconds = (ContinuousClock.now - readStart).seconds
        print(String(format: "step 1, read the spool back: %.2f s   (%.0f s of audio, %d + %d samples)",
                     readSeconds, Double(audio.them.count) / Double(sampleRate), audio.you.count, audio.them.count))
        peaks("step 1")

        // 2: the speaker split on `them`, as FluidDiarizer.split does it.
        let splitStart = ContinuousClock.now
        let models = try await DiarizerModels.download(to: diarizerDirectory)
        let loaded = ContinuousClock.now
        var config = DiarizerConfig.default
        config.clusteringThreshold = 0.55
        let manager = DiarizerManager(config: config)
        manager.initialize(models: models)
        defer { manager.cleanup() }
        let ready = ContinuousClock.now
        let segments = try manager.performCompleteDiarization(audio.them).segments
        let done = ContinuousClock.now
        let splitSeconds = (done - splitStart).seconds
        let speakers = Set(segments.map(\.speakerId)).count
        print(String(format: "step 2, speaker split: %.2f s   (models %.2f s, manager %.2f s, diarization %.2f s; %d segments, %d speakers)",
                     splitSeconds, (loaded - splitStart).seconds, (ready - loaded).seconds, (done - ready).seconds,
                     segments.count, speakers))
        peaks("step 2")

        _ = watch.stop()
        let total = readSeconds + splitSeconds + (tailSeconds ?? 0)
        print(String(format: "\nSUMMARY step 1 read %.2f s | step 2 split %.2f s | step 3 tail %@ | sum %.2f s | process peak %@",
                     readSeconds, splitSeconds, tailSeconds.map { String(format: "%.2f s", $0) } ?? "skipped", total,
                     gigabytes(peakResidentBytes())))
    }

    /// FluidDiarizer.modelDirectory
    static var diarizerDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/diarizer", isDirectory: true)
    }
}
