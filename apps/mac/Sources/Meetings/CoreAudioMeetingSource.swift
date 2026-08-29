import AVFoundation
import CoreAudio
import Foundation
import os

/// The capture layer, as ticket 002 laid it out and the spike proved on this
/// machine: a Core Audio process tap on the meeting app's processes, fed into
/// a private aggregate device whose only real sub-device — and therefore
/// clock — is the microphone. One `AudioBufferList` per cycle carries both,
/// so alignment is the HAL's job. The tap is created by bundle id with
/// process restore on, so a helper that relaunches keeps being heard.
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
    private let lock = NSLock()

    // All guarded by `lock`, touched from the caller and the IO queue.
    private var rig: Rig?
    private var targets: [String] = []
    private var continuation: AsyncStream<MeetingAudioChunk>.Continuation?
    private var assembler: ChunkAssembler?
    private var framesDelivered: Int64 = 0
    private var player: AVAudioPlayer?

    init() {}

    // MARK: - MeetingAudioSource

    func start(tapping app: RunningApp) async throws -> AsyncStream<MeetingAudioChunk> {
        let targets = MeetingApps.tapBundleIDs(for: app)
        let (stream, continuation) = AsyncStream<MeetingAudioChunk>.makeStream(
            bufferingPolicy: .unbounded)
        lock.withLock {
            self.targets = targets
            self.continuation = continuation
            self.framesDelivered = 0
        }
        try build()
        playProbeTone()
        return stream
    }

    func rebuild() async throws {
        teardown()
        try build()
        // The tone again: a rebuilt tap must prove itself like a new one.
        playProbeTone()
    }

    func stop() async {
        teardown()
        let continuation = lock.withLock { () -> AsyncStream<MeetingAudioChunk>.Continuation? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
    }

    // MARK: - the onboarding proof

    /// ADR 0021's probe, run one screen earlier: tap *ourselves*, play the
    /// start sound, and report whether the tap heard it. This is what fires
    /// the real "record your system audio" prompt. Note the spike's caveat:
    /// on a first run the tap delivers audio before macOS has even asked, so
    /// a pass here is not proof of a grant — every real capture proves it
    /// again, which is the doctrine anyway.
    static func proveSystemAudio(within window: Duration = .seconds(1.5)) async -> Bool {
        let source = CoreAudioMeetingSource()
        let me = RunningApp(
            name: "andrew dictate",
            bundleID: Bundle.main.bundleIdentifier ?? AppIdentity.bundleID,
            pid: ProcessInfo.processInfo.processIdentifier)
        guard let stream = try? await source.start(tapping: me) else { return false }
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
        let targets = lock.withLock { self.targets }

        let description = CATapDescription(stereoMixdownOfProcesses: [])
        description.bundleIDs = targets
        description.isProcessRestoreEnabled = true
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
        logger.info("tap up: \(targets.joined(separator: ","), privacy: .public) at \(rate, privacy: .public) Hz")
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
