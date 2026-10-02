import AVFoundation
import CoreAudio
import Foundation
import os

/// The capture layer, as ticket 002 laid it out and the spike proved on this
/// machine: a Core Audio tap on everything the mac plays (ADR 0049), fed into
/// a private aggregate device whose only real sub-device — and therefore
/// clock — is the microphone. One `AudioBufferList` per cycle carries both,
/// so alignment is the HAL's job. The tap excludes no process: whichever app
/// the call is in, and whichever helper of it does the playing, is heard
/// without anyone having to name it.
///
/// Everything arrives here at the device rate (48 kHz on this mac) and leaves
/// as 16 kHz mono pairs, in ~100 ms chunks, on the IO queue.
///
/// `@unchecked Sendable` because Core Audio hands us raw object ids and an
/// IOProc on its own queue; every field they touch is behind `lock`, and the
/// ids themselves are plain integers the HAL owns.
final class CoreAudioMeetingSource: MeetingAudioSource, @unchecked Sendable {
    enum Failure: Error, LocalizedError {
        case coreAudio(String, OSStatus)
        case noMicrophone
        case noStartSound

        var errorDescription: String? {
            switch self {
            case .coreAudio(let call, let status): "\(call) failed (\(status))"
            case .noMicrophone: "no microphone"
            case .noStartSound: "the start sound is missing from the app"
            }
        }
    }

