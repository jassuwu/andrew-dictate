import FluidAudio
import Foundation
import os
import Synchronization

/// FluidAudio's diarizer (pyannote segmentation + a speaker embedder,
/// ~13 mb), heard through the meeting a piece at a time. Each `them` turn
/// takes the speaker whose segment covers its timestamp; speakers are
/// numbered in order of first appearance among the turns, so `them 1` is
/// whoever spoke first. One voice found → turns stay plain `them`.
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

    func hearing() -> (any SpeakerHearing)? {
        guard Self.isOnDisk else {
            logger.notice("diarization skipped: its models are not on this mac")
            return nil
        }
        return Hearing(ear: Ear(segmentation: Self.segmentationURL, embedding: Self.embeddingURL))
    }

    /// The far side whole, heard as one piece: the split a meeting had
    /// before it was heard as it went. Nothing in the app hands a meeting
    /// over whole any more.
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] {
        guard let hearing = hearing() else { return turns }
        do {
            try await hearing.hear(them, at: .zero)
        } catch {
            logger.error("diarization skipped: \(error.localizedDescription, privacy: .public)")
            return turns
        }
        return await hearing.split(turns)
    }
}

/// One meeting's far side, heard through one `DiarizerManager`. Its speaker
/// database is what carries a voice from one piece to the next: the
/// manager hears any audio ten seconds at a time against that database, so
/// pieces cut on those ten-second edges are heard exactly as one pass over
/// the whole meeting would hear them.
///
/// The segments are kept apart from the manager, so the turns can be
/// split by what has been heard while a piece is still being heard.
private final class Hearing: SpeakerHearing {
    private let ear: Ear
    private let segments = Mutex<[SpeakerSegment]>([])

    init(ear: Ear) {
        self.ear = ear
    }

    func hear(_ piece: [Float], at: Duration) async throws {
        let found = try await ear.hear(piece, at: at)
        segments.withLock { $0 += found }
    }

    func split(_ turns: [MeetingTurn]) async -> [MeetingTurn] {
        SpeakerTurns.assign(turns, to: segments.withLock { $0 })
    }
}

/// The manager, one piece at a time, loaded on the first.
private actor Ear {
    private let segmentation: URL
    private let embedding: URL
    private var manager: DiarizerManager?

    init(segmentation: URL, embedding: URL) {
        self.segmentation = segmentation
        self.embedding = embedding
    }

    func hear(_ piece: [Float], at: Duration) throws -> [SpeakerSegment] {
        let manager = try manager ?? load()
        return try manager.performCompleteDiarization(piece, atTime: at.totalSeconds).segments.map {
            SpeakerSegment(
                speaker: $0.speakerId,
                from: .seconds(Double($0.startTimeSeconds)),
                to: .seconds(Double($0.endTimeSeconds)))
        }
    }

    private func load() throws -> DiarizerManager {
        // the models are loaded from the files, never through FluidAudio's
        // downloader, which would fetch what it found missing or damaged.
        let models = try DiarizerModels.load(
            localSegmentationModel: segmentation,
            localEmbeddingModel: embedding)
        // 0.7, the library default, folded two synthesized voices into one
        // on the spike; 0.5 separated them perfectly. Between, on the side
        // of finding a second speaker.
        var config = DiarizerConfig.default
        config.clusteringThreshold = 0.55
        let manager = DiarizerManager(config: config)
        manager.initialize(models: models)
        self.manager = manager
        return manager
    }
}
