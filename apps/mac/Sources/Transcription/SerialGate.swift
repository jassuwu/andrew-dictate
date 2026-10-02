import Synchronization

/// one call at a time, in the order they were asked: each waits for the one
/// before it to finish, however it finished.
///
/// FluidAudio's `AsrManager` is an actor, but a reentrant one: a second
/// `transcribe` starts the moment the first one suspends, and the two share
/// the manager's buffers mid-call. what is pasted has to be what the take
/// alone gives, so every call into one manager — the take, the key-down
/// wake, the health probe — goes through that manager's gate.
///
/// a call that never finishes holds every call behind it for good. that is
/// the point: a wedged manager can't be cancelled, only replaced, and the
/// replacement comes with a fresh gate, so nothing on it waits on the old
/// one.
final class SerialGate: Sendable {
    private struct Queue {
        /// finishes when the last call asked has finished.
        var last: Task<Void, Never>?
        var inFlight = 0
    }

    private let queue = Mutex(Queue())

    init() {}

    /// calls running or waiting their turn.
    var inFlight: Int {
        queue.withLock { $0.inFlight }
    }

    var isBusy: Bool {
        inFlight > 0
    }

    /// `work`, once every call asked before it has finished. cancelled
    /// while it waits, it never runs; cancelled while it runs, `work` is
    /// told, as it would be if it were called directly.
    func run<Value: Sendable>(
        _ work: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        // never nil: only `onlyIfIdle` declines.
        try await wait(for: enqueue(onlyIfIdle: false, work)!)
    }

    /// `work` now, or nil and nothing run when another call is running or
    /// waiting. for the wake: queued, it would stand between the take
    /// asked next and the engine.
    func runIfIdle<Value: Sendable>(
        _ work: @escaping @Sendable () async throws -> Value
    ) async throws -> Value? {
        guard let call = enqueue(onlyIfIdle: true, work) else {
            return nil
        }
        return try await wait(for: call)
    }

    /// the check and the place in line are one step under the lock, so
    /// nothing can be asked between them.
    private func enqueue<Value: Sendable>(
        onlyIfIdle: Bool,
        _ work: @escaping @Sendable () async throws -> Value
    ) -> Task<Value, Error>? {
        queue.withLock { queue in
            if onlyIfIdle, queue.inFlight > 0 {
                return nil
            }
            let previous = queue.last
            let call = Task {
                await previous?.value
                // counted out before the caller hears the answer, so a
                // caller that asks next finds the gate as it now is.
                defer { self.finished() }
                try Task.checkCancellation()
                return try await work()
            }
            queue.inFlight += 1
            queue.last = Task {
                _ = await call.result
            }
            return call
        }
    }

    private func finished() {
        queue.withLock { $0.inFlight -= 1 }
    }

    private func wait<Value: Sendable>(
        for call: Task<Value, Error>
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            try await call.value
        } onCancel: {
            call.cancel()
        }
    }
}
