import Dispatch

/// Runs `body` on its own dispatch queue instead of Swift concurrency's
/// cooperative pool. The task, its cancellation, and `await`s inside work
/// as usual.
///
/// Use it around code that blocks waiting on a framework, such as
/// `AVAssetReaderOutput.copyNextSampleBuffer()`. The pool has one thread
/// per core and never adds more, so a few such waits can take all of it:
/// on a three-core CI runner, three audio reads did, and nothing else in
/// the process ran again.
public func withBlockingExecutor<T>(label: String, _ body: () async throws -> T) async throws -> T {
    try await withTaskExecutorPreference(QueueTaskExecutor(label: label), operation: body)
}

/// A task executor that runs its jobs on one serial dispatch queue. Such a
/// queue gets a new thread when others are blocked, unlike the pool.
private final class QueueTaskExecutor: TaskExecutor {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
