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
        XCTAssertTrue(DependencyBootstrapper.pythonPackages.isEmpty)
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
        XCTAssertFalse(file.isHiddenBasename)
        XCTAssertEqual(file.appendingStemSuffix("_RF64").lastPathComponent, "Album.Track.Final_RF64.wav")
        XCTAssertTrue(URL(fileURLWithPath: "/tmp/.converter-tmp.file").isHiddenBasename)
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
            XCTAssertTrue(error.localizedDescription.contains("greater than zero"))
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
            XCTAssertTrue(error.localizedDescription.contains("greater than zero"))
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
            policy: policy.name,
            targetLUFS: policy.targetLUFS,
            lufsTolerance: policy.lufsTolerance,
            maxTruePeakDBTP: policy.maxTruePeakDBTP,
            maxLoudnessRange: policy.maxLoudnessRange,
            maxDCOffset: policy.maxDCOffset,
            maxStereoImbalanceDB: policy.maxStereoImbalanceDB,
            maxClippedSamples: policy.maxClippedSamples,
            minimumAnalysisSeconds: policy.minimumAnalysisSeconds,
            metrics: metrics,
            passed: false,
            issues: [
                "integrated loudness -13.30 LUFS outside target -12.00 +/- 0.80",
                "true peak -0.60 dBTP exceeds max -1.00"
            ]
        )
        let brokenResult = AudioQCResult(
            policy: policy.name,
            targetLUFS: policy.targetLUFS,
            lufsTolerance: policy.lufsTolerance,
            maxTruePeakDBTP: policy.maxTruePeakDBTP,
            maxLoudnessRange: policy.maxLoudnessRange,
            maxDCOffset: policy.maxDCOffset,
            maxStereoImbalanceDB: policy.maxStereoImbalanceDB,
            maxClippedSamples: policy.maxClippedSamples,
            minimumAnalysisSeconds: policy.minimumAnalysisSeconds,
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
        XCTAssertFalse(config.masteringEnabled)
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
            XCTAssertTrue(error.localizedDescription.contains("requires two positional values"))
        }
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
}
