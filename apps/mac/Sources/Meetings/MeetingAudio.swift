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

/// Something the capture layer did by itself while a meeting ran, for the
/// meeting's record: the mic it moved to, a move that failed, the built-in
/// mic it fell back on. Stamped on the chunks' clock, so it lands in the
/// record at the meeting time it happened.
struct MeetingSourceEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The default input changed, or the mic went away, and the meeting
        /// followed it.
        case micChanged
        /// A rig on another mic was brought up and never delivered, or
        /// there was no mic to move to.
        case micHandoffFailed
        /// There was no default input a meeting could use, so it moved to
        /// the built-in mic.
        case micFellBack
    }

    let kind: Kind
    /// The mic's name as the mac shows it; nil when there was none to move to.
    let mic: String?
    let at: Duration

    /// What the meeting's record keeps of it: the label, at its time. The
    /// mic's name is for whoever tells the user, not for the record.
    var label: MeetingRecord.Label {
        switch kind {
        case .micChanged: .micChanged
        case .micHandoffFailed: .micHandoffFailed
        case .micFellBack: .micFellBack
        }
    }
}

extension MeetingRecord.Label {
    /// the meeting moved to another mic: the default input changed, or the
    /// mic it was on went away.
    static let micChanged = MeetingRecord.Label(rawValue: "mic-changed")
    /// a move to another mic never delivered, or there was no mic to move to.
    static let micHandoffFailed = MeetingRecord.Label(rawValue: "mic-handoff-failed")
    /// no default input would do, so the meeting moved to the built-in mic.
    static let micFellBack = MeetingRecord.Label(rawValue: "mic-fell-back")
}

/// The capture layer. Starting it plays the start sound — that is the probe
/// (ADR 0021) — and the stream keeps flowing through silence because the mic
/// is the clock (002). It ends only when `stop()` is called or the tap dies
/// in a way that cannot be rebuilt. There is no app to name: the far side is
/// everything the mac plays (ADR 0049).
protocol MeetingAudioSource: Sendable {
    func start() async throws -> AsyncStream<MeetingAudioChunk>
    /// 002 §6's response to a tap that went all-zero: tear down, rebuild.
    func rebuild() async throws
    func stop() async
    /// Whether anything but this app was putting audio out when the source
    /// last asked, or `nil` when that cannot be told. Silence from a mac that
    /// is playing nothing is what a working tap should deliver — it is not
    /// evidence of a dead one. The other direction proves nothing (002 §6),
    /// so this is only ever used to *withhold* a verdict, never to reach one
    /// sooner.
    ///
    /// An answer kept, not a question asked: the source asks the HAL on its
    /// own queue, so reading this from the main actor costs nothing.
    var anythingIsPlaying: Bool? { get }
    /// What the source did by itself while the meeting ran: the mic it
    /// moved to, a move that failed. One stream per `start()`, read once it
    /// has returned, and finished by `stop()`.
    var sourceEvents: AsyncStream<MeetingSourceEvent> { get }
}

extension MeetingAudioSource {
    var anythingIsPlaying: Bool? { nil }
    var sourceEvents: AsyncStream<MeetingSourceEvent> {
        AsyncStream { $0.finish() }
    }
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
    /// What its decoding came to, for the meeting's record: asked once the
    /// meeting has been read. `nil` for an engine that keeps no count.
    func decodeTally() async -> StretchTally?
}

extension MeetingTranscriber {
    func decodeTally() async -> StretchTally? { nil }
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

    /// The spool a block of `frames` at a time, both sides, in order: for
    /// whatever reads a whole meeting and must not hold an hour of it in
    /// memory to do it. The last block may be short.
    static func readBlocks(
        _ url: URL,
        frames: Int = 16_000,
        _ body: (_ you: [Float], _ them: [Float]) throws -> Void
    ) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let capacity = AVAudioFrameCount(max(1, frames))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
            return
        }
        let stereo = file.processingFormat.channelCount > 1
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: capacity)
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData else { return }
            try body(
                Array(UnsafeBufferPointer(start: channels[0], count: count)),
                stereo ? Array(UnsafeBufferPointer(start: channels[1], count: count)) : [])
        }
    }

    /// How long the far side was louder than `floor`, judged 100 ms at a
    /// time — the steps the tap hands over and the health check judges.
    /// The spool's own word on whether anyone was heard, for the coverage
    /// check: it never goes near the transcriber, so a transcriber that was
    /// never fed cannot have it wrong.
    static func farSideLoud(in url: URL, above floor: Float) throws -> Duration {
        let window = 1_600
        var loud = 0
        try readBlocks(url, frames: window * 10) { _, them in
            var start = 0
            while start < them.count {
                let end = min(start + window, them.count)
                var sum: Float = 0
                for sample in them[start..<end] { sum += sample * sample }
                if (sum / Float(end - start)).squareRoot() > floor {
                    loud += end - start
                }
                start = end
            }
        }
        return StretchCutter.duration(of: loud)
    }
}
