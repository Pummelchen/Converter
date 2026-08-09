import Foundation

struct HomebrewFormulaDependency: Equatable, Sendable {
    let formula: String
    let executables: [String]
}

enum DependencyBootstrapper {
    static let systemExecutables = ["awk", "sed"]
    static let homebrewFormulaDependencies: [HomebrewFormulaDependency] = [
        HomebrewFormulaDependency(formula: "ffmpeg", executables: ["ffmpeg", "ffprobe"]),
        HomebrewFormulaDependency(formula: "imagemagick", executables: ["magick"])
    ]

    private static let commonExecutableDirectories = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    static func enrichedEnvironment(_ environment: [String: String]) -> [String: String] {
        var enriched = environment
        let mergedPath = executableSearchPathEntries(environment: environment).joined(separator: ":")
        enriched["PATH"] = mergedPath
        return enriched
    }

    static func executableSearchPathEntries(environment: [String: String]) -> [String] {
        var entries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }

        for directory in commonExecutableDirectories where !entries.contains(directory) {
            entries.append(directory)
        }
        return entries
    }

    static func ensureRuntimeDependencies(environment: inout [String: String], logger: Logger, action: Action) throws {
        environment = enrichedEnvironment(environment)
        guard action.requiresRuntimeDependencyBootstrap else {
            return
        }

        let missingSystemTools = systemExecutables.filter { !isExecutableAvailable($0, environment: environment) }
        if !missingSystemTools.isEmpty {
            throw AppError("Missing required macOS system command(s): \(missingSystemTools.joined(separator: ", "))")
        }

        var missingFormulae = missingHomebrewFormulae(environment: environment)
        guard !missingFormulae.isEmpty else {
            logger.debug("Dependency bootstrap: all Homebrew dependencies are present.")
            return
        }

        guard autoInstallEnabled(environment: environment) else {
            let names = missingFormulae.map(\.formula).joined(separator: ", ")
            throw AppError("Missing required Homebrew package(s): \(names). Install them with 'brew install \(names)' or set CONVERTER_AUTO_INSTALL_DEPS=1 to auto-install.")
        }

        let formulaNames = missingFormulae.map(\.formula).joined(separator: ", ")
        logger.info("Dependency bootstrap: installing missing Homebrew package(s): \(formulaNames)")
        let brew = try ensureHomebrew(environment: &environment, logger: logger)

        for dependency in missingFormulae {
            try installHomebrewFormula(dependency.formula, brew: brew, environment: environment)
            logger.info("Dependency bootstrap: installed \(dependency.formula)")
            environment = enrichedEnvironment(environment)
        }

        missingFormulae = missingHomebrewFormulae(environment: environment)
        if !missingFormulae.isEmpty {
            let missingCommands = missingFormulae
                .flatMap(\.executables)
                .filter { !isExecutableAvailable($0, environment: environment) }
            throw AppError("Dependency bootstrap failed; missing command(s) after install: \(missingCommands.joined(separator: ", "))")
        }
    }

    private static func autoInstallEnabled(environment: [String: String]) -> Bool {
        guard let rawValue = environment["CONVERTER_AUTO_INSTALL_DEPS"]?.lowercased(with: Locale(identifier: "en_US_POSIX")) else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(rawValue)
    }

    private static func missingHomebrewFormulae(environment: [String: String]) -> [HomebrewFormulaDependency] {
        homebrewFormulaDependencies.filter { dependency in
            dependency.executables.contains { !isUsableTool($0, environment: environment) }
        }
    }

    // Presence is not enough: a broken stub with the right name must not defeat
    // detection or skip auto-install, so each Homebrew tool is probed functionally.
    private static func isUsableTool(_ name: String, environment: [String: String]) -> Bool {
        guard let url = executableURL(named: name, environment: environment) else {
            return false
        }
        return isFunctionalTool(url)
    }

    private static func isFunctionalTool(_ url: URL) -> Bool {
        let process = Process()
        process.executableURL = url
        process.arguments = ["-version"]
        process.qualityOfService = .utility
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return false
        }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    private static func ensureHomebrew(environment: inout [String: String], logger: Logger) throws -> URL {
        if let brew = executableURL(named: "brew", environment: environment) {
            return brew
        }

        logger.info("Dependency bootstrap: Homebrew missing, installing Homebrew non-interactively")
        try runSilent(
            URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "-c",
                "/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | /bin/bash"
            ],
            environment: environment.merging([
                "NONINTERACTIVE": "1",
                "CI": "1",
                "HOMEBREW_NO_ANALYTICS": "1",
                "HOMEBREW_NO_ENV_HINTS": "1"
            ]) { _, new in new }
        )

        environment = enrichedEnvironment(environment)
        if let brew = executableURL(named: "brew", environment: environment) {
            return brew
        }
        throw AppError("Homebrew installation completed but the brew executable was not found in PATH.")
    }

    private static func installHomebrewFormula(_ formula: String, brew: URL, environment: [String: String]) throws {
        try runSilent(
            brew,
            arguments: ["install", formula],
            environment: environment.merging([
                "CI": "1",
                "HOMEBREW_NO_ANALYTICS": "1",
                "HOMEBREW_NO_ENV_HINTS": "1"
            ]) { _, new in new }
        )
    }

    private static func isExecutableAvailable(_ name: String, environment: [String: String]) -> Bool {
        executableURL(named: name, environment: environment) != nil
    }

    static func executableURL(named name: String, environment: [String: String]) -> URL? {
        if name.contains("/") {
            let url = URL(fileURLWithPath: name)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        for directory in executableSearchPathEntries(environment: environment) {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func runSilent(_ executable: URL, arguments: [String], environment: [String: String]) throws {
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
        process.standardInput = nullInput
        process.standardOutput = nullOutput
        process.standardError = nullOutput

        do {
            try process.run()
        } catch {
            try? nullInput.close()
            try? nullOutput.close()
            throw AppError("Failed to launch dependency installer '\(executable.path)': \(error.localizedDescription)")
        }

        process.waitUntilExit()
        try? nullInput.close()
        try? nullOutput.close()

        guard process.terminationStatus == 0 else {
            throw AppError("Dependency installer failed: \(executable.path) \(arguments.joined(separator: " ")) exited with status \(process.terminationStatus)")
        }
    }
}

extension Action {
    var requiresRuntimeDependencyBootstrap: Bool {
        switch self {
        case .help, .list, .matrix:
            return false
        default:
            return true
        }
    }
}
