import XCTest

/// The site's dictation demo lands text in an agent's prompt box. Every text
/// it can land is in one file the site reads, as what the speech model wrote
/// and what the cleaner makes of it. This reads the same file and asks the
/// real cleaner, so the page can only show what the app produces.
final class DemoPairsTests: XCTestCase {
    private struct Pairs: Decodable {
        let prompts: [Prompt]
    }

    private struct Prompt: Decodable {
        let reply: String
        let cuts: [Cut]
    }

    private struct Cut: Decodable {
        let heard: String
        let pasted: String
    }

    /// apps/mac/Tests/ → apps/site/src/demo/pairs.json
    private static let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("site/src/demo/pairs.json")

    private func pairs() throws -> Pairs {
        try JSONDecoder().decode(Pairs.self, from: Data(contentsOf: Self.file))
    }

    func testThereAreAFewPromptsAndEachCanBeCutAnywhere() throws {
        let prompts = try pairs().prompts
        XCTAssertGreaterThanOrEqual(prompts.count, 4)
        for prompt in prompts {
            // one cut a word: letting go lands the words said so far
            let words = prompt.cuts.last?.heard.split(separator: " ").count
            XCTAssertEqual(prompt.cuts.count, words, prompt.cuts.last?.heard ?? "")
            XCTAssertFalse(prompt.reply.isEmpty)
        }
    }

    func testEveryTextTheDemoLandsIsWhatTheCleanerWrites() throws {
        let cleaner = DeterministicCleaner()
        for prompt in try pairs().prompts {
            for cut in prompt.cuts {
                XCTAssertEqual(cleaner.clean(cut.heard), cut.pasted, cut.heard)
            }
        }
    }
}
