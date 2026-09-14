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

    init(handle: FileHandle, qos: DispatchQoS.QoSClass = .userInitiated) {
        group.enter()
        DispatchQueue.global(qos: qos).async {
            defer {
                closeHandle(handle)
                self.group.leave()
            }
            var exceededCap = false
            while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
                if exceededCap {
                    continue
                }
                // Appended as it arrives, so a timed-out run can report what the child said so
                // far without waiting for a pipe that a grandchild may still hold open.
                self.data.withLock { captured in
                    let remaining = Self.maxCapturedBytes - captured.count
                    if chunk.count > remaining {
                        captured.append(chunk.prefix(max(0, remaining)))
                        exceededCap = true
                    } else {
                        captured.append(chunk)
                    }
                }
            }
        }
    }

    func waitString() -> String {
        group.wait()
        return snapshot()
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

    // SIGTERM first so a well-behaved tool can clean up; SIGKILL when it does not. A child that
    // traps or ignores SIGTERM (or is stuck in uninterruptible I/O) used to keep waitUntilExit
    // blocked for its natural lifetime, which for a wedged encoder is forever.
    static func terminateWithEscalation(_ process: Process, flag: TimeoutFlag, qos: DispatchQoS.QoSClass) {
        guard process.isRunning else { return }
        flag.set()
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global(qos: qos).asyncAfter(deadline: .now() + killGraceSeconds) { [weak process] in
            guard let process, process.isRunning, process.processIdentifier == pid else { return }
            kill(pid, SIGKILL)
        }
    }

    private let logger: Logger
    private let environment: [String: String]
    var fileManager: FileManager { FileManager.default }
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
        let stdoutCapture = PipeCapture(handle: stdoutPipe.fileHandleForReading)
        let stderrCapture = PipeCapture(handle: stderrPipe.fileHandleForReading)

        do {
            try process.run()
        } catch {
            closeHandles([stdoutPipe.fileHandleForWriting, stderrPipe.fileHandleForWriting])
            _ = stdoutCapture.waitString()
            _ = stderrCapture.waitString()
            throw AppError("Failed to launch command: \(formatCommand(executableURL.path, arguments)) | \(error.localizedDescription)")
        }

        closeHandles([stdoutPipe.fileHandleForWriting, stderrPipe.fileHandleForWriting])

        let timeout = timeoutSeconds ?? Self.defaultTimeoutSeconds
        let timeoutFlag = TimeoutFlag()
        let watchdog = DispatchWorkItem { [weak process, timeoutFlag] in
            guard let process else { return }
            Self.terminateWithEscalation(process, flag: timeoutFlag, qos: .userInitiated)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()

        if timeoutFlag.isSet {
            // The child is dead (or being killed); do not block on pipe EOF, which a grandchild
            // that inherited the pipe could postpone. Report the tail captured so far.
            let deadline = DispatchTime.now() + Self.timeoutDrainSeconds
            _ = stdoutCapture.waitString(until: deadline)
            let stderrTail = stderrCapture.waitString(until: deadline).lastNonEmptyLine
            let detail = stderrTail.map { " | \($0)" } ?? ""
            throw AppError("Command timed out after \(Int(timeout)) seconds: \(formatCommand(executableURL.path, arguments))\(detail)")
        }

        let result = makeResult(stdoutCapture, stderrCapture, process)

        if !allowedExitCodes.contains(result.exitCode) {
            let detail = Self.failureDetail(for: result)
            throw AppError("Command failed: \(formatCommand(executableURL.path, arguments)) | \(detail)")
        }

        return result
    }

    private func makeResult(
        _ stdoutCapture: PipeCapture,
        _ stderrCapture: PipeCapture,
        _ process: Process
    ) -> ProcessResult {
        ProcessResult(
            stdout: stdoutCapture.waitString(),
            stderr: stderrCapture.waitString(),
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
