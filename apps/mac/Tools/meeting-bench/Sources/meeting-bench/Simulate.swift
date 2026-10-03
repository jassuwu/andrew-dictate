import Foundation

/// one stretch as the queue sees it.
struct QueueItem {
    let available: Double
    let end: Double
    let decode: Double
}

struct QueueResult {
    var count = 0
    var maxLag = 0.0
    var p95Lag = 0.0
    var meanLag = 0.0
    /// seconds of decoding per second of meeting.
    var utilisation = 0.0
    var decodeSeconds = 0.0
    var maxWaiting = 0
    /// how many stretches arrived to an idle decoder.
    var idleArrivals = 0
    var lastIdleArrivalAt = 0.0
    /// when the decoder finishes the last stretch, minus the end of the audio.
    var drainAfterEnd = 0.0
    var lags: [(end: Double, lag: Double)] = []

    /// whether the backlog is bounded: the decoder is not asked for more than a second of work per
    /// second, and it still catches up (an arrival finds it idle) in the last fifth of the meeting.
    func bounded(audioSeconds: Double) -> Bool {
        utilisation < 1 && lastIdleArrivalAt >= audioSeconds * 0.8
    }
}

enum Queueing {
    /// one decoder, one queue, both sides in it, served in order of availability.
    static func simulate(_ items: [QueueItem], audioSeconds: Double) -> QueueResult {
        let ordered = items.sorted { ($0.available, $0.end) < ($1.available, $1.end) }
        var result = QueueResult()
        var free = 0.0
        var starts: [Double] = []
        var finishes: [Double] = []
        for item in ordered {
            let start = max(free, item.available)
            if start == item.available {
                result.idleArrivals += 1
                result.lastIdleArrivalAt = item.available
            }
            free = start + item.decode
            starts.append(start)
            finishes.append(free)
            result.lags.append((item.end, free - item.end))
            result.decodeSeconds += item.decode
            result.count += 1
        }

        // queue depth: at each arrival, the earlier stretches whose decode had not started yet.
        for (i, item) in ordered.enumerated() {
            let waiting = (0..<i).filter { starts[$0] > item.available }.count
            result.maxWaiting = max(result.maxWaiting, waiting)
        }

        let sorted = result.lags.map(\.lag).sorted()
        guard !sorted.isEmpty else { return result }
        (result.maxLag, result.p95Lag, result.meanLag) = QueueResult.summary(lags: sorted)
        result.utilisation = result.decodeSeconds / audioSeconds
        result.drainAfterEnd = max(0, (finishes.last ?? 0) - audioSeconds)
        return result
    }
}

enum Simulate {
    static func items(of run: RunFile, availableAt: (Measured) -> Double) -> [QueueItem] {
        run.stretches.map { QueueItem(available: availableAt($0), end: $0.end, decode: $0.decodeSeconds) }
    }

    /// `simulate run.json...`: the queue, from the decode times each run measured.
    static func run(_ arguments: [String]) throws {
        guard !arguments.isEmpty else { throw BenchError("simulate needs one or more run files") }
        for path in arguments {
            let run = try RunFile.read(path)
            print("== \(path)")
            print("\(run.engine), \(run.stretches.count) stretches, \(Int(run.audioSeconds)) s of meeting, "
                + "cap \(Int(run.cap)) s, pause \(run.minSilence) s, load at start \(String(format: "%.2f", run.hygiene.loadAverageAtStart))"
                + (run.hygiene.quietAtStart ? "" : " (NOT QUIET at start)"))
            let atEnd = Queueing.simulate(items(of: run) { $0.end }, audioSeconds: run.audioSeconds)
            report("available at its end (the plan's definition)", atEnd, audioSeconds: run.audioSeconds)
            let afterPause = Queueing.simulate(items(of: run) { $0.detectedAt }, audioSeconds: run.audioSeconds)
            report("available when the VAD knows it is over (end + pause)", afterPause, audioSeconds: run.audioSeconds)
            lagByWindow(atEnd, audioSeconds: run.audioSeconds)
            print("")
        }
    }

    static func report(_ title: String, _ r: QueueResult, audioSeconds: Double) {
        print("-- \(title)")
        print(String(format: "   max lag %.1f s   p95 lag %.1f s   mean lag %.1f s", r.maxLag, r.p95Lag, r.meanLag))
        print(String(format: "   decode %.0f s of %.0f s of meeting: utilisation %.2f", r.decodeSeconds, audioSeconds, r.utilisation))
        print(String(format: "   most stretches waiting at once %d; arrived to an idle decoder %d of %d times, last at %.0f s; backlog after the audio ends %.1f s",
                     r.maxWaiting, r.idleArrivals, r.count, r.lastIdleArrivalAt, r.drainAfterEnd))
        print("   queue grows without bound: " + (r.bounded(audioSeconds: audioSeconds) ? "no" : "YES"))
    }

    /// lag by five minutes of meeting, to see a climb if there is one.
    static func lagByWindow(_ r: QueueResult, audioSeconds: Double) {
        print("-- lag by five minutes of meeting (stretch end time): mean / max")
        var window = 0.0
        while window < audioSeconds {
            let inside = r.lags.filter { $0.end >= window && $0.end < window + 300 }.map(\.lag)
            if !inside.isEmpty {
                print(String(format: "   %4.0f to %4.0f s: %5.1f / %5.1f   (%d stretches)", window, window + 300,
                             inside.reduce(0, +) / Double(inside.count), inside.max()!, inside.count))
            }
            window += 300
        }
    }
}
