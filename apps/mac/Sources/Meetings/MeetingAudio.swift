import AVFoundation
import Foundation

/// A slice of the meeting as the capture layer hands it over: both sides,
/// already 16 kHz mono float, stamped from the start of capture. The HAL
/// aligned the two (002: one buffer list, one timestamp per cycle), so they
/// are the same length by construction.
struct MeetingAudioChunk: Sendable {
    static let sampleRate: Double = 16_000

    let you: [Float]
    let them: [Float]
    let at: Duration

    var duration: Duration {
        .seconds(Double(them.count) / Self.sampleRate)
    }

    /// Loudness of the far side, the only number `TapHealthMonitor` needs.
    var themRMS: Float {
        guard !them.isEmpty else { return 0 }
        let sum = them.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(them.count)).squareRoot()
    }
}

/// The capture layer. Starting it plays the start sound — that is the probe
/// (ADR 0021) — and the stream keeps flowing through silence because the mic
/// is the clock (002). It ends only when `stop()` is called or the tap dies
/// in a way that cannot be rebuilt.
protocol MeetingAudioSource: Sendable {
    func start(tapping app: RunningApp) async throws -> AsyncStream<MeetingAudioChunk>
    /// 002 §6's response to a tap that went all-zero: tear down, rebuild.
    func rebuild() async throws
    func stop() async
}

/// The engine listening to a meeting. Lines arrive as whisper decides them,
/// confirmed or not; `finish` returns the turns worth keeping.
protocol MeetingTranscriber: Sendable {
    func begin() async throws
    func feed(_ chunk: MeetingAudioChunk) async
    var lines: AsyncStream<LiveLine> { get }
    func finish() async -> [MeetingTurn]
    /// The whole meeting at once — for a spool the app found after a crash.
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn]
}

/// Splits `them` into `them 1`, `them 2`… after the meeting. Given the far
/// side's audio and the turns as transcribed, returns the same turns with
/// speakers assigned. Leaves `them(nil)` when it finds one voice.
protocol MeetingDiarizer: Sendable {
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn]
}

/// The spool on disk: one two-channel 16 kHz float caf, left = you,
/// right = them. Written as the meeting runs, read back once at the end for
/// diarization (or at launch, for recovery), then deleted.
actor SpoolAudioFile {
    private let file: AVAudioFile
    private let format: AVAudioFormat

    init(url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: MeetingAudioChunk.sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw CocoaError(.featureUnsupported)
        }
        self.format = format
        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func append(_ chunk: MeetingAudioChunk) throws {
        let frames = AVAudioFrameCount(min(chunk.you.count, chunk.them.count))
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData
        else {
            return
        }
        buffer.frameLength = frames
        chunk.you.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: Int(frames)) }
        chunk.them.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: Int(frames)) }
        try file.write(from: buffer)
    }

    static func read(_ url: URL) throws -> (you: [Float], them: [Float]) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else {
            return ([], [])
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { return ([], []) }
        let count = Int(buffer.frameLength)
        let you = Array(UnsafeBufferPointer(start: channels[0], count: count))
        let them = file.processingFormat.channelCount > 1
            ? Array(UnsafeBufferPointer(start: channels[1], count: count))
            : []
        return (you, them)
    }
}
