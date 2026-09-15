import Foundation
import Synchronization

// Installer subprocesses are long but not unbounded, and their diagnostics are the only clue
// when a formula fails to build (#0041). Stderr is captured, stdin is /dev/null, and a timeout
// escalates SIGTERM -> SIGKILL so an installer stuck on a network read cannot hang the run
// forever. Kept in an extension so the main type body stays reviewable, and internal rather than
// private so tests can drive it with a stub executable.
extension DependencyBootstrapper {
    static let defaultInstallerTimeoutSeconds: TimeInterval = 1800
    static let installerKillGraceSeconds: TimeInterval = 5

    static func runSilent(
        _ executable: URL,
        arguments: [String],
        environment: [String: String],
        timeoutSeconds: TimeInterval = defaultInstallerTimeoutSeconds
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.qualityOfService = .utility

        guard
            let nullInput = FileHandle(forReadingAtPath: "/dev/null"),
            let nullOutput = FileHandle(forWritingAtPath: "/dev/null")
        else {
            throw AppError("Unable to open /dev/null for silent dependency installation.")
        }
        let errorPipe = Pipe()
        process.standardInput = nullInput
        process.standardOutput = nullOutput
        process.standardError = errorPipe
        let errorCapture = InstallerErrorCapture(handle: errorPipe.fileHandleForReading)

        do {
            try process.run()
        } catch {
            try? nullInput.close()
            try? nullOutput.close()
            throw AppError("Failed to launch dependency installer '\(executable.path)': \(error.localizedDescription)")
        }
        try? errorPipe.fileHandleForWriting.close()
        try? nullInput.close()
        try? nullOutput.close()

        let timeoutFlag = InstallerTimeoutFlag()
        let watchdog = installerWatchdog(
            process: process, timeoutFlag: timeoutFlag, timeoutSeconds: timeoutSeconds
        )
        process.waitUntilExit()
        watchdog.cancel()

        let diagnostic = errorCapture.lastNonEmptyLine().map { " | \($0)" } ?? ""
        if timeoutFlag.isSet {
            throw AppError(
                "Dependency installer timed out after \(Int(timeoutSeconds)) seconds: \(executable.path)\(diagnostic)"
            )
        }
        guard process.terminationStatus == 0 else {
            throw AppError(
                "Dependency installer failed: \(executable.path) \(arguments.joined(separator: " ")) "
                    + "exited with status \(process.terminationStatus)\(diagnostic)"
            )
        }
    }

    private static func installerWatchdog(
        process: Process, timeoutFlag: InstallerTimeoutFlag, timeoutSeconds: TimeInterval
    ) -> DispatchWorkItem {
        let watchdog = DispatchWorkItem { [weak process, timeoutFlag] in
            guard let process, process.isRunning else { return }
            timeoutFlag.set()
            let pid = process.processIdentifier
            process.terminate()
            DispatchQueue.global(qos: .utility)
                .asyncAfter(deadline: .now() + installerKillGraceSeconds) { [weak process] in
                    guard let process, process.isRunning, process.processIdentifier == pid else { return }
                    kill(pid, SIGKILL)
                }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)
        return watchdog
    }
}

// Reads the installer's stderr on a background queue so a timed-out subprocess whose child still
// holds the pipe cannot block the error path; retained output is bounded like PipeCapture.
private final class InstallerErrorCapture: @unchecked Sendable {
    private static let maxCapturedBytes = 64 * 1024
    private let group = DispatchGroup()
    private let data = Mutex<Data>(Data())

    init(handle: FileHandle) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? handle.close()
                self.group.leave()
            }
            while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
                self.data.withLock { captured in
                    let remaining = Self.maxCapturedBytes - captured.count
                    if remaining > 0 {
                        captured.append(chunk.prefix(remaining))
                    }
                }
            }
        }
    }

    func lastNonEmptyLine() -> String? {
        _ = group.wait(timeout: .now() + 2)
        return String(data: data.withLock { $0 }, encoding: .utf8)?.lastNonEmptyLine
    }
}

private final class InstallerTimeoutFlag: Sendable {
    private let flag = Mutex<Bool>(false)

    func set() {
        flag.withLock { $0 = true }
    }

    var isSet: Bool {
        flag.withLock { $0 }
    }
}
