import Foundation
import os

struct UtteranceTimeline: Sendable {
    typealias Instant = ContinuousClock.Instant

    enum CompletionStage: String, Sendable {
        case pasteVerified
        case leftOnPasteboard
        case commandRouted
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
    }

    let mode: DictationMode
    let keyDown: Instant
    let micFirstBuffer: Instant
    let keyUp: Instant
    let transcriptReady: Instant
    let cleaned: Instant
    let completionStage: CompletionStage
    let completed: Instant

    var durations: Durations {
        Durations(
            microphoneStartup: keyDown.duration(to: micFirstBuffer),
            held: keyDown.duration(to: keyUp),
            capturedAudio: micFirstBuffer.duration(to: keyUp),
            transcription: keyUp.duration(to: transcriptReady),
            cleanup: transcriptReady.duration(to: cleaned),
            delivery: cleaned.duration(to: completed),
            keyUpToCompletion: keyUp.duration(to: completed),
            total: keyDown.duration(to: completed)
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
}

@MainActor
final class UtteranceTimelineStore {
    private static let logger = Logger(
        subsystem: "gg.jass.andrew-dictate",
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
}
