@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// how soon the mic is heard after a press asks for it, the way the app's
/// capture builds it: one AVAudioEngine, a tap in tenth-of-a-second
/// buffers, and a sink node called every I/O cycle. cold builds the engine
/// at the press; warm builds and prepares it first, as the app now does
/// once the hardware settles. it also asks Core Audio whether `prepare()`
/// alone started the input — the mic's indicator follows that.
enum MicStart {
    static func run(_ arguments: [String]) async throws {
        var trials = 8
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--trials":
                guard let text = remaining.popFirst(), let value = Int(text), value > 0 else {
                    throw FidelityError("--trials takes a positive number")
                }
                trials = value
            default:
                throw FidelityError("mic doesn't know '\(argument)'")
            }
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw FidelityError("this terminal has no microphone access (System Settings, Privacy & Security, Microphone)")
        }

        print("built-in or whatever the default input is now: \(defaultInputName() ?? "unknown")")
        print("")
        print("does prepare() start the input? (the mic indicator follows this)")
        let probe = try Capture()
        print("  before prepare  our input running: \(ourInputIsRunning().map(String.init) ?? "unknown")")
        probe.engine.prepare()
        try await Task.sleep(for: .milliseconds(300))
        print("  after prepare   our input running: \(ourInputIsRunning().map(String.init) ?? "unknown")")
        _ = try probe.start()
        try await Task.sleep(for: .milliseconds(300))
        print("  after start     our input running: \(ourInputIsRunning().map(String.init) ?? "unknown")")
        probe.engine.stop()
        try await Task.sleep(for: .milliseconds(500))

        for warm in [false, true] {
            var starts: [Double] = []
            var sinks: [Double] = []
            var taps: [Double] = []
            for _ in 0..<trials {
                let capture: Capture
                if warm {
                    capture = try Capture()
                    capture.engine.prepare()
                    try await Task.sleep(for: .milliseconds(500))
                } else {
                    try await Task.sleep(for: .milliseconds(500))
                    capture = try Capture()
                }
                // cold counts the build, as the first press after a device
                // change used to.
                let asked = warm ? ContinuousClock.now : capture.made
                let started = try capture.start()
                try await Task.sleep(for: .milliseconds(400))
                capture.engine.stop()
                starts.append(ms(asked, started))
                if let sink = capture.firstSink.value { sinks.append(ms(asked, sink)) }
                if let tap = capture.firstTap.value { taps.append(ms(asked, tap)) }
            }
            print("")
            print(warm ? "warm (built and prepared ahead)" : "cold (built at the press)")
            row("start() returned", starts)
            row("first sink callback", sinks)
            row("first tap buffer", taps)
        }
    }

    private static func row(_ label: String, _ values: [Double]) {
        guard !values.isEmpty else {
            print("  \(label.padding(toLength: 20, withPad: " ", startingAt: 0))  never")
            return
        }
        print(
            "  \(label.padding(toLength: 20, withPad: " ", startingAt: 0))  n \(values.count)  "
                + "p50 \(Int(Bench.percentile(values, 0.5).rounded())) ms  p90 \(Int(Bench.percentile(values, 0.9).rounded())) ms"
        )
    }

    private static func ms(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Double {
        Compare.seconds(from.duration(to: to)) * 1_000
    }

    /// one engine as the app's capture builds it, minus the storage.
    private final class Capture: @unchecked Sendable {
        let engine = AVAudioEngine()
        let made = ContinuousClock.now
        let firstSink = FirstInstant()
        let firstTap = FirstInstant()

        init() throws {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                throw FidelityError("the default input has no format")
            }
            let tapFrames = AVAudioFrameCount(max(1_024, ceil(format.sampleRate * 0.1)))
            input.installTap(onBus: 0, bufferSize: tapFrames, format: format) { [firstTap] buffer, _ in
                if buffer.frameLength > 0 { firstTap.set(ContinuousClock.now) }
            }
            let sink = AVAudioSinkNode { [firstSink] _, frames, _ in
                if frames > 0 { firstSink.set(ContinuousClock.now) }
                return noErr
            }
            engine.attach(sink)
            engine.connect(input, to: sink, format: format)
        }

        func start() throws -> ContinuousClock.Instant {
            try engine.start()
            return ContinuousClock.now
        }
    }

    private final class FirstInstant: @unchecked Sendable {
        private let lock = NSLock()
        private var instant: ContinuousClock.Instant?

        var value: ContinuousClock.Instant? {
            lock.withLock { instant }
        }

        func set(_ now: ContinuousClock.Instant) {
            lock.withLock {
                if instant == nil { instant = now }
            }
        }
    }

    // MARK: - core audio

    /// whether this process's input is running, the fact the mic indicator
    /// shows. nil if Core Audio won't say.
    private static func ourInputIsRunning() -> Bool? {
        var pid = getpid()
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process
        ) == noErr, process != kAudioObjectUnknown else {
            return nil
        }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioProcessPropertyIsRunningInput
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr else {
            return nil
        }
        return running != 0
    }

    private static func defaultInputName() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr else {
            return nil
        }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else {
            return nil
        }
        return name.takeRetainedValue() as String
    }
}
