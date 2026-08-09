import Foundation

@main
struct ConverterMain {
    static func main() async {
        let fileManager = FileManager.default
        let currentPath = fileManager.currentDirectoryPath
        let currentURL = URL(fileURLWithPath: currentPath)
        var environment = DependencyBootstrapper.enrichedEnvironment(ProcessInfo.processInfo.environment)
        let executablePath = CommandLine.arguments.first ?? "converter"
        let executableURL = URL(fileURLWithPath: executablePath, relativeTo: currentURL).standardizedFileURL
        let scriptDirectory = environment["CONVERTER_ROOT"].map { URL(fileURLWithPath: $0) } ?? executableURL.deletingLastPathComponent()
        let scriptName = environment["CONVERTER_NAME"] ?? executableURL.lastPathComponent
        let bootstrapLogger = Logger(scriptName: scriptName, debugEnabled: true)
        var logger: Logger?
        var exitCode: Int32 = 0

        do {
            let cli: CLIOptions
            do {
                cli = try CLIOptions.parse(
                    arguments: Array(CommandLine.arguments.dropFirst()),
                    environment: environment,
                    scriptDirectory: scriptDirectory,
                    scriptName: scriptName
                )
            } catch let error as AppError {
                bootstrapLogger.error(error.message)
                bootstrapLogger.debug("\(error.fileID):\(error.line)")
                Foundation.exit(2)
            } catch {
                bootstrapLogger.error(error.localizedDescription)
                Foundation.exit(2)
            }
            let runLogger = Logger(scriptName: scriptName, debugEnabled: cli.debug)
            logger = runLogger
            try DependencyBootstrapper.ensureRuntimeDependencies(environment: &environment, logger: runLogger, action: cli.action)
            let config = try ProjectConfig.load(from: cli.configFile, environment: environment, cli: cli, logger: runLogger)
            let runner = ProcessRunner(logger: runLogger, environment: environment, debugEnabled: cli.debug)
            let instance = ConverterTool(cli: cli, config: config, logger: runLogger, runner: runner, environment: environment)
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

        Foundation.exit(exitCode)
    }
}