    private let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "tap")
    private let queue = DispatchQueue(label: "gg.jass.dictate.meeting-io", qos: .userInitiated)
    /// Where the HAL is asked what is playing. Not the main thread, which
    /// only reads the answer, and not the IO queue, which has audio to keep
    /// up with.
    private let asking = DispatchQueue(label: "gg.jass.dictate.meeting-playing", qos: .utility)
    private let lock = NSLock()

    // All guarded by `lock`, touched from the caller and the IO queue.
    private var rig: Rig?
    private var continuation: AsyncStream<MeetingAudioChunk>.Continuation?
    private var assembler: ChunkAssembler?
    private var framesDelivered: Int64 = 0
    private var lastDelivery: ContinuousClock.Instant?
    private var player: AVAudioPlayer?
    private var playingTimer: DispatchSourceTimer?
    private var playing: Bool?

    init() {}

    // MARK: - MeetingAudioSource

    func start() async throws -> AsyncStream<MeetingAudioChunk> {
        let (stream, continuation) = AsyncStream<MeetingAudioChunk>.makeStream(
            bufferingPolicy: .unbounded)
        lock.withLock {
            self.continuation = continuation
            self.framesDelivered = 0
            self.lastDelivery = ContinuousClock.now
        }
        try build()
        keepAskingWhatIsPlaying()
        playProbeTone()
        return stream
    }

    func rebuild() async throws {
        teardown()
        try build()
        skipTheTimeNothingWasDelivered()
        // The tone again: a rebuilt tap must prove itself like a new one.
        playProbeTone()
    }

    /// A chunk's `at` is a frame count, and frames only exist while the tap
    /// is calling back — so a rebuild after a sleep would stamp the next
    /// chunk as if the lost hour never happened, and the gap the session
    /// records would be zero seconds long. Advancing the counter over the
    /// outage keeps the whole meeting on one clock. Small outages are the
    /// teardown itself and are left alone.
    private func skipTheTimeNothingWasDelivered() {
        lock.withLock {
            guard let last = lastDelivery else { return }
            let now = ContinuousClock.now
            let outage = now - last
            guard outage > .seconds(1) else { return }
            framesDelivered += Int64(outage.totalSeconds * MeetingAudioChunk.sampleRate)
            lastDelivery = now
        }
    }

    var anythingIsPlaying: Bool? {
        lock.withLock { playing }
    }

    /// Once a second while the tap is open, ask the HAL whether any process
    /// but this one is putting audio out, and keep the answer for whoever
    /// reads `anythingIsPlaying`. Ours is left out of the question: the tap
    /// hears it, but all it plays is the probe tone. `nil` until the first
    /// answer, and whenever the HAL will not list its processes — an answer
    /// we cannot get must not be read as "no".
    private func keepAskingWhatIsPlaying() {
        let timer = DispatchSource.makeTimerSource(queue: asking)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let answer = CoreAudioProperties.anotherProcessIsRunningOutput()
            lock.withLock { self.playing = answer }
        }
        let previous = lock.withLock { () -> DispatchSourceTimer? in
            defer { playingTimer = timer; playing = nil }
            return playingTimer
        }
        previous?.cancel()
        timer.resume()
    }

    private func stopAskingWhatIsPlaying() {
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            defer { playingTimer = nil; playing = nil }
            return playingTimer
        }
        timer?.cancel()
    }

    func stop() async {
        stopAskingWhatIsPlaying()
        teardown()
        let continuation = lock.withLock { () -> AsyncStream<MeetingAudioChunk>.Continuation? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
    }

    // MARK: - the onboarding proof

    /// ADR 0021's probe, run one screen earlier: open the tap — which hears
    /// this process like any other — play the start sound, and report
    /// whether the tap heard it. This is what fires the real "record your
    /// system audio" prompt. Note the spike's caveat: on a first run the tap
    /// delivers audio before macOS has even asked, so a pass here is not
    /// proof of a grant — every real capture proves it again, which is the
    /// doctrine anyway.
    static func proveSystemAudio(within window: Duration = .seconds(1.5)) async -> Bool {
        let source = CoreAudioMeetingSource()
        guard let stream = try? await source.start() else { return false }
        // The deadline is a task of its own: a tap that never yields a
        // chunk would otherwise leave the row "proving…" forever, which is
        // a failure wearing a spinner (SPEC §4).
        let heard = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await chunk in stream where chunk.themRMS > 0.001 {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: window)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        await source.stop()
        return heard
    }

    // MARK: - building the rig

    private func build() throws {
        // Everything, ours included: the probe tone (ADR 0021) is played by
        // *this* process, and a tap that left us out could never hear it.
        // The cost is a third of a second of our own start sound at the
        // head of every recording, which whisper ignores.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "andrew dictate meeting tap"

        var tapID = AudioObjectID(0)
        try check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")
        let tapUID = description.uuid.uuidString

        let micDevice = CoreAudioProperties.defaultInputDevice()
        guard micDevice != 0, let micUID = CoreAudioProperties.deviceUID(micDevice) else {
            AudioHardwareDestroyProcessTap(tapID)
            throw Failure.noMicrophone
        }
        let micChannels = CoreAudioProperties.inputChannels(micDevice).reduce(0, +)

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "andrew dictate meeting",
            kAudioAggregateDeviceUIDKey: "gg.jass.dictate.meeting.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: micUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUID,
            ]],
        ]
        var aggregateID = AudioObjectID(0)
        do {
            try check(
                AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                "AudioHardwareCreateAggregateDevice")
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }

        let rate = CoreAudioProperties.nominalSampleRate(aggregateID)
        let assembler = ChunkAssembler(inputRate: rate > 0 ? rate : 48_000)
        lock.withLock { self.assembler = assembler }

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, inputData, _, _, _ in
            self?.ingest(inputData, micChannels: micChannels)
        }
        guard status == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw Failure.coreAudio("AudioDeviceCreateIOProcIDWithBlock", status)
        }

        let rig = Rig(tapID: tapID, aggregateID: aggregateID, procID: procID)
        lock.withLock { self.rig = rig }

        do {
            try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
        } catch {
            teardown()
            throw error
        }
        logger.info("tap up: the whole mac, at \(rate, privacy: .public) Hz")
    }

    private func teardown() {
        let rig = lock.withLock { () -> Rig? in
            defer { self.rig = nil; self.assembler = nil }
            return self.rig
        }
        guard let rig else { return }
        AudioDeviceStop(rig.aggregateID, rig.procID)
        queue.sync {}
        AudioDeviceDestroyIOProcID(rig.aggregateID, rig.procID)
        AudioHardwareDestroyAggregateDevice(rig.aggregateID)
        AudioHardwareDestroyProcessTap(rig.tapID)
    }

    /// The start sound, played whether or not sound feedback is on: it is the
    /// probe (ADR 0021), and cannot be made silent without removing it.
    private func playProbeTone() {
        guard let url = Bundle.main.url(forResource: "dictation-start", withExtension: "wav", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: "dictation-start", withExtension: "wav")
        else {
            logger.error("start sound missing; the probe cannot play")
            return
        }
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        player?.play()
        lock.withLock { self.player = player }
    }

    // MARK: - the IO proc

    private func ingest(_ inputData: UnsafePointer<AudioBufferList>, micChannels: Int) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let first = list.first, first.mData != nil, first.mNumberChannels > 0 else { return }
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / Int(first.mNumberChannels)
        guard frames > 0 else { return }

        // Sub-device channels come first, taps after (002 §4, confirmed by
        // the spike): the first `micChannels` flat channels are the mic.
        var mic = [Float](repeating: 0, count: frames)
        var tap = [Float](repeating: 0, count: frames)
        var micCount: Float = 0
        var tapCount: Float = 0
        var flatIndex = 0
        for buffer in list {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = Int(buffer.mNumberChannels)
            let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / max(channels, 1)
            for channel in 0..<channels {
                let isMic = flatIndex < micChannels
                flatIndex += 1
                let n = min(frames, available)
                if isMic {
                    micCount += 1
                    for f in 0..<n { mic[f] += data[f * channels + channel] }
                } else {
                    tapCount += 1
                    for f in 0..<n { tap[f] += data[f * channels + channel] }
                }
            }
        }
        if micCount > 1 { for f in 0..<frames { mic[f] /= micCount } }
        if tapCount > 1 { for f in 0..<frames { tap[f] /= tapCount } }

        let (assembler, continuation) = lock.withLock { (self.assembler, self.continuation) }
        guard let assembler, let continuation else { return }
        for (you, them) in assembler.push(you: mic, them: tap) {
            let at = lock.withLock { () -> Duration in
                let at = Duration.seconds(Double(framesDelivered) / MeetingAudioChunk.sampleRate)
                framesDelivered += Int64(them.count)
                lastDelivery = ContinuousClock.now
                return at
            }
            continuation.yield(MeetingAudioChunk(you: you, them: them, at: at))
        }
    }

    private func check(_ status: OSStatus, _ call: String) throws {
        guard status == noErr else { throw Failure.coreAudio(call, status) }
    }

    private struct Rig {
        let tapID: AudioObjectID
        let aggregateID: AudioObjectID
        let procID: AudioDeviceIOProcID
    }
}

