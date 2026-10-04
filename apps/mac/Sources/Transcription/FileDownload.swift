import Foundation

/// One file from the network to a temporary file of its own, reporting
/// 0…1 as it comes. The caller moves the file where it belongs, or deletes
/// it. Cancelling the task that awaits it cancels the download.
enum FileDownload {
    static func run(
        _ source: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: source) { location, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let location, let response else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    // the system deletes `location` when this returns, so
                    // the file is moved somewhere that is the caller's.
                    let kept = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                    do {
                        try FileManager.default.moveItem(at: location, to: kept)
                        continuation.resume(returning: (kept, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.set(task, observing: progress)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// The task and its progress watch, for the cancel handler, which can
    /// run on any thread, before or after the task exists.
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDownloadTask?
        private var watch: NSKeyValueObservation?
        private var cancelled = false

        func set(_ task: URLSessionDownloadTask, observing progress: @escaping @Sendable (Double) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            self.task = task
            watch = task.progress.observe(\.fractionCompleted) { value, _ in
                progress(value.fractionCompleted)
            }
            if cancelled { task.cancel() }
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            task?.cancel()
        }
    }
}
