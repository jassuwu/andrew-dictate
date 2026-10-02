import XCTest

/// the learner sits beside the word diff and the mishearing scan: the text
/// we inserted, what you made of it, and the swaps you made before — in,
/// and out a dictionary entry or nothing.
final class CorrectionLearnerTests: XCTestCase {
    // MARK: - sounds like

    /// the mishearings the ticket was written for: a name the engine turned
    /// into words it knows, a domain spelled as it sounds, an acronym said
    /// as a name.
    func testMishearingsSoundAlike() {
        XCTAssertTrue(SoundAlike.soundsAlike("Android dictates", "Andrew Tate's"))
        XCTAssertTrue(SoundAlike.soundsAlike("jaz.gg", "jass.gg"))
        XCTAssertTrue(SoundAlike.soundsAlike("jason", "JSON"))
        XCTAssertTrue(SoundAlike.soundsAlike("cloud code", "Claude Code"))
    }

    /// a different word that means much the same is you choosing it.
    func testSynonymsAndChangedMindsDoNotSoundAlike() {
        XCTAssertFalse(SoundAlike.soundsAlike("big", "large"))
        XCTAssertFalse(SoundAlike.soundsAlike("ship", "release"))
        XCTAssertFalse(SoundAlike.soundsAlike("today", "tomorrow"))
    }
}
