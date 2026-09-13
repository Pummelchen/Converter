import Foundation

actor AsyncSemaphore {
    // Waiters are identified so cancellation resumes the task that was actually
    // cancelled. Resuming positionally strands the cancelled task in the queue and
    // fails an unrelated one, which is reachable whenever `async let` siblings are
    // torn down after one of them throws.
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let limit: Int
    private var available: Int
    private var waiters: [Waiter] = []
    // Ids of tasks that are between wait() and enqueue(). Only an id in here may leave a
    // marker in cancelledBeforeSuspension: a cancel that arrives after signal() has already
    // resumed the waiter finds neither the waiter nor the id and is a no-op.
    private var arming: Set<UUID> = []
    private var cancelledBeforeSuspension: Set<UUID> = []

    // Observability for tests; production code has no reason to look inside.
    var waiterCount: Int { waiters.count }
    var pendingCancellationCount: Int { cancelledBeforeSuspension.count }

    init(value: Int) {
        self.limit = max(1, value)
        self.available = max(1, value)
    }

    func wait() async throws {
        // A task that is already cancelled must not take a permit. `async let` siblings are
        // cancelled when one of them throws, and a sibling that still queued up would start
        // a full ffmpeg or magick job whose result nobody is going to await.
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }

        let id = UUID()
        arming.insert(id)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(id: id, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func enqueue(id: UUID, continuation: CheckedContinuation<Void, any Error>) {
        arming.remove(id)
        // The cancellation handler can run before suspension completes; honor it here.
        if cancelledBeforeSuspension.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }
        waiters.append(Waiter(id: id, continuation: continuation))
    }

    private func cancelWaiter(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        // Cancellation raced ahead of enqueue(), which will consume this marker. Without the
        // arming check the marker was also left behind for a waiter that signal() had already
        // resumed, and the set grew by one entry per such race for the life of the semaphore.
        if arming.contains(id) {
            cancelledBeforeSuspension.insert(id)
        }
    }

    func signal() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume()
            return
        }
        available = min(limit, available + 1)
    }

    func withPermit<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await wait()
        // Cancellation can land between signal() handing this task the permit and the task
        // running again; the permit then goes straight back instead of into a doomed job.
        do {
            try Task.checkCancellation()
        } catch {
            signal()
            throw error
        }
        defer {
            signal()
        }
        return try await operation()
    }
}
