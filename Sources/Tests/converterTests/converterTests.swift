import Synchronization
import XCTest
@testable import converter

final class converterTests: XCTestCase {
    private func makeTool(
        tempDirectory: URL,
        arguments: [String] = [],
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ConverterTool {
        let environment = IntegrationWorkspace.sanitizedEnvironment(inheritedEnvironment)
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

    // audit #0031: the unit helper passed --output-dir but still handed CONFIG_FILE and DEBUG from the
    // host shell to CLIOptions.parse. Exported host overrides must never reach the tool under test.
    func testUnitMakeToolIgnoresHostConfigAndDebugOverrides() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        var poisoned = ProcessInfo.processInfo.environment
        poisoned["OUTPUT_DIR"] = "/nonexistent"
        poisoned["SRC_DIR"] = "/nonexistent"
        poisoned["OUT_DIR"] = "/nonexistent"
        poisoned["CONFIG_FILE"] = "/nonexistent/config.txt"
        poisoned["DEBUG"] = "1"
        poisoned["CONVERTER_TEST_MARKER"] = "kept"

        let tool = try makeTool(tempDirectory: tempDirectory, arguments: ["-help"], inheritedEnvironment: poisoned)
        XCTAssertEqual(tool.cli.outDir.path, tempDirectory.path)
        XCTAssertEqual(tool.cli.srcDir.path, tempDirectory.path)
        XCTAssertEqual(tool.cli.configFile.path, tempDirectory.appendingPathComponent("config.txt").path)
        XCTAssertFalse(tool.cli.debug)
        for key in ["OUTPUT_DIR", "SRC_DIR", "OUT_DIR", "CONFIG_FILE", "DEBUG"] {
            XCTAssertNil(tool.environment[key], "\(key) leaked into the tool environment")
        }
        XCTAssertEqual(tool.environment["PATH"], poisoned["PATH"])
        XCTAssertEqual(tool.environment["CONVERTER_TEST_MARKER"], "kept")
    }

    func testDependencyManifestMatchesCurrentRuntimeTools() throws {
        XCTAssertEqual(DependencyBootstrapper.systemExecutables, ["awk", "sed"])
        XCTAssertEqual(
            DependencyBootstrapper.homebrewFormulaDependencies,
            [
                HomebrewFormulaDependency(formula: "ffmpeg", executables: ["ffmpeg", "ffprobe"]),
                HomebrewFormulaDependency(formula: "imagemagick", executables: ["magick"])
            ]
        )
    }

    func testDependencyBootstrapEnrichesPathWithHomebrewLocations() throws {
        let enriched = DependencyBootstrapper.enrichedEnvironment(["PATH": "/usr/bin:/bin"])
        let path = try XCTUnwrap(enriched["PATH"])
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.contains("/usr/local/bin"))
        XCTAssertTrue(path.hasPrefix("/usr/bin:/bin"))
    }

