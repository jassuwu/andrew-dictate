import CoreML
import FluidAudio
import Foundation
import os

/// file scope: the voice is loaded from a static, and both halves of this
/// file say what went wrong with it.
private let voiceLogger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "voice")

/// Silero, FluidAudio's voice activity model, loaded once for a meeting
/// and shared by both its sides, each of which gets a detector of its own.
///
/// Loaded from disk and from nowhere else: setup fetches it beside the
/// meeting model, so no meeting waits on the network at its start. A mac
/// without it, or one it will not load on, hears speech by loudness instead
/// — said once in the log, and never a reason for a meeting to fail. A
/// meeting that finds it missing fetches it, in the background, for the
/// next one.
final class SileroVoice: Sendable {
    private let loading: Task<VadManager?, Never>

    /// Starts loading now, off the main actor, so it is usually ready by
    /// the time a side has heard its first 256 ms.
    init() {
        loading = Task.detached(priority: .userInitiated) { await Self.load() }
    }

    /// A detector for one side, in step with nothing but what it is fed.
    func detector() -> any SpeechDetector {
        SileroDetector(voice: self)
    }

    /// The loaded model, or nil when there is none to be had.
    fileprivate var manager: VadManager? {
        get async { await loading.value }
    }

    // MARK: - on disk

    /// Beside the other FluidAudio models, where FluidAudio itself would
    /// put it, so removal has one place to look.
    static var modelURL: URL {
        AppIdentity.sharedModelDirectory
            .appendingPathComponent(Repo.vad.folderName, isDirectory: true)
            .appendingPathComponent(ModelNames.VAD.sileroVadFile, isDirectory: true)
    }

    static var isOnDisk: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    /// Fetches the model if it is not here yet: about 2 mb, for setup.
    static func fetch() async throws {
        guard !isOnDisk else { return }
        try await ModelHub.download(.vad, to: AppIdentity.sharedModelDirectory)
    }

    private static func load() async -> VadManager? {
        guard isOnDisk else {
            voiceLogger.notice("the voice model is not on this mac: this meeting hears speech by loudness, and the model is fetched for the next")
            // not waited for: this meeting has already started without it.
            Task.detached(priority: .utility) {
                do {
                    try await fetch()
                } catch {
                    voiceLogger.error("the voice model did not download: \(error.localizedDescription, privacy: .public)")
                }
            }
            return nil
        }
        // FluidAudio's own loader would download the model again if it found
        // it damaged — at the start of a meeting. Loaded by hand, a damaged
        // model is a model that did not load.
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = VadConfig.default.computeUnits
            let model = try MLModel(contentsOf: modelURL, configuration: configuration)
            return VadManager(config: .default, vadModel: model)
        } catch {
            voiceLogger.error("the voice model would not load, so this meeting hears speech by loudness: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// One side of a meeting, heard by Silero.
///
/// Silero judges 4096 samples at a time, so what arrives is held until a
/// whole frame is there. Its start and end events are sample positions
/// counted from the first sample it was fed, which is what `SpeechEdge`
/// means; they pass straight through.
///
/// Fed in order and awaited, like every `SpeechDetector`: it carries
/// Silero's state from one frame to the next.
actor SileroDetector: SpeechDetector {
    private enum Ear {
        case undecided
        case silero(VadManager)
        /// Loudness, from sample `from` on: no model to be had, or the one
        /// there was failed partway.
        case loudness(LoudnessDetector, from: Int)
    }

    private let voice: SileroVoice
    private var ear = Ear.undecided
    /// Samples short of a whole frame, judged when the rest arrives.
    private var pending: [Float] = []
    private var stream = VadStreamState.initial()
    /// Samples Silero has judged.
    private var judged = 0

    /// No padding of its own: the cutter already reaches 300 ms back before
    /// speech begins, and Silero's padding would come on top of it.
    ///
    /// A pause between two sentences should end a stretch: about 0.6 s.
    /// Silero counts quiet from the end of the first quiet frame, a frame
    /// being 256 ms, so a quarter of a second here asks for two more quiet
    /// frames after that one — somewhere between half a second and three
    /// quarters of actual quiet, depending on where in its frame the talk
    /// stopped. 0.6 here would ask for a whole second.
    private static let segmentation = VadSegmentationConfig(
        minSilenceDuration: 0.25,
        speechPadding: 0)

    init(voice: SileroVoice) {
        self.voice = voice
    }

    func hear(_ samples: [Float]) async -> [SpeechEdge] {
        if case .undecided = ear {
            if let manager = await voice.manager {
                ear = .silero(manager)
            } else {
                ear = .loudness(LoudnessDetector(), from: 0)
            }
        }
        switch ear {
        case .undecided:
            return []
        case .loudness(let loudness, let from):
            return await Self.shifted(loudness.hear(samples), by: from)
        case .silero(let manager):
            pending.append(contentsOf: samples)
            return await judge(with: manager)
        }
    }

    private func judge(with manager: VadManager) async -> [SpeechEdge] {
        var edges: [SpeechEdge] = []
        while pending.count >= VadManager.chunkSize {
            let frame = Array(pending.prefix(VadManager.chunkSize))
            let result: VadStreamResult
            do {
                result = try await manager.processStreamingChunk(
                    frame, state: stream, config: Self.segmentation)
            } catch {
                voiceLogger.error("the voice model failed partway, so this side hears speech by loudness from here: \(error.localizedDescription, privacy: .public)")
                return edges + (await hearByLoudnessFromHere())
            }
            pending.removeFirst(VadManager.chunkSize)
            judged += VadManager.chunkSize
            stream = result.state
            if let event = result.event {
                edges.append(event.isStart
                    ? .began(at: event.sampleIndex)
                    : .ended(at: event.sampleIndex))
            }
        }
        return edges
    }

    /// Speech Silero had open is closed where it stopped judging, and
    /// loudness takes over from that sample with what was still waiting.
    private func hearByLoudnessFromHere() async -> [SpeechEdge] {
        let loudness = LoudnessDetector()
        ear = .loudness(loudness, from: judged)
        let closed: [SpeechEdge] = stream.triggered ? [.ended(at: judged)] : []
        let waiting = pending
        pending = []
        return closed + Self.shifted(await loudness.hear(waiting), by: judged)
    }

    private static func shifted(_ edges: [SpeechEdge], by offset: Int) -> [SpeechEdge] {
        guard offset != 0 else { return edges }
        return edges.map { edge in
            switch edge {
            case .began(let at): .began(at: at + offset)
            case .ended(let at): .ended(at: at + offset)
            }
        }
    }
}
