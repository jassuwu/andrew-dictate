import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

protocol TranscriptPolisher: Sendable {
    var isAvailable: Bool { get }

    func polish(
        _ text: String,
        protectedTerms: [String]
    ) async throws -> String
}

enum TranscriptPolishSanityGuard {
    static func acceptedOutput(
        input: String,
        candidate: String,
        protectedTerms: [String]
    ) -> String {
        let output = candidate.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !output.isEmpty, !input.isEmpty else {
            return input
        }

        let lengthRatio = Double(output.count) / Double(input.count)
        guard (0.4...1.6).contains(lengthRatio) else {
            return input
        }

        let lostProtectedTerm = protectedTerms.contains { term in
            !term.isEmpty
                && input.contains(term)
                && !output.contains(term)
        }
        guard !lostProtectedTerm else {
            return input
        }

        return output
    }
}

enum PolishResult: Equatable, Sendable {
    case success(String)
    case failure
}

enum PolishDeadline: Equatable, Sendable {
    case met
    case exceeded
}

struct TimedPolishResult: Equatable, Sendable {
    let result: PolishResult
    let deadline: PolishDeadline
}

enum CleanupPasteChoice: Equatable, Sendable {
    case raw(String)
    case polished(String)

    var text: String {
        switch self {
        case let .raw(text), let .polished(text):
            text
        }
    }
}

func cleanupPasteChoice(
    raw: String,
    polishResult: PolishResult,
    deadline: PolishDeadline
) -> CleanupPasteChoice {
    guard deadline == .met,
          case let .success(polished) = polishResult,
          polished != raw else {
        return .raw(raw)
    }
    return .polished(polished)
}

func polishWithinDeadline(
    _ text: String,
    protectedTerms: [String],
    using polisher: any TranscriptPolisher,
    deadline: ContinuousClock.Instant
) async -> TimedPolishResult {
    let relay = FirstPolishResult()
    let clock = ContinuousClock()

    guard clock.now < deadline else {
        return TimedPolishResult(
            result: .failure,
            deadline: .exceeded
        )
    }

    let polishTask = Task {
        do {
            let candidate = try await polisher.polish(
                text,
                protectedTerms: protectedTerms
            )
            let output = TranscriptPolishSanityGuard.acceptedOutput(
                input: text,
                candidate: candidate,
                protectedTerms: protectedTerms
            )
            await relay.offer(
                TimedPolishResult(
                    result: .success(output),
                    deadline: .met
                )
            )
        } catch {
            await relay.offer(
                TimedPolishResult(
                    result: .failure,
                    deadline: .met
                )
            )
        }
    }

    let timeoutTask = Task {
        do {
            try await clock.sleep(until: deadline)
            await relay.offer(
                TimedPolishResult(
                    result: .failure,
                    deadline: .exceeded
                )
            )
        } catch {
            return
        }
    }

    let result = await relay.value()
    polishTask.cancel()
    timeoutTask.cancel()
    return result
}

private actor FirstPolishResult {
    private var result: TimedPolishResult?
    private var waiters: [
        CheckedContinuation<TimedPolishResult, Never>
    ] = []

    func offer(_ result: TimedPolishResult) {
        guard self.result == nil else {
            return
        }

        self.result = result
        for waiter in waiters {
            waiter.resume(returning: result)
        }
        waiters.removeAll()
    }

    func value() async -> TimedPolishResult {
        if let result {
            return result
        }

        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

enum TranscriptPolisherError: Error {
    case unavailable
}

struct FoundationModelPolisher: TranscriptPolisher {
    static let backendName = "foundation-models"

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    func polish(
        _ text: String,
        protectedTerms: [String]
    ) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.availability == .available
            else {
                throw TranscriptPolisherError.unavailable
            }

            return try await polishWithFoundationModels(
                text,
                protectedTerms: protectedTerms
            )
        }
        #endif
        throw TranscriptPolisherError.unavailable
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private func polishWithFoundationModels(
    _ text: String,
    protectedTerms: [String]
) async throws -> String {
    let protectedWords = protectedTerms.isEmpty
        ? "{}"
        : "{\(protectedTerms.joined(separator: ", "))}"
    let instructions = """
    Correct dictated transcript text only.
    Remove filler words and false starts.
    Fix punctuation, casing, and spacing.
    NEVER add, answer, translate, or expand content.
    Preserve technical tokens, code, URLs, and numbers exactly.
    These words must appear verbatim if present: \(protectedWords)
    Return ONLY the corrected text.
    """
    let session = LanguageModelSession(instructions: instructions)
    let response = try await session.respond(
        to: """
        Correct only the dictated transcript between the delimiters.
        <transcript>
        \(text)
        </transcript>
        """
    )

    return TranscriptPolishSanityGuard.acceptedOutput(
        input: text,
        candidate: response.content,
        protectedTerms: protectedTerms
    )
}
#endif
