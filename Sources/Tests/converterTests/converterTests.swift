import XCTest
@testable import converter

final class converterTests: XCTestCase {
    private func makeTool(tempDirectory: URL, arguments: [String] = []) throws -> ConverterTool {
        let environment = ProcessInfo.processInfo.environment
        let logger = Logger(scriptName: "converterTests", debugEnabled: false)
        let options = try CLIOptions.parse(
            arguments: ["--output-dir", tempDirectory.path] + arguments,
            environment: environment,
            scriptDirectory: tempDirectory,
            scriptName: "converter"
        )
        let runner = ProcessRunner(logger: logger, environment: environment, debugEnabled: false)
        return ConverterTool(cli: options, config: ProjectConfig(), logger: logger, runner: runner, environment: environment)
    }

    func testHelpTextMentionsFullRunContract() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let options = try CLIOptions.parse(
            arguments: ["-help"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        let help = options.helpText()
        XCTAssertTrue(help.contains("Exactly 1 source image"))
        XCTAssertTrue(help.contains(".flac or .wav or .mp3"))
        XCTAssertTrue(help.contains("-mp3toflac"))
        XCTAssertTrue(help.contains("-m4atowav"))
        XCTAssertTrue(help.contains("-pngtojpg"))
        XCTAssertTrue(help.contains(".jpg or .jpeg"))
        XCTAssertFalse(help.contains("-jpegtopng"))
        XCTAssertFalse(help.contains("-pngtojpeg"))
    }

    func testResolveFullAudioPrefersHighestQualitySameStemSource() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        for name in ["song.flac", "song.wav", "song.mp3", "song_RF64.wav", "song_BW64.flac"] {
            FileManager.default.createFile(atPath: tempDirectory.appendingPathComponent(name).path, contents: Data("x".utf8))
        }

        let tool = try makeTool(tempDirectory: tempDirectory)
        XCTAssertEqual(try tool.resolveFullAudio().lastPathComponent, "song.flac")
    }

    func testParserRejectsDeprecatedInputOverrideFlags() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        XCTAssertThrowsError(
            try CLIOptions.parse(
                arguments: ["-m4atomp4", "--audio", "song.m4a"],
                environment: [:],
                scriptDirectory: root,
                scriptName: "converter"
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("--audio is no longer supported"))
        }
    }

    func testMatrixTextMentionsCompletedAudioAndImageGraph() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let options = try CLIOptions.parse(
            arguments: ["-matrix"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        let matrix = options.conversionMatrixText()
        XCTAssertTrue(matrix.contains("mp3  -> flac, wav, m4a"))
        XCTAssertTrue(matrix.contains("m4a  -> flac, wav, mp3"))
        XCTAssertTrue(matrix.contains("png      -> jpg"))
        XCTAssertTrue(matrix.contains("jpg/jpeg -> png"))
    }

    func testParserRejectsRemovedJPEGAliasFlags() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        XCTAssertThrowsError(
            try CLIOptions.parse(
                arguments: ["-jpegtopng"],
                environment: [:],
                scriptDirectory: root,
                scriptName: "converter"
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("-jpegtopng was removed"))
        }

        XCTAssertThrowsError(
            try CLIOptions.parse(
                arguments: ["-pngtojpeg"],
                environment: [:],
                scriptDirectory: root,
                scriptName: "converter"
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("-pngtojpeg was removed"))
        }
    }

    func testInvalidStringConfigIsRejectedDuringLoad() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig + "\nSHORT_MP4_CLIP_SECONDS=abc\n"
        )
        XCTAssertThrowsError(try workspace.makeTool(arguments: ["-help"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("SHORT_MP4_CLIP_SECONDS"))
        }
    }

    func testMatrixInitializationDoesNotRequireProjectOutputDirectory() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let environment = ProcessInfo.processInfo.environment
        let logger = Logger(scriptName: "converterTests", debugEnabled: false)
        let options = try CLIOptions.parse(
            arguments: ["-matrix"],
            environment: environment,
            scriptDirectory: tempDirectory,
            scriptName: "converter"
        )
        let config = try ProjectConfig.load(from: options.configFile, environment: environment, cli: options, logger: logger)
        let runner = ProcessRunner(logger: logger, environment: environment, debugEnabled: false)
        let tool = ConverterTool(cli: options, config: config, logger: logger, runner: runner, environment: environment)

        XCTAssertNoThrow(try tool.initializeForExecution())
    }

    func testHashActionsDefaultToProjectOutputDirectory() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")

        let mp3Options = try CLIOptions.parse(
            arguments: ["-mp3tohash"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertEqual(mp3Options.srcDir.standardizedFileURL.path, root.appendingPathComponent("Output", isDirectory: true).standardizedFileURL.path)
        XCTAssertEqual(mp3Options.outDir.standardizedFileURL.path, root.appendingPathComponent("Output", isDirectory: true).standardizedFileURL.path)

        let flacOptions = try CLIOptions.parse(
            arguments: ["-flactohash"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertEqual(flacOptions.srcDir.standardizedFileURL.path, root.appendingPathComponent("Output", isDirectory: true).standardizedFileURL.path)
        XCTAssertEqual(flacOptions.outDir.standardizedFileURL.path, root.appendingPathComponent("Output", isDirectory: true).standardizedFileURL.path)
    }
}
