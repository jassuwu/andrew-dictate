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
        Self.rms(them)
    }

    /// Loudness of your side, for whoever watches that the mic is heard.
    var youRMS: Float {
        Self.rms(you)
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
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
        /// The mic is muted on the mac, or its input volume is at nothing:
        /// silent on purpose, which is not a fault.
        case micMuted
        /// And it is not any more.
        case micUnmuted
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
        case .micMuted: .micMuted
        case .micUnmuted: .micUnmuted
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
    /// the mic was muted on the mac, or turned all the way down.
    static let micMuted = MeetingRecord.Label(rawValue: "mic-muted")
    /// and it was not any more.
    static let micUnmuted = MeetingRecord.Label(rawValue: "mic-unmuted")
}

/// What a source is delivering, as far as it knows.
enum MeetingCapture: Equatable, Sendable {
    /// The tap and the mic: both sides.
    case bothSides
    /// The tap could not be rebuilt, and the mic is delivered on its own,
    /// the far side as silence: your side is still being recorded.
    case yourSideAlone
    /// Neither: nothing is being delivered.
    case nothing
}

/// Which part of capture would not start, so the meeting can say which and
/// point at the fix that part has, rather than sending every failure to the
/// system-audio switch.
enum CaptureFault: Equatable, Sendable {
    /// No mic to record your side with, or the one there would not start
    /// in time. Named, when known.
    case mic(String?)
    /// The tap would not open, or not in time.
    case tap
}

/// An error from a source's `start()` that knows which part failed. Any
/// other error is taken for the tap's, as every one was before there was a
/// way to tell.
protocol CaptureFailure: Error {
    var fault: CaptureFault { get }
}

/// The capture layer. Starting it plays the start sound — that is the probe
/// (ADR 0021) — and the stream keeps flowing through silence because the mic
/// is the clock (002). It ends only when `stop()` is called or the tap dies
/// in a way that cannot be rebuilt. There is no app to name: the far side is
/// everything the mac plays (ADR 0049).
protocol MeetingAudioSource: Sendable {
    /// Whether this app may use the microphone, asked of the mac before
    /// anything is built — and asked for, if nobody has been asked yet. A
    /// meeting does not start without it: a grant taken back in system
    /// settings would otherwise record your side as silence, and nothing
    /// re-checks a setup that was for meetings only.
    func micAllowed() async -> Bool
    func start() async throws -> AsyncStream<MeetingAudioChunk>
    /// 002 §6's response to a tap that went all-zero: tear down, rebuild.
    func rebuild() async throws
    func stop() async
    /// Whether anything but this app was putting audio out when the source
    /// last asked, or `nil` when that cannot be told. Silence from a mac that
    /// is playing nothing is what a working tap should deliver — it is not
    /// evidence of a dead one. The other direction proves nothing (002 §6),
    /// so this only ever decides whether a silence is worth asking the tap
    /// about (`playQuietProbe`); it is never a verdict on its own.
    ///
    /// An answer kept, not a question asked: the source asks the HAL on its
    /// own queue, so reading this from the main actor costs nothing.
    var anythingIsPlaying: Bool? { get }
    /// What the source did by itself while the meeting ran: the mic it
    /// moved to, a move that failed. One stream per `start()`, read once it
    /// has returned, and finished by `stop()`.
    var sourceEvents: AsyncStream<MeetingSourceEvent> { get }
    /// A short, quiet tone played by this process, which the tap hears
    /// because it hears us: how a far side gone quiet while something plays
    /// is asked whether it is still there. Throws when the tone could not be
    /// played at all — no output device, a player that would not start —
    /// which says nothing about the tap, and must never be read as a tone
    /// it did not hear.
    func playQuietProbe() async throws
    /// Whether the start sound that the last `start()` or `rebuild()`
    /// played could be played at all. `false` is no output device, or a
    /// player that would not start: the tap was given nothing to hear, so
    /// its silence is no verdict on it. `nil` when the source cannot say.
    var startSoundPlayed: Bool? { get }
    /// The mic your side is being recorded from, as the mac names it, so a
    /// problem with it can say which. `nil` when there is none, or the
    /// source cannot say. Kept, like `anythingIsPlaying`: cheap to read.
    var micName: String? { get }
    /// What is being delivered right now: after a rebuild that threw,
    /// whether the mic was kept going on its own. `nil` when the source
    /// cannot say. Kept, like `anythingIsPlaying`.
    var capturing: MeetingCapture? { get }
}

