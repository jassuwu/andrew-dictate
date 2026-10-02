import FluidAudio
import Foundation

/// `live`: the same job as `decode`, but the audio arrives at wall-clock speed. every 256 ms the next
/// chunk of each side goes through the VAD; a stretch that is over is queued; one decoder takes
/// stretches in the order they were queued. nothing is simulated, so what it measures is what a
/// meeting would have felt like on this machine. `--compare offline.json` sets the real lag beside
/// what the queue simulation says from the decode times the offline run measured.
enum Live {
    private struct Job: Sendable {
        let stretch: Stretch
        let samples: [Float]
        let queuedAt: Double
    }

    static func run(_ arguments: [String]) async throws {
        let options = try Options(arguments)
        let engine = try Engine(rawValue: options.require("engine")).orThrow("unknown --engine")
        let outPath = try options.require("out")

        let hygiene = await Hygiene.begin()
        let sides = try Sides.load(you: options.require("you"), them: options.require("them"))
            .prefix(seconds: options.double("seconds"))
        print("feeding \(Int(sides.seconds)) s of each side at wall-clock speed")

        let loadStart = ContinuousClock.now
        let decoder = try await engine.load()
        let loadSeconds = (ContinuousClock.now - loadStart).seconds
        print(String(format: "%@ loaded in %.1f s", decoder.name, loadSeconds))
        let settings = try segmenterSettings(options, engine: decoder)
        let vad = try await SileroProbabilities.load()

        // warm the decoder on ten seconds of the far side, as a meeting's model would be.
        let warmStart = ContinuousClock.now
        _ = try await decoder.decode(Array(sides.them[(20 * sampleRate)..<(30 * sampleRate)]))
        let warmupSeconds = (ContinuousClock.now - warmStart).seconds
        print(String(format: "warm-up decode %.1f s (not counted)", warmupSeconds))

        var segmenters = [Segmenter(side: .you, settings: settings), Segmenter(side: .them, settings: settings)]
        let probabilities = [SileroProbabilities.makeStream(vad: vad), SileroProbabilities.makeStream(vad: vad)]
        let audio = [sides.you, sides.them]
        let (jobs, queue) = AsyncStream<Job>.makeStream()

        let clock = ContinuousClock()
        let watch = Hygiene.Watch()
        let t0 = clock.now
        func now() -> Double { (clock.now - t0).seconds }

        let worker = Task { () -> [Measured] in
            var done: [Measured] = []
            for await job in jobs {
                let started = now()
                let decoded = try? await decoder.decode(job.samples)
                let finished = now()
                var m = Measured(job.stretch, decodeSeconds: finished - started,
                                 decoded: decoded ?? Decoded(text: "(decode failed)", language: nil))
                m.queuedAt = job.queuedAt
                m.startedAt = started
                m.finishedAt = finished
                done.append(m)
            }
            return done
        }

        func enqueue(_ stretches: [Stretch]) {
            for stretch in stretches {
                let samples = Stretching.samples(of: stretch, in: audio[stretch.side == .you ? 0 : 1])
                queue.yield(Job(stretch: stretch, samples: samples, queuedAt: now()))
            }
        }

        var worstLate = 0.0
        let chunks = sides.you.count / Segmenter.chunk
        for i in 0..<chunks {
            let due = Double(i + 1) * Segmenter.chunkSeconds
            try await clock.sleep(until: t0.advanced(by: .seconds(due)))
            worstLate = max(worstLate, now() - due)
            for s in 0..<2 {
                let chunk = Array(audio[s][(i * Segmenter.chunk)..<((i + 1) * Segmenter.chunk)])
                enqueue(segmenters[s].push(try await probabilities[s].next(chunk)))
            }
        }
        for s in 0..<2 { enqueue(segmenters[s].finish(total: sides.seconds)) }
        let fedAt = now()
        queue.finish()
        let measured = await worker.value
        let drainedAt = now()
        let during = watch.stop()
        print(String(format: "audio fed by %.1f s (it is %.0f s long; the feed was never more than %.2f s late); queue empty at %.1f s",
                     fedAt, sides.seconds, worstLate, drainedAt))

        let run = RunFile(
            kind: "paced", engine: decoder.name,
            audio: [options.string("you")!, options.string("them")!], audioSeconds: sides.seconds,
            cap: settings.cap, minSilence: settings.minSilence, threshold: settings.threshold,
            date: ISO8601DateFormatter().string(from: Date()), machine: Hygiene.machine,
            hygiene: hygiene, hygieneDuring: during, modelLoadSeconds: loadSeconds,
            warmupSeconds: warmupSeconds, wallSeconds: drainedAt, stretches: measured)
        try run.write(to: outPath)
        try run.writeTranscript(to: outPath.replacingOccurrences(of: ".json", with: ".txt"))
        print("saved \(outPath)")

        let offline = try options.string("compare").map(RunFile.read)
        compare(run, offline: offline)
    }

