import Foundation
import Needle

/// Whistle's engine (Vendor/Needle): one model for the whole process, and
/// not safe to call from two places at once. This actor is its only
/// caller, so dictation and a meeting that both picked whistle share the
/// one model and take turns; each turn is milliseconds.
actor WhistleRuntime {
    static let shared = WhistleRuntime()

    enum Failure: Error, LocalizedError {
        case notLoaded
        case load(String)
        case transcribe(String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notLoaded: "whistle was asked to transcribe before it had loaded"
            case .load(let reason): "whistle didn't load: \(reason)"
            case .transcribe(let reason): "whistle didn't transcribe: \(reason)"
            case .unreadable: "whistle answered with something that isn't its json"
            }
        }
    }

    /// The most audio it reads in one call.
    static let longest = Duration.seconds(30)

    /// The model's bytes. The engine reads them where they are rather than
    /// copying them, so they are never let go: a model, once loaded, stays
    /// loaded until the app quits, which is the engine's own rule too.
    private var model: UnsafeMutableRawBufferPointer?

    /// Room for the answer: a transcript is capped at 320 tokens, and the
    /// engine cuts an answer too long for its buffer without saying so.
    private static let answerCapacity = 64 * 1024

    func load() throws {
        guard model == nil else { return }
        let data = try Data(contentsOf: ModelFiles.whistleFile, options: .mappedIfSafe)
        let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: data.count, alignment: 64)
        data.copyBytes(to: bytes)
        let result = needle_load(
            bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
            UInt64(bytes.count))
        guard result >= 0 else {
            bytes.deallocate()
            throw Failure.load(Self.lastError)
        }
        model = bytes
    }

    /// At most `longest` of 16 kHz mono, as text: empty for silence.
    func text(of samples: [Float]) throws -> String {
        guard model != nil else { throw Failure.notLoaded }
        var answer = [CChar](repeating: 0, count: Self.answerCapacity)
        let tokens = samples.withUnsafeBufferPointer { pcm in
            answer.withUnsafeMutableBufferPointer { out in
                // no language: it tells which of its seven it hears.
                needle_transcribe(
                    pcm.baseAddress, Int32(pcm.count), nil, nil, 0,
                    out.baseAddress, Int32(out.count))
            }
        }
        guard tokens >= 0 else { throw Failure.transcribe(Self.lastError) }
        let json = answer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let text = object["text"] as? String else {
            throw Failure.unreadable
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var lastError: String {
        needle_last_error().map { String(cString: $0) } ?? "no reason given"
    }
}

/// Whistle, for either job: a meeting hands it a stretch at a time, and
/// dictation a take, cut at quiet into pieces it reads in one call. The
/// model itself is `WhistleRuntime`'s, shared.
final class WhistleModel: StretchEngine, LoadedSpeechModel {
    /// The longest stretch a meeting hands it, inside the 30 s it reads.
    static let ceiling = Duration.seconds(25)

    func load() async throws {
        try await WhistleRuntime.shared.load()
    }

    func text(of samples: [Float]) async throws -> String {
        try await WhistleRuntime.shared.text(of: samples)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        var words: [String] = []
        for piece in QuietSplit.pieces(of: samples, longest: Self.ceiling) {
            let text = try await text(of: piece)
            if !text.isEmpty {
                words.append(text)
            }
        }
        return words.joined(separator: " ")
    }
}
