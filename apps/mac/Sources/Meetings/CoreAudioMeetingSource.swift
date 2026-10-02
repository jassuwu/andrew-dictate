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
/// The mic is the default input, and it follows the default input: when that
/// changes, or the rig's mic goes away, a whole new rig is brought up on the
/// new mic beside the old one (`MicHandoff` decides when, and on which), and
/// takes over on its first buffer. Its chunks carry on the same clock. That
/// move is silent: the probe tone is for a tap nobody has heard yet, and if
/// the new tap stops being heard the coordinator's own checks find out.
///
/// `@unchecked Sendable` because Core Audio hands us raw object ids and an
/// IOProc on its own queue; every field they touch is behind `lock`, the
/// ids themselves are plain integers the HAL owns, and what the handoff
/// keeps is only ever touched on `following`.
final class CoreAudioMeetingSource: MeetingAudioSource, @unchecked Sendable {
    enum Failure: Error, LocalizedError {
        case coreAudio(String, OSStatus)
        case noMicrophone
        case noStartSound
        /// The mic a rig was to be built on is no longer there.
        case micGone(String)
        /// A native call that did not come back in time, and what it was.
        case noAnswer(Stage)

        var errorDescription: String? {
            switch self {
            case .coreAudio(let call, let status): "\(call) failed (\(status))"
            case .noMicrophone: "no microphone"
            case .noStartSound: "the start sound is missing from the app"
            case .micGone(let mic): "the mic (\(mic)) is not there any more"
            case .noAnswer(let stage): stage.description
            }
        }
    }

    /// How far a build or a teardown had got, so one that never comes back
    /// can be told by what it was waiting on.
    enum Stage: Equatable, Sendable, CustomStringConvertible {
        /// Not begun: queued behind a call that has not come back.
        case waiting
        case openingTheTap
        case startingTheMic(String)
        case closing

        var description: String {
            let build = Int(CoreAudioMeetingSource.buildDeadline.totalSeconds)
            let teardown = Int(CoreAudioMeetingSource.teardownDeadline.totalSeconds)
            return switch self {
            case .waiting: "the last tap had still not closed after \(build) s"
            case .openingTheTap: "the tap did not open within \(build) s"
            case .startingTheMic(let mic): "the mic (\(mic)) did not start within \(build) s"
            case .closing: "the tap did not close within \(teardown) s"
            }
        }
    }

    /// How long a rig may take to build and start before it is called
    /// failed, and to stop and go before it is left behind. A native call
    /// can wedge in the audio server, and nothing may wait on one for ever.
    static let buildDeadline = Duration.seconds(8)
    static let teardownDeadline = Duration.seconds(5)

    /// The aggregate device's uid: one per build of the app, the same every
    /// session. A uid made fresh each time left a setting behind in the
    /// audio server for every session that did not stop cleanly. The
    /// release and development builds each have their own (`AppIdentity`),
    /// so neither can clear away the other's. A rig brought up beside the
    /// live one takes the same with `.b` on the end, and the next one the
    /// first again (`uid(for:)`).
    static var meetingDeviceUID: String {
        "\(AppIdentity.bundleID).meeting"
    }

    /// Setup's proof opens a tap of its own, and clearing a stale device
    /// before it builds must never take a meeting's from under it.
    static var proofDeviceUID: String {
        "\(AppIdentity.bundleID).meeting.proof"
    }