    /// real lag on one line, and what each way of simulating it says.
    static func compare(_ run: RunFile, offline: RunFile?) {
        print("")
        print("paced run, \(run.stretches.count) stretches, \(Int(run.audioSeconds)) s of meeting")

        let lags = run.stretches.map { ($0.finishedAt ?? 0) - $0.end }.sorted()
        let measured = QueueResult.summary(lags: lags)
        let busy = run.stretches.reduce(0) { $0 + $1.decodeSeconds }
        print("".padding(toLength: 62, withPad: " ", startingAt: 0) + "  max lag  p95 lag mean lag   util")
        row("measured, wall clock, lag = finished - end", measured, utilisation: busy / run.audioSeconds)

        let own = Queueing.simulate(Simulate.items(of: run) { $0.end }, audioSeconds: run.audioSeconds)
        row("simulated, this run's decode times, available at end", (own.maxLag, own.p95Lag, own.meanLag), utilisation: own.utilisation)
        let ownLate = Queueing.simulate(Simulate.items(of: run) { $0.detectedAt }, audioSeconds: run.audioSeconds)
        row("simulated, this run's decode times, available at end + pause", (ownLate.maxLag, ownLate.p95Lag, ownLate.meanLag), utilisation: ownLate.utilisation)

        guard let offline else { return }
        // the stretches both runs cut, matched by side and time, with the decode time each measured.
        func key(_ m: Measured) -> String { "\(m.side.rawValue) \(Int((m.start * 100).rounded())) \(Int((m.end * 100).rounded()))" }
        let offlineByKey = Dictionary(offline.stretches.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        let matched = run.stretches.compactMap { m in offlineByKey[key(m)].map { (m, $0) } }
        print("   (\(matched.count) of the paced run's \(run.stretches.count) stretches are cut the same way in \(offline.stretches.count) offline ones; compared on those)")
        let thisSet = matched.map(\.0)
        let measuredMatched = QueueResult.summary(lags: thisSet.map { ($0.finishedAt ?? 0) - $0.end }.sorted())
        row("measured, wall clock, matched stretches only", measuredMatched,
            utilisation: thisSet.reduce(0) { $0 + $1.decodeSeconds } / run.audioSeconds)
        let fromOffline = matched.map { QueueItem(available: $0.0.end, end: $0.0.end, decode: $0.1.decodeSeconds) }
        let a = Queueing.simulate(fromOffline, audioSeconds: run.audioSeconds)
        row("simulated, offline run's decode times, available at end", (a.maxLag, a.p95Lag, a.meanLag), utilisation: a.utilisation)
        let fromOfflineLate = matched.map { QueueItem(available: $0.0.detectedAt, end: $0.0.end, decode: $0.1.decodeSeconds) }
        let b = Queueing.simulate(fromOfflineLate, audioSeconds: run.audioSeconds)
        row("simulated, offline run's decode times, available at end + pause", (b.maxLag, b.p95Lag, b.meanLag), utilisation: b.utilisation)
    }

    private static func row(_ title: String, _ lag: (max: Double, p95: Double, mean: Double), utilisation: Double) {
        print(title.padding(toLength: 62, withPad: " ", startingAt: 0)
            + String(format: " %7.1fs %7.1fs %7.1fs %6.2f", lag.max, lag.p95, lag.mean, utilisation))
    }
}

extension QueueResult {
    /// max, p95 and mean of lags that are already sorted.
    static func summary(lags sorted: [Double]) -> (max: Double, p95: Double, mean: Double) {
        guard !sorted.isEmpty else { return (0, 0, 0) }
        return (sorted.last!, sorted[max(0, Int((0.95 * Double(sorted.count)).rounded(.up)) - 1)],
                sorted.reduce(0, +) / Double(sorted.count))
    }
}
