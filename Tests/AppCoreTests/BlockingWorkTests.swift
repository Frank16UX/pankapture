import Dispatch
import Foundation
import Synchronization
import Testing
@testable import AppCore

@Suite("Blocking work")
struct BlockingWorkTests {
    /// More blocking calls than the cooperative pool has threads (one per
    /// core) all get going at once. Had they blocked pool threads, only one
    /// per core would start, and the rest would wait for them to finish.
    @Test func blockingCallsDontTakeThePool() async throws {
        let count = ProcessInfo.processInfo.activeProcessorCount + 2
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        // Off the pool: wait for every call to start, then let them all
        // finish either way, so a regression fails instead of hanging.
        DispatchQueue.global().async {
            let all = (0..<count).allSatisfy { _ in started.wait(timeout: .now() + 10) == .success }
            outcome.allStarted.withLock { $0 = all }
            for _ in 0..<count { release.signal() }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    try await withBlockingExecutor(label: "BlockingWorkTests.\(index)") {
                        started.signal()
                        block(on: release)
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(outcome.allStarted.withLock { $0 })
    }
}

private final class Outcome: Sendable {
    let allStarted = Mutex(false)
}

/// A synchronous wait, like the framework calls `withBlockingExecutor` is for.
private func block(on semaphore: DispatchSemaphore) {
    semaphore.wait()
}
