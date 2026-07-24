import Foundation
import os

struct UtteranceTimeline: Sendable {
    typealias Instant = ContinuousClock.Instant

    enum CompletionStage: String, Sendable {
        case pasteVerified
        case leftOnPasteboard
        case commandRouted
        case askAnswered
        case cancelled
    }

    struct CancellationStages: Equatable, Sendable {
        let cancelRequested: Instant
        let idle: Instant
    }

    struct Durations: Equatable, Sendable {
        let microphoneStartup: Duration
        let held: Duration
        let capturedAudio: Duration
        let transcription: Duration
        let cleanup: Duration
        let delivery: Duration
        let keyUpToCompletion: Duration
        let total: Duration
        let cancelToIdle: Duration?

        init(
            microphoneStartup: Duration,
            held: Duration,
            capturedAudio: Duration,
            transcription: Duration,
            cleanup: Duration,
            delivery: Duration,
            keyUpToCompletion: Duration,
            total: Duration,
            cancelToIdle: Duration? = nil
        ) {
            self.microphoneStartup = microphoneStartup
            self.held = held
            self.capturedAudio = capturedAudio
            self.transcription = transcription
            self.cleanup = cleanup
            self.delivery = delivery
            self.keyUpToCompletion = keyUpToCompletion
            self.total = total
            self.cancelToIdle = cancelToIdle
        }
    }

    let mode: DictationMode
    let keyDown: Instant
    let micFirstBuffer: Instant
    let keyUp: Instant
    let transcriptReady: Instant
    let cleaned: Instant
    let completionStage: CompletionStage
    let completed: Instant
    let cancellationStages: CancellationStages?

    init(
        mode: DictationMode,
        keyDown: Instant,
        micFirstBuffer: Instant,
        keyUp: Instant,
        transcriptReady: Instant,
        cleaned: Instant,
        completionStage: CompletionStage,
        completed: Instant,
        cancellationStages: CancellationStages? = nil
    ) {
        self.mode = mode
        self.keyDown = keyDown
        self.micFirstBuffer = micFirstBuffer
        self.keyUp = keyUp
        self.transcriptReady = transcriptReady
        self.cleaned = cleaned
        self.completionStage = completionStage
        self.completed = completed
        self.cancellationStages = cancellationStages
    }

    var durations: Durations {
        Durations(
            microphoneStartup: keyDown.duration(to: micFirstBuffer),
            held: keyDown.duration(to: keyUp),
            capturedAudio: micFirstBuffer.duration(to: keyUp),
            transcription: keyUp.duration(to: transcriptReady),
            cleanup: transcriptReady.duration(to: cleaned),
            delivery: cleaned.duration(to: completed),
            keyUpToCompletion: keyUp.duration(to: completed),
            total: keyDown.duration(to: completed),
            cancelToIdle: cancellationStages.map {
                $0.cancelRequested.duration(to: $0.idle)
            }
        )
    }
}

struct UtteranceTimelineBuilder {
    typealias Instant = ContinuousClock.Instant

    let id: UInt64
    let mode: DictationMode
    let keyDown: Instant
    var micFirstBuffer: Instant?
    var keyUp: Instant?
    var transcriptReady: Instant?
    var cleaned: Instant?

    func complete(
        _ completionStage: UtteranceTimeline.CompletionStage,
        at completed: Instant
    ) -> UtteranceTimeline? {
        guard let micFirstBuffer,
              let keyUp,
              let transcriptReady,
              let cleaned else {
            return nil
        }

        return UtteranceTimeline(
            mode: mode,
            keyDown: keyDown,
            micFirstBuffer: micFirstBuffer,
            keyUp: keyUp,
            transcriptReady: transcriptReady,
            cleaned: cleaned,
            completionStage: completionStage,
            completed: completed
        )
    }

    func cancelled(
        requestedAt: Instant,
        idleAt: Instant
    ) -> UtteranceTimeline {
        let effectiveMicFirstBuffer = micFirstBuffer ?? keyDown
        let effectiveKeyUp = keyUp ?? requestedAt
        let effectiveTranscriptReady = transcriptReady ?? requestedAt
        let effectiveCleaned = cleaned ?? requestedAt

        return UtteranceTimeline(
            mode: mode,
            keyDown: keyDown,
            micFirstBuffer: effectiveMicFirstBuffer,
            keyUp: effectiveKeyUp,
            transcriptReady: effectiveTranscriptReady,
            cleaned: effectiveCleaned,
            completionStage: .cancelled,
            completed: idleAt,
            cancellationStages: .init(
                cancelRequested: requestedAt,
                idle: idleAt
            )
        )
    }
}

@MainActor
final class UtteranceTimelineStore {
    private static let logger = Logger(
        subsystem: "gg.jass.dictate",
        category: "timeline"
    )

    private let capacity: Int
    private var storage: [UtteranceTimeline?]
    private var nextIndex = 0
    private var count = 0

    init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
        storage = Array(repeating: nil, count: max(1, capacity))
    }

    func append(_ timeline: UtteranceTimeline) {
        storage[nextIndex] = timeline
        nextIndex = (nextIndex + 1) % capacity
        count = min(count + 1, capacity)

        let durations = timeline.durations
        let line = [
            "mode=\(timeline.mode.rawValue)",
            "complete=\(timeline.completionStage.rawValue)",
            "mic_ms=\(Self.milliseconds(durations.microphoneStartup))",
            "held_ms=\(Self.milliseconds(durations.held))",
            "audio_ms=\(Self.milliseconds(durations.capturedAudio))",
            "stt_ms=\(Self.milliseconds(durations.transcription))",
            "clean_ms=\(Self.milliseconds(durations.cleanup))",
            "deliver_ms=\(Self.milliseconds(durations.delivery))",
            "keyup_done_ms=\(Self.milliseconds(durations.keyUpToCompletion))",
            "total_ms=\(Self.milliseconds(durations.total))",
            "cancel_idle_ms=\(Self.milliseconds(durations.cancelToIdle))",
        ].joined(separator: " ")
        Self.logger.info("\(line, privacy: .public)")
    }

    func formattedTable() -> String {
        let header = [
            "#",
            "mode",
            "complete",
            "mic ms",
            "held ms",
            "audio ms",
            "stt ms",
            "clean ms",
            "deliver ms",
            "keyup→done ms",
            "total ms",
            "cancel→idle ms",
        ].joined(separator: "\t")

        let rows = orderedTimelines.enumerated().map { offset, timeline in
            let durations = timeline.durations
            return [
                String(offset + 1),
                timeline.mode.rawValue,
                timeline.completionStage.rawValue,
                Self.milliseconds(durations.microphoneStartup),
                Self.milliseconds(durations.held),
                Self.milliseconds(durations.capturedAudio),
                Self.milliseconds(durations.transcription),
                Self.milliseconds(durations.cleanup),
                Self.milliseconds(durations.delivery),
                Self.milliseconds(durations.keyUpToCompletion),
                Self.milliseconds(durations.total),
                Self.milliseconds(durations.cancelToIdle),
            ].joined(separator: "\t")
        }

        return ([header] + rows).joined(separator: "\n")
    }

    private var orderedTimelines: [UtteranceTimeline] {
        guard count > 0 else {
            return []
        }

        let firstIndex = (nextIndex - count + capacity) % capacity
        return (0..<count).compactMap {
            storage[(firstIndex + $0) % capacity]
        }
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let components = duration.components
        let milliseconds =
            Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return String(format: "%.1f", milliseconds)
    }

    private static func milliseconds(_ duration: Duration?) -> String {
        guard let duration else {
            return "—"
        }
        return milliseconds(duration)
    }
}
