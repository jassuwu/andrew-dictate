import FluidAudio
import Foundation
import WhisperKit

/// what a stretch decodes to.
struct Decoded: Sendable {
    let text: String
    /// the language whisper detected; parakeet does not say.
    let language: String?
}

protocol StretchDecoder: Sendable {
    var name: String { get }
    /// the longest stretch the plan would hand it, in seconds.
    var defaultCap: Double { get }
    func decode(_ samples: [Float]) async throws -> Decoded
}

enum Engine: String, CaseIterable {
    case whisperLargeV3 = "whisper-large-v3"
    case whisperTurbo = "whisper-turbo"
    case parakeetV3 = "parakeet-v3"
    case parakeetV2 = "parakeet-v2"

    /// loads it from the folders the app keeps; parakeet downloads on first use, as the app does.
    func load() async throws -> any StretchDecoder {
        switch self {
        case .whisperLargeV3: try await WhisperDecoder.load(variant: "openai_whisper-large-v3", translate: true)
        case .whisperTurbo: try await WhisperDecoder.load(variant: "openai_whisper-large-v3-v20240930_turbo", translate: false)
        case .parakeetV3: try await ParakeetDecoder.load(.v3)
        case .parakeetV2: try await ParakeetDecoder.load(.v2)
        }
    }
}

/// WhisperKit the way `WhisperMeetingTranscriber` loads and calls it.
final class WhisperDecoder: StretchDecoder, @unchecked Sendable {
    let name: String
    let defaultCap = 25.0
    private let whisper: WhisperKit
    private let translate: Bool

    private init(name: String, whisper: WhisperKit, translate: Bool) {
        self.name = name
        self.whisper = whisper
        self.translate = translate
    }

    /// the same base folder `MeetingEngines` uses: FluidAudio's, then `whisperkit`.
    static func modelBase() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/whisperkit", isDirectory: true)
    }

    static func load(variant: String, translate: Bool) async throws -> WhisperDecoder {
        let base = modelBase()
        let folder = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("TextDecoder.mlmodelc").path) else {
            throw BenchError("\(variant) is not on this mac (\(folder.path)); this tool does not download whisper")
        }
        let whisper = try await WhisperKit(WhisperKitConfig(
            model: variant,
            downloadBase: base,
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false))
        return WhisperDecoder(name: variant, whisper: whisper, translate: translate)
    }

    /// WhisperMeetingTranscriber.decodingOptions(), as it is today.
    private func options() -> DecodingOptions {
        var options = DecodingOptions()
        options.task = translate ? .translate : .transcribe
        options.language = nil
        options.detectLanguage = true
        options.usePrefillPrompt = true
        options.skipSpecialTokens = true
        options.withoutTimestamps = false
        options.temperature = 0
        return options
    }

    func decode(_ samples: [Float]) async throws -> Decoded {
        var options = options()
        // the app turns on the vad chunker for a window over 30 s; a stretch is under it.
        if samples.count > 30 * sampleRate { options.chunkingStrategy = .vad }
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        let text = results
            .flatMap(\.segments)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return Decoded(text: text, language: results.first?.language)
    }
}

/// FluidAudio's AsrManager the way `ParakeetEngine` loads and calls it.
final class ParakeetDecoder: StretchDecoder, @unchecked Sendable {
    let name: String
    let defaultCap = 15.0
    private let manager: AsrManager
    private let layers: Int

    private init(name: String, manager: AsrManager, layers: Int) {
        self.name = name
        self.manager = manager
        self.layers = layers
    }

    static func load(_ version: AsrModelVersion) async throws -> ParakeetDecoder {
        let directory = try await AsrModels.download(version: version)
        let models = try await AsrModels.load(from: directory, version: version)
        let manager = AsrManager(config: .default, models: models)
        let layers = await manager.decoderLayerCount
        var state = TdtDecoderState.make(decoderLayers: layers)
        // the app's warm-up: a second of silence.
        _ = try await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
        return ParakeetDecoder(name: "parakeet-\(version == .v3 ? "v3" : "v2")", manager: manager, layers: layers)
    }

    func decode(_ samples: [Float]) async throws -> Decoded {
        var state = TdtDecoderState.make(decoderLayers: layers)
        let result = try await manager.transcribe(samples, decoderState: &state)
        return Decoded(text: result.text, language: nil)
    }
}
