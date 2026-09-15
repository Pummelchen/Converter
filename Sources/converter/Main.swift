import Foundation

@main
struct ConverterMain {
    static func main() async {
        let exitCode = await run(
            arguments: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment,
            currentDirectory: FileManager.default.currentDirectoryPath
        )
        Foundation.exit(exitCode)
    }

    // The whole entry point, with its inputs as parameters and the process exit code as its result.
    // Nothing here calls exit() directly, so every branch — including the argument-parse failure that
    // must exit 2 — can be driven by a test (#0143).
    static func run(
        arguments: [String],
        environment rawEnvironment: [String: String],
        currentDirectory: String
    ) async -> Int32 {
        var environment = DependencyBootstrapper.enrichedEnvironment(rawEnvironment)
        let location = scriptLocation(
            executablePath: arguments.first ?? "converter",
            currentDirectory: currentDirectory,
            environment: environment
        )
        let bootstrapLogger = Logger(scriptName: location.name, debugEnabled: true)
        var logger: Logger?
        var exitCode: Int32 = 0

        do {
            let cli: CLIOptions
            do {
                cli = try CLIOptions.parse(
                    arguments: Array(arguments.dropFirst()),
                    environment: environment,
                    scriptDirectory: location.directory,
                    scriptName: location.name
                )
            } catch let error as AppError {
                bootstrapLogger.error(error.message)
                bootstrapLogger.debug("\(error.fileID):\(error.line)")
                return 2
            } catch {
                bootstrapLogger.error(error.localizedDescription)
                return 2
            }
            let runLogger = Logger(scriptName: location.name, debugEnabled: cli.debug)
            logger = runLogger
            try DependencyBootstrapper.ensureRuntimeDependencies(
                environment: &environment, logger: runLogger, action: cli.action)
            let config = try ProjectConfig.load(
                from: cli.configFile, environment: environment, cli: cli, logger: runLogger)
            let runner = ProcessRunner(logger: runLogger, environment: environment, debugEnabled: cli.debug)
            let instance = ConverterTool(
                cli: cli, config: config, logger: runLogger, runner: runner, environment: environment)
            defer { instance.cleanupTemps() }
            try instance.initializeForExecution()
            try await instance.execute()
        } catch let error as AppError {
            exitCode = error.exitCode
            var detail = error.message
            if let underlying = error.underlyingDescription {
                detail += " (underlying: \(underlying))"
            }
            (logger ?? bootstrapLogger).error(detail)
            (logger ?? bootstrapLogger).debug("\(error.fileID):\(error.line)")
        } catch {
            exitCode = 1
            (logger ?? bootstrapLogger).error(error.localizedDescription)
        }

        return exitCode
    }

    // Where the running binary lives, and what it calls itself. `URL(fileURLWithPath:relativeTo:)`
    // resolves a *bare* name against the process's current directory, so a `converter` started from
    // `PATH` used to treat the caller's directory as its own — and then read `config.txt` and write
    // `Output` there. A path without a directory component now resolves against the running
    // executable instead (#0143).
    static func scriptLocation(
        executablePath: String,
        currentDirectory: String,
        environment: [String: String]
    ) -> (directory: URL, name: String) {
        if let root = environment["CONVERTER_ROOT"] {
            return (URL(fileURLWithPath: root), environment["CONVERTER_NAME"] ?? "converter")
        }
        // Resolved explicitly: `URL(fileURLWithPath:relativeTo:)` ignores `relativeTo` for a
        // path-only initialiser, so a relative `build/converter` did not end up under the directory
        // that was passed in.
        let executableURL: URL
        let expanded = (executablePath as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            executableURL = URL(fileURLWithPath: expanded).standardizedFileURL
        } else if expanded.contains("/") {
            executableURL =
                URL(fileURLWithPath: currentDirectory)
                .appendingPathComponent(expanded).standardizedFileURL
        } else if let running = Bundle.main.executableURL {
            executableURL = running.standardizedFileURL
        } else {
            executableURL =
                URL(fileURLWithPath: currentDirectory)
                .appendingPathComponent(expanded).standardizedFileURL
        }
        return (
            executableURL.deletingLastPathComponent(), environment["CONVERTER_NAME"] ?? executableURL.lastPathComponent
        )
    }
}
