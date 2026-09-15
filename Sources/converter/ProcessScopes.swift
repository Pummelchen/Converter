import Foundation
import Synchronization

// Process bookkeeping for external commands, kept separate from ProcessRunner so the runner file
// stays within the repository's file_length budget. These types are internal to the module.
//
// Tracks one child by pid. The cancellation handler and the watchdog run on other threads while the
// launching task is blocked in `Process.waitUntilExit()`, so nothing here reads or mutates the
// `Process` object; `markFinished()` is set by the launching task as soon as the child is reaped,
// which closes the window in which a recycled pid could be signalled (#0141). All state is a pid and
// a mutex, so the type is genuinely Sendable instead of `@unchecked`.
final class ProcessHandle: Sendable {
    let pid: Int32
    private let finished = Mutex<Bool>(false)

    init(pid: Int32) {
        self.pid = pid
    }

    // Called by the launching task immediately after waitUntilExit returns.
    func markFinished() {
        finished.withLock { $0 = true }
    }

    var isFinished: Bool {
        finished.withLock { $0 }
    }

    func terminateIfRunning() {
        Self.terminate(pid: pid, unlessFinished: { [weak self] in self?.isFinished ?? true })
    }

    // SIGTERM first so a well-behaved tool can clean up, then SIGKILL if it is still there after the
    // grace period. The same escalation the timeout path uses, by pid only.
    static func terminate(pid: Int32, unlessFinished: @escaping @Sendable () -> Bool) {
        guard pid > 0, kill(pid, 0) == 0, !unlessFinished() else { return }
        kill(pid, SIGTERM)
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + ProcessRunner.killGraceSeconds) {
                guard kill(pid, 0) == 0, !unlessFinished() else { return }
                kill(pid, SIGKILL)
            }
    }
}

// One permitted operation's children. Scoped so a cancelled fan-out sibling stops its own external
// work instead of every process the shared runner has alive (#0117).
final class ProcessScope: Sendable {
    private let handles = Mutex<[ProcessHandle]>([])

    func track(_ handle: ProcessHandle) {
        handles.withLock { $0.append(handle) }
    }

    func untrack(_ handle: ProcessHandle) {
        handles.withLock { list in
            list.removeAll { $0 === handle }
        }
    }

    func terminateAll() {
        for handle in handles.withLock({ $0 }) {
            handle.terminateIfRunning()
        }
    }
}

// The scope stack is thread-confined: a permitted operation runs its synchronous body (and therefore
// every `run` call it makes) on one thread, with no suspension point inside, so a thread-local stack
// associates each child with the innermost open scope. That avoids threading a scope parameter
// through every `run` call site.
private final class ProcessScopeStackBox {
    var scopes: [ProcessScope] = []
}

enum ProcessScopeStack {
    private static let key = "com.pummelchen.converter.process-scope-stack"

    private static var box: ProcessScopeStackBox {
        if let existing = Thread.current.threadDictionary[key] as? ProcessScopeStackBox {
            return existing
        }
        let created = ProcessScopeStackBox()
        Thread.current.threadDictionary[key] = created
        return created
    }

    static var current: ProcessScope? {
        box.scopes.last
    }

    static func push(_ scope: ProcessScope) {
        box.scopes.append(scope)
    }

    static func pop() {
        _ = box.scopes.popLast()
    }
}
