import Foundation

/// Turns a window of recorded utterances into the numbers a latency claim can
/// be made from.
///
/// SPEC §7 has always kept per-utterance timings for debugging. A published
/// claim needs something the debug table cannot give: a distribution, over a
/// stated population, with the sample size attached. Everything here exists to
/// make the resulting sentence checkable rather than flattering.
struct TimelineSummary: Equatable, Sendable {
    /// Nearest-rank percentiles plus the observed maximum.
    ///
    /// `max` is not redundant with `p95`. On a small sample the two are the
    /// same measurement, and printing both is what makes that visible — a p95
    /// drawn from nine observations is a maximum wearing a percentile's name.
    struct Distribution: Equatable, Sendable {
        let p50: Duration
        let p95: Duration
        let max: Duration
    }

    /// How many utterances the numbers below are drawn from.
    let sampleSize: Int

    /// Utterances left out, by the reason they were left out. Kept rather than
    /// discarded: a median over the successes is only honest next to a count
    /// of the things that were not successes.
    let excluded: [UtteranceTimeline.CompletionStage: Int]

    /// key-up → inserted. The headline: the span a user actually waits, and
    /// the one SPEC §7 targets at ≤450ms.
    let keyUpToCompletion: Distribution?

    /// The stages that span decomposes into.
    let transcription: Distribution?
    let cleanup: Distribution?
    let delivery: Distribution?

    /// Only `pasteVerified` utterances count.
    ///
    /// A cancelled utterance has no completion to measure to. One left on the
    /// pasteboard did not reach the cursor, so counting it would be claiming a
    /// delivery that never happened — and it is systematically the fast case,
    /// because the slowest part of delivery is the part it skipped. Both would
    /// bend the number in our favour, which is the exact failure this ticket
    /// exists to avoid.
    init(timelines: [UtteranceTimeline]) {
        var counted: [UtteranceTimeline.Durations] = []
        var excluded: [UtteranceTimeline.CompletionStage: Int] = [:]

        for timeline in timelines {
            guard timeline.completionStage == .pasteVerified else {
                excluded[timeline.completionStage, default: 0] += 1
                continue
            }
            counted.append(timeline.durations)
        }

        sampleSize = counted.count
        self.excluded = excluded
        keyUpToCompletion = Self.distribution(of: counted.map(\.keyUpToCompletion))
        transcription = Self.distribution(of: counted.map(\.transcription))
        cleanup = Self.distribution(of: counted.map(\.cleanup))
        delivery = Self.distribution(of: counted.map(\.delivery))
    }

    /// Nearest-rank, so every published number is one that was measured.
    /// Interpolating between two observations invents a latency nobody
    /// experienced, which is a strange thing to put in a benchmark.
    private static func distribution(of durations: [Duration]) -> Distribution? {
        guard !durations.isEmpty else {
            return nil
        }

        let sorted = durations.sorted()
        return Distribution(
            p50: sorted[rank(percentile: 50, count: sorted.count)],
            p95: sorted[rank(percentile: 95, count: sorted.count)],
            max: sorted[sorted.count - 1]
        )
    }

    /// The `ceil(p/100 * n)`-th smallest, as a zero-based index.
    private static func rank(percentile: Int, count: Int) -> Int {
        let ordinal = Int(
            (Double(percentile) / 100 * Double(count)).rounded(.up)
        )
        return min(Swift.max(ordinal, 1), count) - 1
    }
}

extension TimelineSummary {
    /// The summary as a block of text, built to be pasted somewhere a claim is
    /// being argued about.
    ///
    /// Two rules shape it. The sample size sits next to the numbers, never in a
    /// header the reader can scroll past. And an empty sample says it is empty
    /// rather than rendering a row of zeroes, which would be the most
    /// flattering thing this could possibly print.
    func formatted() -> String {
        guard sampleSize > 0 else {
            return """
                no verified pastes recorded yet — nothing to summarise.
                \(conditionsLine)
                """
        }

        let rows = [
            ("key-up → inserted", keyUpToCompletion),
            ("  transcription", transcription),
            ("  cleanup", cleanup),
            ("  delivery", delivery),
        ].compactMap { label, distribution -> String? in
            guard let distribution else {
                return nil
            }
            return label.padding(toLength: 20, withPad: " ", startingAt: 0)
                + "p50 \(Self.milliseconds(distribution.p50))"
                + "  p95 \(Self.milliseconds(distribution.p95))"
                + "  max \(Self.milliseconds(distribution.max))"
        }

        return (rows + ["", conditionsLine]).joined(separator: "\n")
    }

    private var conditionsLine: String {
        let exclusions = [
            UtteranceTimeline.CompletionStage.cancelled,
            .leftOnPasteboard,
        ].compactMap { stage -> String? in
            guard let count = excluded[stage], count > 0 else {
                return nil
            }
            return "\(count) \(Self.name(of: stage))"
        }

        let tail = exclusions.isEmpty
            ? "nothing excluded"
            : "excluded: " + exclusions.joined(separator: ", ")
        return "n=\(sampleSize) verified pastes · \(tail)"
    }

    private static func name(
        of stage: UtteranceTimeline.CompletionStage
    ) -> String {
        switch stage {
        case .pasteVerified: "verified"
        case .leftOnPasteboard: "left on pasteboard"
        case .cancelled: "cancelled"
        }
    }

    private static func milliseconds(_ duration: Duration) -> String {
        String(format: "%7.1fms", duration.inMilliseconds)
    }
}

extension Duration {
    /// One conversion, shared by the summary and the per-utterance table
    /// beneath it. Two copies drifting apart would put two different numbers
    /// for the same measurement in the same paste.
    var inMilliseconds: Double {
        let components = components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

/// The machine and build a summary was measured on.
///
/// SPEC §7's targets name their conditions — "base M4, warm, p50" — and a
/// number copied out of the app without them is not comparable to anything.
/// This makes the conditions travel with the number, rather than relying on
/// whoever pasted it to remember them.
struct BenchConditions: Sendable {
    let machine: String
    let chip: String
    let system: String
    let engine: String
    let build: String

    static func current(engine: String) -> BenchConditions {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if DEBUG
        let build = "debug — NOT a publishable number, debug swift is slower"
        #else
        let build = "release"
        #endif

        return BenchConditions(
            machine: sysctl("hw.model") ?? "unknown mac",
            chip: sysctl("machdep.cpu.brand_string") ?? "unknown chip",
            system: "macOS \(version.majorVersion).\(version.minorVersion)",
            engine: engine,
            build: build
        )
    }

    func formatted() -> String {
        [
            "\(machine) · \(chip)",
            "\(system) · \(engine)",
            "build: \(build)",
        ].joined(separator: "\n")
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }
}
