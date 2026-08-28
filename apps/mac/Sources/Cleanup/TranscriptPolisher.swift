import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// why cleanup can't run, in words that name the user's next move. the os
/// tells us exactly which of these it is — collapsing them all into "needs
/// macOS 26" showed a mac already on 26 a reason that wasn't true.
enum PolisherAvailability: Equatable, Sendable {
    case available
    case appleIntelligenceOff
    case modelStillDownloading
    case deviceCannotRunIt
    case osTooOld

    var explanation: String? {
        switch self {
        case .available:
            nil
        case .appleIntelligenceOff:
            "turn on Apple Intelligence in system settings to use this"
        case .modelStillDownloading:
            "apple's on-device model is still downloading — check back soon"
        case .deviceCannotRunIt:
            "this mac can't run apple's on-device model"
        case .osTooOld:
            "needs macOS 26 — apple's on-device model"
        }
    }
}

protocol TranscriptPolisher: Sendable {
    var availability: PolisherAvailability { get }

    func polish(
        _ text: String,
        protectedTerms: [String]
    ) async throws -> String
}

extension TranscriptPolisher {
    var isAvailable: Bool { availability == .available }
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

/// why "always" could not keep its promise. a transcript the model read and
/// left alone is not a shortfall — it had nothing to add, which is an answer.
enum PolishShortfall: Equatable, Sendable {
    case none
    case timedOut
    case failed
}

/// only "always" promises polish. "off" promises nothing and "on" promises
/// speed — falling back to raw is that mode working, not failing, so it stays
/// silent.
func polishShortfall(
    mode: CleanupMode,
    polishResult: PolishResult,
    deadline: PolishDeadline
) -> PolishShortfall {
    guard mode == .always else {
        return .none
    }
    guard deadline == .met else {
        return .timedOut
    }
    guard case .success = polishResult else {
        return .failed
    }
    return .none
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

    var availability: PolisherAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.appleIntelligenceNotEnabled):
                return .appleIntelligenceOff
            case .unavailable(.modelNotReady):
                return .modelStillDownloading
            case .unavailable(.deviceNotEligible):
                return .deviceCannotRunIt
            case .unavailable:
                return .deviceCannotRunIt
            }
        }
        #endif
        return .osTooOld
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
