import XCTest

/// when a meeting moves to another mic, and what it does when the move goes
/// wrong. instants and what the mac says about its mics in, steps out.
final class MicHandoffTests: XCTestCase {
    private let origin = ContinuousClock.now

    private let builtIn = MicHandoff.Mic(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    private let airPods = MicHandoff.Mic(uid: "airpods:input", name: "AirPods Pro")
    private let usb = MicHandoff.Mic(uid: "usb:yeti", name: "Yeti")

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        origin + .milliseconds(milliseconds)
    }

    /// a meeting on the built-in mic, nothing pending.
    private func onBuiltIn() -> MicHandoff {
        var handoff = MicHandoff()
        handoff.began(on: builtIn, slot: .first)
        return handoff
    }

    // MARK: - when to move

    /// airpods connect and become the default: once nothing has moved for a
    /// second and a half, a rig on them is brought up under the other uid.
    func testOneChangeMovesTheMeetingOnceTheHardwareHasSettled() {
        var handoff = onBuiltIn()
        let mics = MicHandoff.Mics(
            defaultInput: airPods, builtIn: builtIn,
            present: [builtIn.uid, airPods.uid])

        handoff.changed(at: at(0))

        XCTAssertEqual(handoff.nextLook, at(1_500))
        XCTAssertEqual(handoff.look(at: at(1_499), mics: mics), [])
        XCTAssertEqual(handoff.look(at: at(1_500), mics: mics), [.bringUp(airPods, .second)])
    }

    /// airpods arriving are a burst: the device list, then the default
    /// input, then the list again. the quiet starts over with each, and the
    /// burst is one move, a second and a half after its last change.
    func testABurstOfChangesIsOneHandoff() {
        var handoff = onBuiltIn()
        let mics = MicHandoff.Mics(
            defaultInput: airPods, builtIn: builtIn,
            present: [builtIn.uid, airPods.uid])

        handoff.changed(at: at(0))
        handoff.changed(at: at(400))
        XCTAssertEqual(handoff.look(at: at(1_500), mics: mics), [])
        handoff.changed(at: at(900))

        XCTAssertEqual(handoff.nextLook, at(2_400))
        XCTAssertEqual(handoff.look(at: at(2_399), mics: mics), [])
        XCTAssertEqual(handoff.look(at: at(2_400), mics: mics), [.bringUp(airPods, .second)])
        XCTAssertNil(handoff.nextLook)
        XCTAssertEqual(handoff.look(at: at(5_000), mics: mics), [])
    }

    /// a burst that never goes quiet is not waited out for ever: three
    /// seconds after its first change, the meeting moves anyway.
    func testABurstLongerThanThreeSecondsIsActedOnAtThree() {
        var handoff = onBuiltIn()
        let mics = MicHandoff.Mics(
            defaultInput: airPods, builtIn: builtIn,
            present: [builtIn.uid, airPods.uid])

        handoff.changed(at: at(0))
        handoff.changed(at: at(1_000))
        handoff.changed(at: at(2_000))
        handoff.changed(at: at(2_900))

        XCTAssertEqual(handoff.nextLook, at(3_000))
        XCTAssertEqual(handoff.look(at: at(2_999), mics: mics), [])
        XCTAssertEqual(handoff.look(at: at(3_000), mics: mics), [.bringUp(airPods, .second)])
    }

    /// a monitor plugged in, or the rig's own device coming and going:
    /// the list moved, the mic did not. nothing is built.
    func testNothingMovesWhenTheMicIsStillTheDefaultAndStillThere() {
        var handoff = onBuiltIn()
        let mics = MicHandoff.Mics(
            defaultInput: builtIn, builtIn: builtIn,
            present: [builtIn.uid, airPods.uid])

        handoff.changed(at: at(0))

        XCTAssertEqual(handoff.look(at: at(1_500), mics: mics), [])
        XCTAssertNil(handoff.nextLook)
    }

    // MARK: - the standby

    /// the rig on the airpods delivers its first buffer: it is the meeting's
    /// rig now, and the record hears the mic changed.
    func testAStandbyThatDeliversTakesOver() {
        var handoff = onBuiltIn()
        let mics = MicHandoff.Mics(
            defaultInput: airPods, builtIn: builtIn,
            present: [builtIn.uid, airPods.uid])
        handoff.changed(at: at(0))
        _ = handoff.look(at: at(1_500), mics: mics)
        handoff.standbyUp(at: at(1_800))

        XCTAssertEqual(handoff.standbyDelivered(), [.tell(.micChanged, airPods)])
        XCTAssertEqual(handoff.mic, airPods)
        XCTAssertNil(handoff.nextLook)
    }