/// Device-rate mono in, 16 kHz mono out, in ~100 ms pieces. One converter
/// per side, both fed on the IO queue only.
private final class ChunkAssembler {
    private let you: AVAudioConverter?
    private let them: AVAudioConverter?
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var youPending: [Float] = []
    private var themPending: [Float] = []
    private static let chunkFrames = 1_600

    init(inputRate: Double) {
        inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)!
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: MeetingAudioChunk.sampleRate,
            channels: 1, interleaved: false)!
        let needsConversion = inputRate != MeetingAudioChunk.sampleRate
        you = needsConversion ? AVAudioConverter(from: inputFormat, to: outputFormat) : nil
        them = needsConversion ? AVAudioConverter(from: inputFormat, to: outputFormat) : nil
    }

    func push(you youIn: [Float], them themIn: [Float]) -> [([Float], [Float])] {
        youPending.append(contentsOf: convert(youIn, with: you))
        themPending.append(contentsOf: convert(themIn, with: them))
        var out: [([Float], [Float])] = []
        while youPending.count >= Self.chunkFrames, themPending.count >= Self.chunkFrames {
            out.append((
                Array(youPending.prefix(Self.chunkFrames)),
                Array(themPending.prefix(Self.chunkFrames))))
            youPending.removeFirst(Self.chunkFrames)
            themPending.removeFirst(Self.chunkFrames)
        }
        return out
    }

    private func convert(_ samples: [Float], with converter: AVAudioConverter?) -> [Float] {
        guard let converter else { return samples }
        guard let input = AVAudioPCMBuffer(
            pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return [] }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        else { return [] }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

/// The handful of property reads the rig needs, spelled once.
private enum CoreAudioProperties {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultInputDevice() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : 0
    }

    static func deviceUID(_ device: AudioObjectID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    static func nominalSampleRate(_ device: AudioObjectID) -> Double {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return status == noErr ? rate : 0
    }

    /// Whether any process but this one has output running. The HAL lists
    /// every process that has opened audio IO; ours is told apart by pid,
    /// which every process object carries, where a bundle id is missing for
    /// helpers and daemons. `nil` when the list cannot be read at all.
    static func anotherProcessIsRunningOutput() -> Bool? {
        guard let processes = processObjects() else { return nil }
        let mine = ProcessInfo.processInfo.processIdentifier
        return processes.contains { process in
            pid(of: process) != mine && isRunningOutput(process) == true
        }
    }

    private static func processObjects() -> [AudioObjectID]? {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return nil }
        guard size > 0 else { return [] }
        var objects = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects
        ) == noErr else { return nil }
        return objects
    }

    private static func pid(of process: AudioObjectID) -> pid_t? {
        var address = address(kAudioProcessPropertyPID)
        var pid = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid)
        return status == noErr ? pid : nil
    }

    private static func isRunningOutput(_ process: AudioObjectID) -> Bool? {
        var address = address(kAudioProcessPropertyIsRunningOutput)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value != 0
    }

    static func inputChannels(_ device: AudioObjectID) -> [Int] {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }
}
