/// the capture each press is handed, and when one is thrown away.
///
/// one capture serves press after press while nothing moves: building an
/// engine is the slow part of a first press. anything moving underneath —
/// a monitor, the lid, airpods, a call taking them — makes it stale, and
/// the next press is handed a fresh one bound to whatever the mac says is
/// the mic right now. once the hardware has been quiet for a moment the
/// stale one is thrown away on its own, never from under a take that is
/// still holding it, and with pre-roll on a fresh one starts listening.
///
/// nothing here touches audio: building a capture is cheap, and its engine
/// is made, started and torn down on that capture's own queue.
@MainActor
final class CaptureSlot {
    private let clock: any UtteranceClock
    private let isInUse: @MainActor () -> Bool
    private let keepsListening: @MainActor () -> Bool
    private let make: @MainActor () -> any DisposableMicCapture
    private var current: (any DisposableMicCapture)?
    private var staleness = CaptureStaleness()
    private var settleTask: Task<Void, Never>?

    /// - isInUse: a take is holding the capture, so it is not the slot's
    ///   to throw away yet.
    /// - keepsListening: pre-roll is on, so a capture is kept listening
    ///   between presses.
    /// - make: a new capture. cheap: nothing is opened until it is started
    ///   or prepared.
    init(
        clock: any UtteranceClock,
        isInUse: @escaping @MainActor () -> Bool,
        keepsListening: @escaping @MainActor () -> Bool,
        make: @escaping @MainActor () -> any DisposableMicCapture
    ) {
        self.clock = clock
        self.isInUse = isInUse
        self.keepsListening = keepsListening
        self.make = make
    }

    /// the capture already built, unless something moved since: then a
    /// fresh one. the stale one is not trusted with another take.
    func captureForPress() -> any MicCapture {
        if staleness.isStale {
            throwAway()
        }
        return current ?? build()
    }

    /// ready ahead of the first press, so it is quick: built, and with
    /// pre-roll on, listening.
    func prepare() {
        (current ?? build()).prepare()
    }

    /// something moved underneath. the capture is stale now; it goes once
    /// nothing has moved for a moment.
    func deviceChanged() {
        staleness.changed(at: clock.now)
        scheduleSettle()
    }

    /// the machine gave up on it — it refused, or never answered — so it
    /// goes now and is never handed out again.
    func drop() {
        throwAway()
        // with pre-roll on, a new one should be listening, but not before
        // whatever wedged that one has had a moment to settle.
        if keepsListening() {
            deviceChanged()
        }
    }

    /// the mac is going to sleep: nothing listens through it. waking is a
    /// change like any other, and builds the next one.
    func suspend() {
        settleTask?.cancel()
        settleTask = nil
        throwAway()
    }

    /// pre-roll was switched. a capture is built for one mode or the
    /// other, so it goes, and with pre-roll on a fresh one starts listening.
    func listeningChanged() {
        throwAway()
        if keepsListening() {
            build().prepare()
        }
    }

    private func scheduleSettle() {
        guard let settlesAt = staleness.settlesAt else {
            return
        }
        lookAgain(after: clock.now.duration(to: settlesAt))
    }

    private func lookAgain(after wait: Duration) {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self, clock] in
            try? await clock.sleep(for: max(wait, .zero))
            guard !Task.isCancelled else {
                return
            }
            self?.settleIfQuiet()
        }
    }

    private func settleIfQuiet() {
        settleTask = nil
        guard !isInUse() else {
            // a take is holding it. look again once it might have let go.
            lookAgain(after: CaptureStaleness.quiet)
            return
        }
        guard staleness.settle(at: clock.now) else {
            scheduleSettle()
            return
        }

        throwAway()
        if keepsListening() {
            build().prepare()
        }
    }

    private func build() -> any DisposableMicCapture {
        let capture = make()
        current = capture
        return capture
    }

    private func throwAway() {
        current?.discard()
        current = nil
    }
}