    /// the rig on the airpods came up and never delivered: five seconds
    /// after it started it is torn down, and the built-in mic, which never
    /// stopped delivering, stays the meeting's.
    func testAStandbyThatStaysSilentIsDroppedAndTheOldRigStays() {
        var handoff = onBuiltIn()
        let mics = MicHandoff.Mics(
            defaultInput: airPods, builtIn: builtIn,
            present: [builtIn.uid, airPods.uid])
        handoff.changed(at: at(0))
        _ = handoff.look(at: at(1_500), mics: mics)
        handoff.standbyUp(at: at(1_800))

        XCTAssertEqual(handoff.nextLook, at(6_800))
        XCTAssertFalse(handoff.standbyIsOverdue(at: at(6_799)))
        XCTAssertEqual(handoff.look(at: at(6_799), mics: mics), [])
        XCTAssertTrue(handoff.standbyIsOverdue(at: at(6_800)))
        XCTAssertEqual(handoff.look(at: at(6_800), mics: mics), [
            .dropStandby,
            .tell(.micHandoffFailed, airPods),
        ])
        XCTAssertEqual(handoff.mic, builtIn)
        XCTAssertNil(handoff.nextLook)
    }

    // MARK: - the mic went away

    /// the airpods died mid-meeting and the usb mic is the default now. the
    /// old rig lost its clock with them, so there is nothing to keep
    /// feeding: the usb rig takes over the moment it delivers.
    func testWhenTheOldMicHasGoneTheStandbyTakesOverWhenItDelivers() {
        var handoff = MicHandoff()
        handoff.began(on: airPods, slot: .second)
        let mics = MicHandoff.Mics(
            defaultInput: usb, builtIn: builtIn,
            present: [builtIn.uid, usb.uid])

        handoff.changed(at: at(0))
        XCTAssertEqual(handoff.look(at: at(1_500), mics: mics), [.bringUp(usb, .first)])
        handoff.standbyUp(at: at(1_700))

        XCTAssertEqual(handoff.standbyDelivered(), [.tell(.micChanged, usb)])
        XCTAssertEqual(handoff.mic, usb)
    }

    /// the airpods left and the mac names no default input a meeting can
    /// use: the meeting falls back to the built-in mic, and says so.
    func testWithNoUsableDefaultTheMeetingFallsBackToTheBuiltInMic() {
        var handoff = MicHandoff()
        handoff.began(on: airPods, slot: .first)
        let mics = MicHandoff.Mics(
            defaultInput: nil, builtIn: builtIn,
            present: [builtIn.uid])

        handoff.changed(at: at(0))
        XCTAssertEqual(handoff.look(at: at(1_500), mics: mics), [.bringUp(builtIn, .second)])
        handoff.standbyUp(at: at(1_700))

        XCTAssertEqual(handoff.standbyDelivered(), [.tell(.micFellBack, builtIn)])
        XCTAssertEqual(handoff.mic, builtIn)
    }

    /// the airpods died and the usb mic, the default now, would not build:
    /// the old rig has nothing left to deliver, so the meeting goes to the
    /// built-in mic rather than to nothing.
    func testAStandbyThatFailsWithTheOldRigDeadFallsBackToTheBuiltInMic() {
        var handoff = MicHandoff()
        handoff.began(on: airPods, slot: .first)
        let mics = MicHandoff.Mics(
            defaultInput: usb, builtIn: builtIn,
            present: [builtIn.uid, usb.uid])
        handoff.changed(at: at(0))
        _ = handoff.look(at: at(1_500), mics: mics)

        XCTAssertEqual(handoff.standbyFailed(mics: mics), [
            .tell(.micHandoffFailed, usb),
            .bringUp(builtIn, .second),
        ])
        handoff.standbyUp(at: at(1_900))
        XCTAssertEqual(handoff.standbyDelivered(), [.tell(.micFellBack, builtIn)])
        XCTAssertEqual(handoff.mic, builtIn)
    }

