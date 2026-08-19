import XCTest

/// the whole path, not just the parser: an address has to survive
/// capitalisation and punctuation finishing too.
final class SpokenEmailTests: XCTestCase {
    private func cleaned(_ input: String) -> String {
        DeterministicCleaner(entries: []).clean(input)
    }

    func testSpokenDotBecomesAnAddress() {
        XCTAssertEqual(cleaned("jass at jass dot gg"), "jass@jass.gg.")
        XCTAssertEqual(
            cleaned("jazz at gmail dot com"),
            "jazz@gmail.com."
        )
    }

    /// the speech model often renders a spoken "dot" as a real period, and
    /// shouts the tld: "jass at jass dot gg" arrives as "jass at jass. GG".
    func testPeriodAndShoutedTLDStillBecomeAnAddress() {
        XCTAssertEqual(cleaned("jazz at jazz. GG"), "jazz@jazz.gg.")
        XCTAssertEqual(
            cleaned("send it to jazz at jazz. GG please"),
            "Send it to jazz@jazz.gg please."
        )
    }

    func testAlreadyFormedDomainIsAccepted() {
        XCTAssertEqual(cleaned("jazz at jazz.gg"), "jazz@jazz.gg.")
    }

    /// the dangerous half of accepting a bare period: a sentence break after
    /// the word "at" is ordinary speech, not an address.
    func testASentenceBreakAfterAtIsNotAnAddress() {
        XCTAssertEqual(
            cleaned("i met him at home. great to see him"),
            "I met him at home. Great to see him."
        )
        XCTAssertEqual(
            cleaned("we landed at heathrow. paris is next"),
            "We landed at heathrow. Paris is next."
        )
        XCTAssertEqual(
            cleaned("it happened at midnight. sunday was quiet"),
            "It happened at midnight. Sunday was quiet."
        )
    }

    /// an address is not a sentence — capitalising it gives you Jass@jass.gg,
    /// which is nobody's email.
    func testAnAddressIsNeverCapitalised() {
        XCTAssertTrue(cleaned("jass at jass dot gg").hasPrefix("jass@"))
        XCTAssertTrue(cleaned("jazz at jazz. GG").hasPrefix("jazz@"))
    }

    func testAddressMidSentenceKeepsTheSentenceCapitalised() {
        XCTAssertEqual(
            cleaned("ping me at support at acme dot io tomorrow"),
            "Ping me at support@acme.io tomorrow."
        )
    }
}
