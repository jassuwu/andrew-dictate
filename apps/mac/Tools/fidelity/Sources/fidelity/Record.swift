@preconcurrency import AVFoundation
import Foundation
import Synchronization

enum Record {
    static func run(_ arguments: [String]) async throws {
        guard arguments.count == 1, let number = Int(arguments[0]), number > 0 else {
            throw FidelityError("usage: fidelity record <n>   (n is a prompt number from `fidelity passages`)")
        }

        let prompt = try loadPrompt(number)
        try await requireMicrophone()

        print("")
        print("passage \(number), \(prompt.words) words")
        print("")
        print(wrapped(prompt.text, width: 78))
        print("")
        print("read it aloud as you would dictate it. Enter to start, Enter again to stop.")
        _ = await waitForEnter()

        let microphone = try Microphone()
        try microphone.start()
        let meter = Task.detached {
            while !Task.isCancelled {
                let seconds = Int(microphone.duration)
                let bar = String(repeating: "#", count: min(24, Int(microphone.level * 60)))
                let line = String(format: "\r  recording %d:%02d  %@", seconds / 60, seconds % 60, bar.padding(toLength: 24, withPad: " ", startingAt: 0))
                FileHandle.standardOutput.write(Data(line.utf8))
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        _ = await waitForEnter()
        meter.cancel()
        let samples = microphone.stop()
        print("")

        let seconds = Double(samples.count) / Wav.sampleRate
        guard seconds >= 1 else {
            throw FidelityError("only \(String(format: "%.1f", seconds)) s was recorded; nothing saved.")
        }

        try Folders.makeRecordings()
        let url = Folders.passage(number)
        let replacing = FileManager.default.fileExists(atPath: url.path)
        try Wav.write(samples, to: url)
        print("\(replacing ? "replaced" : "saved") \(url.lastPathComponent), \(String(format: "%.1f", seconds)) s")

        let peak = samples.reduce(0) { max($0, abs($1)) }
        if peak < 0.001 {
            print("warning: the recording is silent. is the microphone allowed for this terminal?")
            print("  System Settings > Privacy & Security > Microphone")
        } else if peak >= 0.99 {
            print("warning: the recording clips. move back from the mic or turn the input level down, and record it again.")
        }
    }

    // MARK: - prompts

    private static func loadPrompt(_ number: Int) throws -> Prompt {
        guard FileManager.default.fileExists(atPath: Folders.prompts.path) else {
            throw FidelityError("no prompts yet. run `fidelity passages` first.")
        }
        let prompts = try JSONDecoder().decode([Prompt].self, from: Data(contentsOf: Folders.prompts))
        guard let prompt = prompts.first(where: { $0.number == number }) else {
            throw FidelityError("there is no prompt \(number); the prompts are 1 to \(prompts.count).")
        }
        return prompt
    }

    private static func wrapped(_ text: String, width: Int) -> String {
        var lines: [String] = []
        var line = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            if !line.isEmpty, line.count + 1 + word.count > width {
                lines.append(line)
                line = String(word)
            } else {
                line += (line.isEmpty ? "" : " ") + word
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines.map { "  " + $0 }.joined(separator: "\n")
    }

    /// blocks on stdin off the main actor, so the meter keeps drawing.
    private static func waitForEnter() async -> String? {
        await Task.detached { readLine() }.value
    }

    // MARK: - microphone

    private static func requireMicrophone() async throws {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw FidelityError(
                "the microphone is not allowed for this terminal. "
                    + "System Settings > Privacy & Security > Microphone, then run it again."
            )
        }
    }
}

/// true the first time it is asked and never again.
private final class Handover: Sendable {
    private let taken = Mutex(false)

    func take() -> Bool {
        taken.withLock { taken in
            defer { taken = true }
            return !taken
        }
    }
}

/// the mic as a stream of 16 kHz mono float samples, which is what the app
/// hands the model, however the hardware delivers them.
private final class Microphone: Sendable {
    private struct State {
        var samples: [Float] = []
        var level: Float = 0
    }

    private let engine = AVAudioEngine()
    private let state = Mutex(State())
    private let target: AVAudioFormat
    private let converter: AVAudioConverter
    private let inputRate: Double

    init() throws {
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw FidelityError("there is no microphone input to record from.")
        }
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Wav.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: target)
        else {
            throw FidelityError("cannot convert \(inputFormat) to 16 kHz mono.")
        }
        self.target = target
        self.converter = converter
        self.inputRate = inputFormat.sampleRate
    }

    func start() throws {
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [self] buffer, _ in
            append(convert(buffer))
        }
        engine.prepare()
        try engine.start()
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return state.withLock { $0.samples }
    }

    var duration: Double {
        Double(state.withLock { $0.samples.count }) / Wav.sampleRate
    }

    /// the loudest sample of the latest buffer, for the meter.
    var level: Float {
        state.withLock { $0.level }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Wav.sampleRate / inputRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }

        // the converter asks for input until told there is none; the buffer
        // is handed over once.
        let handedOver = Handover()
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, inputStatus in
            if handedOver.take() {
                inputStatus.pointee = .haveData
                return buffer
            }
            inputStatus.pointee = .noDataNow
            return nil
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    private func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let peak = samples.reduce(0) { max($0, abs($1)) }
        state.withLock {
            $0.samples.append(contentsOf: samples)
            $0.level = peak
        }
    }
}