    /// the usb mic would not build, and the built-in mic it was meant to
    /// replace is still delivering: the meeting stays where it is.
    func testAStandbyThatFailsWithTheOldRigAliveLeavesItBe() {
        var handoff = onBuiltIn()
        let mics = MicHandoff.Mics(
            defaultInput: usb, builtIn: builtIn,
            present: [builtIn.uid, usb.uid])
        handoff.changed(at: at(0))
        _ = handoff.look(at: at(1_500), mics: mics)

        XCTAssertEqual(handoff.standbyFailed(mics: mics), [.tell(.micHandoffFailed, usb)])
        XCTAssertEqual(handoff.mic, builtIn)
        XCTAssertNil(handoff.nextLook)
    }

    /// the usb mic came up and never delivered, and the airpods it was to
    /// replace are gone: the built-in mic is tried next, as for a build that
    /// failed outright.
    func testAStandbyThatTimesOutWithTheOldRigDeadFallsBackToTheBuiltInMic() {
        var handoff = MicHandoff()
        handoff.began(on: airPods, slot: .first)
        let mics = MicHandoff.Mics(
            defaultInput: usb, builtIn: builtIn,
            present: [builtIn.uid, usb.uid])
        handoff.changed(at: at(0))
        _ = handoff.look(at: at(1_500), mics: mics)
        handoff.standbyUp(at: at(1_800))

        XCTAssertEqual(handoff.look(at: at(6_800), mics: mics), [
            .dropStandby,
            .tell(.micHandoffFailed, usb),
            .bringUp(builtIn, .second),
        ])
    }

    /// a mac mini whose only mic was the airpods: they went, and there is
    /// nothing to move to. the record hears it all the same.
    func testWithNowhereToGoTheRecordHearsTheMoveFailed() {
        var handoff = MicHandoff()
        handoff.began(on: airPods, slot: .first)
        let mics = MicHandoff.Mics(defaultInput: nil, builtIn: nil, present: [])

        handoff.changed(at: at(0))

        XCTAssertEqual(handoff.look(at: at(1_500), mics: mics), [.tell(.micHandoffFailed, nil)])
        XCTAssertEqual(handoff.mic, airPods)
        XCTAssertNil(handoff.nextLook)
    }

    // MARK: - one move at a time

    /// each rig comes up beside the last, so each takes the uid the last
    /// one is not using.
    func testTheUidsAlternate() {
        var handoff = onBuiltIn()
        let toAirPods = MicHandoff.Mics(
            defaultInput: airPods, builtIn: builtIn,
            present: [builtIn.uid, airPods.uid])
        let toUSB = MicHandoff.Mics(
            defaultInput: usb, builtIn: builtIn,
            present: [builtIn.uid, airPods.uid, usb.uid])

        handoff.changed(at: at(0))
        XCTAssertEqual(handoff.look(at: at(1_500), mics: toAirPods), [.bringUp(airPods, .second)])
        handoff.standbyUp(at: at(1_700))
        _ = handoff.standbyDelivered()

        handoff.changed(at: at(10_000))
        XCTAssertEqual(handoff.look(at: at(11_500), mics: toUSB), [.bringUp(usb, .first)])
        handoff.standbyUp(at: at(11_700))
        _ = handoff.standbyDelivered()

        handoff.changed(at: at(20_000))
        XCTAssertEqual(handoff.look(at: at(21_500), mics: toAirPods), [.bringUp(airPods, .second)])
    }

    /// building a rig moves the device list too, and the user can pick
    /// another mic while one is building. those changes wait for the
    /// standby to deliver or be given up, then settle like any other.
    func testChangesWhileAStandbyIsOutWaitForIt() {
        var handoff = onBuiltIn()
        let mics = MicHandoff.Mics(
            defaultInput: airPods, builtIn: builtIn,
            present: [builtIn.uid, airPods.uid])
        handoff.changed(at: at(0))
        _ = handoff.look(at: at(1_500), mics: mics)

        handoff.changed(at: at(1_600))
        XCTAssertNil(handoff.nextLook)
        handoff.standbyUp(at: at(1_800))
        XCTAssertEqual(handoff.nextLook, at(6_800))
        XCTAssertEqual(handoff.look(at: at(3_100), mics: mics), [])

        _ = handoff.standbyDelivered()
        XCTAssertEqual(handoff.nextLook, at(3_100))
        // the change was the new rig's own device: the airpods are still
        // the default, and still there.
        XCTAssertEqual(handoff.look(at: at(3_200), mics: mics), [])
        XCTAssertNil(handoff.nextLook)
    }
}
