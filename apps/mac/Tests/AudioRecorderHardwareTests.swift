import CoreAudio
import XCTest

/// the recorder against the real audio server, not a fake. a mac's mic and
/// its speakers can run at different rates — the speakers at 44.1 kHz, the
/// built-in mic at 48 — and a capture bound to the mic has to hear it
/// anyway. the test sets the default output to another rate than the
/// default input for a moment and puts it back; a mac with no input, no
/// output, or an output that won't change rate skips.
@MainActor
final class AudioRecorderHardwareTests: XCTestCase {
    func testAMicAtAnotherRateThanTheOutputStillSendsFrames() async throws {
        guard let input = MicDescription.defaultInputDevice(),
              let output = Self.defaultOutputDevice(),
              input != output,
              let inputRate = Self.rate(of: input),
              let outputRate = Self.rate(of: output) else {
            throw XCTSkip("this mac has no separate default input and output")
        }
        let otherRate: Float64 = inputRate == 44_100 ? 48_000 : 44_100
        guard Self.setRate(otherRate, of: output) else {
            throw XCTSkip("the default output won't run at \(otherRate) Hz")
        }
        addTeardownBlock {
            _ = Self.setRate(outputRate, of: output)
        }

        let recorder = AudioRecorder(preRollEnabled: false)
        defer { recorder.discard() }
        let heard = expectation(description: "the mic's first frames")
        try await recorder.start { _ in
            heard.fulfill()
        }

        // the press gives a mic a second before it says no sound.
        await fulfillment(of: [heard], timeout: 1)
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        ) == noErr,
              device != kAudioObjectUnknown else {
            return nil
        }
        return device
    }

    private static func rate(of device: AudioObjectID) -> Float64? {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &size,
            &rate
        ) == noErr else {
            return nil
        }
        return rate
    }

    /// asks, then waits for the device to say it is there: the change
    /// lands asynchronously.
    private static func setRate(
        _ rate: Float64,
        of device: AudioObjectID
    ) -> Bool {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var wanted = rate
        guard AudioObjectSetPropertyData(
            device,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float64>.size),
            &wanted
        ) == noErr else {
            return false
        }
        for _ in 0..<20 where Self.rate(of: device) != rate {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return Self.rate(of: device) == rate
    }

    private static func address(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
