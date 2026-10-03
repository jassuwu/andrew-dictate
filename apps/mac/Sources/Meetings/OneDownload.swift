import Foundation

/// A download into one folder that several may ask for at once — a
/// meeting's load, the fetch beside it, setup — run once at a time:
/// whoever asks while it runs waits on that one, so two never write into
/// the folder together. Asked again once it has ended, it runs again, so a
/// download that failed is tried afresh.
actor OneDownload {
    private let fetch: @Sendable () async throws -> Void
    private var running: Task<Void, any Error>?

    init(_ fetch: @escaping @Sendable () async throws -> Void) {
        self.fetch = fetch
    }

    /// Until the download running now, or a fresh one, has ended.
    func run() async throws {
        try await (running ?? start()).value
    }

    /// The same, waited on for `limit` at most: past that it throws
    /// `Deadline.Passed`, and the download goes on where it is, for the
    /// next to ask to join.
    func run(within limit: Duration) async throws {
        try await Deadline.race(limit) { try await self.run() }
    }

    private func start() -> Task<Void, any Error> {
        let fetch = fetch
        let download = Task {
            do {
                try await fetch()
            } catch {
                await ended()
                throw error
            }
            await ended()
        }
        running = download
        return download
    }

    /// Cleared before anyone waiting on it hears it ended, so whoever asks
    /// next starts a fresh one.
    private func ended() {
        running = nil
    }
}
