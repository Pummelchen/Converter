import Foundation
import Synchronization

struct ProcessResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    // Set only when the child was killed by a signal. Foundation then reports the signal number
    // through `terminationStatus`, which is otherwise indistinguishable from a genuine exit code.
    let terminationSignal: Int32?
}

// Data is Mutex-protected; @unchecked is required only because the captured
// FileHandle/DispatchGroup thread-safety is not compiler-verifiable.
private final class PipeCapture: @unchecked Sendable {
    // Bounds retained output so a chatty child cannot exhaust memory; surplus is drained and discarded.
    private static let maxCapturedBytes = 64 * 1024 * 1024

    private let group = DispatchGroup()
    private let data = Mutex<Data>(Data())
    private let readFailure = Mutex<(any Error)?>(nil)
    private let truncated = Mutex<Bool>(false)

    init(handle: FileHandle, qos: DispatchQoS.QoSClass = .userInitiated) {
        group.enter()
        DispatchQueue.global(qos: qos).async {
            defer {
                closeHandle(handle)
                self.group.leave()
            }
            while true {
                let chunk: Data
                do {
                    // A thrown read error used to end the loop silently, so a truncated capture was
                    // indistinguishable from a complete one (#0158).
                    guard let read = try handle.read(upToCount: 65_536), !read.isEmpty else { break }
                    chunk = read
                } catch {
                    self.readFailure.withLock { $0 = error }
                    break
                }
                // Appended as it arrives, so a timed-out run can report what the child said so far
                // without waiting for a pipe that a grandchild may still hold open. The cap keeps the
                // first `maxCapturedBytes` and drains the surplus (behaviour pinned by #0034's
                // boundary tests); `truncated` lets the failure message say the tail is missing
                // instead of quoting a stale last line as if it were the child's final word (#0136).
                self.data.withLock { captured in
                    let remaining = Self.maxCapturedBytes - captured.count
                    if chunk.count > remaining {
                        captured.append(chunk.prefix(max(0, remaining)))
                        self.truncated.withLock { $0 = true }
                    } else {
                        captured.append(chunk)
                    }
                }
            }
        }
    }

    // Set when the read loop ended on an error, and when bytes were dropped at the cap.
    var capturedReadFailure: (any Error)? {
        readFailure.withLock { $0 }
    }

    var wasTruncated: Bool {
        truncated.withLock { $0 }
    }

    func waitString() -> String {
        group.wait()
        return snapshot()
    }

    // True once the reader has observed EOF. A bounded wait that returns false means something still
    // holds the write end, so the captured text may be short (#0116).
    var hasFinishedReading: Bool {
        group.wait(timeout: .now()) == .success
    }

    // Bounded wait for the timeout path: returns whatever has been captured by the deadline.
    func waitString(until deadline: DispatchTime) -> String {
        _ = group.wait(timeout: deadline)
        return snapshot()
    }

    private func snapshot() -> String {
        String(data: data.withLock({ $0 }), encoding: .utf8) ?? ""
    }
}

private func closeHandle(_ handle: FileHandle) {
    try? handle.close()
}

private func closeHandles(_ handles: [FileHandle]) {
    for handle in handles {
        closeHandle(handle)
    }
}

final class TimeoutFlag: Sendable {
    private let flag = Mutex<Bool>(false)

    func set() {
        flag.withLock { $0 = true }
    }

    var isSet: Bool {
        flag.withLock { $0 }
    }
}

final class ProcessRunner: Sendable {
    // Bounds every external command so a hung tool cannot stall a run forever.
    static let defaultTimeoutSeconds: TimeInterval = 1800
    // After the timeout a child gets SIGTERM and this long to exit before SIGKILL.
    static let killGraceSeconds: TimeInterval = 5
    // How long the timeout path collects the child's last output before giving up on the pipe.
    static let timeoutDrainSeconds: TimeInterval = 2
    // The success path waits for the reader to see EOF. A child that has exited normally closes its
    // end immediately, so this only elapses when a grandchild inherited and still holds the pipe; it
    // is generous because a large buffered backlog is still legitimately being drained (#0116).
    static let successDrainSeconds: TimeInterval = 10

