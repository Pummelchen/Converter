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

        var previewConfig = ProjectConfig()
        previewConfig.shortMP4ClipSeconds = "0:30"
        let logger = Logger(scriptName: "converterTests", debugEnabled: false)
        let runner = ProcessRunner(logger: logger, environment: [:], debugEnabled: false)
        let previewTool = ConverterTool(
            cli: defaultTool.cli,
            config: previewConfig,
            logger: logger,
            runner: runner,
            environment: [:]
        )
        XCTAssertEqual(try previewTool.configuredShortClipSeconds(), 30, accuracy: 0.0001)
        XCTAssertEqual(try previewTool.effectiveShortClipSeconds(forDuration: 90), 30, accuracy: 0.0001)
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
        XCTAssertTrue(help.contains("fits the image into the portrait frame as large as possible with black padding"))
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
                "integrated loudness -13.30 LUFS outside target -12.00 +/- 0.80",
                "true peak -0.60 dBTP exceeds max -1.00"
            ]
        )
        let brokenResult = AudioQCResult(
            policy: policy,
            metrics: metrics,
            passed: false,
            issues: ["Audio verification failed: output appears silent"]
        )

        XCTAssertTrue(tool.loudnessCandidateIsPublishableFallback(recoverableResult, policy: policy))
        XCTAssertFalse(tool.loudnessCandidateIsPublishableFallback(brokenResult, policy: policy))
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

        let tool = try makeTool(tempDirectory: tempDirectory)
        XCTAssertEqual(try tool.resolveFullAudio().lastPathComponent, "song.flac")
    }

    // A full run writes its image deliverables next to the source, so rerunning in the same
    // directory used to fail with "expects exactly one source image" once the derived family
    // existed. The audio side already collapsed its own family; the image side now matches.
    func testResolveFullImageCollapsesItsOwnDerivedOutputsOnRerun() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        for name in [
            "9_8K.png", "9_4K.png", "9_3K.png", "9_2K.png",
            "9_NFT8K.png", "9_NFT3K.png", "9_NFT2K.png",
            "9_8K_1MB.jpg", "9_8K_2MB.jpg", "9_8K_20MB.jpg", "9_3K_1MB.jpg", "9_3K_5MB.jpg"
        ] {
            FileManager.default.createFile(atPath: tempDirectory.appendingPathComponent(name).path, contents: Data("x".utf8))
        }

        let tool = try makeTool(tempDirectory: tempDirectory)
        XCTAssertEqual(try tool.resolveFullImage().lastPathComponent, "9_8K.png")

        // A bare source outranks every derived rendition.
        FileManager.default.createFile(atPath: tempDirectory.appendingPathComponent("9.png").path, contents: Data("x".utf8))
        XCTAssertEqual(try tool.resolveFullImage().lastPathComponent, "9.png")
    }

    func testResolveFullImageStillRejectsTwoDistinctSources() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        for name in ["cover.png", "cover_8K.png", "backdrop.png"] {
            FileManager.default.createFile(atPath: tempDirectory.appendingPathComponent(name).path, contents: Data("x".utf8))
        }

        let tool = try makeTool(tempDirectory: tempDirectory)
        XCTAssertThrowsError(try tool.resolveFullImage()) { error in
            XCTAssertTrue(error.localizedDescription.contains("exactly one source image"))
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
        XCTAssertEqual(tool.fullRunImageBaseName("cover"), "cover")
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
    func testAsyncSemaphoreCancellationResumesOnlyTheCancelledWaiter() async throws {
        let semaphore = AsyncSemaphore(value: 1)
        try await semaphore.wait()

        let first = Task { try await semaphore.wait() }
        try await Task.sleep(nanoseconds: 80_000_000)
        let second = Task { try await semaphore.wait() }
        try await Task.sleep(nanoseconds: 80_000_000)

        second.cancel()
        try await Task.sleep(nanoseconds: 80_000_000)

        // Releasing the held permit must hand it to the first, uncancelled waiter.
        await semaphore.signal()
        try await first.value

        var secondError: (any Error)?
        do {
            try await second.value
        } catch {
            secondError = error
        }
        XCTAssertTrue(secondError is CancellationError, "the cancelled waiter must be the one that fails")

        await semaphore.signal()
    }

    func testAsyncSemaphoreCancellationBeforeSuspensionStillThrows() async throws {
        let semaphore = AsyncSemaphore(value: 1)
        try await semaphore.wait()

        let queued = Task { try await semaphore.wait() }
        queued.cancel()

        var queuedError: (any Error)?
        do {
            try await queued.value
        } catch {
            queuedError = error
        }
        XCTAssertTrue(queuedError is CancellationError, "cancellation racing ahead of suspension must still be honored")

        await semaphore.signal()
    }

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

        // A throwing body must still return its permit.
        struct Boom: Error {}
        for _ in 0 ..< 4 {
            do {
                try await semaphore.withPermit { throw Boom() }
            } catch is Boom {
                continue
            }
        }
        try await semaphore.wait()
        try await semaphore.wait()
        await semaphore.signal()
        await semaphore.signal()
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
