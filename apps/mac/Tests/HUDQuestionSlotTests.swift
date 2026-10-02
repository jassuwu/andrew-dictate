import XCTest

/// a pill with a button is a question, and a question waits its turn: it
/// never speaks over a take or a sentence, gives way to them unanswered, and
/// is answered once.
final class HUDQuestionSlotTests: XCTestCase {
    private typealias Slot = HUDQuestionSlot<String>

    func testAQuestionOnAFreePillGoesUpAtOnce() {
        var slot = Slot()

        XCTAssertTrue(slot.ask("record zoom?", pillIsFree: true))
        XCTAssertEqual(slot.asked, "record zoom?")
        XCTAssertNil(slot.waiting)
    }

    /// a take is on the lamp, or a sentence is on the pill: the question
    /// waits for it, and goes up once the pill is free.
    func testAQuestionAskedOverATakeOrASentenceWaitsForThePill() {
        var slot = Slot()

        XCTAssertFalse(slot.ask("record zoom?", pillIsFree: false))
        XCTAssertNil(slot.asked)
        XCTAssertEqual(slot.waiting, "record zoom?")

        XCTAssertEqual(slot.pillFreed { _ in true }, "record zoom?")
        XCTAssertEqual(slot.asked, "record zoom?")
        XCTAssertNil(slot.waiting)
    }

    /// dictation wins: a press takes the pill from the question, which is
    /// gone unanswered. the menu still has the call; the pill does not come
    /// back to ask again.
    func testATakeDisplacesTheQuestionAndItDoesNotComeBack() {
        var slot = Slot()
        _ = slot.ask("record zoom?", pillIsFree: true)

        slot.pillTaken()

        XCTAssertNil(slot.asked)
        XCTAssertNil(slot.pillFreed { _ in true })
        XCTAssertFalse(slot.answer("record zoom?"))
    }

    /// the call it was about ended while the take ran: asking now would be
    /// about nothing.
    func testAWaitingQuestionNoLongerWorthAskingIsDropped() {
        var slot = Slot()
        _ = slot.ask("record zoom?", pillIsFree: false)

        XCTAssertNil(slot.pillFreed { _ in false })
        XCTAssertNil(slot.asked)
        XCTAssertNil(slot.waiting)
    }

    func testANewerQuestionTakesTheWaitingPlace() {
        var slot = Slot()
        _ = slot.ask("call ended — stop?", pillIsFree: false)
        _ = slot.ask("still recording?", pillIsFree: false)

        XCTAssertEqual(slot.pillFreed { _ in true }, "still recording?")
    }

    /// two questions are never up at once: the newer one has the pill.
    func testANewerQuestionReplacesTheOneOnThePill() {
        var slot = Slot()
        _ = slot.ask("call ended — stop?", pillIsFree: true)

        XCTAssertTrue(slot.ask("still recording?", pillIsFree: true))
        XCTAssertEqual(slot.asked, "still recording?")
        XCTAssertFalse(slot.answer("call ended — stop?"))
    }

    /// a click and the countdown can both arrive; only the first is an
    /// answer.
    func testAQuestionIsAnsweredOnce() {
        var slot = Slot()
        _ = slot.ask("still recording?", pillIsFree: true)

        XCTAssertTrue(slot.answer("still recording?"))
        XCTAssertFalse(slot.answer("still recording?"))
        XCTAssertNil(slot.asked)
    }

    /// the nudge is asked on the pill and in a notification. answered in
    /// the notification, the pill's copy leaves without being acted on, and
    /// so does one still waiting for the pill.
    func testAQuestionAnsweredElsewhereLeavesThePill() {
        var slot = Slot()
        _ = slot.ask("still recording?", pillIsFree: true)

        XCTAssertTrue(slot.withdraw("still recording?"))
        XCTAssertNil(slot.asked)
        XCTAssertFalse(slot.answer("still recording?"))

        _ = slot.ask("still recording?", pillIsFree: false)
        XCTAssertFalse(slot.withdraw("still recording?"))
        XCTAssertNil(slot.waiting)
    }

    /// withdrawing one question leaves another alone.
    func testWithdrawingAnotherQuestionChangesNothing() {
        var slot = Slot()
        _ = slot.ask("record zoom?", pillIsFree: true)

        XCTAssertFalse(slot.withdraw("still recording?"))
        XCTAssertEqual(slot.asked, "record zoom?")
    }
}