    // SIGTERM first so a well-behaved tool can clean up; SIGKILL when it does not. A child that
    // traps or ignores SIGTERM (or is stuck in uninterruptible I/O) used to keep waitUntilExit
    // blocked for its natural lifetime, which for a wedged encoder is forever. Signals the pid only,
    // so it is safe from a watchdog thread while the caller is blocked in waitUntilExit (#0141).
    static func terminateWithEscalation(pid: Int32, flag: TimeoutFlag) {
        guard pid > 0, kill(pid, 0) == 0 else { return }
        flag.set()
        kill(pid, SIGTERM)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + killGraceSeconds) {
            guard kill(pid, 0) == 0 else { return }
            kill(pid, SIGKILL)
        }
    }

    private let logger: Logger
    private let environment: [String: String]
    private let debugEnabled: Bool

    init(logger: Logger, environment: [String: String], debugEnabled: Bool) {
        self.logger = logger
        self.environment = environment
        self.debugEnabled = debugEnabled
    }

    func requireExecutable(_ name: String) throws {
        _ = try resolveExecutable(named: name)
    }

    func resolveExecutable(named name: String) throws -> URL {
        guard let url = DependencyBootstrapper.executableURL(named: name, environment: environment) else {
            throw AppError("Required command not found: \(name)")
        }
        return url
    }

    // The child plus the two capture readers, and the parent's write ends that must be closed once the
    // child has started (otherwise the readers never see EOF). Split out of run() to keep that
    // function inside the repository's body-length budget.
    private struct ChildProcess {
        let process: Process
        let writeEnds: [FileHandle]
        let stdout: PipeCapture
        let stderr: PipeCapture
    }

    private func makeChildProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectory: URL?,
        extraEnvironment: [String: String]
    ) -> ChildProcess {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment.merging(extraEnvironment) { _, new in new }
        process.qualityOfService = .userInitiated
        // No child may read the terminal. An ffmpeg without -nostdin, a magick that asks a
        // question or an `open` waiting for a keypress would otherwise block the whole run
        // on a prompt nobody sees, or swallow keystrokes meant for the shell.
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        return ChildProcess(
            process: process,
            writeEnds: [stdoutPipe.fileHandleForWriting, stderrPipe.fileHandleForWriting],
            stdout: PipeCapture(handle: stdoutPipe.fileHandleForReading),
            stderr: PipeCapture(handle: stderrPipe.fileHandleForReading)
        )
    }

    @discardableResult
    func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        extraEnvironment: [String: String] = [:],
        allowedExitCodes: Set<Int32> = [0],
        timeoutSeconds: TimeInterval? = nil
    ) throws -> ProcessResult {
        let executableURL = try resolveExecutable(named: executable)
        if debugEnabled {
            logger.debug(formatCommand(executableURL.path, arguments))
        }

        let child = makeChildProcess(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectory: currentDirectory,
            extraEnvironment: extraEnvironment
        )
        let process = child.process
        do {
            try process.run()
        } catch {
            closeHandles(child.writeEnds)
            _ = child.stdout.waitString()
            _ = child.stderr.waitString()
            throw AppError(
                "Failed to launch command: \(formatCommand(executableURL.path, arguments)) | \(error.localizedDescription)"
            )
        }

        closeHandles(child.writeEnds)

        let timeout = timeoutSeconds ?? Self.defaultTimeoutSeconds
        let timeoutFlag = TimeoutFlag()
        // The pid is read here, on the launching thread, and every later signal goes through the
        // handle or the pid, so no other thread ever touches the Process object (#0141).
        let handle = ProcessHandle(pid: process.processIdentifier)
        let scope = ProcessScopeStack.current
        let isTracked = scope != nil
        scope?.track(handle)
        defer {
            scope?.untrack(handle)
        }
        // Cancellation can arrive while this child was still being launched, because the
        // cancellation handler at the fan-out boundary may have run before the process existed.
        if Task.isCancelled { handle.terminateIfRunning() }
        waitForExit(process, handle: handle, timeout: timeout, timeoutFlag: timeoutFlag)
        // A child started outside any permit scope has no cancellation handler watching it.
        if !isTracked { logger.debug("Started a child outside a permit scope: \(executable)") }
        try abortIfCancelled(child.stdout, child.stderr)

        if timeoutFlag.isSet {
            try throwTimeout(
                executableURL: executableURL, arguments: arguments, timeout: timeout,
                stdout: child.stdout, stderr: child.stderr)
        }

        let result = makeResult(child.stdout, child.stderr, process)
        try throwIfFailed(
            result,
            executableURL: executableURL,
            arguments: arguments,
            allowedExitCodes: allowedExitCodes,
            truncated: child.stdout.wasTruncated || child.stderr.wasTruncated
        )
        return result
    }

    // Reports a child that had to be killed; never returns. The child is dead (or being killed), so
    // this must not block on pipe EOF, which a grandchild that inherited the pipe could postpone.
    private func throwTimeout(
        executableURL: URL, arguments: [String], timeout: TimeInterval,
        stdout: PipeCapture, stderr: PipeCapture
    ) throws -> Never {
        let deadline = DispatchTime.now() + Self.timeoutDrainSeconds
        _ = stdout.waitString(until: deadline)
        let stderrTail = stderr.waitString(until: deadline).lastNonEmptyLine
        let detail = stderrTail.map { " | \($0)" } ?? ""
        throw AppError(
            "Command timed out after \(Int(timeout)) seconds: \(formatCommand(executableURL.path, arguments))\(detail)")
    }

    // Turns a finished child into the right error, or returns when it succeeded. A signal death is
    // never an exit status a caller may allow: `terminationStatus` carries the signal number, so
    // `allowedExitCodes: [0, 15]` would otherwise accept a SIGTERM (#0135). `truncated` says the
    // retained output is not the child's last word, as the 64 MiB cap keeps the beginning (#0136).
    private func throwIfFailed(
        _ result: ProcessResult,
        executableURL: URL,
        arguments: [String],
        allowedExitCodes: Set<Int32>,
        truncated: Bool
    ) throws {
        let command = formatCommand(executableURL.path, arguments)
        if let signal = result.terminationSignal {
            throw AppError("Command failed: \(command) | killed by signal \(signal) (\(Self.signalName(signal)))")
        }
        guard !allowedExitCodes.contains(result.exitCode) else { return }
        let detail = Self.failureDetail(for: result)
        let note = truncated ? " (output exceeded the 64 MiB capture cap; only the beginning was kept)" : ""
        throw AppError("Command failed: \(command) | \(detail)\(note)")
    }

    // Bounds the wait with the timeout watchdog; the child is killed by SIGTERM then SIGKILL.
    private func waitForExit(
        _ process: Process, handle: ProcessHandle, timeout: TimeInterval, timeoutFlag: TimeoutFlag
    ) {
        let pid = handle.pid
        let watchdog = DispatchWorkItem { [timeoutFlag] in
            Self.terminateWithEscalation(pid: pid, flag: timeoutFlag)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        // Reaped: the watchdog must not signal a pid that may already belong to someone else.
        handle.markFinished()
        watchdog.cancel()
    }

    // Diagnostics for a capture that may not hold everything the child wrote. Separate from run() so
    // that function stays inside the repository's body-length budget.
    private func reportCaptureIssues(stdout: PipeCapture, stderr: PipeCapture, process: Process) {
        if !stdout.hasFinishedReading || !stderr.hasFinishedReading {
            let command = formatCommand(process.executableURL?.path ?? "child", process.arguments ?? [])
            logger.warn(
                "A child left its output pipes open after exiting; captured output may be incomplete: \(command)")
        }
        for (label, capture) in [("stdout", stdout), ("stderr", stderr)] {
            if capture.wasTruncated {
                logger.debug("Captured \(label) exceeded the cap; the oldest bytes were dropped.")
            }
            if let failure = capture.capturedReadFailure {
                logger.warn("Reading the child's \(label) failed: \(failure.localizedDescription)")
            }
        }
    }

    // A cancelled fan-out sibling is killed by the permit helper's cancellation handler, so the
    // wait returns with a signal death; report the cancellation instead of that status.
    private func abortIfCancelled(_ stdoutCapture: PipeCapture, _ stderrCapture: PipeCapture) throws {
        guard Task.isCancelled else { return }
        let deadline = DispatchTime.now() + Self.timeoutDrainSeconds
        _ = stdoutCapture.waitString(until: deadline)
        _ = stderrCapture.waitString(until: deadline)
        throw CancellationError()
    }

    private func makeResult(
        _ stdoutCapture: PipeCapture,
        _ stderrCapture: PipeCapture,
        _ process: Process
    ) -> ProcessResult {
        // Bounded drain: a grandchild that inherited the pipe keeps it open after the child exits,
        // and the watchdog has already been cancelled at that point, so an unbounded wait could hang
        // the run forever (#0116). The timeout path has always bounded this; now the success path
        // does too, and says so when it gives up.
        let deadline = DispatchTime.now() + Self.successDrainSeconds
        let stdout = stdoutCapture.waitString(until: deadline)
        let stderr = stderrCapture.waitString(until: deadline)
        reportCaptureIssues(stdout: stdoutCapture, stderr: stderrCapture, process: process)
        return ProcessResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: process.terminationStatus,
            terminationSignal: process.terminationReason == .uncaughtSignal ? process.terminationStatus : nil
        )
    }

    // A crash and a tool that deliberately exits with the signal number are different failures,
    // so a signal death is always named and any captured output is appended to it.
    static func failureDetail(for result: ProcessResult) -> String {
        let captured = result.stderr.lastNonEmptyLine ?? result.stdout.lastNonEmptyLine
        if let signal = result.terminationSignal {
            let named = "killed by signal \(signal) (\(signalName(signal)))"
            return captured.map { "\(named) | \($0)" } ?? named
        }
        return captured ?? "exit code \(result.exitCode)"
    }

    // Foundation reports a signal death as the raw signal number, so a name lookup keeps the
    // message short and avoids a 13-branch switch.
    private static let signalNames: [Int32: String] = [
        SIGSEGV: "SIGSEGV", SIGABRT: "SIGABRT", SIGKILL: "SIGKILL", SIGTERM: "SIGTERM",
        SIGBUS: "SIGBUS", SIGILL: "SIGILL", SIGFPE: "SIGFPE", SIGPIPE: "SIGPIPE",
        SIGINT: "SIGINT", SIGHUP: "SIGHUP", SIGQUIT: "SIGQUIT", SIGALRM: "SIGALRM",
        SIGXCPU: "SIGXCPU"
    ]

    static func signalName(_ signal: Int32) -> String {
        signalNames[signal] ?? "unknown signal"
    }
}
