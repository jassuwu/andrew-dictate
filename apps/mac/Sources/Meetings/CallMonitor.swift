import Foundation
import os

/// The call watcher, fed (ADR 0047). The mic listener says when anyone takes
/// the mic; the schedule says when to read Core Audio's processes and when to
/// stop; the reads run on a queue of their own; the watcher, here on the main
/// actor, turns what they say into a suggestion and a call that is on.
///
/// It suggests, and what it suggests goes to whoever owns the pill. Nothing
/// in here can start or stop a recording.
@MainActor
final class CallMonitor {
    /// `record(zoom)` or `stop(zoom)`, once each per call.
    var onSuggestion: ((CallWatcher.Suggestion) -> Void)?
    /// `currentCall` or `unrecordedCall` changed.
    var onCallsChanged: (() -> Void)?
    /// Whether a meeting is recording, asked at every observation.
    var isRecording: () -> Bool = { false }

    /// The call on now, recorded or not: what a meeting started from the
    /// menu is named after.
    private(set) var currentCall: String?
    /// The call on now that nothing is recording.
    private(set) var unrecordedCall: String?

    private let mic: any MicUseSignal
    private let read: @Sendable () async -> [AudioProcess]?
    private let ownPID: Int32
    private let now: () -> Duration
    private let sleep: @Sendable (Duration) async -> Void
    private let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "call")

    private var watcher = CallWatcher()
    private var schedule = CallReadingSchedule()
    private var isStarted = false
    private var micInUse = false
    /// From the last read. True until a read says otherwise, so the first
    /// reads after the mic is taken are close together.
    private var othersOnTheMic = true
    private var lastApps: [CallWatcher.App] = []
    private var loop: Task<Void, Never>?

    init(
        mic: any MicUseSignal = MicInUseListener(),
        read: @escaping @Sendable () async -> [AudioProcess]? = CallMonitor.readOffTheMainThread,
        ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        now: (() -> Duration)? = nil,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.mic = mic
        self.read = read
        self.ownPID = ownPID
        let origin = ContinuousClock.now
        self.now = now ?? { ContinuousClock.now - origin }
        self.sleep = sleep
    }

    private nonisolated static let readingQueue = DispatchQueue(
        label: "\(AppIdentity.bundleID).call-reader", qos: .utility)

    /// The HAL on a queue of its own: it can be the thing that is stuck,
    /// and the main thread is dictation's.
    nonisolated static let readOffTheMainThread: @Sendable () async -> [AudioProcess]? = {
        await withCheckedContinuation { continuation in
            readingQueue.async {
                continuation.resume(returning: AudioProcessList.running())
            }
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        logger.info("watching for calls")
        mic.start { [weak self] inUse in
            Task { @MainActor in self?.micChanged(inUse) }
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        mic.stop()
        loop?.cancel()
        loop = nil
        micInUse = false
        othersOnTheMic = true
        lastApps = []
        watcher = CallWatcher()
        schedule = CallReadingSchedule()
        publish()
        logger.info("stopped watching for calls")
    }

    /// A meeting started or stopped. The watcher hears it now rather than at
    /// the next read, so the call stops reading as unrecorded the moment you
    /// press record; between reads it assumes the apps are as they were.
    func recordingChanged() {
        guard isStarted else { return }
        observe(lastApps)
        wake()
    }

    /// No to the record suggestion, for this call.
    func declineTheCall() {
        watcher.dismissRecordSuggestion()
    }

    private func micChanged(_ inUse: Bool) {
        guard isStarted, inUse != micInUse else { return }
        micInUse = inUse
        logger.info("the mic is \(inUse ? "in use" : "free", privacy: .public)")
        wake()
    }

    /// Something changed: plan again now, not at the end of the last wait.
    private func wake() {
        loop?.cancel()
        loop = Task { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        while !Task.isCancelled, isStarted {
            let plan = schedule.plan(
                at: now(),
                micInUse: micInUse,
                isRecording: isRecording(),
                followingACall: watcher.currentCall != nil,
                othersOnTheMic: othersOnTheMic)
            switch plan.step {
            case .read?:
                // a read that cannot be done is skipped, not taken for a
                // quiet mac: that would end a call nobody left.
                if let processes = await read(), isStarted {
                    othersOnTheMic = processes.contains {
                        $0.pid != ownPID && $0.isRunningInput
                    }
                    observe(MeetingApps.apps(in: processes, leavingOut: ownPID))
                }
            case .observeNothing?:
                observe([])
            case nil:
                break
            }
            guard let next = plan.next else {
                lastApps = []
                return
            }
            let wait = next - now()
            if wait > .zero {
                await sleep(wait)
            }
        }
    }

    private func observe(_ apps: [CallWatcher.App]) {
        if apps != lastApps {
            let said = apps.isEmpty ? "none" : apps.map(Self.describe).joined(separator: ", ")
            logger.info("call apps: \(said, privacy: .public)")
        }
        lastApps = apps
        let suggestions = watcher.observe(apps, isRecording: isRecording(), at: now())
        publish()
        for suggestion in suggestions {
            logger.notice("suggesting \(String(describing: suggestion), privacy: .public)")
            onSuggestion?(suggestion)
        }
    }

    private func publish() {
        let current = watcher.currentCall
        let unrecorded = watcher.unrecordedCall
        guard current != currentCall || unrecorded != unrecordedCall else { return }
        currentCall = current
        unrecordedCall = unrecorded
        logger.notice(
            "call: \(current ?? "none", privacy: .public), unrecorded: \(unrecorded ?? "none", privacy: .public)")
        onCallsChanged?()
    }

    /// `zoom (mic, audio)`: app names only, nothing about what is said.
    private static func describe(_ app: CallWatcher.App) -> String {
        let parts = [app.holdsMic ? "mic" : nil, app.playsAudio ? "audio" : nil].compactMap { $0 }
        return "\(app.name) (\(parts.joined(separator: ", ")))"
    }
}