    // audit #0042: the functional probe (`tool -version`) inherited stdin too. A tool that reads
    // the terminal blocked until the 10 s probe watchdog fired and was then reported as broken,
    // which on an auto-install machine triggers a pointless reinstall. Every stub here reads
    // stdin first; with stdin closed all three probes finish at once and nothing is "missing".
    func testDependencyProbeGivesToolsNoStdin() throws {
        let stubs = try FakeToolDirectory()
        for name in ["ffmpeg", "ffprobe", "magick"] {
            try stubs.add(name, body: "read x; exit 0")
        }
        var environment = stubs.environment()
        let logger = Logger(scriptName: "converterTests", debugEnabled: false)
        let start = Date()

        XCTAssertNoThrow(
            try DependencyBootstrapper.ensureRuntimeDependencies(
                environment: &environment, logger: logger, action: .full)
        )
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "a probe must not wait on the terminal")
    }

    func testHelpListAndMatrixSkipRuntimeDependencyBootstrap() throws {
        XCTAssertFalse(Action.help.requiresRuntimeDependencyBootstrap)
        XCTAssertFalse(Action.list.requiresRuntimeDependencyBootstrap)
        XCTAssertFalse(Action.matrix.requiresRuntimeDependencyBootstrap)
        XCTAssertTrue(Action.full.requiresRuntimeDependencyBootstrap)
        XCTAssertTrue(Action.noise.requiresRuntimeDependencyBootstrap)
        XCTAssertTrue(Action.short.requiresRuntimeDependencyBootstrap)
    }

    func testNoArgumentsShowHelpInsteadOfFullRun() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let options = try CLIOptions.parse(
            arguments: [],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertEqual(options.action, .help)
        XCTAssertFalse(options.action.requiresRuntimeDependencyBootstrap)
    }

    func testStringAndURLHelpersNormalizeNamesWithoutFileSystemAccess() throws {
        XCTAssertEqual("  Mixed Case  \n".trimmed, "Mixed Case")
        XCTAssertEqual("ÄUDIO.PNG".lowercasedASCII, "äudio.png")
        XCTAssertEqual("\n\nfirst\n\nsecond  \n".lastNonEmptyLine, "second  ")
        XCTAssertNil("\n  \n".lastNonEmptyLine)

        let file = URL(fileURLWithPath: "/tmp/Album.Track.Final.wav")
        XCTAssertEqual(file.basename, "Album.Track.Final.wav")
        XCTAssertEqual(file.stem, "Album.Track.Final")
        XCTAssertFalse(file.lastPathComponent.hasPrefix("."))
        XCTAssertEqual(
            file.deletingLastPathComponent().appendingPathComponent(file.stem + "_RF64").appendingPathExtension(file.pathExtension).lastPathComponent,
            "Album.Track.Final_RF64.wav"
        )
        XCTAssertTrue(URL(fileURLWithPath: "/tmp/.converter-tmp.file").lastPathComponent.hasPrefix("."))
    }

    func testFlexibleTimecodeParsingAcceptsSupportedFormsAndRejectsInvalidBounds() throws {
        XCTAssertEqual(try parseFlexibleTimecode("90.25", label: "TIME"), 90.25, accuracy: 0.0001)
        XCTAssertEqual(try parseFlexibleTimecode("1:30.5", label: "TIME"), 90.5, accuracy: 0.0001)
        XCTAssertEqual(try parseFlexibleTimecode("2:03:04.25", label: "TIME"), 7_384.25, accuracy: 0.0001)
        XCTAssertEqual(try parseFlexibleTimecode("  0:05  ", label: "TIME"), 5, accuracy: 0.0001)

        XCTAssertThrowsError(try parseFlexibleTimecode("", label: "TIME")) { error in
            XCTAssertTrue(error.localizedDescription.contains("empty"))
        }
        XCTAssertThrowsError(try parseFlexibleTimecode("1:60", label: "TIME")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Seconds must be below 60"))
        }
        XCTAssertThrowsError(try parseFlexibleTimecode("1:60:00", label: "TIME")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Minutes and seconds must be below 60"))
        }
        XCTAssertThrowsError(try parseFlexibleTimecode("1:2:3:4", label: "TIME")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Use seconds, MM:SS, or HH:MM:SS"))
        }
    }

    // A colon-separated timecode is positional: ":30" is not "30 seconds" and "1::30" is not
    // "1 minute 30 seconds". Splitting with the default omittingEmptySubsequences dropped the
    // empty component, so the guard in parseTimecodeComponent was unreachable and these forms
    // silently parsed as a different duration.
    func testTimecodeRejectsEmptyColonSeparatedComponents() throws {
        for malformed in [":30", "1::30", "1:30:", "::30", "1:", ":", "1:2:", ":2:03"] {
            XCTAssertThrowsError(
                try parseFlexibleTimecode(malformed, label: "TIME"),
                "expected '\(malformed)' to be rejected"
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("Empty time component"),
                    "unexpected message for '\(malformed)': \(error.localizedDescription)"
                )
            }
        }

        // The component-count guard still rejects a fourth field before any component is parsed.
        XCTAssertThrowsError(try parseFlexibleTimecode("1:2:3:4", label: "TIME")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Use seconds, MM:SS, or HH:MM:SS"))
        }
    }

    // audit #0079: Foundation reports the signal number as the termination status, so a process
    // killed by SIGSEGV used to surface as "exit code 11" — indistinguishable from a tool that
    // chose to exit 11.
    func testProcessRunnerNamesSignalDeaths() throws {
        let environment = IntegrationWorkspace.sanitizedEnvironment(ProcessInfo.processInfo.environment)
        let logger = Logger(scriptName: "converterTests", debugEnabled: false)
        let runner = ProcessRunner(logger: logger, environment: environment, debugEnabled: false)

        XCTAssertThrowsError(try runner.run("sh", ["-c", "kill -SEGV $$"])) { error in
            let message = (error as? AppError)?.message ?? error.localizedDescription
            XCTAssertTrue(message.contains("killed by signal 11 (SIGSEGV)"), "unexpected message: \(message)")
        }
    }

    // audit #0078: a regular file at OUT_DIR passed the isWritableFile check, so the failure
    // surfaced later as "Failed to create unique temporary file" instead of naming the real cause.
    func testEnsureWritableDirectoryRejectsARegularFile() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let file = tempDirectory.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: file)

        let tool = try makeTool(tempDirectory: tempDirectory, arguments: ["-help"])
        XCTAssertThrowsError(try tool.ensureWritableDirectory(file)) { error in
            let message = (error as? AppError)?.message ?? error.localizedDescription
            XCTAssertTrue(message.contains("Not a directory"), "unexpected message: \(message)")
        }
        XCTAssertNoThrow(try tool.ensureWritableDirectory(tempDirectory))
    }

    // audit #0060: album.txt is a per-user order file and is git-ignored, so a fresh checkout has
    // none; the error has to point at the committed template instead of only naming the path.
    func testMissingAlbumFileErrorPointsAtTheExampleTemplate() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tool = try makeTool(tempDirectory: tempDirectory, arguments: ["-wavtoalbum"])
        XCTAssertThrowsError(
            try tool.buildAlbumFromAlbumFile(extension: "wav", defaultOutputName: "album.rf64.wav")
        ) { error in
            let message = (error as? AppError)?.message ?? error.localizedDescription
            XCTAssertTrue(message.contains("album.example.txt"), "unexpected message: \(message)")
        }
    }

    // audit #0041: installer subprocesses ran with stdout/stderr on /dev/null and no timeout, so
    // a failing formula reported only its exit status and a hung installer hung the whole run.
    func testInstallerSubprocessReportsStderrAndTimesOut() throws {
        let fake = try FakeToolDirectory()
        let path = ["PATH": "/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin"]

        let failing = try fake.add("failing-installer", body: "echo 'Error: boom' 1>&2; exit 3")
        XCTAssertThrowsError(
            try DependencyBootstrapper.runSilent(failing, arguments: [], environment: path, timeoutSeconds: 30)
        ) { error in
            let message = (error as? AppError)?.message ?? error.localizedDescription
            XCTAssertTrue(message.contains("exited with status 3"), "unexpected message: \(message)")
            XCTAssertTrue(message.contains("Error: boom"), "stderr must be reported: \(message)")
        }

        let sleeping = try fake.add("sleeping-installer", body: "sleep 10")
        let start = Date()
        XCTAssertThrowsError(
            try DependencyBootstrapper.runSilent(sleeping, arguments: [], environment: path, timeoutSeconds: 1)
        ) { error in
            let message = (error as? AppError)?.message ?? error.localizedDescription
            XCTAssertTrue(message.contains("timed out after 1 seconds"), "unexpected message: \(message)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the watchdog must end a hung installer")
    }

    // audit #0040: when one async-let sibling fails, Swift cancels the others, but the blocking
    // waitUntilExit ignored cancellation and kept the external process (and its ffmpeg/magick
    // work) alive until it finished on its own.
    func testCancellingAPermittedOperationTerminatesItsChildProcess() async throws {
        let workspace = try IntegrationWorkspace()
        let tool = try workspace.makeTool(arguments: ["-full"])

        let started = Date()
        let task = Task {
            try await tool.withAudioPermit { try tool.runner.run("sleep", ["15"]) }
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await task.result
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 5, "cancellation must terminate the child instead of waiting it out")
        guard case .failure = result else {
            return XCTFail("a cancelled run must not succeed")
        }
    }

    // audit #0087: the parser accepted several inputs that contradict its own contracts:
    // --seed 0 despite "positive integer", an unbounded --sharpness, a second action flag that
    // silently won, and an option-like token stored as a flag's value.
    func testCLIRejectsZeroSeedUnboundedSharpnessRepeatedActionsAndOptionLikeValues() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        func parse(_ arguments: [String]) throws -> CLIOptions {
            try CLIOptions.parse(arguments: arguments, environment: [:], scriptDirectory: root, scriptName: "converter")
        }

        XCTAssertThrowsError(try parse(["-aipix", "--seed", "0"])) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("--seed"),
                "unexpected message: \(error.localizedDescription)"
            )
        }
        XCTAssertThrowsError(try parse(["-aipix", "--sharpness", "100"])) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("--sharpness"),
                "unexpected message: \(error.localizedDescription)"
            )
        }
        XCTAssertThrowsError(try parse(["-full", "-album"])) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("Only one action"),
                "unexpected message: \(error.localizedDescription)"
            )
        }
        XCTAssertThrowsError(try parse(["-m4atomp4", "--output-file", "--overwrite"])) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("Missing value for --output-file"),
                "unexpected message: \(error.localizedDescription)"
            )
        }

        // The same flags in the intended order still parse.
        let options = try parse(["-m4atomp4", "--output-file", "release.mp4", "--overwrite", "--seed", "7"])
        XCTAssertEqual(options.action, .m4atomp4)
        XCTAssertEqual(options.outputFile, "release.mp4")
        XCTAssertTrue(options.overwrite)
        XCTAssertEqual(options.seed, 7)
    }

    func testNumericFormattingAndBitrateParsingUseStableFFmpegForms() throws {
        XCTAssertEqual(ffmpegNumber(5), "5")
        XCTAssertEqual(ffmpegNumber(-12.5), "-12.5")
        XCTAssertEqual(ffmpegNumber(0.125), "0.125")

        XCTAssertEqual(parseBitrateBps("320k"), 320_000)
        XCTAssertEqual(parseBitrateBps("1.5m"), 1_500_000)
        XCTAssertEqual(parseBitrateBps("48000"), 48_000)
        XCTAssertNil(parseBitrateBps(""))
        XCTAssertNil(parseBitrateBps("0k"))
        XCTAssertNil(parseBitrateBps("not-a-bitrate"))
    }

    func testSchedulerProfileKeepsExpectedConcurrencyCaps() throws {
        XCTAssertEqual(SchedulerProfile.recommended(for: 1).summary, "total=2 image=2 audio=2 video=1")
        XCTAssertEqual(SchedulerProfile.recommended(for: 4).summary, "total=2 image=2 audio=2 video=1")
        XCTAssertEqual(SchedulerProfile.recommended(for: 5).summary, "total=3 image=2 audio=2 video=1")
        XCTAssertEqual(SchedulerProfile.recommended(for: 8).summary, "total=3 image=2 audio=2 video=1")
        XCTAssertEqual(SchedulerProfile.recommended(for: 12).summary, "total=4 image=2 audio=2 video=1")
        XCTAssertEqual(SchedulerProfile.recommended(for: 0).summary, "total=2 image=2 audio=2 video=1")
    }

    func testShortDurationHelpersClampToInputDurationConfigAndHardLimit() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("converter-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let defaultTool = try makeTool(tempDirectory: tempDirectory, arguments: ["-short"])
        XCTAssertEqual(try defaultTool.configuredShortClipSeconds(), 58, accuracy: 0.0001)
        XCTAssertEqual(try defaultTool.effectiveShortClipSeconds(forDuration: 12.25), 12.25, accuracy: 0.0001)
        XCTAssertEqual(try defaultTool.effectiveShortClipSeconds(forDuration: 90), 58, accuracy: 0.0001)

        // audit #0063: this used to assign shortMP4ClipSeconds="0:30" straight to the struct, a value
        // validate() rejected, so the MM:SS form was only ever exercised on a config no user could load.
        // The value now arrives the way production receives it, through ProjectConfig.load.
        let workspace = try IntegrationWorkspace()
        try workspace.overwriteConfig(IntegrationWorkspace.defaultConfig + "\nSHORT_MP4_CLIP_SECONDS=0:30\n")
        let previewTool = try workspace.makeTool(arguments: ["-short"])
        XCTAssertEqual(previewTool.config.shortMP4ClipSeconds, "0:30")
        XCTAssertEqual(try previewTool.configuredShortClipSeconds(), 30, accuracy: 0.0001)
        XCTAssertEqual(try previewTool.effectiveShortClipSeconds(forDuration: 90), 30, accuracy: 0.0001)
    }

    // audit #0063: validate() checked SHORT_MP4_CLIP_SECONDS with Double() while the render read it
    // through parseFlexibleTimecode, so "0:58" and "1:30" were rejected at load although the consumer
    // understood them. One parser now decides: seconds, MM:SS and HH:MM:SS load, and zero, negative,
    // malformed and absurdly large values fail with a message naming the key.
    func testShortClipSecondsAcceptsTimecodesAndRejectsNonPositiveOrMalformedValues() throws {
        let workspace = try IntegrationWorkspace()
        func load(_ value: String) throws -> Double {
            try workspace.overwriteConfig(IntegrationWorkspace.defaultConfig + "\nSHORT_MP4_CLIP_SECONDS=\(value)\n")
            let config = try loadConfig(from: workspace)
            return try parseFlexibleTimecode(config.shortMP4ClipSeconds, label: "SHORT_MP4_CLIP_SECONDS")
        }

        XCTAssertEqual(try load("58"), 58)
        XCTAssertEqual(try load("0:58"), 58)
        XCTAssertEqual(try load("1:30"), 90)
        XCTAssertEqual(try load("0:01:30.5"), 90.5)

        for invalid in ["0", "0:00", "-5", "1:75", "abc", "1e300", "1:2:3:4"] {
            XCTAssertThrowsError(try load(invalid), "SHORT_MP4_CLIP_SECONDS=\(invalid) must be rejected") { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("SHORT_MP4_CLIP_SECONDS"),
                    "'\(invalid)': \(error.localizedDescription)"
                )
            }
        }
    }

    func testOutputNamingAndSuffixHelpersAreStable() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("converter-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tool = try makeTool(tempDirectory: tempDirectory, arguments: ["-short"])

        XCTAssertEqual(tool.shortMP4Stem(forInputStem: "song_8K"), "song_8K_Short")
        XCTAssertEqual(tool.shortMP4Stem(forInputStem: "song_8K_Short"), "song_8K_Short")
        XCTAssertEqual(tool.portraitShortMP4Stem(forAudioStem: "song"), "song_8K_Short")
        XCTAssertEqual(tool.portraitShortMP4Stem(forAudioStem: "song_8K"), "song_8K_Short")
        XCTAssertEqual(tool.portraitShortMP4Stem(forAudioStem: "song_8K_Short"), "song_8K_Short")
        XCTAssertEqual(tool.fullSongShortMP4Stem(forAudioStem: "song"), "song_8K_Short_FullSong")
        XCTAssertEqual(tool.fullSongShortMP4Stem(forAudioStem: "song_8K_Short"), "song_8K_Short_FullSong")

        XCTAssertEqual(tool.bassOutputSuffix(for: BassBoostSpec(frequencyHz: 80, gainDB: 5)), "_bass")
        XCTAssertEqual(tool.bassOutputSuffix(for: BassBoostSpec(frequencyHz: 60, gainDB: 7.5)), "_bass_60Hz_7_5dB")
        XCTAssertEqual(tool.loudnessOutputSuffix(for: LoudnessSpec(targetLUFS: -12)), "_loudness_m12LUFS")
        XCTAssertEqual(tool.loudnessOutputSuffix(for: LoudnessSpec(targetLUFS: -13.5)), "_loudness_m13_5LUFS")
        XCTAssertEqual(tool.silenceOutputSuffix(for: SilenceSpec(seconds: 30)), "_silence_30s")
        XCTAssertEqual(tool.silenceOutputSuffix(for: SilenceSpec(seconds: 0.5)), "_silence_0_5s")
        XCTAssertEqual(tool.noiseOutputSuffix(for: NoiseSpec(seconds: 45)), "_noise_45s")
        XCTAssertEqual(tool.noiseOutputSuffix(for: NoiseSpec(seconds: 0.75)), "_noise_0_75s")
    }

    func testNFTToShortFlagParsesAndOldMP3ToShortFlagIsRejected() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let options = try CLIOptions.parse(
            arguments: ["-nfttoshort"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertEqual(options.action, .nfttoshort)

        XCTAssertThrowsError(try CLIOptions.parse(
            arguments: ["-mp3toshort"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("Use -nfttoshort"))
        }
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
        XCTAssertTrue(help.contains("-album"))
        XCTAssertTrue(help.contains("natural numeric filename order"))
        XCTAssertTrue(help.contains("Horizontal_8K.png"))
        XCTAssertTrue(help.contains("Vertical_8K.png"))
        XCTAssertTrue(help.contains(".flac or .wav or .mp3"))
        XCTAssertTrue(help.contains("--hash"))
        XCTAssertTrue(help.contains(".wav, .flac, .mp3, and .mp4"))
        XCTAssertTrue(help.contains("-bass [FREQUENCY_HZ GAIN_DB]"))
        XCTAssertTrue(help.contains(".flac, .wav, .mp3, .m4a, or .mp4"))
        XCTAssertTrue(help.contains("-loudscan"))
        XCTAssertTrue(help.contains("-loudness [TARGET_LUFS]"))
        XCTAssertTrue(help.contains("-noise [SECONDS]"))
        XCTAssertTrue(help.contains("-silence [SECONDS]"))
        XCTAssertTrue(help.contains("-short"))
        XCTAssertTrue(help.contains("audio-only file supported by ffmpeg"))
        // Both portrait framings must stay documented in help.
        XCTAssertTrue(help.contains("fits the image into the frame with black padding"))
        XCTAssertTrue(help.contains("_8K_Short_CenterCut.mp4"))
        XCTAssertTrue(help.contains("crops the centre of the 8K master to fill the frame"))
        XCTAssertTrue(help.contains("_FullSong"))
        XCTAssertTrue(help.contains("Use: -full / -run"))
        XCTAssertFalse(help.contains("Default action with no parameter"))
        XCTAssertTrue(help.contains("-mp3toflac"))
        XCTAssertTrue(help.contains("-nfttoshort"))
        XCTAssertTrue(help.contains("-fade [SECONDS]"))
        XCTAssertTrue(help.contains("-fadecut CUT_SECONDS FADE_SECONDS"))
        XCTAssertTrue(help.contains("-fadeout START DURATION"))
        XCTAssertTrue(help.contains("-m4atowav"))
        XCTAssertTrue(help.contains("-pngtojpg"))
        XCTAssertTrue(help.contains(".jpg or .jpeg"))
        XCTAssertFalse(help.contains("-jpegtopng"))
        XCTAssertFalse(help.contains("-pngtojpeg"))
    }

    func testAlbumActionParsesAndSortsNaturallyIgnoringExtension() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        for name in ["10 - Storm.flac", "1 - Sun.mp3", "2 - Rain.wav", "album.wav", "3_loudness_m12LUFS.mp3"] {
            FileManager.default.createFile(atPath: tempDirectory.appendingPathComponent(name).path, contents: Data("x".utf8))
        }

        let tool = try makeTool(tempDirectory: tempDirectory, arguments: ["-album"])
        XCTAssertEqual(tool.cli.action, .album)
        XCTAssertEqual(try tool.albumAudioCandidates().map(\.lastPathComponent), ["1 - Sun.mp3", "2 - Rain.wav", "10 - Storm.flac"])
    }

    // audit #0085: the leading track number was collected with Character.isNumber, which also
    // accepts vulgar fractions and non-ASCII digits, so "3½ x" became Int("3½") == nil and sorted
    // as an unnumbered track after "10 y"; a run of more than 19 digits overflowed Int the same way.
    // The prefix is now ASCII digits only and anything longer than a plausible track number is
    // not a number at all, so a hash- or timestamp-like prefix can never reorder real tracks.
    func testAlbumTrackSortParsesOnlyASCIIDigitPrefixes() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let tool = try makeTool(tempDirectory: temp, arguments: ["-album"])

        let names = [
            "10 y.flac", "3½ x.flac", "2 z.flac", "07 v.flac",
            "1234567890123456789012345 w.flac", "٣ arabic.flac", "untitled.flac"
        ]
        let sorted = tool.sortAlbumAudioTracks(names.map { temp.appendingPathComponent($0) }).map(\.lastPathComponent)
        XCTAssertEqual(Array(sorted.prefix(4)), ["2 z.flac", "3½ x.flac", "07 v.flac", "10 y.flac"])
        // The unnumbered tail follows the locale-aware stem comparison, which this test does not pin.
        XCTAssertEqual(
            Set(sorted.dropFirst(4)),
            ["1234567890123456789012345 w.flac", "untitled.flac", "٣ arabic.flac"]
        )
    }

    func testBassParsesDefaultsAndManualValues() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let defaultOptions = try CLIOptions.parse(
            arguments: ["-bass"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertEqual(defaultOptions.action, .bass)
        XCTAssertEqual(try defaultOptions.bassBoostSpec(), BassBoostSpec(frequencyHz: 80, gainDB: 5))

        let manualOptions = try CLIOptions.parse(
            arguments: ["-bass", "60", "7.5"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertEqual(try manualOptions.bassBoostSpec(), BassBoostSpec(frequencyHz: 60, gainDB: 7.5))

        let cutOptions = try CLIOptions.parse(
            arguments: ["-bass", "80", "-5"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertEqual(try cutOptions.bassBoostSpec(), BassBoostSpec(frequencyHz: 80, gainDB: -5))
    }

    func testBassRejectsInvalidArguments() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        XCTAssertThrowsError(
            try CLIOptions.parse(
                arguments: ["-bass", "80"],
                environment: [:],
                scriptDirectory: root,
                scriptName: "converter"
            ).bassBoostSpec()
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("FREQUENCY_HZ GAIN_DB"))
        }
        XCTAssertThrowsError(
            try CLIOptions.parse(
                arguments: ["-bass", "0", "5"],
                environment: [:],
                scriptDirectory: root,
                scriptName: "converter"
            ).bassBoostSpec()
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("positive"))
        }
    }

    func testSilenceParsesDefaultAndExplicitDuration() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let defaultOptions = try CLIOptions.parse(
            arguments: ["-silence"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertEqual(defaultOptions.action, .silence)
        XCTAssertEqual(try defaultOptions.silenceSpec(), SilenceSpec(seconds: 30))

        let options = try CLIOptions.parse(
            arguments: ["-silence", "45"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertEqual(options.action, .silence)
        XCTAssertEqual(try options.silenceSpec(), SilenceSpec(seconds: 45))
    }

    func testSilenceRejectsInvalidArguments() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        XCTAssertThrowsError(
            try CLIOptions.parse(
                arguments: ["-silence", "30", "45"],
                environment: [:],
                scriptDirectory: root,
                scriptName: "converter"
            ).silenceSpec()
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("at most one positional duration"))
        }
        XCTAssertThrowsError(
            try CLIOptions.parse(
                arguments: ["-silence", "0"],
                environment: [:],
                scriptDirectory: root,
                scriptName: "converter"
            ).silenceSpec()
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("at least"))
        }
    }

    func testNoiseParsesDefaultAndExplicitDuration() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let defaultOptions = try CLIOptions.parse(
            arguments: ["-noise"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertEqual(defaultOptions.action, .noise)
        XCTAssertEqual(try defaultOptions.noiseSpec(), NoiseSpec(seconds: 30))

        let options = try CLIOptions.parse(
            arguments: ["-noise", "45"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertEqual(options.action, .noise)
        XCTAssertEqual(try options.noiseSpec(), NoiseSpec(seconds: 45))
    }

    func testNoiseRejectsInvalidArguments() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        XCTAssertThrowsError(
            try CLIOptions.parse(
                arguments: ["-noise", "30", "45"],
                environment: [:],
                scriptDirectory: root,
                scriptName: "converter"
            ).noiseSpec()
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("at most one positional duration"))
        }
        XCTAssertThrowsError(
            try CLIOptions.parse(
                arguments: ["-noise", "0"],
                environment: [:],
                scriptDirectory: root,
                scriptName: "converter"
            ).noiseSpec()
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("at least"))
        }
    }

    func testProjectLoudnessDefaultsAreMinus12LUFS() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let logger = Logger(scriptName: "converterTests", debugEnabled: false)
        let options = try CLIOptions.parse(arguments: ["-help"], environment: [:], scriptDirectory: root, scriptName: "converter")
        let config = try ProjectConfig.load(
            from: root.appendingPathComponent("missing-config.txt"),
            environment: [:],
            cli: options,
            logger: logger
        )

        XCTAssertEqual(config.audioQCTargetLUFS, -12)
        XCTAssertEqual(config.shortAudioQCTargetLUFS, -12)
        XCTAssertEqual(config.masteringTargetLUFS, -12)
        XCTAssertEqual(config.deliveryAudioQCPolicy.targetLUFS, -12)
        XCTAssertEqual(config.shortFormAudioQCPolicy.targetLUFS, -12)
        XCTAssertEqual(config.masteringAudioQCPolicy.targetLUFS, -12)
    }

    func testYouTubeShortProfileKeepsProjectMinus12LUFSTarget() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let logger = Logger(scriptName: "converterTests", debugEnabled: false)
        let options = try CLIOptions.parse(
            arguments: ["--profile", "youtube_short", "-help"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        let config = try ProjectConfig.load(
            from: root.appendingPathComponent("missing-config.txt"),
            environment: [:],
            cli: options,
            logger: logger
        )

        XCTAssertEqual(config.audioQCTargetLUFS, -12)
        XCTAssertEqual(config.shortAudioQCTargetLUFS, -12)
        XCTAssertEqual(config.masteringTargetLUFS, -12)
    }

    // audit #0045: the youtube_short overlay put h264_videotoolbox first at the default 4320x7680
    // portrait size, where VideoToolbox cannot open an H.264 session (ffmpeg: "Cannot create
    // compression session: -12903"), so every short variant burned a failing rung and a warning
    // before libx264 ran. libx264 stays primary with VideoToolbox as the fallback.
    func testYouTubeShortProfileKeepsLibx264PrimaryAtPortrait8K() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let options = try CLIOptions.parse(
            arguments: ["--profile", "youtube_short", "-help"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        let config = try ProjectConfig.load(
            from: root.appendingPathComponent("missing-config.txt"),
            environment: [:],
            cli: options,
            logger: Logger(scriptName: "converterTests", debugEnabled: false)
        )

        XCTAssertEqual(config.shortMP4ScaleW, 4320)
        XCTAssertEqual(config.shortMP4ScaleH, 7680)
        XCTAssertEqual(config.shortVideoEncoderLadder, ["libx264", "h264_videotoolbox"])
        // The rest of the overlay is unchanged.
        XCTAssertEqual(config.shortMP4VTQuality, "65")
        XCTAssertEqual(config.shortAudioQCLUFSTolerance, 6)
    }

    // audit #0045: an h264_videotoolbox primary above the 4096-pixel VideoToolbox H.264 session
    // limit is a configuration error and must be rejected at load, naming the codec key, the size
    // and the limit, instead of failing on every render. VideoToolbox as a fallback stays allowed.
    func testValidateRejectsH264VideoToolboxPrimaryAboveVideoToolboxSessionLimit() throws {
        let workspace = try IntegrationWorkspace()
        func load(_ extraLines: String) throws -> ProjectConfig {
            try workspace.overwriteConfig(IntegrationWorkspace.defaultConfig + "\n" + extraLines + "\n")
            return try loadConfig(from: workspace)
        }
        let shortVTPrimary = "SHORT_MP4_VIDEO_CODEC=h264_videotoolbox\nSHORT_MP4_VIDEO_FALLBACKS=libx264\n"

        XCTAssertThrowsError(try load(shortVTPrimary + "SHORT_MP4_SCALE_W=4320\nSHORT_MP4_SCALE_H=7680")) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.hasPrefix("SHORT_MP4_VIDEO_CODEC=h264_videotoolbox cannot encode 4320x7680"), message)
            XCTAssertTrue(message.contains("limited to 4096 pixels per dimension"), message)
        }
        // Either axis alone over the limit is rejected; exactly at the limit is fine.
        XCTAssertThrowsError(try load(shortVTPrimary + "SHORT_MP4_SCALE_W=4098\nSHORT_MP4_SCALE_H=4096"))
        XCTAssertThrowsError(try load(shortVTPrimary + "SHORT_MP4_SCALE_W=4096\nSHORT_MP4_SCALE_H=4098"))
        let atLimit = try load(shortVTPrimary + "SHORT_MP4_SCALE_W=4096\nSHORT_MP4_SCALE_H=4096")
        XCTAssertEqual(atLimit.shortVideoEncoderLadder.first, "h264_videotoolbox")

        // As a fallback behind libx264 the encoder is never asked to open the oversized session.
        let vtFallback = try load("SHORT_MP4_VIDEO_CODEC=libx264\nSHORT_MP4_VIDEO_FALLBACKS=h264_videotoolbox\n"
            + "SHORT_MP4_SCALE_W=4320\nSHORT_MP4_SCALE_H=7680")
        XCTAssertEqual(vtFallback.shortVideoEncoderLadder, ["libx264", "h264_videotoolbox"])

        // The main ladder has the same limit.
        XCTAssertThrowsError(
            try load("VIDEO_MP4_ENCODER=h264_videotoolbox\nVIDEO_MP4_WIDTH=7680\nVIDEO_MP4_HEIGHT=4320")
        ) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.hasPrefix("VIDEO_MP4_ENCODER=h264_videotoolbox cannot encode 7680x4320"), message)
        }
        XCTAssertNoThrow(try load("VIDEO_MP4_ENCODER=hevc_videotoolbox\nVIDEO_MP4_WIDTH=7680\nVIDEO_MP4_HEIGHT=4320"))

        // fast_preview keeps h264_videotoolbox first for both ladders, so its short render must sit
        // inside the limit too (the portrait counterpart of its 1920x1080 main render). Loaded
        // without a config.txt so the profile overlay is what sets the size.
        let previewOptions = try CLIOptions.parse(
            arguments: ["-help", "--profile", "fast_preview"],
            environment: [:],
            scriptDirectory: workspace.root,
            scriptName: "converter"
        )
        let preview = try ProjectConfig.load(
            from: workspace.root.appendingPathComponent("missing-config.txt"),
            environment: [:],
            cli: previewOptions,
            logger: Logger(scriptName: "converterTests", debugEnabled: false)
        )
        XCTAssertEqual(preview.shortVideoEncoderLadder.first, "h264_videotoolbox")
        XCTAssertEqual(preview.shortMP4ScaleW, 1080)
        XCTAssertEqual(preview.shortMP4ScaleH, 1920)
    }

    func testLoudnessParsesTargetLUFS() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let defaultOptions = try CLIOptions.parse(
            arguments: ["-loudness"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertEqual(defaultOptions.action, .loudness)
        XCTAssertEqual(try defaultOptions.loudnessSpec(), LoudnessSpec(targetLUFS: -12))

        let options = try CLIOptions.parse(
            arguments: ["-loudness", "-16"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertEqual(options.action, .loudness)
        XCTAssertEqual(try options.loudnessSpec(), LoudnessSpec(targetLUFS: -16))

        let scanOptions = try CLIOptions.parse(
            arguments: ["-loudscan"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertEqual(scanOptions.action, .loudscan)

        let typoAliasOptions = try CLIOptions.parse(
            arguments: ["-loundscan"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertEqual(typoAliasOptions.action, .loudscan)
    }

    func testStaticLoudnessGainNeverAttenuatesQuietPeakConstrainedAudio() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("converter-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tool = try makeTool(tempDirectory: tempDirectory, arguments: ["-loudness"])
        XCTAssertEqual(tool.staticLoudnessAppliedGainDB(requestedGainDB: 4, maxSafeBoostDB: 2), 2)
        XCTAssertEqual(tool.staticLoudnessAppliedGainDB(requestedGainDB: 4, maxSafeBoostDB: -0.5), 0)
        XCTAssertEqual(tool.staticLoudnessAppliedGainDB(requestedGainDB: -3, maxSafeBoostDB: -0.5), -3)
    }

    func testLoudnessFiltersRejectBassAndEQFilters() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("converter-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tool = try makeTool(tempDirectory: tempDirectory, arguments: ["-loudness"])
        let policy = tool.loudnessPolicy(targetLUFS: -12)
        let singlePass = tool.loudnormSinglePassFilter(policy: policy)
        let staticGain = tool.staticLoudnessGainFilter(gainDB: 1.25)
        let secondPass = try XCTUnwrap(tool.loudnormSecondPassFilter(policy: policy, measurement: [
            "input_i": "-16.20",
            "input_lra": "4.10",
            "input_tp": "-2.50",
            "input_thresh": "-26.40",
            "target_offset": "0.10"
        ]))

        XCTAssertNoThrow(try tool.validateLoudnessFilterIsEQNeutral(singlePass))
        XCTAssertNoThrow(try tool.validateLoudnessFilterIsEQNeutral(staticGain))
        XCTAssertNoThrow(try tool.validateLoudnessFilterIsEQNeutral(secondPass))
        XCTAssertThrowsError(try tool.validateLoudnessFilterIsEQNeutral(tool.bassFilter(for: BassBoostSpec(frequencyHz: 80, gainDB: 5)))) { error in
            XCTAssertTrue(error.localizedDescription.contains("forbidden filter 'bass'"))
        }
        XCTAssertThrowsError(try tool.validateLoudnessFilterIsEQNeutral("loudnorm=I=-12:TP=-1:LRA=50,lowpass=f=120")) { error in
            XCTAssertTrue(error.localizedDescription.contains("forbidden filter 'lowpass'"))
        }
    }

    func testLoudnessFallbackAcceptsMediaValidQCIssuesOnly() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("converter-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tool = try makeTool(tempDirectory: tempDirectory, arguments: ["-loudness"])
        let policy = tool.loudnessPolicy(targetLUFS: -12)
        let metrics = AudioQCMetrics(
            integratedLUFS: -13.3,
            truePeakDBTP: -0.6,
            loudnessRange: 5,
            dcOffset: 0,
            stereoImbalanceDB: 0,
            peakLevelDBFS: -1,
            clippedSamples: 0,
            maxVolumeDBFS: -1,
            analysisLimited: false
        )
        let recoverableResult = AudioQCResult(
            policy: policy,
            metrics: metrics,
            passed: false,
            issues: [
                "integrated loudness -13.30 LUFS outside -12.80 to -11.20 LUFS (target -12.00)",
                "true peak -0.60 dBTP exceeds max -1.00"
            ]
        )
        let brokenResult = AudioQCResult(
            policy: policy,
            metrics: metrics,
            passed: false,
            issues: ["Audio verification failed: output appears silent"]
        )
        // The breach is inherent: the source already peaked at -0.6, so no gain was applied.
        let inherentPeakPlan = loudnessFallbackPlan(sourcePeakDBFS: -0.6, appliedGainDB: 0, peakConstrained: true)

        XCTAssertTrue(
            tool.loudnessCandidateIsPublishableFallback(recoverableResult, policy: policy, plan: inherentPeakPlan)
        )
        XCTAssertFalse(
            tool.loudnessCandidateIsPublishableFallback(brokenResult, policy: policy, plan: inherentPeakPlan)
        )

        // The warning names what actually limited the render.
        XCTAssertEqual(tool.loudnessFallbackReason(result: recoverableResult), "peak-constrained")
        XCTAssertEqual(tool.loudnessFallbackReason(result: brokenResult), "closest-safe")
    }

    // audit #0050: the fallback used to excuse every true-peak issue. It may only excuse one the
    // render did not add - the source peak plus the gain actually applied - and MP3 gets the
    // documented 0.3 dB of lossy-encoder headroom on top.
    func testLoudnessFallbackOnlyExcusesAnInherentTruePeak() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("converter-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tool = try makeTool(tempDirectory: tempDirectory, arguments: ["-loudness"])
        let policy = tool.loudnessPolicy(targetLUFS: -12)
        let addedPeakPlan = loudnessFallbackPlan(sourcePeakDBFS: -1.5, appliedGainDB: 0.5, peakConstrained: false)
        let addedPeakResult = try loudnessFallbackResult(
            tool: tool, policy: policy, truePeakDBTP: -0.6, peakLevelDBFS: -1.5
        )

        // -0.6 dBTP against a ceiling of -1.5 + 0.5 + 0.1 = -0.9: the render added the breach.
        XCTAssertFalse(
            tool.loudnessCandidateIsPublishableFallback(addedPeakResult, policy: policy, plan: addedPeakPlan)
        )

        // -0.75 dBTP is inside the lossy allowance (-0.7) but outside the lossless one (-0.9).
        let nearCeilingResult = try loudnessFallbackResult(
            tool: tool, policy: policy, truePeakDBTP: -0.75, peakLevelDBFS: -1.5
        )
        XCTAssertFalse(
            tool.loudnessCandidateIsPublishableFallback(nearCeilingResult, policy: policy, plan: addedPeakPlan)
        )
        XCTAssertTrue(
            tool.loudnessCandidateIsPublishableFallback(
                nearCeilingResult, policy: policy, plan: addedPeakPlan, lossyOutput: true
            )
        )
    }

    private func loudnessFallbackPlan(
        sourcePeakDBFS: Double, appliedGainDB: Double, peakConstrained: Bool
    ) -> LoudnessStaticGainPlan {
        LoudnessStaticGainPlan(
            sourceIntegratedLUFS: -13.3,
            sourcePeakDBFS: sourcePeakDBFS,
            requestedGainDB: 1.3,
            maxSafeBoostDB: 0.5,
            appliedGainDB: appliedGainDB,
            peakConstrained: peakConstrained
        )
    }

    private func loudnessFallbackResult(
        tool: ConverterTool, policy: AudioQCPolicy, truePeakDBTP: Double, peakLevelDBFS: Double
    ) throws -> AudioQCResult {
        let metrics = AudioQCMetrics(
            integratedLUFS: -13.3,
            truePeakDBTP: truePeakDBTP,
            loudnessRange: 5,
            dcOffset: 0,
            stereoImbalanceDB: 0,
            peakLevelDBFS: peakLevelDBFS,
            clippedSamples: 0,
            maxVolumeDBFS: peakLevelDBFS,
            analysisLimited: false
        )
        return AudioQCResult(
            policy: policy,
            metrics: metrics,
            passed: false,
            issues: ["true peak \(truePeakDBTP) dBTP exceeds max -1.00"]
        )
    }

    func testLoudnessRejectsInvalidTargets() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        XCTAssertThrowsError(
            try CLIOptions.parse(
                arguments: ["-loudness", "-12", "-13"],
                environment: [:],
                scriptDirectory: root,
                scriptName: "converter"
            ).loudnessSpec()
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("optional TARGET_LUFS"))
        }
        XCTAssertThrowsError(
            try CLIOptions.parse(
                arguments: ["-loudness", "12"],
                environment: [:],
                scriptDirectory: root,
                scriptName: "converter"
            ).loudnessSpec()
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("at or below -5"))
        }
        XCTAssertThrowsError(
            try CLIOptions.parse(
                arguments: ["-loudness", "-4"],
                environment: [:],
                scriptDirectory: root,
                scriptName: "converter"
            ).loudnessSpec()
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("at or below -5"))
        }
    }

    func testResolveFullAudioPrefersHighestQualitySameStemSource() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        for name in ["song.flac", "song.wav", "song.mp3", "song_RF64.wav", "song_BW64.flac"] {
            FileManager.default.createFile(atPath: tempDirectory.appendingPathComponent(name).path, contents: Data("x".utf8))
        }

        // The family collapses to the FLAC, which the run then renames to the release stem.
        let tool = try makeTool(tempDirectory: tempDirectory)
        XCTAssertEqual(try tool.resolveFullAudio().lastPathComponent, "1_source.flac")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("song.flac").path))
        // The rest of the family moves with the source (audit #0022), so a rerun sees one family.
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("song.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent("1_source.wav").path))
    }

    // A full run writes its image deliverables next to the source, so rerunning in the same
    // directory used to fail with "expects exactly one source image" once the derived family
    // existed. The audio side already collapsed its own family; the image side now matches.
    func testResolveFullImageCollapsesItsOwnDerivedOutputsOnRerun() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tool = try makeTool(tempDirectory: tempDirectory)
        func write(_ name: String, _ width: Int, _ height: Int) throws {
            _ = try tool.runner.run("magick", ["-size", "\(width)x\(height)", "canvas:gray", tempDirectory.appendingPathComponent(name).path])
        }

        // Landscape renditions the run derived from its own master.
        for name in ["9_8K.png", "9_4K.png", "9_3K.png", "9_8K_1MB.jpg", "9_3K_1MB.jpg"] {
            try write(name, 320, 180)
        }
        // Square NFT renditions count as masters too, so they must collapse into the family.
        for name in ["9_NFT8K.png", "9_NFT3K.png"] {
            try write(name, 200, 200)
        }

        XCTAssertEqual(try tool.resolveFullImage().lastPathComponent, "9_8K.png")

        // A bare source outranks every derived rendition.
        try write("9.png", 320, 180)
        XCTAssertEqual(try tool.resolveFullImage().lastPathComponent, "9.png")
    }

    // A full run takes one landscape master plus, optionally, one portrait image for the
    // fitted shorts. They are told apart by orientation, so neither needs a special name.
    func testFullRunSourceImagesSplitByOrientation() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let tool = try makeTool(tempDirectory: tempDirectory)

        func write(_ name: String, _ width: Int, _ height: Int) throws {
            _ = try tool.runner.run("magick", ["-size", "\(width)x\(height)", "canvas:gray", tempDirectory.appendingPathComponent(name).path])
        }

        try write("cover.png", 300, 169)
        let landscapeOnly = try tool.resolveFullRunSourceImages()
        XCTAssertEqual(landscapeOnly.master.lastPathComponent, "cover.png")
        XCTAssertNil(landscapeOnly.portrait)

        try write("vertical.png", 108, 192)
        let both = try tool.resolveFullRunSourceImages()
        XCTAssertEqual(both.master.lastPathComponent, "cover.png")
        XCTAssertEqual(both.portrait?.lastPathComponent, "vertical.png")

        // A second portrait is ambiguous and must be rejected rather than silently picked.
        try write("vertical_alt.png", 200, 400)
        XCTAssertThrowsError(try tool.resolveFullRunSourceImages()) { error in
            XCTAssertTrue(error.localizedDescription.contains("at most one portrait"))
        }
    }

    func testFullRunSourceImagesRejectTwoLandscapeMasters() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let tool = try makeTool(tempDirectory: tempDirectory)

        for name in ["cover.png", "backdrop.png"] {
            _ = try tool.runner.run("magick", ["-size", "300x169", "canvas:gray", tempDirectory.appendingPathComponent(name).path])
        }
        XCTAssertThrowsError(try tool.resolveFullRunSourceImages()) { error in
            XCTAssertTrue(error.localizedDescription.contains("exactly one landscape source image"))
        }
    }

    func testResolveFullImageStillRejectsTwoDistinctSources() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tool = try makeTool(tempDirectory: tempDirectory)
        for name in ["cover.png", "cover_8K.png", "backdrop.png"] {
            _ = try tool.runner.run("magick", ["-size", "320x180", "canvas:gray", tempDirectory.appendingPathComponent(name).path])
        }

        XCTAssertThrowsError(try tool.resolveFullImage()) { error in
            XCTAssertTrue(error.localizedDescription.contains("exactly one landscape source image"))
        }
    }

    func testFullRunImageBaseNameStripsStackedDerivedSuffixes() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let tool = try makeTool(tempDirectory: tempDirectory)

        XCTAssertEqual(tool.fullRunImageBaseName("9_8K_20MB"), "9")
        XCTAssertEqual(tool.fullRunImageBaseName("9_NFT3K"), "9")
        XCTAssertEqual(tool.fullRunImageBaseName("mix_8K_take_8K"), "mix_8K_take")
        XCTAssertEqual(tool.fullRunImageBaseName("9_Short_8K"), "9")
        XCTAssertEqual(tool.fullRunImageBaseName("9_Short_CenterCut_8K"), "9")
        XCTAssertEqual(tool.fullRunImageBaseName("cover"), "cover")
    }

    // The short set is four files: a letterboxed pair and a centre-cut pair, each with a
    // full-length companion. The names must stay distinct and stable so they are sortable
    // in a delivery folder.
    func testShortMP4StemsCoverLetterboxedAndCenterCutVariants() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let tool = try makeTool(tempDirectory: tempDirectory)

        let shortStem = tool.portraitShortMP4Stem(forAudioStem: "8CF14A3F")
        let fullSongStem = tool.fullSongShortMP4Stem(forAudioStem: "8CF14A3F")

        XCTAssertEqual(shortStem, "8CF14A3F_8K_Short")
        XCTAssertEqual(fullSongStem, "8CF14A3F_8K_Short_FullSong")
        XCTAssertEqual(tool.centerCutShortMP4Stem(shortStem), "8CF14A3F_8K_Short_CenterCut")
        XCTAssertEqual(tool.centerCutShortMP4Stem(fullSongStem), "8CF14A3F_8K_Short_FullSong_CenterCut")

        // All four are distinct, so no variant can overwrite another.
        let stems = Set([shortStem, fullSongStem, tool.centerCutShortMP4Stem(shortStem), tool.centerCutShortMP4Stem(fullSongStem)])
        XCTAssertEqual(stems.count, 4)

        // Applying the suffix twice must not stack it.
        XCTAssertEqual(
            tool.centerCutShortMP4Stem(tool.centerCutShortMP4Stem(shortStem)),
            "8CF14A3F_8K_Short_CenterCut"
        )
    }

    func testShortFillModesUseDistinctTempStemsAndSuffixes() throws {
        XCTAssertEqual(ConverterTool.ShortFillMode.fit.outputStemSuffix, "")
        XCTAssertEqual(ConverterTool.ShortFillMode.centerCut.outputStemSuffix, "_CenterCut")
        // Distinct temp stems keep concurrent renders from colliding on the same temp name.
        XCTAssertNotEqual(
            ConverterTool.ShortFillMode.fit.tempStem,
            ConverterTool.ShortFillMode.centerCut.tempStem
        )
    }

    // A source-relative true-peak ceiling rebased onto a master that peaks above 0 dBTP once
    // produced "TP=0.19", which loudnorm rejects with "Result too large" — surfacing as an
    // encoder failure several layers away from the cause.
    func testLoudnormArgumentsStayInsideFFmpegsAcceptedRanges() throws {
        XCTAssertEqual(LoudnormArgument.truePeak(0.19), "0.00")
        XCTAssertEqual(LoudnormArgument.truePeak(-0.75), "-0.75")
        XCTAssertEqual(LoudnormArgument.truePeak(-20), "-9.00")

        XCTAssertEqual(LoudnormArgument.integrated(-4), "-5.00")
        XCTAssertEqual(LoudnormArgument.integrated(-12), "-12.00")
        XCTAssertEqual(LoudnormArgument.integrated(-90), "-70.00")

        XCTAssertEqual(LoudnormArgument.loudnessRange(0.5), "1.00")
        XCTAssertEqual(LoudnormArgument.loudnessRange(20), "20.00")
        XCTAssertEqual(LoudnormArgument.loudnessRange(80), "50.00")
    }

    // audit #0070: the clamps were only tested well past their bounds. ffmpeg's loudnorm accepts
    // I -70..-5, TP -9..0 and LRA 1..50 inclusive, so the exact bound must pass through unchanged and a
    // value one hundredth outside must land on the bound, while one hundredth inside stays put. A bound
    // that drifted inward or an exclusive comparison would otherwise surface much later as loudnorm's
    // unrelated-looking "Result too large" failure.
    func testLoudnormArgumentClampsAreInclusiveAtTheExactBounds() throws {
        XCTAssertEqual(LoudnormArgument.integrated(-70), "-70.00")
        XCTAssertEqual(LoudnormArgument.integrated(-5), "-5.00")
        XCTAssertEqual(LoudnormArgument.truePeak(-9), "-9.00")
        XCTAssertEqual(LoudnormArgument.truePeak(0), "0.00")
        XCTAssertEqual(LoudnormArgument.loudnessRange(1), "1.00")
        XCTAssertEqual(LoudnormArgument.loudnessRange(50), "50.00")

        XCTAssertEqual(LoudnormArgument.integrated(-70.01), "-70.00")
        XCTAssertEqual(LoudnormArgument.integrated(-69.99), "-69.99")
        XCTAssertEqual(LoudnormArgument.integrated(-4.99), "-5.00")
        XCTAssertEqual(LoudnormArgument.integrated(-5.01), "-5.01")
        XCTAssertEqual(LoudnormArgument.truePeak(-9.01), "-9.00")
        XCTAssertEqual(LoudnormArgument.truePeak(-8.99), "-8.99")
        XCTAssertEqual(LoudnormArgument.truePeak(0.01), "0.00")
        XCTAssertEqual(LoudnormArgument.truePeak(-0.01), "-0.01")
        XCTAssertEqual(LoudnormArgument.loudnessRange(0.99), "1.00")
        XCTAssertEqual(LoudnormArgument.loudnessRange(1.01), "1.01")
        XCTAssertEqual(LoudnormArgument.loudnessRange(50.01), "50.00")
        XCTAssertEqual(LoudnormArgument.loudnessRange(49.99), "49.99")
    }

    // audit #0070: the "%.2f" formatting rounds at the third decimal. A value just inside a bound may
    // round onto the bound (still accepted) but must never round past it, half-way cases must round
    // the way ffmpeg's own parser will read them back, and a tiny negative true peak may print as
    // "-0.00" only because ffmpeg reads that as 0. Every formatted value must parse back inside the
    // accepted range, whatever the input.
    func testLoudnormArgumentRoundingNeverLeavesTheAcceptedRange() throws {
        XCTAssertEqual(LoudnormArgument.integrated(-69.996), "-70.00")
        XCTAssertEqual(LoudnormArgument.integrated(-5.004), "-5.00")
        XCTAssertEqual(LoudnormArgument.integrated(-12.344), "-12.34")
        XCTAssertEqual(LoudnormArgument.integrated(-12.346), "-12.35")
        XCTAssertEqual(LoudnormArgument.truePeak(-8.996), "-9.00")
        XCTAssertEqual(LoudnormArgument.truePeak(-0.996), "-1.00")
        XCTAssertEqual(LoudnormArgument.truePeak(-0.004), "-0.00")
        XCTAssertEqual(Double(LoudnormArgument.truePeak(-0.004)), 0)
        XCTAssertEqual(LoudnormArgument.loudnessRange(1.004), "1.00")
        XCTAssertEqual(LoudnormArgument.loudnessRange(49.996), "50.00")

        // Inputs sweep from far below to far above every bound in a step that is not a multiple of
        // 0.01, so both clamping and rounding are exercised at arbitrary third-decimal positions.
        for value in stride(from: -120.0, through: 120.0, by: 0.037) {
            let integrated = try XCTUnwrap(Double(LoudnormArgument.integrated(value)))
            XCTAssertTrue((-70 ... -5).contains(integrated), "I=\(integrated) for \(value)")
            let truePeak = try XCTUnwrap(Double(LoudnormArgument.truePeak(value)))
            XCTAssertTrue((-9 ... 0).contains(truePeak), "TP=\(truePeak) for \(value)")
            let loudnessRange = try XCTUnwrap(Double(LoudnormArgument.loudnessRange(value)))
            XCTAssertTrue((1 ... 50).contains(loudnessRange), "LRA=\(loudnessRange) for \(value)")
        }
        // Non-finite policy values must still produce an argument inside the range.
        XCTAssertEqual(LoudnormArgument.integrated(-.infinity), "-70.00")
        XCTAssertEqual(LoudnormArgument.truePeak(.infinity), "0.00")
    }

    // Black-and-white artwork comes back out of the PNG coder as a grayscale frame, so a
    // deliverable rendered from a bilevel master identified as "gray" where the pipeline had
    // asked for sRGB and the run aborted on correct output. A genuinely foreign space still
    // has to fail.
    func testGrayscaleOutputSatisfiesAnSRGBExpectation() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let tool = try makeTool(tempDirectory: temp)

        XCTAssertTrue(tool.imageColorSpaceMatches(got: "srgb", expected: "srgb"))
        XCTAssertTrue(tool.imageColorSpaceMatches(got: "gray", expected: "srgb"))
        XCTAssertTrue(tool.imageColorSpaceMatches(got: "grey", expected: "srgb"))
        XCTAssertTrue(tool.imageColorSpaceMatches(got: "gray", expected: "rgb"))

        XCTAssertFalse(tool.imageColorSpaceMatches(got: "cmyk", expected: "srgb"))
        XCTAssertFalse(tool.imageColorSpaceMatches(got: "lab", expected: "srgb"))
        XCTAssertFalse(tool.imageColorSpaceMatches(got: "ycbcr", expected: "srgb"))
        XCTAssertFalse(tool.imageColorSpaceMatches(got: "", expected: "srgb"))
        XCTAssertFalse(tool.imageColorSpaceMatches(got: "srgb", expected: "gray"))
    }

    // A master exported elsewhere and named `Mirage_bass_80Hz_4dB_RF64.flac` was the only audio
    // in the folder, and the unconditional `_RF64` skip made it invisible: the run reported that
    // it "expects exactly one source audio file" while exactly one sat there. The suffix only
    // means "this pipeline's own companion" when the file it was written beside still exists.
    func testArchivalSuffixOnlySkipsAudioThatSitsBesideItsSource() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let tool = try makeTool(tempDirectory: temp)

        func touch(_ name: String) throws -> URL {
            let url = temp.appendingPathComponent(name)
            try Data().write(to: url)
            return url
        }

        // Alone in the folder, an _RF64 name is just a filename: it is the source.
        let lone = try touch("Mirage_bass_80Hz_4dB_RF64.flac")
        XCTAssertFalse(tool.isExternalArchivalAudioVariant(lone))
        // Resolving it also renames it, so ask again on a fresh copy of the name.
        XCTAssertEqual(try tool.resolveFullAudio().basename, "1_source.flac")
        try FileManager.default.moveItem(at: temp.appendingPathComponent("1_source.flac"), to: lone)

        // Once the source it was derived from is present, the same name is a companion.
        _ = try touch("Mirage_bass_80Hz_4dB.flac")
        let companion = try touch("Mirage_bass_80Hz_4dB_RF64.wav")
        let bw64 = try touch("Mirage_bass_80Hz_4dB_BW64.wav")
        XCTAssertTrue(tool.isExternalArchivalAudioVariant(companion))
        XCTAssertTrue(tool.isExternalArchivalAudioVariant(bw64))
        XCTAssertTrue(tool.isExternalArchivalAudioVariant(lone))

        // A rerun of the _RF64-named source keeps working: its own companions carry the suffix
        // twice, so they are recognised and skipped.
        let doubled = try touch("Mirage_bass_80Hz_4dB_RF64_RF64.flac")
        XCTAssertTrue(tool.isExternalArchivalAudioVariant(doubled))
    }

    // The message has to say what was actually in the folder; "expects exactly one" told the
    // user nothing when the answer was "one file, and I ignored it".
    func testMissingSourceAudioErrorNamesWhatWasSkipped() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let tool = try makeTool(tempDirectory: temp)

        XCTAssertThrowsError(try tool.resolveFullAudio()) { error in
            XCTAssertTrue("\(error)".contains("found no source audio"), "\(error)")
        }

        // A lone companion, with the source it names already gone: say why it was skipped.
        try Data().write(to: temp.appendingPathComponent("Mirage.flac"))
        try Data().write(to: temp.appendingPathComponent("Mirage_RF64.wav"))
        try FileManager.default.removeItem(at: temp.appendingPathComponent("Mirage.flac"))
        try Data().write(to: temp.appendingPathComponent("Mirage.mp3"))
        XCTAssertEqual(try tool.resolveFullAudio().basename, "1_source.mp3")

        // Two unrelated stems: name both, and do not count the companion among them (it moved
        // with its source to 1_source_RF64.wav, audit #0022).
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("1_source_RF64.wav").path))
        try Data().write(to: temp.appendingPathComponent("Other.wav"))
        XCTAssertThrowsError(try tool.resolveFullAudio()) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("but found 2"), message)
            XCTAssertTrue(message.contains("1_source.mp3"), message)
            XCTAssertTrue(message.contains("Other.wav"), message)
        }
    }

    // The release stem names all 29 deliverables, so the run normalises whatever arrives to
    // `1_source.<ext>`: the release is `1`, the untouched original carries the `_source` marker,
    // and no deliverable can ever be written over it. (audit #0007 / #0023)
    func testFullRunRenamesItsSourceAudioToOneSource() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let tool = try makeTool(tempDirectory: temp)

        try Data().write(to: temp.appendingPathComponent("Mirage_bass_80Hz_4dB_RF64.flac"))
        XCTAssertEqual(try tool.resolveFullAudio().basename, "1_source.flac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("1_source.flac").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: temp.appendingPathComponent("Mirage_bass_80Hz_4dB_RF64.flac").path))
        XCTAssertEqual(tool.fullRunReleaseStem(for: temp.appendingPathComponent("1_source.flac")), "1")

        // A rerun sees `1_source.flac` beside its own deliverables and resolves the same origin:
        // the preserved source outranks every derived family member.
        try Data().write(to: temp.appendingPathComponent("1.wav"))
        try Data().write(to: temp.appendingPathComponent("1.mp3"))
        try Data().write(to: temp.appendingPathComponent("1_RF64.flac"))
        try Data().write(to: temp.appendingPathComponent("1_BW64.wav"))
        XCTAssertEqual(try tool.resolveFullAudio().basename, "1_source.flac")

        // A new source dropped beside an old release is refused rather than renamed onto it.
        try FileManager.default.removeItem(at: temp.appendingPathComponent("1.wav"))
        try FileManager.default.removeItem(at: temp.appendingPathComponent("1.mp3"))
        try FileManager.default.removeItem(at: temp.appendingPathComponent("1_RF64.flac"))
        try FileManager.default.removeItem(at: temp.appendingPathComponent("1_BW64.wav"))
        try Data().write(to: temp.appendingPathComponent("Next.flac"))
        XCTAssertThrowsError(try tool.resolveFullAudio()) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("but found 2"), message)
            XCTAssertTrue(message.contains("1_source.flac"), message)
            XCTAssertTrue(message.contains("Next.flac"), message)
        }
        try FileManager.default.removeItem(at: temp.appendingPathComponent("1_source.flac"))
        try Data().write(to: temp.appendingPathComponent("1_source.flac"))
        try FileManager.default.removeItem(at: temp.appendingPathComponent("Next.flac"))
        try Data().write(to: temp.appendingPathComponent("Next.mp3"))
        // Same family key would be needed for a collapse; distinct stems still error out, and a
        // lone new file whose release name is taken is refused explicitly.
        try FileManager.default.removeItem(at: temp.appendingPathComponent("1_source.flac"))
        try Data().write(to: temp.appendingPathComponent("1_source.mp3"))
        XCTAssertThrowsError(try tool.resolveFullAudio()) { error in
            XCTAssertTrue("\(error)".contains("but found 2"), "\(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("Next.mp3").path),
                      "a refused rename must leave the new source untouched")
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

    func testParserRejectsRecursiveDiscoveryFlag() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        XCTAssertThrowsError(
            try CLIOptions.parse(
                arguments: ["--recursive"],
                environment: [:],
                scriptDirectory: root,
                scriptName: "converter"
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("--recursive is no longer supported"))
        }
    }

    func testExplicitPathsMustStayDirectlyInOutput() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tool = try makeTool(tempDirectory: tempDirectory)
        XCTAssertThrowsError(try tool.resolveOutputPath("nested/out.mp4")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Output path must stay directly"))
        }
        XCTAssertThrowsError(try tool.resolveExplicitPath("nested/track.wav", baseDirectory: tempDirectory)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Input path must stay directly"))
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

    func testInvalidLoudnormConfigTargetIsRejectedDuringLoad() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig + "\nAUDIO_QC_TARGET_LUFS=-4\n"
        )
        XCTAssertThrowsError(try workspace.makeTool(arguments: ["-help"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("AUDIO_QC_TARGET_LUFS"))
            XCTAssertTrue(error.localizedDescription.contains("between -70 and -5"))
        }
    }

    // Logger writes straight to file descriptor 2 and has no injectable sink, so the only way to
    // observe a log line without adding a production hook is to point fd 2 at a pipe around the
    // call. A background reader drains the pipe so a chatty body cannot block on a full buffer.
    private func captureStandardError(_ body: () throws -> Void) throws -> String {
        let pipe = Pipe()
        let savedStandardError = dup(STDERR_FILENO)
        XCTAssertNotEqual(savedStandardError, -1)
        XCTAssertNotEqual(dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO), -1)
        let captured = Mutex(Data())
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            captured.withLock { $0 = data }
            drained.leave()
        }
        let outcome = Result { try body() }
        dup2(savedStandardError, STDERR_FILENO)
        close(savedStandardError)
        // Closing the last writer is what lets the reader see end-of-file.
        try pipe.fileHandleForWriting.close()
        drained.wait()
        try outcome.get()
        return String(bytes: captured.withLock { $0 }, encoding: .utf8) ?? ""
    }

    private func loadConfig(from workspace: IntegrationWorkspace) throws -> ProjectConfig {
        let options = try CLIOptions.parse(
            arguments: ["-help"],
            environment: [:],
            scriptDirectory: workspace.root,
            scriptName: "converter"
        )
        return try ProjectConfig.load(
            from: workspace.configFile,
            environment: [:],
            cli: options,
            logger: Logger(scriptName: "converterTests", debugEnabled: false)
        )
    }

    // audit #0046: a misspelled key such as AUDIO_QC_TARGET_LUF was dropped with a debug-level line
    // that no normal run shows, so the setting silently kept its default while every output looked
    // plausible. Unknown keys must be reported at WARN level naming both the key and the file.
    func testUnknownConfigKeyIsReportedAtWarnLevelNamingKeyAndFile() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.overwriteConfig(IntegrationWorkspace.defaultConfig + "\nAUDIO_QC_TARGET_LUF=-14\n")

        var loaded: ProjectConfig?
        let standardError = try captureStandardError {
            loaded = try loadConfig(from: workspace)
        }

        XCTAssertEqual(loaded?.audioQCTargetLUFS, -12, "the typo must not change the real key")
        let lines = standardError.split(whereSeparator: \.isNewline).map(String.init)
        let warnings = lines.filter { $0.contains("AUDIO_QC_TARGET_LUF") }
        XCTAssertEqual(warnings.count, 1, "expected one line naming the unknown key, got: \(lines)")
        XCTAssertTrue(warnings.first?.contains("[WARN]") == true, "unknown key must be a warning: \(warnings)")
        XCTAssertTrue(warnings.first?.contains(workspace.configFile.path) == true, "must name the file: \(warnings)")
    }

    // audit #0046: editors that save config.txt with a UTF-8 byte-order mark must not turn the first
    // line into an unknown "\u{FEFF}KEY". Foundation's UTF-8 decoding drops the mark, so the first key
    // applies; this pins that so a change of file reader cannot silently lose the first setting.
    func testConfigFileStartingWithUTF8BOMAppliesItsFirstKey() throws {
        let workspace = try IntegrationWorkspace()
        let byteOrderMark = Data([0xEF, 0xBB, 0xBF])
        try (byteOrderMark + Data("AUDIO_QC_TARGET_LUFS=-14\nMASTERING_TARGET_LUFS=-16\n".utf8))
            .write(to: workspace.configFile)

        var loaded: ProjectConfig?
        let standardError = try captureStandardError {
            loaded = try loadConfig(from: workspace)
        }

        XCTAssertEqual(loaded?.audioQCTargetLUFS, -14, "the key after the BOM must apply")
        XCTAssertEqual(loaded?.masteringTargetLUFS, -16)
        XCTAssertFalse(standardError.contains("[WARN]"), "no line may be reported as unknown: \(standardError)")
    }

    // audit #0071: only three config keys had a rejection test, and several rules were missing
    // outright (WAV_WRITE_BEXT, FLAC_COMPRESSION_LEVEL, PNG levels, byte targets, CRF and VT quality
    // bounds, an upper bound on CRC_CHUNK_BYTES, empty filter and sampling strings). Every key with a
    // rule gets one invalid value here, loaded through ProjectConfig.load, and the error must name the
    // key and the bound it broke so a user can act on it.
    private struct InvalidConfigValue {
        let key: String
        let value: String
        let expected: String
        init(_ key: String, _ value: String, _ expected: String) {
            self.key = key
            self.value = value
            self.expected = expected
        }
    }

    private static let invalidConfigValues: [InvalidConfigValue] = [
        .init("PROFILE", "bogus", "PROFILE must be one of"),
        .init("PREFLIGHT_SECONDS", "0", "PREFLIGHT_SECONDS must be > 0"),
        .init("PREFLIGHT_SECONDS", "-1", "PREFLIGHT_SECONDS must be a non-negative integer"),
        .init("PREFLIGHT_SECONDS", "abc", "PREFLIGHT_SECONDS must be an integer"),
        .init("DURATION_TOLERANCE_SEC", "-1", "DURATION_TOLERANCE_SEC must be >= 0"),
        .init("DURATION_TOLERANCE_SEC", "nan", "DURATION_TOLERANCE_SEC must be a finite number"),
        .init("CRC_CHUNK_BYTES", "0", "CRC_CHUNK_BYTES must be between 1 and 67108864"),
        .init("CRC_CHUNK_BYTES", "67108865", "CRC_CHUNK_BYTES must be between 1 and 67108864"),
        .init("WAV_SAMPLE_RATE", "0", "WAV_SAMPLE_RATE must be > 0"),
        .init("WAV_SAMPLE_RATE", "48000", "WAV_SAMPLE_RATE must be 96000"),
        .init("WAV_CODEC", "pcm_s16le", "WAV_CODEC must be pcm_s24le"),
        .init("WAV_CHANNELS", "3", "WAV_CHANNELS must be 1 or 2"),
        .init("WAV_CHANNELS", "1", "WAV_CHANNELS must be 2"),
        .init("WAV_WRITE_BEXT", "2", "WAV_WRITE_BEXT must be between 0 and 1"),
        .init("MP3_SAMPLE_RATE", "0", "MP3_SAMPLE_RATE must be > 0"),
        .init("MP3_SAMPLE_RATE", "44100", "MP3_SAMPLE_RATE must be 48000"),
        .init("MP3_BITRATE", "128k", "MP3_BITRATE must be 320k"),
        .init("MP3_CHANNELS", "0", "MP3_CHANNELS must be 1 or 2"),
        .init("MP3_CHANNELS", "1", "MP3_CHANNELS must be 2"),
        .init("MP3_MIN_BITRATE_BPS", "0", "MP3_MIN_BITRATE_BPS must be > 0"),
        .init("FLAC_SAMPLE_RATE", "0", "FLAC_SAMPLE_RATE must be > 0"),
        .init("FLAC_CHANNELS", "3", "FLAC_CHANNELS must be 1 or 2"),
        .init("FLAC_COMPRESSION_LEVEL", "13", "FLAC_COMPRESSION_LEVEL must be between 0 and 12"),
        .init("M4A_SAMPLE_RATE", "0", "M4A_SAMPLE_RATE must be > 0"),
        .init("M4A_SAMPLE_RATE", "44100", "M4A_SAMPLE_RATE must be 48000"),
        .init("M4A_CHANNELS", "3", "M4A_CHANNELS must be 1 or 2"),
        .init("M4A_CHANNELS", "1", "M4A_CHANNELS must be 2"),
        .init("AUDIO_QC_TARGET_LUFS", "-4", "AUDIO_QC_TARGET_LUFS must be between -70 and -5"),
        .init("AUDIO_QC_LUFS_TOLERANCE", "-1", "AUDIO_QC_LUFS_TOLERANCE must be >= 0"),
        .init("AUDIO_QC_MAX_TRUE_PEAK_DBTP", "1", "AUDIO_QC_MAX_TRUE_PEAK_DBTP must be <= 0"),
        .init("AUDIO_QC_MAX_LOUDNESS_RANGE", "-1", "AUDIO_QC_MAX_LOUDNESS_RANGE must be >= 0"),
        .init("AUDIO_QC_MAX_DC_OFFSET", "-1", "AUDIO_QC_MAX_DC_OFFSET must be >= 0"),
        .init("AUDIO_QC_MAX_STEREO_IMBALANCE_DB", "-1", "AUDIO_QC_MAX_STEREO_IMBALANCE_DB must be >= 0"),
        .init("AUDIO_QC_MAX_CLIPPED_SAMPLES", "-1", "AUDIO_QC_MAX_CLIPPED_SAMPLES must be a non-negative integer"),
        .init("AUDIO_QC_MINIMUM_ANALYSIS_SECONDS", "0", "AUDIO_QC_MINIMUM_ANALYSIS_SECONDS must be > 0"),
        .init("SHORT_AUDIO_QC_TARGET_LUFS", "-80", "SHORT_AUDIO_QC_TARGET_LUFS must be between -70 and -5"),
        .init("SHORT_AUDIO_QC_LUFS_TOLERANCE", "-1", "SHORT_AUDIO_QC_LUFS_TOLERANCE must be >= 0"),
        .init("SHORT_AUDIO_QC_MAX_LOUDNESS_RANGE", "-1", "SHORT_AUDIO_QC_MAX_LOUDNESS_RANGE must be >= 0"),
        .init("MASTERING_TARGET_LUFS", "0", "MASTERING_TARGET_LUFS must be between -70 and -5"),
        .init("MASTERING_MAX_TRUE_PEAK_DBTP", "0.5", "MASTERING_MAX_TRUE_PEAK_DBTP must be <= 0"),
        .init("MASTERING_MAX_LOUDNESS_RANGE", "-1", "MASTERING_MAX_LOUDNESS_RANGE must be >= 0"),
        .init("VIDEO_MP4_ENCODER", "", "VIDEO_MP4_ENCODER must not be empty"),
        .init("VIDEO_MP4_VT_QUALITY", "0", "VIDEO_MP4_VT_QUALITY must be between 1 and 100"),
        .init("VIDEO_MP4_VT_QUALITY", "101", "VIDEO_MP4_VT_QUALITY must be between 1 and 100"),
        .init("VIDEO_MP4_VT_QUALITY", "abc", "VIDEO_MP4_VT_QUALITY must be numeric"),
        .init("VIDEO_MP4_SOFTWARE_PRESET", "", "VIDEO_MP4_SOFTWARE_PRESET must not be empty"),
        .init("VIDEO_MP4_SOFTWARE_CRF", "52", "VIDEO_MP4_SOFTWARE_CRF must be between 0 and 51"),
        .init("VIDEO_MP4_SOFTWARE_CRF", "-1", "VIDEO_MP4_SOFTWARE_CRF must be between 0 and 51"),
        .init("VIDEO_MP4_INPUT_FPS", "0", "VIDEO_MP4_INPUT_FPS must be a positive number or ratio"),
        .init("VIDEO_MP4_INPUT_FPS", "1/0", "VIDEO_MP4_INPUT_FPS must be a positive number or ratio"),
        .init("VIDEO_MP4_AUDIO_SAMPLE_RATE", "0", "VIDEO_MP4_AUDIO_SAMPLE_RATE must be > 0"),
        .init("VIDEO_MP4_AUDIO_SAMPLE_RATE", "44100", "VIDEO_MP4_AUDIO_SAMPLE_RATE must be 48000"),
        .init("VIDEO_MP4_WIDTH", "0", "VIDEO_MP4_WIDTH must be > 0"),
        .init("VIDEO_MP4_HEIGHT", "0", "VIDEO_MP4_HEIGHT must be > 0"),
        .init("VIDEO_MP4_SCALE_FILTER", "", "VIDEO_MP4_SCALE_FILTER must not be empty"),
        .init("VIDEO_MP4_PIXEL_FORMAT", "", "VIDEO_MP4_PIXEL_FORMAT must not be empty"),
        .init("VIDEO_MP4_TAG", "", "VIDEO_MP4_TAG must not be empty"),
        .init("VIDEO_MP4_VERIFY_CODEC", "", "VIDEO_MP4_VERIFY_CODEC must not be empty"),
        .init("VIDEO_COLOR_PRIMARIES", "", "VIDEO_COLOR_PRIMARIES must not be empty"),
        .init("VIDEO_COLOR_TRANSFER", "", "VIDEO_COLOR_TRANSFER must not be empty"),
        .init("VIDEO_COLOR_SPACE", "", "VIDEO_COLOR_SPACE must not be empty"),
        .init("VIDEO_COLOR_RANGE", "", "VIDEO_COLOR_RANGE must not be empty"),
        .init("SHORT_MP4_CLIP_SECONDS", "0", "SHORT_MP4_CLIP_SECONDS must be > 0"),
        .init("SHORT_MP4_FPS", "0", "SHORT_MP4_FPS must be a positive number or ratio"),
        .init("SHORT_MP4_SCALE_W", "0", "SHORT_MP4_SCALE_W must be > 0"),
        .init("SHORT_MP4_SCALE_H", "0", "SHORT_MP4_SCALE_H must be > 0"),
        .init("SHORT_MP4_VIDEO_PRESET", "", "SHORT_MP4_VIDEO_PRESET must not be empty"),
        .init("SHORT_MP4_VIDEO_CRF", "52", "SHORT_MP4_VIDEO_CRF must be between 0 and 51"),
        .init("SHORT_MP4_VT_QUALITY", "0", "SHORT_MP4_VT_QUALITY must be between 1 and 100"),
        .init("SHORT_MP4_AUDIO_SAMPLE_RATE", "44100", "SHORT_MP4_AUDIO_SAMPLE_RATE must be 48000"),
        .init("SHORT_MP4_VIDEO_CODEC", "", "SHORT_MP4_VIDEO_CODEC must not be empty"),
        .init("SHORT_MP4_PIXEL_FORMAT", "", "SHORT_MP4_PIXEL_FORMAT must not be empty"),
        .init("SHORT_MP4_VERIFY_CODEC", "", "SHORT_MP4_VERIFY_CODEC must not be empty"),
        .init("IMAGE_8K_WIDTH", "0", "IMAGE_8K_WIDTH must be > 0"),
        .init("IMAGE_8K_HEIGHT", "0", "IMAGE_8K_HEIGHT must be > 0"),
        .init("IMAGE_4K_WIDTH", "0", "IMAGE_4K_WIDTH must be > 0"),
        .init("IMAGE_4K_HEIGHT", "0", "IMAGE_4K_HEIGHT must be > 0"),
        .init("IMAGE_3K_SIZE", "0", "IMAGE_3K_SIZE must be > 0"),
        .init("IMAGE_2K_SIZE", "0", "IMAGE_2K_SIZE must be > 0"),
        .init("IMAGE_AIPIX_SHARPNESS", "-0.1", "IMAGE_AIPIX_SHARPNESS must be >= 0"),
        .init("IMAGE_AIPIX_FILTER", "", "IMAGE_AIPIX_FILTER must not be empty"),
        .init("IMAGE_AIPIX_PNG_COMPRESSION_LEVEL", "10", "IMAGE_AIPIX_PNG_COMPRESSION_LEVEL must be between 0 and 9"),
        .init("IMAGE_JPG_TO_PNG_COMPRESSION_LEVEL", "10", "IMAGE_JPG_TO_PNG_COMPRESSION_LEVEL must be between 0 and 9"),
        .init("IMAGE_PNG_TO_JPEG_QUALITY", "0", "IMAGE_PNG_TO_JPEG_QUALITY must be between 1 and 100"),
        .init("IMAGE_PNG_TO_JPEG_QUALITY", "101", "IMAGE_PNG_TO_JPEG_QUALITY must be between 1 and 100"),
        .init("IMAGE_JPEG_SAMPLING_FACTOR", "", "IMAGE_JPEG_SAMPLING_FACTOR must not be empty"),
        .init("IMAGE_OUTPUT_COLORSPACE", "", "IMAGE_OUTPUT_COLORSPACE must not be empty"),
        .init("IMAGE_3K_JPG_1MB_TARGET_BYTES", "0", "IMAGE_3K_JPG_1MB_TARGET_BYTES must be > 0"),
        .init("IMAGE_3K_JPG_5MB_TARGET_BYTES", "0", "IMAGE_3K_JPG_5MB_TARGET_BYTES must be > 0"),
        .init("IMAGE_8K_JPG_1MB_TARGET_BYTES", "0", "IMAGE_8K_JPG_1MB_TARGET_BYTES must be > 0"),
        .init("IMAGE_8K_JPG_2MB_TARGET_BYTES", "0", "IMAGE_8K_JPG_2MB_TARGET_BYTES must be > 0"),
        .init("IMAGE_8K_JPG_20MB_TARGET_BYTES", "0", "IMAGE_8K_JPG_20MB_TARGET_BYTES must be > 0"),
        .init("ALBUM_SILENCE_SECS", "0", "ALBUM_SILENCE_SECS must be > 0"),
        .init("WAV_FADE_DUR", "0", "WAV_FADE_DUR must be > 0")
    ]

    func testEveryConfigRuleRejectsAnInvalidValueNamingTheKey() throws {
        let workspace = try IntegrationWorkspace()
        let table = Self.invalidConfigValues

        // The two fallback lists are free-form (any comma-separated encoder names, including none),
        // so they are the only supported keys without a rule. Everything else must appear in the table.
        let freeFormKeys: Set<String> = ["VIDEO_MP4_ENCODER_FALLBACKS", "SHORT_MP4_VIDEO_FALLBACKS"]
        XCTAssertEqual(Set(table.map(\.key)), ProjectConfig.supportedKeys.subtracting(freeFormKeys))

        for row in table {
            try workspace.overwriteConfig(IntegrationWorkspace.defaultConfig + "\n\(row.key)=\(row.value)\n")
            XCTAssertThrowsError(try loadConfig(from: workspace), "\(row.key)=\(row.value) must be rejected") { error in
                let message = error.localizedDescription
                XCTAssertTrue(message.contains(row.expected), "\(row.key)=\(row.value): got '\(message)'")
            }
        }
    }

    // audit #0071: the bounds are inclusive; each edge that a user may legitimately choose must load.
    func testConfigRangeRulesAcceptTheirBoundaryValues() throws {
        let workspace = try IntegrationWorkspace()
        let accepted: [(key: String, value: String)] = [
            ("WAV_WRITE_BEXT", "0"), ("WAV_WRITE_BEXT", "1"),
            ("FLAC_COMPRESSION_LEVEL", "0"), ("FLAC_COMPRESSION_LEVEL", "12"),
            ("IMAGE_AIPIX_PNG_COMPRESSION_LEVEL", "9"), ("IMAGE_JPG_TO_PNG_COMPRESSION_LEVEL", "9"),
            ("IMAGE_PNG_TO_JPEG_QUALITY", "1"), ("IMAGE_PNG_TO_JPEG_QUALITY", "100"),
            ("VIDEO_MP4_SOFTWARE_CRF", "0"), ("VIDEO_MP4_SOFTWARE_CRF", "51"), ("SHORT_MP4_VIDEO_CRF", "23.5"),
            ("VIDEO_MP4_VT_QUALITY", "1"), ("VIDEO_MP4_VT_QUALITY", "100"), ("SHORT_MP4_VT_QUALITY", "100"),
            ("CRC_CHUNK_BYTES", "1"), ("CRC_CHUNK_BYTES", "67108864"),
            ("IMAGE_3K_JPG_1MB_TARGET_BYTES", "1"), ("DURATION_TOLERANCE_SEC", "0"), ("IMAGE_AIPIX_SHARPNESS", "0")
        ]
        for row in accepted {
            try workspace.overwriteConfig(IntegrationWorkspace.defaultConfig + "\n\(row.key)=\(row.value)\n")
            XCTAssertNoThrow(try loadConfig(from: workspace), "\(row.key)=\(row.value) must load")
        }
    }

    // audit #0071: the repository's config.txt is the reference every user starts from, so every key
    // in it must be one the loader knows (a stale or misspelled key there would be reported as unknown
    // on every run) and the file as shipped must pass validation.
    func testRepositoryConfigKeysAreSupportedAndTheFileLoadsWithoutWarnings() throws {
        let configURL = IntegrationWorkspace.projectRoot.appendingPathComponent("config.txt")
        let keys = try Self.configKeys(in: configURL)
        XCTAssertFalse(keys.isEmpty)
        XCTAssertEqual(keys.subtracting(ProjectConfig.supportedKeys), [], "config.txt keys the loader does not know")

        let options = try CLIOptions.parse(
            arguments: ["-help"],
            environment: [:],
            scriptDirectory: IntegrationWorkspace.projectRoot,
            scriptName: "converter"
        )
        var loaded: ProjectConfig?
        let standardError = try captureStandardError {
            loaded = try ProjectConfig.load(
                from: configURL,
                environment: [:],
                cli: options,
                logger: Logger(scriptName: "converterTests", debugEnabled: false)
            )
        }
        XCTAssertEqual(loaded?.profileName, "youtube_master")
        XCTAssertFalse(standardError.contains("[WARN]"), standardError)
    }

    // audit #0082: PREFLIGHT_SECONDS, DURATION_TOLERANCE_SEC and CRC_CHUNK_BYTES were supported but
    // absent from the shipped config.txt, so nothing told a user they exist. Every supported key must be
    // present there with the built-in default, which together with the subset check above makes the
    // two key sets equal.
    func testEverySupportedConfigKeyIsDocumentedInRepositoryConfigWithItsDefault() throws {
        let configURL = IntegrationWorkspace.projectRoot.appendingPathComponent("config.txt")
        let keys = try Self.configKeys(in: configURL)
        XCTAssertEqual(ProjectConfig.supportedKeys.subtracting(keys), [], "supported keys missing from config.txt")
        XCTAssertEqual(keys, ProjectConfig.supportedKeys)

        let options = try CLIOptions.parse(
            arguments: ["-help"],
            environment: [:],
            scriptDirectory: IntegrationWorkspace.projectRoot,
            scriptName: "converter"
        )
        let shipped = try ProjectConfig.load(
            from: configURL,
            environment: [:],
            cli: options,
            logger: Logger(scriptName: "converterTests", debugEnabled: false)
        )
        let builtIn = ProjectConfig()
        XCTAssertEqual(shipped.preflightSeconds, builtIn.preflightSeconds)
        XCTAssertEqual(shipped.durationToleranceSec, builtIn.durationToleranceSec)
        XCTAssertEqual(shipped.crcChunkBytes, builtIn.crcChunkBytes)
    }

    static func configKeys(in url: URL) throws -> Set<String> {
        let text = try String(contentsOf: url, encoding: .utf8)
        let keys = text.split(whereSeparator: \.isNewline).compactMap { rawLine -> String? in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { return nil }
            return String(line[..<separator]).trimmingCharacters(in: .whitespaces)
        }
        return Set(keys)
    }

    func testMatrixInitializationDoesNotRequireProjectOutputDirectory() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let environment = IntegrationWorkspace.sanitizedEnvironment(ProcessInfo.processInfo.environment)
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

        let unifiedOptions = try CLIOptions.parse(
            arguments: ["--hash"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertEqual(unifiedOptions.action, .hash)
        XCTAssertEqual(unifiedOptions.srcDir.standardizedFileURL.path, root.appendingPathComponent("Output", isDirectory: true).standardizedFileURL.path)
        XCTAssertEqual(unifiedOptions.outDir.standardizedFileURL.path, root.appendingPathComponent("Output", isDirectory: true).standardizedFileURL.path)

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

        let wavOptions = try CLIOptions.parse(
            arguments: ["-wavtohash"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertEqual(wavOptions.srcDir.standardizedFileURL.path, root.appendingPathComponent("Output", isDirectory: true).standardizedFileURL.path)
        XCTAssertEqual(wavOptions.outDir.standardizedFileURL.path, root.appendingPathComponent("Output", isDirectory: true).standardizedFileURL.path)
    }

    func testBuiltInFastPreviewProfileOverridesRenderDefaults() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let logger = Logger(scriptName: "converterTests", debugEnabled: false)
        let options = try CLIOptions.parse(
            arguments: ["-help", "--profile", "fast_preview"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        let config = try ProjectConfig.load(
            from: root.appendingPathComponent("config.txt"),
            environment: [:],
            cli: options,
            logger: logger
        )

        XCTAssertEqual(config.profileName, "fast_preview")
        XCTAssertEqual(config.videoMP4Encoder, "h264_videotoolbox")
        XCTAssertEqual(config.videoMP4VerifyCodec, "h264")
        XCTAssertEqual(config.videoMP4Width, 1920)
        XCTAssertEqual(config.videoMP4Height, 1080)
    }

    // audit #0044: the "archive" profile only assigned values that already were the defaults (and
    // MP3_BITRATE cannot be anything but 320k), so selecting it changed nothing while the help text
    // advertised it as a real profile. It is removed; asking for it must fail like any unknown name.
    func testArchiveProfileIsNoLongerAcceptedOrAdvertised() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let logger = Logger(scriptName: "converterTests", debugEnabled: false)
        let options = try CLIOptions.parse(
            arguments: ["-help", "--profile", "archive"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertThrowsError(
            try ProjectConfig.load(
                from: root.appendingPathComponent("missing-config.txt"),
                environment: [:],
                cli: options,
                logger: logger
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "PROFILE must be one of: youtube_master, youtube_short, fast_preview (got 'archive')"
            )
        }

        // PROFILE=archive in config.txt goes through the same check.
        let workspace = try IntegrationWorkspace()
        try workspace.overwriteConfig(IntegrationWorkspace.defaultConfig + "\nPROFILE=archive\n")
        XCTAssertThrowsError(try loadConfig(from: workspace)) { error in
            XCTAssertTrue(error.localizedDescription.contains("(got 'archive')"), error.localizedDescription)
        }

        XCTAssertEqual(RunProfile.allCases.map(\.rawValue), ["youtube_master", "youtube_short", "fast_preview"])
        let help = options.helpText()
        XCTAssertTrue(help.contains("Built-in profiles: youtube_master, youtube_short, fast_preview"))
        XCTAssertFalse(help.contains("archive"))
    }

    func testFadeOutParsesFlexibleTimeArguments() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let options = try CLIOptions.parse(
            arguments: ["-fadeout", "1:30", "10"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        let spec = try options.fadeOutSpec()

        XCTAssertEqual(options.action, .fadeout)
        XCTAssertEqual(spec.fadeStartSeconds, 90, accuracy: 0.0001)
        XCTAssertEqual(spec.fadeDurationSeconds, 10, accuracy: 0.0001)
        XCTAssertEqual(spec.endSeconds, 100, accuracy: 0.0001)
    }

    func testTailFadeParsesDefaultAndExplicitDuration() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let defaultOptions = try CLIOptions.parse(
            arguments: ["-fade"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertEqual(defaultOptions.action, .fade)
        XCTAssertEqual(try defaultOptions.tailFadeSeconds(), 10, accuracy: 0.0001)

        let explicitOptions = try CLIOptions.parse(
            arguments: ["-fade", "0:05"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        XCTAssertEqual(explicitOptions.action, .fade)
        XCTAssertEqual(try explicitOptions.tailFadeSeconds(), 5, accuracy: 0.0001)
    }

    func testFadeFLACAliasNoLongerFallsThroughToFullRun() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let options = try CLIOptions.parse(
            arguments: ["-fadeflac", "5"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )

        XCTAssertEqual(options.action, .fade)
        XCTAssertEqual(try options.tailFadeSeconds(), 5, accuracy: 0.0001)
    }

    func testTailFadeRejectsTooManyArguments() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let options = try CLIOptions.parse(
            arguments: ["-fade", "5", "10"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )

        XCTAssertThrowsError(try options.tailFadeSeconds()) { error in
            XCTAssertTrue(error.localizedDescription.contains("at most one positional duration"))
        }
    }

    func testFadeActionsUseDefaultNormalCurve() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tool = try makeTool(tempDirectory: tempDirectory, arguments: ["-fade", "5"])
        let fadeFilter = tool.fadeOutFilter(fadeStartSeconds: 10, fadeDurationSeconds: 5)

        XCTAssertFalse(fadeFilter.contains("curve="))
    }

    func testFadeCutParsesCutAndFadeDurations() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let options = try CLIOptions.parse(
            arguments: ["-fadecut", "0:05", "10"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        let spec = try options.fadeCutSpec()

        XCTAssertEqual(options.action, .fadecut)
        XCTAssertEqual(spec.cutSeconds, 5, accuracy: 0.0001)
        XCTAssertEqual(spec.fadeDurationSeconds, 10, accuracy: 0.0001)
    }

    func testFadeCutRejectsMissingArguments() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let options = try CLIOptions.parse(
            arguments: ["-fadecut", "5"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )

        XCTAssertThrowsError(try options.fadeCutSpec()) { error in
            XCTAssertTrue(error.localizedDescription.contains("requires two positional values"))
        }
    }

    func testFadeOutRejectsMissingArguments() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let options = try CLIOptions.parse(
            arguments: ["-fadeout", "1:30"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )

        XCTAssertThrowsError(try options.fadeOutSpec()) { error in
            XCTAssertTrue(error.localizedDescription.contains("requires exactly two positional values"))
        }
    }

    func testFadeOutRejectsTooManyArguments() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let options = try CLIOptions.parse(
            arguments: ["-fadeout", "1:30", "10", "5"],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )

        XCTAssertThrowsError(try options.fadeOutSpec()) { error in
            XCTAssertTrue(error.localizedDescription.contains("requires exactly two positional values"))
        }
    }

    func testNonFiniteConfigDoubleIsRejectedDuringLoad() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig + "\nAUDIO_QC_MINIMUM_ANALYSIS_SECONDS=nan\n"
        )
        XCTAssertThrowsError(try workspace.makeTool(arguments: ["-help"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("AUDIO_QC_MINIMUM_ANALYSIS_SECONDS"))
            XCTAssertTrue(error.localizedDescription.contains("finite"))
        }
    }

    func testCLIRejectsNonFiniteSharpnessValue() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        XCTAssertThrowsError(
            try CLIOptions.parse(
                arguments: ["-aipix", "--sharpness", "nan"],
                environment: [:],
                scriptDirectory: root,
                scriptName: "converter"
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("--sharpness"))
        }
    }

    func testVerifyCodecMapsEncoderFamilies() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("converter-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tool = try makeTool(tempDirectory: tempDirectory, arguments: ["-short"])
        XCTAssertEqual(tool.verifyCodec(forEncoder: "libx264"), "h264")
        XCTAssertEqual(tool.verifyCodec(forEncoder: "h264_videotoolbox"), "h264")
        XCTAssertEqual(tool.verifyCodec(forEncoder: "libx265"), "hevc")
        XCTAssertEqual(tool.verifyCodec(forEncoder: "hevc_videotoolbox"), "hevc")
        XCTAssertNil(tool.verifyCodec(forEncoder: "unknown_encoder"))
    }

    func testPublishBackupRecoveryRestoresMissingDestination() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("converter-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tool = try makeTool(tempDirectory: tempDirectory, arguments: ["-short"])
        let destination = tool.cli.outDir.appendingPathComponent("song.mp3")
        let backup = tool.cli.outDir.appendingPathComponent(".song.mp3.publish-backup")
        try "old data".write(to: backup, atomically: true, encoding: .utf8)

        tool.recoverPublishBackups()

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testPublishBackupRecoveryRemovesStaleBackupWhenDestinationExists() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("converter-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tool = try makeTool(tempDirectory: tempDirectory, arguments: ["-short"])
        let destination = tool.cli.outDir.appendingPathComponent("song.mp3")
        let backup = tool.cli.outDir.appendingPathComponent(".song.mp3.publish-backup")
        try "new data".write(to: destination, atomically: true, encoding: .utf8)
        try "old data".write(to: backup, atomically: true, encoding: .utf8)

        tool.recoverPublishBackups()

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testPublishTempLeavesNoBackupBehind() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("converter-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tool = try makeTool(tempDirectory: tempDirectory, arguments: ["-short"])
        let destination = tool.cli.outDir.appendingPathComponent("song.wav")
        let firstTemp = try tool.makeTemp(in: tool.cli.outDir, stem: "publish1", ext: ".wav")
        try "first".write(to: firstTemp, atomically: true, encoding: .utf8)
        try tool.publishTemp(firstTemp, to: destination)
        let secondTemp = try tool.makeTemp(in: tool.cli.outDir, stem: "publish2", ext: ".wav")
        try "second".write(to: secondTemp, atomically: true, encoding: .utf8)
        try tool.publishTemp(secondTemp, to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "second")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tool.cli.outDir.path)
            .filter { $0.contains("publish-backup") }
        XCTAssertTrue(leftovers.isEmpty, "publishTemp must not leave backups behind")
    }

    // audit #0032: publishTemp's restore-on-failure branch (the `catch` in PipelineCore.publishTemp) had no
    // test. publishTemp never checks that `temp` exists, so deleting the temp after makeTemp lets the
    // destination -> backup move succeed and makes the temp -> destination move fail with
    // NSFileNoSuchFileError. The catch must move the backup back, leave no `.publish-backup` behind,
    // unregister the temp and rethrow the original move error (not the "could not be restored" AppError).
    func testPublishTempRestoresPreviousVersionWhenTempMoveFails() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("converter-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tool = try makeTool(tempDirectory: tempDirectory, arguments: ["-short"])
        let destination = tool.cli.outDir.appendingPathComponent("song.wav")
        let backup = tool.cli.outDir.appendingPathComponent(".song.wav.publish-backup")
        let firstTemp = try tool.makeTemp(in: tool.cli.outDir, stem: "publish1", ext: ".wav")
        try "first".write(to: firstTemp, atomically: true, encoding: .utf8)
        try tool.publishTemp(firstTemp, to: destination)

        // The second temp lives in a subdirectory that is neither srcDir nor outDir, so the run-scoped
        // sweep in cleanupTemps() cannot touch it: only the RuntimeState registry could, which is what
        // proves the unregistration below.
        let scratch = tempDirectory.appendingPathComponent("scratch", isDirectory: true)
        let secondTemp = try tool.makeTemp(in: scratch, stem: "publish2", ext: ".wav")
        try "second".write(to: secondTemp, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: secondTemp)

        XCTAssertThrowsError(try tool.publishTemp(secondTemp, to: destination)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSCocoaErrorDomain, "expected Foundation's own move error: \(error)")
            XCTAssertEqual(nsError.code, NSFileNoSuchFileError, "expected the missing-temp move error: \(error)")
            XCTAssertFalse(error is AppError, "the original move error must be rethrown, got: \(error)")
            XCTAssertFalse(error.localizedDescription.contains("could not be restored"), "\(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path), "previous version must be restored")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "backup must be moved back, not kept")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tool.cli.outDir.path)
            .filter { $0.contains("publish-backup") }
        XCTAssertTrue(leftovers.isEmpty, "restore must not leave a backup behind: \(leftovers)")

        // The failed temp must be unregistered: a file recreated at its path survives cleanupTemps().
        try "sentinel".write(to: secondTemp, atomically: true, encoding: .utf8)
        tool.cleanupTemps()
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondTemp.path), "temp must be unregistered")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "first")
    }

    // audit #0032: the other half of publishTemp's catch. When the destination -> backup move itself fails
    // (here the destination carries UF_IMMUTABLE, Finder's "Locked" checkbox, so rename(2) returns EPERM)
    // the destination still exists: no restore may be attempted, no backup may be left behind, the temp
    // must be unregistered and the original error rethrown. The temp stays on disk until cleanupTemps()
    // sweeps the run-scoped names out of outDir.
    func testPublishTempKeepsDestinationWhenBackupMoveFails() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("converter-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tool = try makeTool(tempDirectory: tempDirectory, arguments: ["-short"])
        let destination = tool.cli.outDir.appendingPathComponent("song.wav")
        let backup = tool.cli.outDir.appendingPathComponent(".song.wav.publish-backup")
        let firstTemp = try tool.makeTemp(in: tool.cli.outDir, stem: "publish1", ext: ".wav")
        try "first".write(to: firstTemp, atomically: true, encoding: .utf8)
        try tool.publishTemp(firstTemp, to: destination)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: destination.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: destination.path) }
        let secondTemp = try tool.makeTemp(in: tool.cli.outDir, stem: "publish2", ext: ".wav")
        try "second".write(to: secondTemp, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try tool.publishTemp(secondTemp, to: destination)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSCocoaErrorDomain, "expected Foundation's own move error: \(error)")
            XCTAssertEqual(nsError.code, NSFileWriteNoPermissionError, "expected the EPERM move error: \(error)")
            XCTAssertFalse(error is AppError, "the original move error must be rethrown, got: \(error)")
            XCTAssertFalse(error.localizedDescription.contains("could not be restored"), "\(error)")
        }

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "no backup may be left behind")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: secondTemp.path),
            "a failed publish must not delete the temp"
        )
        tool.cleanupTemps()
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondTemp.path), "run-scoped sweep removes the temp")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "first")
    }

    func testAlbumFileFlagRejectionNamesAlbumTxtAndDirectoryCommands() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        XCTAssertThrowsError(
            try CLIOptions.parse(
                arguments: ["-wavtoalbum", "--album-file", "order.txt"],
                environment: [:],
                scriptDirectory: root,
                scriptName: "converter"
            )
        ) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("--album-file is no longer supported"))
            XCTAssertTrue(message.contains("-wavtoalbum and -mp3toalbum read album.txt"))
            XCTAssertTrue(message.contains("-album and -flactoalbum scan SRC_DIR directly"))
        }
    }

    func testHelpTextDistinguishesAlbumTxtAndDirectoryAlbumBuilds() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        let options = try CLIOptions.parse(
            arguments: [],
            environment: [:],
            scriptDirectory: root,
            scriptName: "converter"
        )
        let help = options.helpText()
        XCTAssertTrue(help.contains("album.txt order file plus referenced .wav files"))
        XCTAssertTrue(help.contains("album.txt order file plus referenced .mp3 files"))
        XCTAssertTrue(help.contains("without loudness normalization; use -album for a normalized directory build"))
    }

    private func makeParserTool() throws -> ConverterTool {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDirectory) }
        return try makeTool(tempDirectory: tempDirectory)
    }

    // The canonical PCM comparison is the backbone of the lossless guarantee. It must scan
    // the whole file: an earlier implementation stopped at the first differing sample, so a
    // later out-of-tolerance sample was never reached and the check reported a pass.
    func testCanonicalPCMComparisonScansWholeFileAndEnforcesPerSampleTolerance() throws {
        let tool = try makeParserTool()
        let directory = tool.cli.outDir

        func writeS24LE(_ samples: [Int32], as name: String) throws -> URL {
            var data = Data(capacity: samples.count * 3)
            for sample in samples {
                let raw = UInt32(bitPattern: sample)
                data.append(UInt8(raw & 0xFF))
                data.append(UInt8((raw >> 8) & 0xFF))
                data.append(UInt8((raw >> 16) & 0xFF))
            }
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }

        let count = 20_000
        let base = (0 ..< count).map { Int32(($0 % 1000) * 100) }
        let reference = try writeS24LE(base, as: "pcm_reference.raw")

        let identical = try writeS24LE(base, as: "pcm_identical.raw")
        let exact = try tool.compareCanonicalPCMFiles(reference, identical, format: .s24le, maxAllowedDelta: 0, maxAllowedFailures: 0)
        XCTAssertEqual(exact.failingSamples, 0)
        XCTAssertEqual(exact.maxDelta, 0)

        // Uniform small drift, plus one sample near the very end that breaks tolerance.
        var drifted = base.map { $0 + 10 }
        drifted[count - 1] = base[count - 1] + 5_000
        let candidate = try writeS24LE(drifted, as: "pcm_drifted.raw")

        let generousTolerance = try tool.compareCanonicalPCMFiles(reference, candidate, format: .s24le, maxAllowedDelta: 20_000, maxAllowedFailures: 0)
        XCTAssertEqual(generousTolerance.failingSamples, 0, "drift inside the tolerance must not be counted as a failure")

        let strictTolerance = try tool.compareCanonicalPCMFiles(reference, candidate, format: .s24le, maxAllowedDelta: 256, maxAllowedFailures: 0)
        XCTAssertGreaterThan(strictTolerance.failingSamples, 0, "an out-of-tolerance sample at the end of the file must be reached")
        XCTAssertEqual(strictTolerance.maxDelta, 5_000)
    }

    // CRC-32 values become filenames, so they are pinned against the reference
    // implementation (zlib.crc32 / IEEE 802.3) rather than against themselves.
    func testCRC32MatchesReferenceImplementationAcrossChunkBoundaries() throws {
        let tool = try makeParserTool()
        let directory = tool.cli.outDir

        let cases: [(name: String, contents: Data, expected: String)] = [
            ("probe.bin", Data("converter-crc-probe".utf8), "8A32DD54"),
            ("empty.bin", Data(), "00000000"),
            ("repeated.bin", Data(repeating: UInt8(ascii: "a"), count: 100_000), "1BE2FA87")
        ]

        for testCase in cases {
            let file = directory.appendingPathComponent(testCase.name)
            try testCase.contents.write(to: file)
            XCTAssertEqual(try tool.crc32(for: file), testCase.expected, "CRC-32 mismatch for \(testCase.name)")
        }

        // The slice-by-8 loop consumes eight bytes at a time and drops the remainder to a
        // tail loop, so every length modulo 8 needs a reference value.
        let lengthVectors: [(length: Int, expected: String)] = [
            (1, "45D03605"), (7, "EF6F3B31"), (8, "648BAD8B"), (9, "17DC5F9E"),
            (15, "53605EE3"), (16, "24E8A988"), (19, "3CA5F099"), (65_537, "B864FD3A")
        ]
        for vector in lengthVectors {
            let contents = Data((0 ..< vector.length).map { UInt8(($0 &* 37 &+ 11) & 0xFF) })
            let file = directory.appendingPathComponent("len_\(vector.length).bin")
            try contents.write(to: file)
            XCTAssertEqual(try tool.crc32(for: file), vector.expected, "CRC-32 mismatch at length \(vector.length)")
        }
    }

    // Reading is chunked, and a chunk size that is not a multiple of eight puts the split
    // in the middle of a slice-by-8 group. The stream result must be independent of it.
    func testCRC32IsIndependentOfReadChunkBoundaries() throws {
        let tool = try makeParserTool()
        var awkwardConfig = ProjectConfig()
        awkwardConfig.crcChunkBytes = 7
        let chunked = ConverterTool(
            cli: tool.cli,
            config: awkwardConfig,
            logger: Logger(scriptName: "converterTests", debugEnabled: false),
            runner: tool.runner,
            environment: tool.environment
        )

        let contents = Data((0 ..< 65_537).map { UInt8(($0 &* 37 &+ 11) & 0xFF) })
        let file = tool.cli.outDir.appendingPathComponent("chunked.bin")
        try contents.write(to: file)

        XCTAssertEqual(try chunked.crc32(for: file), "B864FD3A")
        XCTAssertEqual(try chunked.crc32(for: file), try tool.crc32(for: file))
    }

    // astats and volumedetect now share one ffmpeg pass, so they also share one stderr.
    // The astats parser must consume only its own lines.
    func testAstatsParserIgnoresOtherFiltersSharingTheSameStderr() throws {
        let tool = try makeParserTool()
        let stderr = """
        [Parsed_astats_0 @ 0x1] Channel: 1
        [Parsed_astats_0 @ 0x1] DC offset: -0.000001
        [Parsed_astats_0 @ 0x1] Peak level dB: -21.074211
        [Parsed_astats_0 @ 0x1] RMS level dB: -24.084343
        [Parsed_astats_0 @ 0x1] Channel: 2
        [Parsed_astats_0 @ 0x1] DC offset: 0.000002
        [Parsed_astats_0 @ 0x1] Peak level dB: -21.074211
        [Parsed_astats_0 @ 0x1] RMS level dB: -24.100000
        [Parsed_astats_0 @ 0x1] Overall
        [Parsed_astats_0 @ 0x1] DC offset: 0.000002
        [Parsed_astats_0 @ 0x1] Peak level dB: -21.074211
        [Parsed_astats_0 @ 0x1] Peak count: 1120
        [Parsed_volumedetect_1 @ 0x2] n_samples: 192000
        [Parsed_volumedetect_1 @ 0x2] mean_volume: -24.1 dB
        [Parsed_volumedetect_1 @ 0x2] max_volume: -21.1 dB
        [Parsed_volumedetect_1 @ 0x2] histogram_21db: 55360
        """

        let report = tool.parseAstatsReport(from: stderr)
        XCTAssertEqual(report.channelMetrics.count, 2)
        XCTAssertEqual(report.channelMetrics[0]["RMS level dB"], "-24.084343")
        XCTAssertEqual(report.channelMetrics[1]["RMS level dB"], "-24.100000")
        XCTAssertEqual(report.overallMetrics["Peak level dB"], "-21.074211")
        XCTAssertEqual(report.overallMetrics["Peak count"], "1120")
        XCTAssertNil(report.overallMetrics["max_volume"], "volumedetect output must not leak into astats metrics")
        XCTAssertNil(report.overallMetrics["n_samples"], "volumedetect output must not leak into astats metrics")
    }

    func testLoudnormJSONParsingToleratesSurroundingFilterOutput() throws {
        let tool = try makeParserTool()
        let stderr = """
        [Parsed_astats_0 @ 0x1] Peak level dB: -21.074211
        [Parsed_loudnorm_0 @ 0x2]\u{0020}
        {
        \t"input_i" : "-23.05",
        \t"input_tp" : "-3.02",
        \t"input_lra" : "7.20",
        \t"input_thresh" : "-33.10",
        \t"output_i" : "-12.00",
        \t"target_offset" : "0.11"
        }
        """

        let measurement = try tool.parseLoudnormJSON(from: stderr)
        XCTAssertEqual(measurement.inputI, "-23.05")
        XCTAssertEqual(measurement.inputTp, "-3.02")
        XCTAssertEqual(measurement.inputLra, "7.20")
        XCTAssertEqual(measurement.inputThresh, "-33.10")
        XCTAssertEqual(measurement.targetOffset, "0.11")
    }

    // Regression: cancelling one waiter used to resume waiters[0] positionally, which
    // failed an unrelated task and left the cancelled one queued forever. Reachable
    // whenever `async let` siblings are torn down after one of them throws.
    // audit #0065: the queue order used to rest on 80 ms sleeps, which a busy machine can
    // reorder, and a regression that lost a permit hung the whole suite instead of failing
    // this test. The queue is now observed through waiterCount and every await is bounded.
    func testAsyncSemaphoreCancellationResumesOnlyTheCancelledWaiter() async throws {
        let semaphore = AsyncSemaphore(value: 1)
        try await semaphore.wait()

        let first = Task { try await semaphore.wait() }
        try await waitUntil { await semaphore.waiterCount == 1 }
        let second = Task { try await semaphore.wait() }
        try await waitUntil { await semaphore.waiterCount == 2 }

        second.cancel()
        try await waitUntil { await semaphore.waiterCount == 1 }

        // Releasing the held permit must hand it to the first, uncancelled waiter.
        await semaphore.signal()
        try await expectCompletion { try await first.value }

        let secondOutcome = try await expectCompletion { await second.result }
        XCTAssertThrowsError(try secondOutcome.get()) { error in
            XCTAssertTrue(error is CancellationError, "the cancelled waiter must be the one that fails, got \(error)")
        }

        await semaphore.signal()
    }

    // audit #0065: bounded like the test above; a waiter that never resumes is a failure here,
    // not a hung suite.
    func testAsyncSemaphoreCancellationBeforeSuspensionStillThrows() async throws {
        let semaphore = AsyncSemaphore(value: 1)
        try await semaphore.wait()

        let queued = Task { try await semaphore.wait() }
        queued.cancel()

        let outcome = try await expectCompletion { await queued.result }
        XCTAssertThrowsError(try outcome.get()) { error in
            XCTAssertTrue(
                error is CancellationError, "cancellation racing ahead of suspension must be honored, got \(error)")
        }

        await semaphore.signal()
    }

    // audit #0065: the throwing loop and the final wait() pair together assert that a throwing
    // body returned its permit; unbounded, a leaked permit made this test hang the suite (the
    // third throwing call already blocks) instead of failing.
    func testAsyncSemaphoreWithPermitCapsConcurrencyAndReleasesOnThrow() async throws {
        let semaphore = AsyncSemaphore(value: 2)
        let tracker = PermitPeakTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    try? await semaphore.withPermit {
                        await tracker.enter()
                        try await Task.sleep(nanoseconds: 20_000_000)
                        await tracker.leave()
                    }
                }
            }
        }
        let peak = await tracker.peak
        XCTAssertLessThanOrEqual(peak, 2, "withPermit must never exceed the configured limit")
        XCTAssertGreaterThan(peak, 0)

        // A throwing body must still return its permit: four throws through two permits, and
        // both permits must be free again afterwards.
        struct Boom: Error {}
        try await expectCompletion {
            for _ in 0 ..< 4 {
                do {
                    try await semaphore.withPermit { throw Boom() }
                } catch is Boom {
                    continue
                }
            }
            try await semaphore.wait()
            try await semaphore.wait()
        }
        await semaphore.signal()
        await semaphore.signal()
    }

    // audit #0039: withPermit never looked at cancellation, so a task cancelled because an
    // `async let` sibling had thrown still took a permit and ran its closure (a full ffmpeg or
    // magick job whose result nobody awaits). It must throw CancellationError, leave the closure
    // unrun and hand the permit back; the follow-up withPermit would hang on a leaked permit.
    func testAsyncSemaphoreWithPermitRefusesCancelledTask() async throws {
        let semaphore = AsyncSemaphore(value: 1)
        let closureRan = ResultBox<Bool>()

        let cancelled = Task {
            // Spin until the cancel below has landed, so the semaphore is asked by a cancelled task.
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await semaphore.withPermit { closureRan.store(true) }
        }
        cancelled.cancel()

        let outcome = await cancelled.result
        XCTAssertThrowsError(try outcome.get()) { error in
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        XCTAssertNil(closureRan.load(), "the closure must not run for a cancelled task")

        // The single permit must still be available: a leaked one would time out here.
        try await expectCompletion { try await semaphore.withPermit { } }
    }

    // audit #0039: the wait() fast path (a free permit) never checked cancellation either, so a
    // cancelled task walked off with the permit. The follow-up wait() proves it was never taken.
    func testAsyncSemaphoreWaitFastPathRefusesCancelledTask() async throws {
        let semaphore = AsyncSemaphore(value: 1)

        let cancelled = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            try await semaphore.wait()
        }
        cancelled.cancel()

        let outcome = await cancelled.result
        XCTAssertThrowsError(try outcome.get()) { error in
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }

        try await expectCompletion { try await semaphore.wait() }
        await semaphore.signal()
    }

    // audit #0076: when signal() resumed a waiter and the waiter's task was cancelled at the
    // same moment, cancelWaiter() found no queued waiter and left a "cancelled before
    // suspension" marker that nothing ever consumed, one per race for the life of the
    // semaphore. Racing the two 500 times must leave the marker set empty and the permit intact.
    func testAsyncSemaphoreSignalRacingCancellationLeavesNoMarkerBehind() async throws {
        let semaphore = AsyncSemaphore(value: 1)

        for _ in 0 ..< 500 {
            try await semaphore.wait()
            let waiter = Task { try await semaphore.withPermit { } }
            try await waitUntil { await semaphore.waiterCount == 1 }

            // Hand over the permit and cancel the receiver in the same breath; whichever wins,
            // withPermit returns the permit.
            await semaphore.signal()
            waiter.cancel()
            _ = await waiter.result
        }

        let pending = await semaphore.pendingCancellationCount
        XCTAssertEqual(pending, 0, "a cancel that lost the race against signal() must leave no marker")
        let queued = await semaphore.waiterCount
        XCTAssertEqual(queued, 0)
        try await expectCompletion { try await semaphore.wait() }
        await semaphore.signal()
    }

    // audit #0021: one ladder for every render — reports each failed rung, stops at the first
    // failure that a different encoder cannot fix.
    func testEncoderLadderReportsEveryRungAndStopsOnEncoderIndependentFailure() throws {
        let tool = try makeParserTool()
        var attempted: [String] = []
        XCTAssertThrowsError(try tool.withEncoderLadder(["a", "b", "c"], label: "test") { encoder in
            attempted.append(encoder)
            throw AppError("\(encoder) exploded")
        }) { error in
            let message = "\(error)"
            for rung in ["a: a exploded", "b: b exploded", "c: c exploded"] {
                XCTAssertTrue(message.contains(rung), message)
            }
        }
        XCTAssertEqual(attempted, ["a", "b", "c"])

        attempted = []
        XCTAssertThrowsError(try tool.withEncoderLadder(["a", "b"], label: "test") { encoder in
            attempted.append(encoder)
            try tool.encoderIndependent { throw AppError("audio wrong") }
        }) { error in
            XCTAssertTrue("\(error)".contains("a: audio wrong"), "\(error)")
            XCTAssertFalse("\(error)".contains("b:"), "\(error)")
        }
        XCTAssertEqual(attempted, ["a"], "an encoder-independent failure must stop the ladder")

        let result = try tool.withEncoderLadder(["a", "b"], label: "test") { encoder -> String in
            guard encoder == "b" else { throw AppError("no") }
            return "ok"
        }
        XCTAssertEqual(result, "ok", "a later rung's success is returned")
    }

    // audit #0022: the whole discovered family moves with the source, so a rerun resolves the
    // same origin: same-stem conversions become 1_source.<ext> siblings and archival companions
    // become 1_source_RF64/_BW64 companions of it. A source that fails preflight keeps its name.
    func testFullRunRenamesTheWholeSourceFamilyAndKeepsRerunsStable() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let tool = try makeTool(tempDirectory: temp)
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: temp.path + "/" + name) }

        for name in ["song.flac", "song.wav", "song_RF64.flac", "song_BW64.wav"] {
            try Data().write(to: temp.appendingPathComponent(name))
        }
        XCTAssertEqual(try tool.resolveFullAudio().basename, "1_source.flac")
        XCTAssertTrue(exists("1_source.wav"), "same-stem sibling must move with the source")
        XCTAssertTrue(exists("1_source_RF64.flac") && exists("1_source_BW64.wav"), "companions move with the source")
        XCTAssertFalse(exists("song.wav") || exists("song_RF64.flac"))
        // Second run in the same folder: the renamed family still resolves to the origin.
        XCTAssertEqual(try tool.resolveFullAudio().basename, "1_source.flac")
        XCTAssertTrue(tool.isExternalArchivalAudioVariant(temp.appendingPathComponent("1_source_RF64.flac")))
    }

    // audit #0048 / #0049: -master and -flactoalbum must skip what the pipeline itself produced.
    func testMasterAndFLACAlbumCandidatesSkipDerivedOutputs() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let tool = try makeTool(tempDirectory: temp)
        let names = [
            "song.flac", "song_mastered.flac", "song_loudness_m12LUFS.flac", "song_RF64.flac", "02.flac", "02_bass.flac"
        ]
        for name in names {
            try Data().write(to: temp.appendingPathComponent(name))
        }
        XCTAssertEqual(try tool.audioMasterCandidates().map(\.basename).sorted(),
                       ["02.flac", "02_bass.flac", "song.flac", "song_RF64.flac"])
        XCTAssertEqual(try tool.flacAlbumCandidates().map(\.basename), ["02.flac", "song.flac"])
    }

    // audit #0016: with the default shared directory an album run saw every same-stem
    // conversion (01.flac + 01.wav + 01.mp3) as three tracks, and the pipeline's own
    // _mastered / _silence_ / _noise_ outputs as more tracks.
    func testAlbumCandidatesCollapseSameStemFamiliesAndSkipDerivedOutputs() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let tool = try makeTool(tempDirectory: temp)
        let names = [
            "01.flac", "01.wav", "01.mp3", "02.mp3", "02_mastered.mp3", "03_noise_30s.flac", "04_silence_10s.wav", "05.wav"
        ]
        for name in names {
            try Data().write(to: temp.appendingPathComponent(name))
        }
        XCTAssertEqual(try tool.albumAudioCandidates().map(\.basename), ["01.flac", "02.mp3", "05.wav"])
    }

    // audit #0084: isSilenceDerivedMedia / isNoiseDerivedMedia looked at the FIRST "_silence_" /
    // "_noise_" marker, so a file padded twice (song_silence_2s_silence_3s.wav, the output of a
    // -silence rerun over its own output) read as a fresh source and was padded a third time.
    func testDerivedMediaPredicatesRecogniseRepeatedPaddingMarkers() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let tool = try makeTool(tempDirectory: temp)

        let doubleSilence = temp.appendingPathComponent("a_silence_2s_silence_3s.wav")
        let doubleNoise = temp.appendingPathComponent("a_noise_2s_noise_0_5s.flac")
        XCTAssertTrue(tool.isSilenceDerivedMedia(doubleSilence), "second marker must be recognised")
        XCTAssertTrue(tool.isNoiseDerivedMedia(doubleNoise), "second marker must be recognised")
        XCTAssertTrue(tool.isSilenceDerivedMedia(temp.appendingPathComponent("a_silence_2s.wav")))
        XCTAssertTrue(tool.isNoiseDerivedMedia(temp.appendingPathComponent("a_noise_2s.wav")))
        // A marker that is not the tail of the stem is not this pipeline's output.
        XCTAssertFalse(tool.isSilenceDerivedMedia(temp.appendingPathComponent("a_silence_2s_take.wav")))
        XCTAssertFalse(tool.isNoiseDerivedMedia(temp.appendingPathComponent("a_noise_2s_mix.wav")))
        XCTAssertFalse(tool.isSilenceDerivedMedia(temp.appendingPathComponent("a_silence_s.wav")))

        for name in ["song.wav", "song_silence_2s.wav", "song_silence_2s_silence_3s.wav",
                     "song_noise_2s.wav", "song_noise_2s_noise_3s.wav"] {
            try Data().write(to: temp.appendingPathComponent(name))
        }
        XCTAssertEqual(try tool.audioSilenceCandidates().map(\.basename).sorted(),
                       ["song.wav", "song_noise_2s.wav", "song_noise_2s_noise_3s.wav"])
        XCTAssertEqual(try tool.audioNoiseCandidates().map(\.basename).sorted(),
                       ["song.wav", "song_silence_2s.wav", "song_silence_2s_silence_3s.wav"])
    }

    // audit #0011: the Homebrew bootstrap must only ever execute the exact installer it was
    // reviewed against: pinned to a commit, verified by SHA-256 before a single line runs.
    func testHomebrewInstallerIsPinnedAndIntegrityChecked() throws {
        let pinnedPattern = #"/Homebrew/install/[0-9a-f]{40}/install\.sh$"#
        XCTAssertNotNil(DependencyBootstrapper.homebrewInstallerURL.range(of: pinnedPattern, options: .regularExpression),
                        DependencyBootstrapper.homebrewInstallerURL)
        XCTAssertEqual(DependencyBootstrapper.homebrewInstallerSHA256.count, 64)

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let sentinel = temp.appendingPathComponent("executed")
        let script = temp.appendingPathComponent("installer.sh")
        try "#!/bin/bash\ntouch '\(sentinel.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        let good = DependencyBootstrapper.sha256Hex(of: try Data(contentsOf: script))

        // Wrong hash: refused before execution, nothing runs, no temp copy is left behind.
        XCTAssertThrowsError(try DependencyBootstrapper.fetchVerifiedInstaller(
            from: "file://\(script.path)", expectedSHA256: String(repeating: "0", count: 64),
            environment: ProcessInfo.processInfo.environment)
        ) { error in
            XCTAssertTrue("\(error)".contains("integrity"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))

        // Right hash: the verified copy is handed back for execution.
        let verified = try DependencyBootstrapper.fetchVerifiedInstaller(
            from: "file://\(script.path)", expectedSHA256: good, environment: ProcessInfo.processInfo.environment)
        defer { try? FileManager.default.removeItem(at: verified) }
        XCTAssertEqual(try Data(contentsOf: verified), try Data(contentsOf: script))
    }

    // audit #0025: a misspelled option must be an error, not a silently ignored positional.
    func testUnknownOptionsAndStrayPositionalsAreRejected() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        func parse(_ arguments: [String]) throws -> CLIOptions {
            try CLIOptions.parse(arguments: arguments, environment: [:], scriptDirectory: root, scriptName: "converter")
        }
        let unknown = [["-full", "--overwite"], ["-full", "--continue-on-eror"], ["-loudness", "--sharpnes", "2"], ["-short", "-verbose"]]
        for arguments in unknown {
            XCTAssertThrowsError(try parse(arguments), arguments.joined(separator: " ")) { error in
                XCTAssertTrue("\(error)".contains("Unknown option"), "\(error)")
            }
        }
        for arguments in [["-full", "45"], ["-full", "extra"], ["-doctor", "x"], ["-flactomp3", "song.flac"]] {
            XCTAssertThrowsError(try parse(arguments), arguments.joined(separator: " ")) { error in
                XCTAssertTrue("\(error)".contains("positional"), "\(error)")
            }
        }
        // Negative numbers are values, not options.
        XCTAssertEqual(try parse(["-loudness", "-13"]).actionArgs, ["-13"])
        XCTAssertEqual(try parse(["-bass", "80", "-5"]).actionArgs, ["80", "-5"])
        XCTAssertEqual(try parse(["-visualsubs", "9"]).actionArgs, ["9"])
    }

    // audit #0014: an astats report that is missing pieces used to degrade every derived
    // ceiling to "pass"; it must fail closed. audit #0013: "-inf" RMS is a measurement.
    func testAstatsMetricsFailClosedAndTreatSilentChannelAsInfiniteImbalance() throws {
        let tool = try makeParserTool()
        let file = URL(fileURLWithPath: "/tmp/qc.wav")
        let complete = """
        [Parsed_astats_0 @ 0x1] Channel: 1
        [Parsed_astats_0 @ 0x1] DC offset: -0.000100
        [Parsed_astats_0 @ 0x1] RMS level dB: -20.000000
        [Parsed_astats_0 @ 0x1] Channel: 2
        [Parsed_astats_0 @ 0x1] DC offset: 0.000200
        [Parsed_astats_0 @ 0x1] RMS level dB: -inf
        [Parsed_astats_0 @ 0x1] Overall
        [Parsed_astats_0 @ 0x1] DC offset: 0.000200
        [Parsed_astats_0 @ 0x1] Peak level dB: 0.000000
        [Parsed_astats_0 @ 0x1] Peak count: 12
        """
        let metrics = try tool.audioQCAstatsMetrics(from: complete, expectedChannels: 2, file: file)
        XCTAssertEqual(metrics.stereoImbalanceDB, .infinity)
        XCTAssertEqual(metrics.dcOffset, 0.0002, accuracy: 1e-9)
        XCTAssertEqual(metrics.clippedSamples, 12)
        XCTAssertEqual(metrics.peakLevelDBFS, 0)

        XCTAssertThrowsError(try tool.audioQCAstatsMetrics(from: "", expectedChannels: 2, file: file)) { error in
            XCTAssertTrue("\(error)".contains("incomplete astats report"), "\(error)")
        }
        XCTAssertThrowsError(try tool.audioQCAstatsMetrics(from: complete, expectedChannels: 1, file: file))
        let nanCount = complete.replacingOccurrences(of: "Peak count: 12", with: "Peak count: nan")
        XCTAssertThrowsError(try tool.audioQCAstatsMetrics(from: nanCount, expectedChannels: 2, file: file)) { error in
            XCTAssertTrue("\(error)".contains("Peak count"), "\(error)")
        }
        let noRMS = complete.replacingOccurrences(of: "[Parsed_astats_0 @ 0x1] RMS level dB: -20.000000\n", with: "")
        XCTAssertThrowsError(try tool.audioQCAstatsMetrics(from: noRMS, expectedChannels: 2, file: file))
    }

    // audit #0010: an absurd but finite duration reached Int(Double) and trapped the process
    // instead of being rejected as input.
    func testTimecodeRejectsAbsurdDurationsAndFFmpegNumberNeverTraps() throws {
        XCTAssertThrowsError(try parseFlexibleTimecode("1e300", label: "silence"))
        XCTAssertThrowsError(try parseFlexibleTimecode("31622401", label: "silence"))
        XCTAssertEqual(try parseFlexibleTimecode("31622400", label: "silence"), 31_622_400)
        XCTAssertEqual(ffmpegNumber(2.5), "2.5")
        XCTAssertEqual(ffmpegNumber(1e18), "1000000000000000000")
        XCTAssertFalse(ffmpegNumber(1e300).isEmpty, "out-of-Int-range values must format, not trap")
        XCTAssertEqual(SilenceSpec(seconds: 1e300).delayMilliseconds, Int.max, "unrepresentable delays saturate instead of trapping")
    }

    // audit #0012: ffmpeg prints input metadata at -v info before the loudnorm summary, so a
    // tag containing a brace used to corrupt the JSON slice and fail QC on a valid file.
    func testLoudnormJSONParsingIgnoresBracesInInputMetadata() throws {
        let tool = try makeParserTool()
        let stderr = """
        Input #0, mp3, from 'song.mp3':
          Metadata:
            title           : Song {Remix}
            comment         : {mixed} by {someone}
        [Parsed_loudnorm_0 @ 0x2]\u{0020}
        {
        \t"input_i" : "-14.20",
        \t"input_tp" : "-0.80",
        \t"input_lra" : "6.10",
        \t"input_thresh" : "-24.30",
        \t"output_i" : "-12.00",
        \t"target_offset" : "0.05"
        }
        """
        let measurement = try tool.parseLoudnormJSON(from: stderr)
        XCTAssertEqual(measurement.inputI, "-14.20")
        XCTAssertEqual(measurement.inputTp, "-0.80")
    }

    // audit #0008: --output-file names exactly one output, so only single-output actions may
    // take it. A full run produces ~29 files and used to hand the same override to both the
    // album WAV and the main MP4 render, which then published the video over the WAV.
    func testOutputFileIsOnlyAcceptedBySingleOutputActions() throws {
        let root = URL(fileURLWithPath: "/tmp/converter-test")
        func parse(_ arguments: [String]) throws -> CLIOptions {
            try CLIOptions.parse(arguments: arguments, environment: [:], scriptDirectory: root, scriptName: "converter")
        }
        let rejected = [
            ["-full", "--output-file", "x.mp4"], ["-run", "--output-file", "x.mp4"],
            ["-short", "--output-file", "x.mp4"], ["-flactomp3", "--output-file", "x.mp3"]
        ]
        for arguments in rejected {
            XCTAssertThrowsError(try parse(arguments), arguments.joined(separator: " ")) { error in
                XCTAssertTrue("\(error)".contains("--output-file"), "\(error)")
            }
        }
        let accepted = [
            ["-m4atomp4", "--output-file", "x.mp4"], ["-album", "--output-file", "a.wav"],
            ["-wavtoalbum", "--output-file", "a.wav"], ["-mp3toalbum", "--output-file", "a.wav"],
            ["-flactoalbum", "--output-file", "a.wav"], ["-visualsubs", "9", "--output-file", "d.png"]
        ]
        for arguments in accepted {
            XCTAssertNoThrow(try parse(arguments), arguments.joined(separator: " "))
        }
    }

    // audit #0007: a conversion must never publish onto the file it reads from. With the default
    // shared SRC_DIR/OUT_DIR the full run's MP3 deliverable used to land on the renamed source.
    func testAudioConversionRefusesToWriteOverItsSource() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let tool = try makeTool(tempDirectory: temp)
        let source = temp.appendingPathComponent("1.mp3")
        try Data("not-an-mp3".utf8).write(to: source)

        XCTAssertThrowsError(try tool.convertAudioToMP3(source)) { error in
            XCTAssertTrue("\(error)".contains("its own source"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: source), Data("not-an-mp3".utf8), "source bytes must be untouched")
    }

    // audit #0033: requireDirectChild was only tested with a plain subfolder. It is the whole
    // containment check for --output-file and explicit inputs, so every escape shape must be
    // pinned: "..", a subfolder, a symlinked subfolder pointing elsewhere, and "link/..".
    func testRequireDirectChildRejectsRelativeEscapesSubfoldersAndSymlinkedSubfolders() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let outDir = temp.appendingPathComponent("out", isDirectory: true)
        let other = temp.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outDir.appendingPathComponent("sub"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        // out/escape -> other: a symlink inside outDir whose target lives outside it.
        try FileManager.default.createSymbolicLink(
            at: outDir.appendingPathComponent("escape"), withDestinationURL: other
        )
        let tool = try makeTool(tempDirectory: outDir)

        let expected = "must stay directly in '\(outDir.path)'"
        let rejected = ["../x.wav", "sub/x.wav", "escape/x.wav", "sub/../x.wav", "escape/../x.wav", "sub/./x.wav"]
        for relative in rejected {
            XCTAssertThrowsError(try tool.resolveOutputPath(relative), relative) { error in
                XCTAssertTrue("\(error)".contains("Output path \(expected)"), "\(relative): \(error)")
            }
            XCTAssertThrowsError(try tool.resolveExplicitPath(relative, baseDirectory: outDir), relative) { error in
                XCTAssertTrue("\(error)".contains("Input path \(expected)"), "\(relative): \(error)")
            }
            XCTAssertThrowsError(
                try tool.requireDirectChild(outDir.appendingPathComponent(relative), of: outDir, label: "Probe"),
                relative
            ) { error in
                XCTAssertTrue("\(error)".contains("Probe \(expected)"), "\(relative): \(error)")
            }
        }

        // A plain file name is the only relative form that is accepted, and it resolves under outDir.
        XCTAssertEqual(try tool.resolveOutputPath("x.wav").path, outDir.appendingPathComponent("x.wav").path)
        XCTAssertEqual(
            try tool.resolveExplicitPath("x.wav", baseDirectory: outDir).path,
            outDir.appendingPathComponent("x.wav").path
        )
    }

    // audit #0033: --output-file and explicit inputs accept absolute paths, which bypass the
    // outDir prefix entirely; only an absolute path whose parent IS outDir may pass, and the
    // comparison must survive the /var -> /private/var symlink on both sides.
    func testRequireDirectChildHandlesAbsolutePathsInsideAndOutsideOutDir() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let outDir = temp.appendingPathComponent("out", isDirectory: true)
        let other = temp.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outDir.appendingPathComponent("sub"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let tool = try makeTool(tempDirectory: outDir)
        let expected = "must stay directly in '\(outDir.path)'"

        let rejected = [
            other.appendingPathComponent("x.wav").path,
            temp.appendingPathComponent("x.wav").path,
            outDir.appendingPathComponent("sub/x.wav").path,
            outDir.appendingPathComponent("sub/../x.wav").path,
            "/tmp/x.wav"
        ]
        for absolute in rejected {
            XCTAssertTrue(absolute.hasPrefix("/"))
            XCTAssertThrowsError(try tool.resolveOutputPath(absolute), absolute) { error in
                XCTAssertTrue("\(error)".contains("Output path \(expected)"), "\(absolute): \(error)")
            }
            XCTAssertThrowsError(try tool.resolveExplicitPath(absolute, baseDirectory: outDir), absolute) { error in
                XCTAssertTrue("\(error)".contains("Input path \(expected)"), "\(absolute): \(error)")
            }
        }

        // Directly inside outDir: accepted verbatim (not re-rooted under outDir).
        let inside = outDir.appendingPathComponent("x.wav").path
        XCTAssertEqual(try tool.resolveOutputPath(inside).path, inside)
        XCTAssertEqual(try tool.resolveExplicitPath(inside, baseDirectory: outDir).path, inside)

        // The same file spelled through the fully resolved (symlink-free) directory is also accepted,
        // even though cli.outDir keeps the unresolved spelling.
        let resolvedInside = outDir.resolvingSymlinksInPath().appendingPathComponent("x.wav").path
        XCTAssertEqual(try tool.resolveOutputPath(resolvedInside).path, resolvedInside)
        XCTAssertEqual(try tool.resolveExplicitPath(resolvedInside, baseDirectory: outDir).path, resolvedInside)
    }

    // audit #0033: when outDir itself is a symlink, a direct child must be accepted whether the
    // caller spells it through the link or through the real directory (resolution on both sides),
    // while "real/../x" and siblings of the link target stay rejected.
    func testRequireDirectChildResolvesSymlinkedOutDirOnBothSides() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let real = temp.appendingPathComponent("real", isDirectory: true)
        let link = temp.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let tool = try makeTool(tempDirectory: link)
        XCTAssertEqual(tool.cli.outDir.path, link.path, "the tool must keep the symlinked spelling")

        // Relative name, absolute through the link, absolute through the real directory: all accepted.
        XCTAssertEqual(try tool.resolveOutputPath("x.wav").path, link.appendingPathComponent("x.wav").path)
        let viaLink = link.appendingPathComponent("x.wav").path
        XCTAssertEqual(try tool.resolveOutputPath(viaLink).path, viaLink)
        let viaReal = real.appendingPathComponent("x.wav").path
        XCTAssertEqual(try tool.resolveOutputPath(viaReal).path, viaReal)
        XCTAssertEqual(try tool.resolveExplicitPath(viaReal, baseDirectory: link).path, viaReal)
        // The mirror image: the base is the real directory and the caller spells it through the link.
        XCTAssertEqual(try tool.resolveExplicitPath(viaLink, baseDirectory: real).path, viaLink)

        let expected = "must stay directly in '\(link.path)'"
        let rejected = [
            real.appendingPathComponent("../x.wav").path,
            link.appendingPathComponent("../x.wav").path,
            temp.appendingPathComponent("x.wav").path,
            "../real/x.wav"
        ]
        for candidate in rejected {
            XCTAssertThrowsError(try tool.resolveOutputPath(candidate), candidate) { error in
                XCTAssertTrue("\(error)".contains("Output path \(expected)"), "\(candidate): \(error)")
            }
        }
    }

    // audit #0036: -clean must only remove converter-owned normalisation scratch files, i.e. hidden
    // entries whose name contains ".normalized". Every other OUT_DIR entry (visible files whatever
    // their name or extension, other hidden files, publish backups, subdirectories) is user data and
    // must survive byte-for-byte. No test guarded that before.
    func testCleanTransientsRemovesOnlyHiddenNormalizedFiles() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let tool = try makeTool(tempDirectory: temp, arguments: ["-clean"])

        let transients = [".x.normalized.wav", ".x.normalized"]
        let survivors = [
            "song.normalized.wav", ".song.wav.publish-backup", ".converter-tmp.1.foo",
            "song.wav", "notes.log", "mix.w64", ".DS_Store"
        ]
        for name in transients + survivors {
            try Data(name.utf8).write(to: temp.appendingPathComponent(name))
        }
        let keepDirectory = temp.appendingPathComponent("keep", isDirectory: true)
        try FileManager.default.createDirectory(at: keepDirectory, withIntermediateDirectories: false)
        let keptFile = keepDirectory.appendingPathComponent("inner.wav")
        try Data("inner".utf8).write(to: keptFile)

        try tool.cleanTransients()

        for name in transients {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: temp.appendingPathComponent(name).path),
                "\(name) is a converter transient and must be removed"
            )
        }
        for name in survivors {
            XCTAssertEqual(
                try Data(contentsOf: temp.appendingPathComponent(name)),
                Data(name.utf8),
                "\(name) must survive -clean with its bytes untouched"
            )
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: keepDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "keep/ must remain a directory")
        XCTAssertEqual(try Data(contentsOf: keptFile), Data("inner".utf8), "keep/inner.wav must survive")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: temp.path).sorted()
        XCTAssertEqual(remaining, (survivors + ["keep"]).sorted(), "exactly the two transients may go")
    }

    // audit #0036: the real `-clean` entry point (initializeForExecution + execute) also runs
    // publish-backup recovery and orphaned-temp cleanup before cleanTransients(). Only converter-owned
    // artefacts may change there: a backup whose destination is missing is restored (not deleted),
    // a stale backup and a temp of a dead process are removed, a temp of a live process stays, and
    // every user file keeps its bytes.
    func testCleanActionEntryPointPreservesUserFiles() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let tool = try makeTool(tempDirectory: temp, arguments: ["-clean"])
        XCTAssertEqual(tool.cli.action, .clean)

        // PID 1 (launchd) is always alive; Int32.max is never a live PID, so that temp is orphaned.
        let orphanTemp = ".converter-tmp.\(Int32.max).orphan"
        let untouched = [
            "song.normalized.wav", "song.wav", "notes.log", "mix.w64", ".DS_Store", ".converter-tmp.1.foo"
        ]
        let removed = [".x.normalized.wav", ".x.normalized", ".song.wav.publish-backup", orphanTemp]
        for name in untouched + removed {
            try Data(name.utf8).write(to: temp.appendingPathComponent(name))
        }
        let previousVersion = Data("previous version of lost.wav".utf8)
        try previousVersion.write(to: temp.appendingPathComponent(".lost.wav.publish-backup"))
        let keepDirectory = temp.appendingPathComponent("keep", isDirectory: true)
        try FileManager.default.createDirectory(at: keepDirectory, withIntermediateDirectories: false)
        let keptFile = keepDirectory.appendingPathComponent("inner.wav")
        try Data("inner".utf8).write(to: keptFile)

        try tool.initializeForExecution()
        try await tool.execute()

        for name in removed + [".lost.wav.publish-backup"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: temp.appendingPathComponent(name).path),
                "\(name) is converter-owned and must be gone after -clean"
            )
        }
        for name in untouched {
            XCTAssertEqual(
                try Data(contentsOf: temp.appendingPathComponent(name)),
                Data(name.utf8),
                "\(name) must survive the -clean entry point with its bytes untouched"
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: temp.appendingPathComponent("lost.wav")),
            previousVersion,
            "a publish backup without its destination is restored, never deleted"
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: keepDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "keep/ must remain a directory")
        XCTAssertEqual(try Data(contentsOf: keptFile), Data("inner".utf8), "keep/inner.wav must survive")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: temp.path).sorted()
        XCTAssertEqual(remaining, (untouched + ["keep", "lost.wav"]).sorted())
    }

    private func writeFixture(_ data: Data, as name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // audit #0043: containsChunk was a 64 KiB substring scan. The four bytes of a chunk id inside
    // a LIST/INFO string (or inside the samples) counted as the chunk, a chunk past 64 KiB read
    // as absent, and the RF64 size placeholder was never resolved through ds64, so nothing after
    // a large data chunk was reachable. A chunk id is only a chunk id at a chunk boundary.
    func testContainsChunkWalksChunksInsteadOfScanningBytes() throws {
        let tool = try makeParserTool()
        let directory = tool.cli.outDir
        let fmt = WAVFixture.pcmFormatChunk(channels: 2, sampleRate: 96_000, bitsPerSample: 24)
        var samples = Data(count: 6 * 97)
        samples.replaceSubrange(30 ..< 34, with: WAVFixture.fourCC("bext"))

        // "bext" as text inside LIST/INFO or inside the PCM is not a bext chunk.
        let info = WAVFixture.fourCC("INFO") + WAVFixture.chunk("ICMT", Data("bext is only a word here\0".utf8))
        let textOnly = try writeFixture(
            WAVFixture.rf64File(container: "RF64", before: [fmt, WAVFixture.chunk("LIST", info)], dataPayload: samples),
            as: "text_only.wav", in: directory
        )
        XCTAssertFalse(try tool.containsChunk(textOnly, chunkID: "bext"), "bext inside LIST/INFO text is not a chunk")
        XCTAssertTrue(try tool.containsChunk(textOnly, chunkID: "LIST"))
        XCTAssertTrue(try tool.containsChunk(textOnly, chunkID: "data"))
        let plain = try writeFixture(
            WAVFixture.riffFile(chunks: [fmt, WAVFixture.chunk("data", samples)]), as: "plain.wav", in: directory
        )
        XCTAssertFalse(try tool.containsChunk(plain, chunkID: "bext"), "bext inside the samples is not a chunk")
        XCTAssertTrue(try tool.containsChunk(plain, chunkID: "data"))

        // A real bext chunk after 70 001 bytes of JUNK (odd, so the pad byte is walked) is present.
        let junk = WAVFixture.chunk("JUNK", Data(count: 70_001))
        let farBext = try writeFixture(
            WAVFixture.rf64File(
                container: "RF64", before: [fmt, junk, WAVFixture.bextChunk(description: "late")], dataPayload: samples
            ),
            as: "far_bext.wav", in: directory
        )
        XCTAssertTrue(try tool.containsChunk(farBext, chunkID: "bext"), "a bext chunk past 64 KiB must be found")

        // The data chunk carries the placeholder; only ds64 says where it ends, and the chunk
        // behind it is reachable only through that substitution.
        let afterData = try writeFixture(
            WAVFixture.rf64File(
                container: "BW64", before: [fmt], dataPayload: Data(count: 6 * 12_000),
                after: [WAVFixture.bextChunk(description: "trailing")]
            ),
            as: "after_data.wav", in: directory
        )
        XCTAssertTrue(try tool.containsChunk(afterData, chunkID: "ds64"))
        XCTAssertTrue(
            try tool.containsChunk(afterData, chunkID: "bext"), "the chunk after a placeholder-sized data chunk"
        )
        XCTAssertFalse(try tool.containsChunk(afterData, chunkID: "JUNK"))
    }

    // audit #0043: the walk is bounds-checked and fails closed. Each layout below either passed
    // the byte scan or was never examined: a file that ends after its header, a form type that
    // is not WAVE, an RF64 whose first chunk is not ds64, a BW64 whose only "ds64" is text inside
    // bext, a chunk running past the end of the file, the RF64 size placeholder inside a plain
    // RIFF, a ds64 too short to hold its sizes, and stray bytes after the last chunk.
    func testContainsChunkRejectsMalformedRIFFStructures() throws {
        let tool = try makeParserTool()
        let directory = tool.cli.outDir
        let fmt = WAVFixture.pcmFormatChunk(channels: 2, sampleRate: 96_000, bitsPerSample: 24)
        let samples = Data(count: 6 * 40)
        let data = WAVFixture.chunk("data", samples)
        let header = WAVFixture.fourCC("RF64") + WAVFixture.uint32LE(WAVFixture.sizePlaceholder)
            + WAVFixture.fourCC("WAVE")

        func assertRejected(_ bytes: Data, as name: String, reason: String, line: UInt = #line) throws {
            let url = try writeFixture(bytes, as: name, in: directory)
            XCTAssertThrowsError(try tool.containsChunk(url, chunkID: "data"), name, line: line) { error in
                let message = error.localizedDescription
                XCTAssertTrue(message.contains(reason), "\(name): expected '\(reason)' in: \(message)", line: line)
                XCTAssertTrue(message.contains(url.path), "\(name): the error must name the file", line: line)
            }
        }

        let riffHeader = WAVFixture.fourCC("RIFF") + WAVFixture.uint32LE(4)
        try assertRejected(riffHeader, as: "eight_bytes.wav", reason: "need 12")
        try assertRejected(riffHeader + WAVFixture.fourCC("WAVX"), as: "wavx.wav", reason: "WAVE")
        try assertRejected(
            WAVFixture.rf64FileWithoutDs64(container: "RF64", chunks: [fmt, data]),
            as: "rf64_no_ds64.wav", reason: "ds64"
        )
        try assertRejected(
            WAVFixture.rf64FileWithoutDs64(
                container: "BW64", chunks: [WAVFixture.bextChunk(description: "ds64 lives here"), fmt, data]
            ),
            as: "bw64_ds64_text.wav", reason: "ds64"
        )
        try assertRejected(
            WAVFixture.riffFile(chunks: [fmt, data]).dropLast(10), as: "truncated_data.wav", reason: "ends at"
        )
        try assertRejected(
            WAVFixture.riffFile(chunks: [fmt, WAVFixture.placeholderChunk("data", samples)]),
            as: "riff_placeholder.wav", reason: "placeholder"
        )
        try assertRejected(
            header + WAVFixture.chunk("ds64", Data(count: 16)) + fmt + data, as: "short_ds64.wav", reason: "ds64"
        )
        try assertRejected(
            WAVFixture.riffFile(chunks: [fmt, data]) + Data("junk".utf8), as: "trailing.wav", reason: "trailing"
        )
    }

    // audit #0043 (T-18): verifyWAVHeader boundaries pinned alongside the walker. A file that
    // ends inside the header, a form type other than WAVE, and a RIFF where RF64 is required
    // are all rejected with the message that names the mismatch; "ANY" accepts both containers.
    func testWAVHeaderRejectsTruncatedWAVXAndMismatchedContainers() throws {
        let tool = try makeParserTool()
        let directory = tool.cli.outDir
        let fmt = WAVFixture.pcmFormatChunk(channels: 2, sampleRate: 96_000, bitsPerSample: 24)
        let data = WAVFixture.chunk("data", Data(count: 6 * 40))

        let riffHeader = WAVFixture.fourCC("RIFF") + WAVFixture.uint32LE(4)
        let eightBytes = try writeFixture(riffHeader, as: "eight.wav", in: directory)
        XCTAssertThrowsError(try tool.verifyWAVHeader(eightBytes)) { error in
            XCTAssertTrue(error.localizedDescription.contains("WAV header too short"), error.localizedDescription)
        }
        let wavx = try writeFixture(riffHeader + WAVFixture.fourCC("WAVX") + fmt + data, as: "wavx.wav", in: directory)
        XCTAssertThrowsError(try tool.verifyWAVHeader(wavx, expectedContainer: "ANY")) { error in
            XCTAssertTrue(error.localizedDescription.contains("got='WAVX' expected='WAVE'"), error.localizedDescription)
        }
        let riff = try writeFixture(WAVFixture.riffFile(chunks: [fmt, data]), as: "riff.wav", in: directory)
        XCTAssertThrowsError(try tool.verifyWAVHeader(riff, expectedContainer: "RF64")) { error in
            XCTAssertTrue(error.localizedDescription.contains("got='RIFF' expected='RF64'"), error.localizedDescription)
        }
        XCTAssertNoThrow(try tool.verifyWAVHeader(riff, expectedContainer: "RIFF"))
        XCTAssertNoThrow(try tool.verifyWAVHeader(riff, expectedContainer: "ANY"))
        let rf64 = try writeFixture(
            WAVFixture.rf64File(container: "RF64", before: [fmt], dataPayload: Data(count: 6 * 40)),
            as: "rf64.wav", in: directory
        )
        XCTAssertNoThrow(try tool.verifyWAVHeader(rf64, expectedContainer: "RF64"))
        XCTAssertThrowsError(try tool.verifyWAVHeader(rf64, expectedContainer: "RIFF"))
    }

    // audit #0043 (T-18): the canonical PCM comparison's own boundaries. Sign extension at the
    // extremes of both sample widths, a length mismatch, and a byte count that is not a whole
    // number of samples are each pinned; the lossless guarantee rests on these paths.
    func testCanonicalPCMSampleDecodingAndLengthBoundaries() throws {
        let tool = try makeParserTool()
        let directory = tool.cli.outDir

        let s24 = Data([0xFF, 0xFF, 0x7F, 0x00, 0x00, 0x80, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00])
        XCTAssertEqual(tool.littleEndianSignedSample(s24, offset: 0, format: .s24le), 8_388_607)
        XCTAssertEqual(tool.littleEndianSignedSample(s24, offset: 3, format: .s24le), -8_388_608)
        XCTAssertEqual(tool.littleEndianSignedSample(s24, offset: 6, format: .s24le), -1)
        XCTAssertEqual(tool.littleEndianSignedSample(s24, offset: 9, format: .s24le), 0)
        let s32 = Data([0xFF, 0xFF, 0xFF, 0x7F, 0x00, 0x00, 0x00, 0x80, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(tool.littleEndianSignedSample(s32, offset: 0, format: .s32le), Int64(Int32.max))
        XCTAssertEqual(tool.littleEndianSignedSample(s32, offset: 4, format: .s32le), Int64(Int32.min))
        XCTAssertEqual(tool.littleEndianSignedSample(s32, offset: 8, format: .s32le), -1)

        let reference = try writeFixture(Data(count: 3 * 1_000), as: "reference.s24le", in: directory)
        let shorter = try writeFixture(Data(count: 3 * 999), as: "shorter.s24le", in: directory)
        func compare(_ expected: URL, _ actual: URL) throws {
            _ = try tool.compareCanonicalPCMFiles(
                expected, actual, format: .s24le, maxAllowedDelta: 0, maxAllowedFailures: 0
            )
        }
        XCTAssertThrowsError(try compare(reference, shorter)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("size mismatch (expected=3000 actual=2997)"), message)
        }
        let unaligned = try writeFixture(Data(count: 3 * 1_000 + 1), as: "unaligned.s24le", in: directory)
        let unalignedCopy = try writeFixture(Data(count: 3 * 1_000 + 1), as: "unaligned_copy.s24le", in: directory)
        XCTAssertThrowsError(try compare(unaligned, unalignedCopy)) { error in
            XCTAssertTrue(error.localizedDescription.contains("not sample-aligned"), error.localizedDescription)
        }
        let same = try tool.compareCanonicalPCMFiles(
            reference, reference, format: .s24le, maxAllowedDelta: 0, maxAllowedFailures: 0
        )
        XCTAssertEqual(same.samples, 1_000)
        XCTAssertEqual(same.failingSamples, 0)
    }
}

// audit #0039: bounds an await so a leaked permit fails the test instead of hanging the suite.
// The loser of the race is cancelled by the group on exit, which AsyncSemaphore honours.
private struct AwaitTimedOut: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "await did not complete within \(seconds) s" }
}

