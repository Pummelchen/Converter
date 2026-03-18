import Foundation

struct ProcessResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

struct PipelineProcessResult {
    let producer: ProcessResult
    let consumer: ProcessResult
}

private final class PipeCapture: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var data = Data()

    init(handle: FileHandle, qos: DispatchQoS.QoSClass = .userInitiated) {
        group.enter()
        DispatchQueue.global(qos: qos).async {
            let captured = (try? handle.readToEnd()) ?? Data()
            self.lock.lock()
            self.data = captured
            self.lock.unlock()
            self.group.leave()
        }
    }

    func waitString() -> String {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private func closeHandles(_ handles: [FileHandle]) {
    for handle in handles {
        handle.closeFile()
    }
}

final class ProcessRunner: @unchecked Sendable {
    private let logger: Logger
    private let environment: [String: String]
    private let fileManager = FileManager.default
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
        if name.contains("/") {
            let url = URL(fileURLWithPath: name)
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
            throw AppError("Required command not found: \(name)")
        }

        let pathEntries = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin").split(separator: ":")
        for entry in pathEntries {
            let candidate = URL(fileURLWithPath: String(entry)).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw AppError("Required command not found: \(name)")
    }

    @discardableResult
    func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        extraEnvironment: [String: String] = [:],
        allowedExitCodes: Set<Int32> = [0]
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
            throw AppError("Failed to launch command: \(formatCommand(executableURL.path, arguments))")
        }

        closeHandles([stdoutPipe.fileHandleForWriting, stderrPipe.fileHandleForWriting])

        process.waitUntilExit()
        let stdout = stdoutCapture.waitString()
        let stderr = stderrCapture.waitString()
        let result = ProcessResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)

        if !allowedExitCodes.contains(result.exitCode) {
            let detail = stderr.lastNonEmptyLine ?? stdout.lastNonEmptyLine ?? "exit code \(result.exitCode)"
            throw AppError("Command failed: \(formatCommand(executableURL.path, arguments)) | \(detail)")
        }

        return result
    }

    @discardableResult
    func runPipeline(
        producerExecutable: String,
        producerArguments: [String],
        consumerExecutable: String,
        consumerArguments: [String],
        currentDirectory: URL? = nil,
        extraEnvironment: [String: String] = [:],
        allowedProducerExitCodes: Set<Int32> = [0],
        allowedConsumerExitCodes: Set<Int32> = [0]
    ) throws -> PipelineProcessResult {
        let producerURL = try resolveExecutable(named: producerExecutable)
        let consumerURL = try resolveExecutable(named: consumerExecutable)
        if debugEnabled {
            logger.debug("\(formatCommand(producerURL.path, producerArguments)) | \(formatCommand(consumerURL.path, consumerArguments))")
        }

        let mergedEnvironment = environment.merging(extraEnvironment) { _, new in new }
        let dataPipe = Pipe()
        let producerErrorPipe = Pipe()
        let consumerErrorPipe = Pipe()
        let consumerOutputPipe = Pipe()

        let producer = Process()
        producer.executableURL = producerURL
        producer.arguments = producerArguments
        producer.currentDirectoryURL = currentDirectory
        producer.environment = mergedEnvironment
        producer.qualityOfService = .userInitiated
        producer.standardOutput = dataPipe
        producer.standardError = producerErrorPipe

        let consumer = Process()
        consumer.executableURL = consumerURL
        consumer.arguments = consumerArguments
        consumer.currentDirectoryURL = currentDirectory
        consumer.environment = mergedEnvironment
        consumer.qualityOfService = .userInitiated
        consumer.standardInput = dataPipe
        consumer.standardOutput = consumerOutputPipe
        consumer.standardError = consumerErrorPipe
        let producerErrorCapture = PipeCapture(handle: producerErrorPipe.fileHandleForReading)
        let consumerOutputCapture = PipeCapture(handle: consumerOutputPipe.fileHandleForReading)
        let consumerErrorCapture = PipeCapture(handle: consumerErrorPipe.fileHandleForReading)

        do {
            try consumer.run()
            try producer.run()
        } catch {
            closeHandles([
                dataPipe.fileHandleForReading,
                dataPipe.fileHandleForWriting,
                producerErrorPipe.fileHandleForWriting,
                consumerOutputPipe.fileHandleForWriting,
                consumerErrorPipe.fileHandleForWriting
            ])
            if consumer.isRunning {
                consumer.terminate()
            }
            if producer.isRunning {
                producer.terminate()
            }
            throw AppError(
                "Failed to launch pipeline: \(formatCommand(producerURL.path, producerArguments)) | \(formatCommand(consumerURL.path, consumerArguments))"
            )
        }

        closeHandles([
            dataPipe.fileHandleForReading,
            dataPipe.fileHandleForWriting,
            producerErrorPipe.fileHandleForWriting,
            consumerOutputPipe.fileHandleForWriting,
            consumerErrorPipe.fileHandleForWriting
        ])

        producer.waitUntilExit()
        consumer.waitUntilExit()

        let producerResult = ProcessResult(
            stdout: "",
            stderr: producerErrorCapture.waitString(),
            exitCode: producer.terminationStatus
        )
        let consumerResult = ProcessResult(
            stdout: consumerOutputCapture.waitString(),
            stderr: consumerErrorCapture.waitString(),
            exitCode: consumer.terminationStatus
        )

        if !allowedProducerExitCodes.contains(producerResult.exitCode) {
            let detail = producerResult.stderr.lastNonEmptyLine ?? consumerResult.stderr.lastNonEmptyLine ?? "exit code \(producerResult.exitCode)"
            throw AppError(
                "Pipeline producer failed: \(formatCommand(producerURL.path, producerArguments)) | \(detail)"
            )
        }
        if !allowedConsumerExitCodes.contains(consumerResult.exitCode) {
            let detail = consumerResult.stderr.lastNonEmptyLine ?? producerResult.stderr.lastNonEmptyLine ?? "exit code \(consumerResult.exitCode)"
            throw AppError(
                "Pipeline consumer failed: \(formatCommand(consumerURL.path, consumerArguments)) | \(detail)"
            )
        }

        return PipelineProcessResult(producer: producerResult, consumer: consumerResult)
    }
}
