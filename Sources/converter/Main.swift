import Foundation

@main
struct ConverterMain {
    static func main() async {
        let fileManager = FileManager.default
        let currentPath = fileManager.currentDirectoryPath
        let currentURL = URL(fileURLWithPath: currentPath)
        let environment = ProcessInfo.processInfo.environment
        let executablePath = CommandLine.arguments.first ?? "converter"
        let executableURL = URL(fileURLWithPath: executablePath, relativeTo: currentURL).standardizedFileURL
        let scriptDirectory = environment["CONVERTER_ROOT"].map { URL(fileURLWithPath: $0) } ?? executableURL.deletingLastPathComponent()
        let scriptName = environment["CONVERTER_NAME"] ?? executableURL.lastPathComponent
        let bootstrapLogger = Logger(scriptName: scriptName, debugEnabled: true)
        var logger: Logger?
        var exitCode: Int32 = 0

        do {
            let cli = try CLIOptions.parse(
                arguments: Array(CommandLine.arguments.dropFirst()),
                environment: environment,
                scriptDirectory: scriptDirectory,
                scriptName: scriptName
            )
            let runLogger = Logger(scriptName: scriptName, debugEnabled: cli.debug)
            logger = runLogger
            let config = try ProjectConfig.load(from: cli.configFile, environment: environment, cli: cli, logger: runLogger)
            let runner = ProcessRunner(logger: runLogger, environment: environment, debugEnabled: cli.debug)
            let instance = ConverterTool(cli: cli, config: config, logger: runLogger, runner: runner, environment: environment)
            defer { instance.cleanupTemps() }
            try instance.initializeForExecution()
            try await instance.execute()
        } catch let error as AppError {
            exitCode = error.exitCode
            (logger ?? bootstrapLogger).error(error.message)
        } catch {
            exitCode = 1
            (logger ?? bootstrapLogger).error(error.localizedDescription)
        }

        Foundation.exit(exitCode)
    }
}
