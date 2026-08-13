import Foundation
import Synchronization

struct ProcessResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
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
            var captured = Data()
            var exceededCap = false
            while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
                if exceededCap {
                    continue
                }
                let remaining = Self.maxCapturedBytes - captured.count
                if chunk.count > remaining {
                    captured.append(chunk.prefix(max(0, remaining)))
                    exceededCap = true
                } else {
                    captured.append(chunk)
                }
            }
            self.data.withLock { $0 = captured }
        }
    }

    func waitString() -> String {
        group.wait()
        return String(data: data.withLock({ $0 }), encoding: .utf8) ?? ""
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
            guard let process, process.isRunning else { return }
            timeoutFlag.set()
            process.terminate()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()

        if timeoutFlag.isSet {
            _ = stdoutCapture.waitString()
            _ = stderrCapture.waitString()
            throw AppError("Command timed out after \(Int(timeout)) seconds: \(formatCommand(executableURL.path, arguments))")
        }

        let stdout = stdoutCapture.waitString()
        let stderr = stderrCapture.waitString()
        let result = ProcessResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)

        if !allowedExitCodes.contains(result.exitCode) {
            let detail = stderr.lastNonEmptyLine ?? stdout.lastNonEmptyLine ?? "exit code \(result.exitCode)"
            throw AppError("Command failed: \(formatCommand(executableURL.path, arguments)) | \(detail)")
        }

        return result
    }
}
