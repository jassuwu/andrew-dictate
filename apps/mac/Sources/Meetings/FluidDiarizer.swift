import FluidAudio
import Foundation
import os

/// FluidAudio's diarizer (pyannote segmentation + a speaker embedder,
/// ~13 mb) run once over the far side after the meeting ends. Each `them`
/// turn takes the speaker whose segment covers its timestamp; speakers are
/// numbered in order of first appearance, so `them 1` is whoever spoke
/// first. One voice found → turns stay plain `them`.
///
/// Anything going wrong here — models missing, inference failing — leaves the
/// turns as they were. A transcript without speaker numbers is still the
/// transcript; a transcript that never arrived because diarization threw is
/// spec §4's forbidden shape.
///
/// The models are read from disk and from nowhere else: setup fetches them
/// beside the meeting model, so the end of a meeting never waits on the
/// network. A mac that does not have them gets plain `them`.
struct FluidDiarizer: MeetingDiarizer {
    private let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "diarizer")

    /// Beside the other FluidAudio models, where FluidAudio itself would put
    /// them, so removal has one place to look.
    private static var modelFolder: URL {
        AppIdentity.sharedModelDirectory
            .appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    }

    private static var segmentationURL: URL {
        modelFolder.appendingPathComponent(ModelNames.Diarizer.segmentationFile, isDirectory: true)
    }

    private static var embeddingURL: URL {
        modelFolder.appendingPathComponent(ModelNames.Diarizer.embeddingFile, isDirectory: true)
    }

    static var isOnDisk: Bool {
        [segmentationURL, embeddingURL].allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// Fetches the models if they are not here yet: about 13 mb, for setup.
    static func fetch() async throws {
        guard !isOnDisk else { return }
        try await ModelHub.download(.diarizer, to: AppIdentity.sharedModelDirectory)
    }

    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] {
        guard turns.contains(where: { if case .them = $0.speaker { true } else { false } }),
              them.count > Int(MeetingAudioChunk.sampleRate) * 2
        else {
            return turns
        }
        guard Self.isOnDisk else {
            logger.notice("diarization skipped: its models are not on this mac")
            return turns
        }

        let segments: [TimedSpeakerSegment]
        do {
            // the models are loaded from the files, never through
            // FluidAudio's downloader, which would fetch what it found
            // missing or damaged.
            let models = try DiarizerModels.load(
                localSegmentationModel: Self.segmentationURL,
                localEmbeddingModel: Self.embeddingURL)
            // 0.7, the library default, folded two synthesized voices into
            // one on the spike; 0.5 separated them perfectly. Between, on
            // the side of finding a second speaker.
            var config = DiarizerConfig.default
            config.clusteringThreshold = 0.55
            let manager = DiarizerManager(config: config)
            manager.initialize(models: models)
            defer { manager.cleanup() }
            segments = try manager.performCompleteDiarization(them).segments
        } catch {
            logger.error("diarization skipped: \(error.localizedDescription, privacy: .public)")
            return turns
        }

        // Number speakers by first appearance, not by the model's ids.
        var numbers: [String: Int] = [:]
        for segment in segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds })
        where numbers[segment.speakerId] == nil {
            numbers[segment.speakerId] = numbers.count + 1
        }
        guard numbers.count > 1 else {
            return turns
        }

        return turns.map { turn in
            guard case .them = turn.speaker else { return turn }
            let at = turn.at.totalSeconds
            let covering = segments.first {
                Double($0.startTimeSeconds) <= at && at < Double($0.endTimeSeconds)
            } ?? segments.min {
                abs(Double($0.startTimeSeconds) - at) < abs(Double($1.startTimeSeconds) - at)
            }
            guard let covering, let number = numbers[covering.speakerId] else { return turn }
            return MeetingTurn(speaker: .them(number), at: turn.at, text: turn.text)
        }
    }
}
