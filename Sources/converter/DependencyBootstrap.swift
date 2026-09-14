import CryptoKit
import Foundation
import Synchronization

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
            let detail = missingFormulae.flatMap { unusableToolDescriptions($0, environment: environment) }
            throw AppError("Dependency bootstrap failed; unusable command(s) after install: \(detail.joined(separator: ", "))")
        }
    }

    // Describes every tool of an installed formula that is still unusable, and why. A tool that
    // is present but fails its functional probe is not "missing", so filtering by presence alone
    // produced an empty list and an error naming nothing (#0077).
    static func unusableToolDescriptions(
        _ formula: HomebrewFormulaDependency, environment: [String: String]
    ) -> [String] {
        formula.executables
            .filter { !isUsableTool($0, environment: environment) }
            .map { name in
                isExecutableAvailable(name, environment: environment)
                    ? "\(name) (installed but fails its -version probe)"
                    : "\(name) (not found)"
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

    private static let toolProbeTimeoutSeconds: TimeInterval = 10

    private static func isFunctionalTool(_ url: URL) -> Bool {
        let process = Process()
        process.executableURL = url
        process.arguments = ["-version"]
        process.qualityOfService = .utility
        // A probe that inherits the terminal can sit on a read until the watchdog fires and
        // then be misreported as broken; it gets the same closed stdin as every other child.
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return false
        }

        // Release the parent's write end so the drain below observes EOF.
        try? outputPipe.fileHandleForWriting.close()

        // Drain concurrently: a tool whose -version output exceeds the pipe buffer would
        // otherwise block on write forever and be misreported as broken. Waiting on the
        // process itself (rather than a terminationHandler installed after run()) also
        // removes the race where a fast-exiting tool never fires the handler.
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? outputPipe.fileHandleForReading.close()
                drained.leave()
            }
            while let chunk = try? outputPipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                continue
            }
        }

        let timedOut = TimeoutFlag()
        let watchdog = DispatchWorkItem { [weak process, timedOut] in
            guard let process else { return }
            ProcessRunner.terminateWithEscalation(process, flag: timedOut, qos: .utility)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + toolProbeTimeoutSeconds, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        // Bounded: a probe that spawned something holding the pipe must not stall startup.
        _ = drained.wait(timeout: .now() + toolProbeTimeoutSeconds)

        return !timedOut.isSet && process.terminationStatus == 0
    }

    private static func ensureHomebrew(environment: inout [String: String], logger: Logger) throws -> URL {
        if let brew = executableURL(named: "brew", environment: environment) {
            return brew
        }

        logger.info("Dependency bootstrap: Homebrew missing, installing the pinned installer non-interactively")
        let installer = try fetchVerifiedInstaller(
            from: homebrewInstallerURL,
            expectedSHA256: homebrewInstallerSHA256,
            environment: environment
        )
        defer { try? FileManager.default.removeItem(at: installer) }
        try runSilent(
            URL(fileURLWithPath: "/bin/bash"),
            arguments: [installer.path],
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

    // The installer is pinned to a reviewed commit and verified by SHA-256 before a single line
    // of it runs. `HEAD` would execute whatever the branch holds at run time, and piping curl
    // into bash executes a truncated script on a mid-stream disconnect. Update both constants
    // together when deliberately moving to a newer installer.
    static let homebrewInstallerURL =
        "https://raw.githubusercontent.com/Homebrew/install/fde1410a61157a71c78d2dc0c3a57a3a848b9756/install.sh"
    static let homebrewInstallerSHA256 = "25548e1da7930c1563dbbe2cb05834a4131c4da09234540b6fdac812fda3c287"

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // Downloads `url` to a private (0600) temp file, checks its SHA-256 against `expectedSHA256`
    // and returns the verified copy. Nothing is executed here; a mismatch removes the download
    // and throws. `file://` is allowed so the check can be tested without the network.
    static func fetchVerifiedInstaller(
        from url: String, expectedSHA256: String, environment: [String: String]
    ) throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("converter-homebrew-installer-\(UUID().uuidString).sh")
        let privateMode: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: privateMode) else {
            throw AppError("Unable to create a private temporary file for the Homebrew installer.")
        }
        do {
            try runSilent(
                URL(fileURLWithPath: "/usr/bin/curl"),
                arguments: ["-fsSL", "--proto", "=https,file", "--tlsv1.2", "--max-time", "300", "-o", temp.path, url],
                environment: environment,
                timeoutSeconds: 360
            )
            let actual = sha256Hex(of: try Data(contentsOf: temp))
            guard actual == expectedSHA256.lowercased() else {
                throw AppError(
                    "Homebrew installer integrity check failed: expected SHA-256 \(expectedSHA256) "
                    + "but the download has \(actual). "
                    + "Refusing to execute it. Install Homebrew manually from https://brew.sh and rerun."
                )
            }
            return temp
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private static func installHomebrewFormula(_ formula: String, brew: URL, environment: [String: String]) throws {
        try runSilent(
            brew,
            arguments: ["install", formula],
            environment: environment.merging([
                "CI": "1",
                "HOMEBREW_NO_ANALYTICS": "1",
                "HOMEBREW_NO_ENV_HINTS": "1",
                // An implicit `brew update` can add minutes and pull in unrelated formula
                // changes; the operator updates Homebrew explicitly.
                "HOMEBREW_NO_AUTO_UPDATE": "1"
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