extension MeetingAudioSource {
    var capturing: MeetingCapture? { nil }
    func micAllowed() async -> Bool { true }
    var anythingIsPlaying: Bool? { nil }
    var micName: String? { nil }
    var sourceEvents: AsyncStream<MeetingSourceEvent> {
        AsyncStream { $0.finish() }
    }
    func playQuietProbe() async throws {}
    var startSoundPlayed: Bool? { nil }
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

/// Splits `them` into `them 1`, `them 2`…: who on the far side spoke when.
/// The far side is heard a piece at a time while the meeting records
/// (`SpeakerSplit` cuts the pieces and hands them over), so the end of a
/// meeting has only its last few minutes left to hear.
protocol MeetingDiarizer: Sendable {
    /// One meeting's hearing, fresh: its pieces are handed to it in order,
    /// and a voice keeps its id from one piece to the next. Nil when this
    /// mac cannot split a meeting — its models are not here — and the turns
    /// stay plain `them`.
    func hearing() -> (any SpeakerHearing)?
    /// The far side whole, and the turns as transcribed, on its clock: the
    /// same turns with speakers assigned. Leaves `them(nil)` when it finds
    /// one voice.
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn]
}

extension MeetingDiarizer {
    /// A diarizer that can only hear a meeting whole is handed it whole, at
    /// the end: every piece is held until then, so what it holds grows with
    /// the meeting. `FluidDiarizer` hears in pieces.
    func hearing() -> (any SpeakerHearing)? {
        WholeMeeting(diarizer: self)
    }
}

/// One meeting's far side as a diarizer hears it, a piece at a time.
protocol SpeakerHearing: Sendable {
    /// How much far side a piece is, in samples: the diarizer's to say, as
    /// it hears in windows of its own and a piece should end on one.
    var pieceLength: Int { get }
    /// One piece of the far side, `at` into the spool, after the piece
    /// before it. Throws when this piece could not be heard; the next one
    /// still can be.
    func hear(_ piece: [Float], at: Duration) async throws
    /// The turns, on the spool's clock, with the speakers heard so far. It
    /// answers from what it has: a piece still being heard is not waited
    /// for, so a stop that gave up on one is not held up by it here.
    func split(_ turns: [MeetingTurn]) async -> [MeetingTurn]
}

extension SpeakerHearing {
    var pieceLength: Int {
        SpeakerPieces.length
    }
}

/// The pieces, kept, and handed to a diarizer that hears only whole
/// meetings when the turns are asked about.
private actor WholeMeeting: SpeakerHearing {
    private let diarizer: any MeetingDiarizer
    private var them: [Float] = []

    init(diarizer: any MeetingDiarizer) {
        self.diarizer = diarizer
    }

    func hear(_ piece: [Float], at: Duration) {
        them += piece
    }

    func split(_ turns: [MeetingTurn]) async -> [MeetingTurn] {
        await diarizer.split(them: them, turns: turns)
    }
}

/// Where a meeting's audio is written as it arrives: the spool's audio
/// file. Named apart from it so a test can hand a meeting one that refuses.
protocol MeetingAudioWriter: Sendable {
    func append(_ chunk: MeetingAudioChunk) async throws
}

extension SpoolAudioFile: MeetingAudioWriter {}

/// The spool on disk: one two-channel 16 kHz float caf, left = you,
/// right = them. Written as the meeting runs, read back at the end a block
/// at a time for the coverage check (or whole at launch, for recovery, and
/// for a reading again), then kept compressed or deleted (ADR 0048).
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

    /// The far side alone, read a piece at a time when asked for: for what
    /// hears a whole spool more slowly than the disk reads it, and so reads
    /// the next piece only once it has heard the last. Reading ahead would
    /// have the whole far side waiting in memory.
    final class FarSide {
        private let file: AVAudioFile
        private var buffer: AVAudioPCMBuffer?

        init(_ url: URL) throws {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        }

        /// The next `frames` of the far side, fewer at the end, and none
        /// once there is no more. A spool with one channel has no far side.
        func next(_ frames: Int) throws -> [Float] {
            guard file.processingFormat.channelCount > 1, file.framePosition < file.length else {
                return []
            }
            let capacity = AVAudioFrameCount(max(1, frames))
            if buffer == nil || buffer!.frameCapacity != capacity {
                buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity)
            }
            guard let buffer else { return [] }
            try file.read(into: buffer, frameCount: capacity)
            guard let channels = buffer.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: channels[1], count: Int(buffer.frameLength)))
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
