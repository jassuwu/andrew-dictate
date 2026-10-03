import Foundation
import WhisperKit

/// Whisper reading a meeting a stretch at a time: large-v3 translating
/// into english, turbo writing it as spoken (turbo was never taught to
/// translate). Each stretch is one decode with no window of its own to
/// manage, because none is longer than the 30 s whisper reads at once.
///
/// Loaded from the folders setup downloaded the model and its tokenizer to,
/// and never from the network.
actor WhisperStretchEngine: StretchEngine {
    enum Failure: Error, LocalizedError {
        case notLoaded
        case notWhisper(MeetingModel)
        case noTokenizer(MeetingModel)

        var errorDescription: String? {
            switch self {
            case .notLoaded: "whisper was asked to decode before it had loaded"
            case .notWhisper(let model): "\(model.shortName) is not a whisper model"
            case .noTokenizer(let model): "\(model.shortName)'s tokenizer is not on this mac"
            }
        }
    }

    /// The longest stretch it is handed: comfortably inside the 30 s
    /// whisper reads at once.
    static let ceiling = Duration.seconds(25)

    /// How long a load waits for a tokenizer setup never fetched: a 2 mb
    /// file, seconds on any network that answers. A meeting has started
    /// recording by then and its words wait for the model, so this is how
    /// long they wait before the meeting says the model failed and keeps
    /// its spool. Provisional.
    static let tokenizerPatience = Duration.seconds(30)

    private let model: MeetingModel
    private var whisper: WhisperKit?

    init(model: MeetingModel) {
        self.model = model
    }

    func load() async throws {
        guard whisper == nil else { return }
        guard let variant = model.whisperVariant,
              let folder = MeetingEngines.folder(for: model),
              let tokenizerFolder = MeetingEngines.tokenizerFolder(for: model)
        else {
            throw Failure.notWhisper(model)
        }
        // WhisperKit fetches a tokenizer it cannot find or cannot read from
        // the Hugging Face Hub, in the middle of loading. Read here first.
        //
        // A mac set up before the tokenizer came down with the model has
        // the model and no tokenizer. That is fetched here, the way setup
        // would have: failing a meeting over a 2 mb file the download owed
        // it would be the wrong thing to be strict about. The tokenizer and
        // nothing else — the speaker split is fetched beside the meeting,
        // not in front of it — and for `tokenizerPatience` at most. Only
        // when it still cannot be read does the load stop.
        if (try? await AutoTokenizerWrapper.from(modelFolder: tokenizerFolder)) == nil {
            await MeetingEngines.fetchTokenizer(within: Self.tokenizerPatience)
            do {
                _ = try await AutoTokenizerWrapper.from(modelFolder: tokenizerFolder)
            } catch {
                throw Failure.noTokenizer(model)
            }
        }
        whisper = try await WhisperKit(WhisperKitConfig(
            model: variant,
            downloadBase: MeetingEngines.modelDirectory,
            modelFolder: folder.path,
            tokenizerFolder: tokenizerFolder,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false))
    }

    func text(of samples: [Float]) async throws -> String {
        guard let whisper else { throw Failure.notLoaded }
        // WhisperKit's own guards are on, at its defaults, and are left
        // there: a decode that repeats itself or is unsure of itself
        // (compression ratio 2.4, average log probability -1.0, first token
        // -1.5) is retried hotter, and the last try is used whatever it
        // scored. Its drop of a stretch judged no-speech (0.6) is on but
        // never fires in 1.1.0, which does not work out a no-speech
        // probability. What whisper makes up over room noise is let go by
        // the transcriber, which does not depend on any of this.
        var options = DecodingOptions()
        options.task = model.translatesToEnglish ? .translate : .transcribe
        options.language = nil
        options.detectLanguage = true
        options.usePrefillPrompt = true
        options.skipSpecialTokens = true
        options.temperature = 0
        // A stretch is decoded as one window, whole. With timestamps on,
        // WhisperKit moves on to the last timestamp whisper wrote and
        // decodes whatever is after it as a window of its own, padded out
        // to 30 s with silence — the input whisper makes things up on.
        // Measured on large-v3 (2026-10-03): of six sentences of 7 to 19 s,
        // cut as the cutter cuts them, half came back with a second window
        // and "you", "Thank you." or "End of Episode One" after the last
        // word, in twice the time. Without timestamps every one was a
        // single window with nothing added, and "yes." and "okay." still
        // came back.
        options.withoutTimestamps = true
        // WhisperKit skips whatever is left in the last second of a window:
        // its default `windowClipTime` is 1 s, so a stretch of a second or
        // less is never decoded at all. Measured on large-v3: "yes." (0.6 s)
        // and "okay." (0.5 s) came back empty, and came back whole with
        // this at zero. A stretch is one window, cut at speech, so there is
        // no tail of a longer recording to clip.
        options.windowClipTime = 0
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        return results
            .flatMap(\.segments)
            .map { Self.clean($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Whisper marks a change of speaker with a leading dash, from the
    /// subtitles it learned on. The speaker is already known here: it is the
    /// side the stretch came from.
    private static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("-") || t.hasPrefix("–") {
            t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return t
    }
}