@discardableResult
private func expectCompletion<T: Sendable>(
    within seconds: Double = 1,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw AwaitTimedOut(seconds: seconds)
        }
        guard let result = try await group.next() else {
            throw AwaitTimedOut(seconds: seconds)
        }
        group.cancelAll()
        return result
    }
}

// audit #0076: yields until `condition` holds, failing after `seconds` so a state that never
// arrives (a waiter that never queued) is reported instead of spun on forever.
private func waitUntil(
    within seconds: Double = 1,
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while await !condition() {
        guard Date() < deadline else {
            throw AwaitTimedOut(seconds: seconds)
        }
        await Task.yield()
    }
}

private actor PermitPeakTracker {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
    }
}

// Moved from the converter module: bitrate parsing has no production consumer
// (all delivery audio is ALAC/320k by design) but the behavior stays covered.
func parseBitrateBps(_ rawValue: String) -> Int? {
    let value = rawValue.trimmed.lowercasedASCII
    guard !value.isEmpty else {
        return nil
    }
    let multiplier: Double
    let digits: String
    if value.hasSuffix("k") {
        multiplier = 1_000
        digits = String(value.dropLast())
    } else if value.hasSuffix("m") {
        multiplier = 1_000_000
        digits = String(value.dropLast())
    } else {
        multiplier = 1
        digits = value
    }
    guard let parsed = Double(digits), parsed > 0 else {
        return nil
    }
    return Int((parsed * multiplier).rounded())
}