    private let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "tap")
    private let queue = DispatchQueue(label: "gg.jass.dictate.meeting-io", qos: .userInitiated)
    /// Everything said to the HAL that is not the audio itself: building and
    /// tearing down the rig, clearing a stale device, asking what is
    /// playing. One serial queue, so the sweep can never land on a device
    /// just built — and never the main thread, which only reads answers.
    private let hal = DispatchQueue(label: "gg.jass.dictate.meeting-hal", qos: .userInitiated)
    /// Where the mic is followed: the device listeners call back here, and
    /// the handoff's decisions, its timer and its answers all happen here.
    /// Not the HAL queue, which a build can hold for seconds, or for good.
    private let following = DispatchQueue(label: "gg.jass.dictate.meeting-mic", qos: .userInitiated)
    private let lock = NSLock()
    private let deviceUID: String

    // All guarded by `lock`, touched from the caller, the IO queue and
    // `following`.
    /// The rig whose buffers become chunks.
    private var live: Rig?
    /// A rig brought up beside the live one, until its first buffer makes
    /// it the live one or it is given up.
    private var standby: Rig?
    private var rigsBuilt = 0
    /// Counts starts, rebuilds and stops: a handoff begun under one count
    /// is not adopted under another.
    private var epoch = 0
    private var continuation: AsyncStream<MeetingAudioChunk>.Continuation?
    private var events = AsyncStream<MeetingSourceEvent> { $0.finish() }
    private var told: AsyncStream<MeetingSourceEvent>.Continuation?
    private var framesDelivered: Int64 = 0
    private var lastDelivery: ContinuousClock.Instant?
    private var player: AVAudioPlayer?
    /// Whether the last start sound could be played at all.
    private var startSoundSounded: Bool?
    private var playingTimer: DispatchSourceTimer?
    private var playing: Bool?
    /// The device the last teardown under each uid destroyed. The HAL's
    /// answer to a uid lags a destroy, so for a moment it still names this
    /// one, which is gone rather than stale.
    private var lastDestroyed: [String: AudioObjectID] = [:]

    // Only ever touched on `following`.
    private var handoff = MicHandoff()
    /// The epoch `handoff` belongs to.
    private var handoffEpoch = 0
    private var lookTimer: DispatchSourceTimer?
    private var listeners: [Listener] = []

    /// Built with the rest of the meeting machinery, and that is when a
    /// device an earlier session left under either uid is swept away.
    init(deviceUID: String = CoreAudioMeetingSource.meetingDeviceUID) {
        self.deviceUID = deviceUID
        hal.async { [weak self] in
            guard let self else { return }
            destroyStaleAggregate(uid(for: .first))
            destroyStaleAggregate(uid(for: .second))
        }
    }

    /// The uid a rig in `slot` is built under.
    private func uid(for slot: MicHandoff.Slot) -> String {
        switch slot {
        case .first: deviceUID
        case .second: "\(deviceUID).b"
        }
    }

    // MARK: - MeetingAudioSource

    func start() async throws -> AsyncStream<MeetingAudioChunk> {
        let (stream, continuation) = AsyncStream<MeetingAudioChunk>.makeStream(
            bufferingPolicy: .unbounded)
        let (events, told) = AsyncStream<MeetingSourceEvent>.makeStream(
            bufferingPolicy: .unbounded)
        let epoch = lock.withLock { () -> Int in
            self.continuation = continuation
            self.events = events
            self.told = told
            self.framesDelivered = 0
            self.lastDelivery = ContinuousClock.now
            self.epoch += 1
            return self.epoch
        }
        let rig = try await bringUp(.first, on: nil)
        try await adopt(rig, epoch: epoch)
        keepAskingWhatIsPlaying()
        playProbeTone()
        return stream
    }

    func rebuild() async throws {
        let (old, epoch) = lock.withLock { () -> ([Rig], Int) in
            defer {
                live = nil
                standby = nil
            }
            self.epoch += 1
            return ([live, standby].compactMap { $0 }, self.epoch)
        }
        await retire(old)
        // The live rig's uid, which it has just let go of: the other may
        // still be closing a standby that never delivered.
        let rig = try await bringUp(old.first?.slot ?? .first, on: nil)
        try await adopt(rig, epoch: epoch)
        skipTheTimeNothingWasDelivered()
        // The tone again: a rebuilt tap must prove itself like a new one.
        playProbeTone()
    }

    /// `rig` is the live one, and the mic is followed from it — unless the
    /// source was stopped while it was building, when it goes again.
    private func adopt(_ rig: Rig, epoch: Int) async throws {
        let adopted = lock.withLock { () -> Bool in
            guard self.epoch == epoch else { return false }
            live = rig
            return true
        }
        guard adopted else {
            await retire([rig])
            throw CancellationError()
        }
        follow(rig, epoch: epoch)
    }

    var sourceEvents: AsyncStream<MeetingSourceEvent> {
        lock.withLock { events }
    }

    /// A chunk's `at` is a frame count, and frames only exist while the tap
    /// is calling back — so a rebuild after a sleep would stamp the next
    /// chunk as if the lost hour never happened, and the gap the session
    /// records would be zero seconds long. Advancing the counter over the
    /// outage keeps the whole meeting on one clock. Small outages are the
    /// teardown itself and are left alone.
    private func skipTheTimeNothingWasDelivered() {
        lock.withLock { skipOutage(until: ContinuousClock.now) }
    }

    /// `skipTheTimeNothingWasDelivered`, with `lock` already held: a rig
    /// taking over from one whose mic went away carries on from where that
    /// one stopped, plus the time nothing came.
    private func skipOutage(until now: ContinuousClock.Instant) {
        guard let last = lastDelivery else { return }
        let outage = now - last
        guard outage > .seconds(1) else { return }
        framesDelivered += Int64(outage.totalSeconds * MeetingAudioChunk.sampleRate)
        lastDelivery = now
    }

    /// Where the meeting's clock is: the `at` the next chunk will carry.
    /// With `lock` held.
    private var nextStamp: Duration {
        .seconds(Double(framesDelivered) / MeetingAudioChunk.sampleRate)
    }

    var anythingIsPlaying: Bool? {
        lock.withLock { playing }
    }

    /// The live rig's: after a move to another mic, the one moved to.
    var micName: String? {
        lock.withLock { live?.mic.name }
    }

    /// Once a second while the tap is open, ask the HAL whether any process
    /// but this one is putting audio out, and keep the answer for whoever
    /// reads `anythingIsPlaying`. Ours is left out of the question: the tap
    /// hears it, but all it plays is the probe tone. `nil` until the first
    /// answer, and whenever the HAL will not list its processes — an answer
    /// we cannot get must not be read as "no".
    private func keepAskingWhatIsPlaying() {
        let timer = DispatchSource.makeTimerSource(queue: hal)
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
        let rigs = lock.withLock { () -> [Rig] in
            defer {
                live = nil
                standby = nil
            }
            epoch += 1
            return [live, standby].compactMap { $0 }
        }
        unfollow()
        await retire(rigs)
        let (continuation, told) = lock.withLock {
            () -> (AsyncStream<MeetingAudioChunk>.Continuation?, AsyncStream<MeetingSourceEvent>.Continuation?) in
            defer {
                self.continuation = nil
                self.told = nil
            }
            return (self.continuation, self.told)
        }
        continuation?.finish()
        told?.finish()
    }

    // MARK: - following the default input

    /// From now on `rig` is the meeting's, and the mic is followed from it.
    /// Whatever the last handoff was in the middle of is forgotten: it
    /// belonged to an epoch that has ended.
    private func follow(_ rig: Rig, epoch: Int) {
        following.async { [self] in
            handoff = MicHandoff()
            handoff.began(on: rig.mic, slot: rig.slot, seeing: CoreAudioProperties.mics())
            handoffEpoch = epoch
            listen()
            scheduleLook()
        }
    }

    private func unfollow() {
        following.async { [self] in
            stopListening()
            lookTimer?.cancel()
            lookTimer = nil
            handoff = MicHandoff()
        }
    }

    /// The handoff here is the meeting's own, not one left over from
    /// before a stop or a rebuild.
    private var isFollowing: Bool {
        handoff.mic != nil && lock.withLock { epoch } == handoffEpoch
    }

    /// The default input and the list of devices: between them, every way
    /// the meeting's mic can change or go.
    private func listen() {
        guard listeners.isEmpty else { return }
        let watched: [(AudioObjectPropertySelector, String)] = [
            (kAudioHardwarePropertyDefaultInputDevice, "the default input"),
            (kAudioHardwarePropertyDevices, "the device list"),
        ]
        for (selector, what) in watched {
            var listener = Listener(
                address: CoreAudioProperties.address(selector),
                block: { [weak self] _, _ in self?.somethingMoved(what) })
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &listener.address, following, listener.block)
            if status == noErr {
                listeners.append(listener)
            } else {
                logger.error("couldn't watch \(what, privacy: .public) (\(status, privacy: .public)); the meeting stays on its mic")
            }
        }
    }

    /// On the queue the blocks were added with, which is how Core Audio
    /// knows them again.
    private func stopListening() {
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &listener.address, following, listener.block)
        }
        listeners = []
    }

    private func somethingMoved(_ what: String) {
        guard isFollowing else { return }
        if handoff.changed(at: ContinuousClock.now, mics: CoreAudioProperties.mics()) {
            logger.info("mic: \(what, privacy: .public) changed")
            scheduleLook()
        } else {
            logger.debug("mic: \(what, privacy: .public) moved, and no input did")
        }
    }

    /// One timer, set for whenever the handoff next has something to decide.
    private func scheduleLook() {
        lookTimer?.cancel()
        lookTimer = nil
        guard let next = handoff.nextLook else { return }
        let wait = max(.zero, ContinuousClock.now.duration(to: next))
        // Rounded up: a look a millisecond early finds nothing settled.
        let milliseconds = Int((wait.totalSeconds * 1_000).rounded(.up))
        let timer = DispatchSource.makeTimerSource(queue: following)
        timer.schedule(deadline: .now() + .milliseconds(milliseconds), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.lookNow() }
        timer.resume()
        lookTimer = timer
    }

    private func lookNow() {
        lookTimer?.cancel()
        lookTimer = nil
        guard isFollowing else { return }
        let now = ContinuousClock.now
        var dropped: Rig?
        if handoff.standbyIsOverdue(at: now) {
            // Taken off the IO queue's hands first, so it cannot take over
            // in the instant it is given up.
            dropped = lock.withLock { () -> Rig? in
                defer { standby = nil }
                return standby
            }
            // It delivered just now after all: its takeover is queued
            // behind this, and settles the handoff.
            guard dropped != nil else { return }
        }
        let steps = handoff.look(at: now, mics: CoreAudioProperties.mics())
        if steps.isEmpty, let mic = handoff.mic {
            logger.info("mic: settled; still on \(mic.name, privacy: .public)")
        }
        perform(steps, dropping: dropped)
    }

    /// What the handoff decided, done. `dropped` is the standby taken back
    /// from the IO queue, for `.dropStandby`. `stamp` is when what is told
    /// happened, for a takeover, whose time is its first chunk's.
    private func perform(
        _ steps: [MicHandoff.Step], dropping dropped: Rig? = nil, at stamp: Duration? = nil
    ) {
        for step in steps {
            switch step {
            case .bringUp(let mic, let slot):
                bringUpStandby(on: mic, slot: slot)
            case .dropStandby:
                guard let dropped else { continue }
                logger.error("mic: \(dropped.mic.name, privacy: .public) came up and never delivered the mic; tearing it down")
                hal.async { self.teardown(dropped) }
            case .tell(let kind, let mic):
                tell(kind, mic: mic, at: stamp)
            }
        }
        scheduleLook()
    }

    /// Built beside the live rig, which keeps delivering meanwhile. No
    /// tone: this tap is heard the moment anything plays.
    private func bringUpStandby(on mic: MicHandoff.Mic, slot: MicHandoff.Slot) {
        let epoch = handoffEpoch
        logger.notice("mic: bringing up \(mic.name, privacy: .public) beside the live rig, through \(self.uid(for: slot), privacy: .public)")
        Task { [weak self] in
            guard let self else { return }
            do {
                let rig = try await bringUp(slot, on: mic)
                following.async { self.standbyBuilt(rig, epoch: epoch) }
            } catch {
                following.async { self.standbyFailed(error, epoch: epoch) }
            }
        }
    }

    /// The standby is up. It is the IO queue's to make the live rig from
    /// here, on its first buffer, unless the meeting moved on meanwhile.
    private func standbyBuilt(_ rig: Rig, epoch: Int) {
        let adopted = lock.withLock { () -> Bool in
            guard self.epoch == epoch else { return false }
            standby = rig
            return true
        }
        guard adopted else {
            hal.async { self.teardown(rig) }
            return
        }
        handoff.standbyUp(at: ContinuousClock.now)
        scheduleLook()
    }

    private func standbyFailed(_ error: any Error, epoch: Int) {
        guard epoch == handoffEpoch, isFollowing else { return }
        logger.error("mic: the next rig would not come up: \(error.localizedDescription, privacy: .public)")
        perform(handoff.standbyFailed(mics: CoreAudioProperties.mics()))
    }

    /// The old rig goes whatever else has happened: nothing else holds it.
    private func tookOver(_ takeover: Takeover) {
        let quiet = Int(takeover.quiet.totalSeconds * 1_000)
        logger.notice("mic: \(takeover.new.mic.name, privacy: .public) took over after \(quiet, privacy: .public) ms with nothing delivered")
        if let old = takeover.old {
            hal.async { self.teardown(old) }
        }
        guard takeover.epoch == handoffEpoch, isFollowing else { return }
        perform(handoff.standbyDelivered(), at: takeover.at)
    }

    /// For the meeting's record, and the log.
    private func tell(_ kind: MeetingSourceEvent.Kind, mic: MicHandoff.Mic?, at stamp: Duration?) {
        let (told, at) = lock.withLock { (self.told, stamp ?? nextStamp) }
        let name = mic?.name ?? "no mic"
        let seconds = String(format: "%.2f", at.totalSeconds)
        switch kind {
        case .micChanged:
            logger.notice("mic: moved to \(name, privacy: .public) at \(seconds, privacy: .public) s")
        case .micHandoffFailed:
            logger.error("mic: couldn't move to \(name, privacy: .public) at \(seconds, privacy: .public) s")
        case .micFellBack:
            logger.notice("mic: fell back to \(name, privacy: .public) at \(seconds, privacy: .public) s")
        }
        told?.yield(MeetingSourceEvent(kind: kind, mic: mic?.name, at: at))
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
        let source = CoreAudioMeetingSource(deviceUID: proofDeviceUID)
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

    /// A rig on `mic` — or, with none named, on the mic a meeting should use
    /// now — under `slot`'s uid, built and started on the HAL queue with
    /// eight seconds to do it. One that comes back later is nobody's, and
    /// is torn down where it lands.
    private func bringUp(_ slot: MicHandoff.Slot, on mic: MicHandoff.Mic?) async throws -> Rig {
        let progress = BuildProgress()
        return try await onHAL(
            within: Self.buildDeadline,
            late: { Failure.noAnswer(progress.stage) },
            abandoned: { [weak self] rig in
                self?.logger.notice("a rig came up after its deadline; tearing it down")
                self?.teardown(rig)
            },
            { try self.build(slot, on: mic, progress) })
    }

    /// Tears `rigs` down on the HAL queue, and waits five seconds for it at
    /// most. A teardown that never comes back is left to finish or not
    /// where it is: whoever waits on this — a stop, with a meeting's file
    /// still to write — goes on.
    private func retire(_ rigs: [Rig]) async {
        guard !rigs.isEmpty else { return }
        do {
            try await onHAL(within: Self.teardownDeadline, late: { Failure.noAnswer(.closing) }) {
                for rig in rigs { self.teardown(rig) }
            }
        } catch {
            logger.error("\(error.localizedDescription, privacy: .public); left behind")
        }
    }

    /// `work` on the HAL queue, given `limit` to come back. Whichever comes
    /// first is the answer: the work's own, or `late()`'s error. The clock
    /// runs off the HAL queue, which a call that never returns holds for
    /// good, along with everything queued behind it. Work that comes back
    /// after its deadline is handed to `abandoned`, there, to undo.
    private func onHAL<T: Sendable>(
        within limit: Duration,
        late: @escaping @Sendable () -> any Error,
        abandoned: @escaping @Sendable (T) -> Void = { _ in },
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<T, Error>) in
            let answer = FirstAnswer()
            hal.async {
                let result = Result { try work() }
                if answer.claim() {
                    done.resume(with: result)
                } else if case .success(let value) = result {
                    abandoned(value)
                }
            }
            let milliseconds = Int(limit.totalSeconds * 1_000)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .milliseconds(milliseconds)
            ) {
                if answer.claim() { done.resume(throwing: late()) }
            }
        }
    }

    /// The aggregate device under `uid`, destroyed if there is one. There is
    /// one only when a session before this did not get to destroy its own,
    /// and the HAL refuses a second device under a uid that is taken. Only
    /// ever on the HAL queue.
    private func destroyStaleAggregate(_ uid: String) {
        guard let stale = CoreAudioProperties.device(uid: uid),
              stale != lock.withLock({ lastDestroyed[uid] })
        else { return }
        let status = AudioHardwareDestroyAggregateDevice(stale)
        if status == noErr {
            logger.notice("cleared a stale aggregate device: \(uid, privacy: .public)")
        } else {
            logger.error("could not clear a stale aggregate device \(uid, privacy: .public) (\(status, privacy: .public))")
        }
    }

    /// A rig on `wanted`, or on the default input — the built-in mic when
    /// the default is none a meeting can use — under `slot`'s uid, started.
    /// Only ever on the HAL queue. `progress` is told how far it got.
    private func build(
        _ slot: MicHandoff.Slot, on wanted: MicHandoff.Mic?, _ progress: BuildProgress
    ) throws -> Rig {
        progress.stage = .openingTheTap
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

        guard let mic = wanted ?? CoreAudioProperties.micToUse() else {
            AudioHardwareDestroyProcessTap(tapID)
            throw Failure.noMicrophone
        }
        guard let micDevice = CoreAudioProperties.device(uid: mic.uid) else {
            AudioHardwareDestroyProcessTap(tapID)
            throw Failure.micGone(mic.name)
        }
        // An aggregate device (one made in Audio MIDI Setup) cannot sit
        // inside ours: the HAL leaves its channels out. The inputs inside it
        // go in instead, its main one first, as the clock.
        let parts = CoreAudioProperties.inputsInside(aggregate: micDevice) ?? [mic.uid]
        let micChannels = parts.compactMap { CoreAudioProperties.device(uid: $0) }
            .reduce(0) { $0 + CoreAudioProperties.inputChannels($1).reduce(0, +) }
        progress.stage = .startingTheMic(mic.name)

        let uid = uid(for: slot)
        destroyStaleAggregate(uid)
        let subDevices: [[String: Any]] = parts.enumerated().map { index, part in
            index == 0
                ? [kAudioSubDeviceUIDKey: part]
                : [kAudioSubDeviceUIDKey: part, kAudioSubDeviceDriftCompensationKey: true]
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "andrew dictate meeting",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceMainSubDeviceKey: parts[0],
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
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

        // Read for this rig, not once for the source: the next mic may run
        // at another rate.
        let nominal = CoreAudioProperties.nominalSampleRate(aggregateID)
        let rate = nominal > 0 ? nominal : 48_000
        let id = lock.withLock { () -> Int in
            rigsBuilt += 1
            return rigsBuilt
        }

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, inputData, _, _, _ in
            self?.ingest(inputData, from: id)
        }
        guard status == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw Failure.coreAudio("AudioDeviceCreateIOProcIDWithBlock", status)
        }

        let rig = Rig(
            id: id, slot: slot, uid: uid, mic: mic, tapID: tapID,
            aggregateID: aggregateID, procID: procID, micChannels: micChannels, rate: rate)
        do {
            try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
        } catch {
            teardown(rig)
            throw error
        }
        let from = parts == [mic.uid] ? "" : ", from \(parts.joined(separator: " + "))"
        logger.notice("tap up: the whole mac and \(mic.name, privacy: .public) (\(micChannels, privacy: .public) ch\(from, privacy: .public)), at \(rate, privacy: .public) Hz, through \(uid, privacy: .public)")
        return rig
    }

    /// Only ever on the HAL queue, or inside `build`, which is.
    private func teardown(_ rig: Rig) {
        AudioDeviceStop(rig.aggregateID, rig.procID)
        queue.sync {}
        AudioDeviceDestroyIOProcID(rig.aggregateID, rig.procID)
        AudioHardwareDestroyAggregateDevice(rig.aggregateID)
        AudioHardwareDestroyProcessTap(rig.tapID)
        lock.withLock { lastDestroyed[rig.uid] = rig.aggregateID }
        logger.info("tap down: \(rig.mic.name, privacy: .public), through \(rig.uid, privacy: .public)")
    }

    /// The start sound, played whether or not sound feedback is on: it is the
    /// probe (ADR 0021), and cannot be made silent without removing it.
    private func playProbeTone() {
        guard let url = Bundle.main.url(forResource: "dictation-start", withExtension: "wav", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: "dictation-start", withExtension: "wav")
        else {
            logger.error("start sound missing; the probe cannot play")
            lock.withLock { startSoundSounded = false }
            return
        }
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        // false with no output to play on: then the tap had nothing to hear,
        // and the meeting must not read its silence as a deaf tap.
        let played = player?.play() ?? false
        lock.withLock {
            self.player = player
            startSoundSounded = played
        }
        logger.info("probe tone played: \(played, privacy: .public)")
    }

    // MARK: - the IO proc

    /// A buffer from rig `id`. Read if it is the live rig's. The standby's
    /// first makes it the live one, there and then, so not a buffer of it
    /// is lost to the handoff; the old rig's are dropped from that moment,
    /// as is the one last callback of any rig being torn down.
    private func ingest(_ inputData: UnsafePointer<AudioBufferList>, from id: Int) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let first = list.first, first.mData != nil, first.mNumberChannels > 0 else { return }
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / Int(first.mNumberChannels)
        guard frames > 0 else { return }
        let layout = list.reduce(0) { $0 + Int($1.mNumberChannels) }

        let (rig, continuation, takeover) = lock.withLock {
            () -> (Rig?, AsyncStream<MeetingAudioChunk>.Continuation?, Takeover?) in
            if let live, live.id == id {
                return (live, self.continuation, nil)
            }
            // A standby whose mic brought none of its channels is not the
            // mic the meeting moved to. It is left to run out its time,
            // and the move is told as failed.
            guard let standby, standby.id == id,
                  MicMix.micChannels(said: standby.micChannels, carried: layout) > 0
            else { return (nil, nil, nil) }
            let old = live
            live = standby
            self.standby = nil
            // An old rig still delivering left off a moment ago, and the
            // clock carries straight on; one whose mic went stopped
            // seconds back, and the clock skips the time nothing came.
            let now = ContinuousClock.now
            let quiet = lastDelivery.map { now - $0 } ?? .zero
            skipOutage(until: now)
            let takeover = Takeover(
                old: old, new: standby, at: nextStamp, quiet: quiet, epoch: epoch)
            return (standby, self.continuation, takeover)
        }
        if let takeover {
            following.async { self.tookOver(takeover) }
        }
        guard let rig, let continuation else { return }
        let micChannels = MicMix.micChannels(said: rig.micChannels, carried: layout)
        if rig.layout == nil {
            rig.layout = layout
            if micChannels < rig.micChannels {
                logger.error("\(rig.mic.name, privacy: .public) brought \(micChannels, privacy: .public) of its \(rig.micChannels, privacy: .public) channels through \(rig.uid, privacy: .public); the rest of `you` is silence")
            } else {
                logger.info("first buffer through \(rig.uid, privacy: .public): \(layout, privacy: .public) channels, \(micChannels, privacy: .public) of them the mic's")
            }
        }
        // A rig whose mic went from under it can keep calling back with the
        // tap's channels where the mic's were. That is not `you`.
        guard rig.layout == layout else { return }

        // Sub-device channels come first, taps after (002 §4, confirmed by
        // the spike): the first `micChannels` flat channels are the mic.
        // The mic's are kept apart and mixed by `MicMix`; the tap's two
        // sides are averaged.
        var micChannelSamples: [[Float]] = []
        var tap = [Float](repeating: 0, count: frames)
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
                    var samples = [Float](repeating: 0, count: frames)
                    for f in 0..<n { samples[f] = data[f * channels + channel] }
                    micChannelSamples.append(samples)
                } else {
                    tapCount += 1
                    for f in 0..<n { tap[f] += data[f * channels + channel] }
                }
            }
        }
        let mic = micChannelSamples.isEmpty
            ? [Float](repeating: 0, count: frames)
            : MicMix.mono(micChannelSamples)
        if tapCount > 1 { for f in 0..<frames { tap[f] /= tapCount } }

        for (you, them) in rig.assembler.push(you: mic, them: tap) {
            let at = lock.withLock { () -> Duration in
                let at = nextStamp
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

    /// One build of the rig: the tap and the mic in their aggregate, the IO
    /// proc on it, and what reading its buffers takes. All its own: the
    /// next rig may be on a mic with another rate or another channel count.
    ///
    /// `@unchecked Sendable`: the ids are plain integers the HAL owns, and
    /// the assembler and the layout are only ever touched on the IO queue.
    private final class Rig: @unchecked Sendable {
        let id: Int
        let slot: MicHandoff.Slot
        let uid: String
        let mic: MicHandoff.Mic
        let tapID: AudioObjectID
        let aggregateID: AudioObjectID
        let procID: AudioDeviceIOProcID
        /// How many of the flat channels, from the first, are the mic's.
        let micChannels: Int
        let rate: Double
        let assembler: ChunkAssembler
        /// How many channels its first buffer carried, the mic's and the
        /// tap's together.
        var layout: Int?

        init(
            id: Int, slot: MicHandoff.Slot, uid: String, mic: MicHandoff.Mic,
            tapID: AudioObjectID, aggregateID: AudioObjectID, procID: AudioDeviceIOProcID,
            micChannels: Int, rate: Double
        ) {
            self.id = id
            self.slot = slot
            self.uid = uid
            self.mic = mic
            self.tapID = tapID
            self.aggregateID = aggregateID
            self.procID = procID
            self.micChannels = micChannels
            self.rate = rate
            assembler = ChunkAssembler(inputRate: rate)
        }
    }

    /// The standby's first buffer made it the live rig. Handed from the IO
    /// queue to `following`, which tears the old one down and tells.
    private struct Takeover: @unchecked Sendable {
        let old: Rig?
        let new: Rig
        /// The `at` of the new rig's first chunk.
        let at: Duration
        /// How long nothing had been delivered when it took over.
        let quiet: Duration
        let epoch: Int
    }

    /// A Core Audio listener and the property it listens to, kept so the
    /// same block can be removed again.
    private struct Listener {
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
}

/// How far a build has got, written on the HAL queue and read by its
/// deadline, which is not on it.
private final class BuildProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _stage: CoreAudioMeetingSource.Stage = .waiting

    var stage: CoreAudioMeetingSource.Stage {
        get { lock.withLock { _stage } }
        set { lock.withLock { _stage = newValue } }
    }
}

/// A native call and its deadline race; this is the finish line. Whichever
/// claims it first answers, and the other knows it lost.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

// MARK: - the quiet probe

extension CoreAudioMeetingSource {
    /// The quiet probe's level: the peak of the tone, in dBFS. Provisional —
    /// whether a person hears it is for the owner's ears to tune. -40 dBFS
    /// is a peak of 0.01, ten times the tap's silence floor of 0.001; the
    /// tap hears it at 0.007 rms, seven times the floor, and before the
    /// system volume, so the margin does not shrink when you turn the mac
    /// down (measurement 02: -50 reads only twice the floor).
    static let quietProbeLevel: Float = -40
    /// A third of a second of 1 kHz: long enough to fill a few of the tap's
    /// tenth-of-a-second chunks, short enough to pass for nothing.
    private static let quietProbeLength = 0.3
    private static let quietProbeFrequency: Float = 1_000

    var startSoundPlayed: Bool? {
        lock.withLock { startSoundSounded }
    }

    func playQuietProbe() async throws {
        try await playQuietProbe(dBFS: Self.quietProbeLevel)
    }

    /// The tone, through an engine of its own on the default output, and
    /// back once it has played out. The tap hears it because the tap hears
    /// this process. Throws when it cannot be played at all — no output
    /// device, an engine that will not start — which is not the tap
    /// failing to hear it.
    func playQuietProbe(dBFS level: Float) async throws {
        let engine: AVAudioEngine
        do {
            engine = try Self.startTone(peak: pow(10, level / 20))
        } catch {
            logger.error("the quiet probe could not play: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        // a wait rather than a completion handler: a device that goes away
        // mid-tone never calls one back, and this must come back regardless.
        try? await Task.sleep(for: .seconds(Self.quietProbeLength + 0.2))
        engine.stop()
    }

    /// The engine, started with the tone scheduled and playing.
    private static func startTone(peak: Float) throws -> AVAudioEngine {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let tone = tone(peak: peak, format: format)
        else {
            throw CocoaError(.featureUnsupported)
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        player.scheduleBuffer(tone, completionHandler: nil)
        player.play()
        return engine
    }

    /// A sine at `quietProbeFrequency`, eased in and out over ten
    /// milliseconds so it starts and stops without a click.
    private static func tone(peak: Float, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let frames = AVAudioFrameCount(rate * quietProbeLength)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = frames
        let count = Int(frames)
        let ease = Int(rate * 0.01)
        let step = 2 * Float.pi * quietProbeFrequency / Float(rate)
        for i in 0..<count {
            let edge = min(i, count - 1 - i)
            let envelope = edge < ease ? Float(edge) / Float(ease) : 1
            samples[i] = peak * envelope * sin(step * Float(i))
        }
        return buffer
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

    /// What the mac says about its inputs right now: the default, the
    /// built-in mic, and every one there is. A default that is not among
    /// them, or has no input, is none a meeting can use. Our own rigs are
    /// left out: they are not mics, and their coming and going is not an
    /// input changing.
    static func mics() -> MicHandoff.Mics {
        var present: Set<String> = []
        var builtIn: MicHandoff.Mic?
        for device in devices() where inputChannels(device).reduce(0, +) > 0 && isAlive(device) {
            guard let uid = deviceUID(device),
                  !uid.hasPrefix(CoreAudioMeetingSource.meetingDeviceUID)
            else { continue }
            present.insert(uid)
            if builtIn == nil, transportType(device) == kAudioDeviceTransportTypeBuiltIn {
                builtIn = MicHandoff.Mic(uid: uid, name: name(device) ?? uid)
            }
        }
        let device = defaultInputDevice()
        let defaultInput = deviceUID(device).flatMap { uid in
            present.contains(uid) ? MicHandoff.Mic(uid: uid, name: name(device) ?? uid) : nil
        }
        return MicHandoff.Mics(defaultInput: defaultInput, builtIn: builtIn, present: present)
    }

    /// The mic a meeting starts on: the default input, or the built-in mic
    /// when the default is none a meeting can use.
    static func micToUse() -> MicHandoff.Mic? {
        let mics = mics()
        return mics.defaultInput ?? mics.builtIn
    }

    private static func devices() -> [AudioObjectID] {
        objects(kAudioHardwarePropertyDevices, of: AudioObjectID(kAudioObjectSystemObject))
    }

    /// The uids of the inputs inside an aggregate device, its main one
    /// first; nil when `device` is not an aggregate, or has none.
    static func inputsInside(aggregate device: AudioObjectID) -> [String]? {
        guard transportType(device) == kAudioDeviceTransportTypeAggregate else { return nil }
        let inputs = objects(kAudioAggregateDevicePropertyActiveSubDeviceList, of: device)
            .filter { inputChannels($0).reduce(0, +) > 0 }
            .compactMap { deviceUID($0) }
        guard !inputs.isEmpty else { return nil }
        guard let main = string(kAudioAggregateDevicePropertyMainSubDevice, of: device),
              inputs.contains(main)
        else { return inputs }
        return [main] + inputs.filter { $0 != main }
    }

    private static func objects(
        _ selector: AudioObjectPropertySelector, of object: AudioObjectID
    ) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size > 0
        else { return [] }
        var objects = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &objects) == noErr
        else { return [] }
        return objects
    }

    /// True unless the HAL says otherwise: one it cannot be asked about is
    /// still in its own device list.
    private static func isAlive(_ device: AudioObjectID) -> Bool {
        uint32(kAudioDevicePropertyDeviceIsAlive, of: device).map { $0 != 0 } ?? true
    }

    private static func transportType(_ device: AudioObjectID) -> UInt32? {
        uint32(kAudioDevicePropertyTransportType, of: device)
    }

    private static func uint32(
        _ selector: AudioObjectPropertySelector, of device: AudioObjectID
    ) -> UInt32? {
        var address = address(selector)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
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
        string(kAudioDevicePropertyDeviceUID, of: device)
    }

    /// The name the mac shows for it: "MacBook Pro Microphone".
    static func name(_ device: AudioObjectID) -> String? {
        string(kAudioObjectPropertyName, of: device)
    }

    private static func string(
        _ selector: AudioObjectPropertySelector, of device: AudioObjectID
    ) -> String? {
        var address = address(selector)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    /// The device with this uid, if there is one. The HAL answers
    /// `kAudioObjectUnknown`, not an error, for a uid nothing has.
    static func device(uid: String) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) {
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
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
