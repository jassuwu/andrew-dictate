import Foundation
import os

/// the press category: a stall is part of how a press felt.
private let watchdogLogger = Logger(
    subsystem: AppIdentity.loggingSubsystem,
    category: "press"
)

/// Pings the main thread from a background queue while a press is in
/// flight, and for a few seconds after, and for ten seconds after the
/// hardware moves underneath — a device, a wake, the displays — and says
/// when a ping went unanswered for more than half a second: the hourglass
/// in the menu bar, caught in the field instead of described afterwards.
///
/// Only while something is happening: at idle there is no timer at all,
/// because a menu bar app that wakes four times a second to check on itself
/// is a menu bar app that shows up in the energy pane.
///
/// A stall is said once, when the main thread answers again, with how long
/// it was gone. A main thread that does not come back cannot say anything,
/// so past `stuckAfter` this queue says it instead — the one line a hang
/// that ends in a force quit would otherwise never leave.
final class MainThreadWatchdog: @unchecked Sendable {
    /// what the app was doing when the main thread went quiet, as the log
    /// line names it.
    enum Phase: String, Sendable {
        case idle
        case prewarming
        case recording
        case transcribing
        /// no press in flight, inside the window after the hardware moved:
        /// the stall a monitor or the lid used to leave.
        case hardwareChanged = "hardware-changed"
    }

    private let interval: TimeInterval
    private let threshold: TimeInterval
    private let linger: TimeInterval
    private let afterHardwareChange: TimeInterval
    private let stuckAfter: TimeInterval
    private let onStall: @MainActor @Sendable (_ milliseconds: Int) -> Void
    private let queue = DispatchQueue(
        label: "\(AppIdentity.bundleID).watchdog",
        qos: .utility
    )

    // everything below is touched only on `queue`.
    private var timer: DispatchSourceTimer?
    /// the press in flight, and what it is doing. nil between presses.
    private var press: Phase?
    /// with no press in flight, the timer runs until this: a press's
    /// linger or a hardware change's window, whichever ends later.
    private var watchUntil: DispatchTime?
    private var hardwareChangedUntil: DispatchTime?
    private var stopCheck: DispatchWorkItem?
    private var outstandingPing: (sentAt: UInt64, saidStuck: Bool)?

    /// `onStall` runs on the main thread once it answers, with how long it
    /// was gone, for every stall past `threshold`.
    init(
        interval: TimeInterval = 0.25,
        threshold: TimeInterval = 0.5,
        linger: TimeInterval = 5,
        afterHardwareChange: TimeInterval = 10,
        stuckAfter: TimeInterval = 5,
        onStall: @escaping @MainActor @Sendable (_ milliseconds: Int) -> Void
    ) {
        self.interval = interval
        self.threshold = threshold
        self.linger = linger
        self.afterHardwareChange = afterHardwareChange
        self.stuckAfter = stuckAfter
        self.onStall = onStall
    }

    deinit {
        timer?.cancel()
    }

    /// whether the timer exists. at idle, after the linger, it must not.
    var isWatching: Bool {
        queue.sync { timer != nil }
    }

    /// a press is in flight, in `phase`: ping until it winds down.
    func watch(_ phase: Phase) {
        queue.async { [self] in
            press = phase
            startTicking()
        }
    }

    /// the press is over. a stall right after it still belongs to it, so
    /// keep pinging through the linger, then stop costing anything.
    func windDown() {
        queue.async { [self] in
            guard press != nil else {
                return
            }
            press = nil
            keepTicking(until: .now() + linger)
        }
    }

    /// the hardware moved underneath: a device, a wake, the displays. the
    /// main thread stalled after these before any key was pressed, so the
    /// window starts here, press or not.
    func watchAfterHardwareChange() {
        queue.async { [self] in
            let until = DispatchTime.now() + afterHardwareChange
            hardwareChangedUntil = until
            startTicking()
            keepTicking(until: until)
        }
    }

    private func startTicking() {
        guard timer == nil else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(25)
        )
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    private func keepTicking(until deadline: DispatchTime) {
        let until = max(watchUntil ?? deadline, deadline)
        watchUntil = until
        stopCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.stopIfDone()
        }
        stopCheck = work
        queue.asyncAfter(deadline: until, execute: work)
    }

    /// nothing in flight and every window over: no timer at all.
    private func stopIfDone() {
        stopCheck = nil
        guard press == nil else {
            // a press took over; its wind-down sets the next check.
            return
        }
        if let watchUntil, DispatchTime.now() < watchUntil {
            keepTicking(until: watchUntil)
            return
        }
        timer?.cancel()
        timer = nil
        watchUntil = nil
        hardwareChangedUntil = nil
    }

    private var phase: Phase {
        if let press {
            return press
        }
        if let hardwareChangedUntil, DispatchTime.now() < hardwareChangedUntil {
            return .hardwareChanged
        }
        return .idle
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        if let ping = outstandingPing {
            let waited = Self.milliseconds(now - ping.sentAt)
            if !ping.saidStuck,
               Double(waited) >= stuckAfter * 1_000 {
                outstandingPing?.saidStuck = true
                watchdogLogger.notice(
                    """
                    main stalled \(waited, privacy: .public)+ ms during \
                    \(self.phase.rawValue, privacy: .public) and has not come back
                    """
                )
            }
            return
        }

        outstandingPing = (sentAt: now, saidStuck: false)
        let phase = phase
        DispatchQueue.main.async { [weak self] in
            let answeredAt = DispatchTime.now().uptimeNanoseconds
            self?.answered(sentAt: now, answeredAt: answeredAt, phase: phase)
        }
    }

    /// on the main thread, the moment it got round to the ping.
    private func answered(sentAt: UInt64, answeredAt: UInt64, phase: Phase) {
        queue.async { [weak self] in
            self?.outstandingPing = nil
        }
        let stalled = Self.milliseconds(answeredAt - sentAt)
        guard Double(stalled) > threshold * 1_000 else {
            return
        }
        watchdogLogger.notice(
            "main stalled \(stalled, privacy: .public) ms during \(phase.rawValue, privacy: .public)"
        )
        MainActor.assumeIsolated {
            onStall(stalled)
        }
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> Int {
        Int((Double(nanoseconds) / 1_000_000).rounded())
    }
}
