import Foundation

enum Action: String {
    case album
    case bass
    case doctor
    case fade
    case fadecut
    case fadeout
    case hash
    case loudness
    case loudscan
    case master
    case noise
    case silence
    case short
    case full
    case runPix = "run_pix"
    case aipix
    case clean
    case fadewav
    case flactoalbum
    case flactohash
    case flactom4a
    case flactomp3
    case flactowav
    case jpgtopng
    case m4atomp4
    case m4atoflac
    case m4atomp3
    case m4atowav
    case matrix
    case mp3clean
    case mp3toalbum
    case mp3toflac
    case mp3tohash
    case mp3tom4a
    case mp3towav
    case mp4toshort
    case nfttoshort
    case pngto2k
    case pngto3k
    case pngto3k1mb
    case pngto3k5mb
    case pngtojpg
    case pngtonft
    case pngtojpg1mb
    case pngtojpg2mb
    case pngtojpg20mb
    case visualsubs
    case wavtoalbum
    case wavtoflac
    case wavtohash
    case wavtom4a
    case wavtomp3
    case help
    case list
}

extension Action {
    // --output-file binds to exactly one output. Multi-output actions (the full run, batch
    // conversions, shorts) must reject it: handing one override to several producers made an
    // album run publish its main MP4 over its own album WAV.
    // Actions that read positional values (`-bass 80 5`, `-loudness -13`, `-visualsubs 9`).
    // Every other action must reject stray words: a typo such as `-full --overwite` used to run
    // as if the option had never been given.
    static let actionsAcceptingPositionalArguments: [Action] = [
        .bass, .loudness, .fade, .fadecut, .fadeout, .noise, .silence, .visualsubs
    ]

    var acceptsPositionalArguments: Bool {
        Self.actionsAcceptingPositionalArguments.contains(self)
    }

    static let actionsAcceptingOutputFile: [Action] = [
        .m4atomp4, .album, .wavtoalbum, .mp3toalbum, .flactoalbum, .visualsubs
    ]

    var acceptsOutputFile: Bool {
        Self.actionsAcceptingOutputFile.contains(self)
    }
}

struct CLIOptions {
    // Padding below this cannot be verified by the silence/noise content probes.
    static let minimumPaddingSeconds = 0.5
    // --sleep-seconds is a deliberate pacing pause, not a way to park the process indefinitely.
    static let maximumSleepSeconds: Double = 3600
    // The dot overlay's placement loop grows one dictionary entry per placed dot, so an unbounded
    // count or attempt budget is an out-of-memory path on the 8 GB target machine (#0129). 200k
    // dots is far above any usable overlay on the 7680x4320 canvas.
    static let maximumVisualSubsDots = 200_000
    static let maximumVisualSubsAttempts = 1_000_000

    var action: Action = .help
    var debug = false
    var overwrite = false
    var continueOnError = false
    var keepFullName = false
    var lowercasePrefix = false
    var trailingSilence = false
    var openAfterCreate = false

    var outputFile: String?
    var profileName: String?
    var numDots: Int?
    var dotSize = 10
    var maxAttempts = 10_000
    var seed: UInt64?
    // The options above (and --open) are consumed only by `-visualsubs`; the names are recorded
    // here so every other action can reject them instead of silently ignoring them (#0155).
    var usedVisualSubsOptions: Set<String> = []
    var sleepSeconds: Double = 0
    var sharpnessOverride: Double?
    var actionArgs: [String] = []

    var configFile: URL
    // True when the path came from --config or CONFIG_FILE rather than the script-directory default.
    var configFileWasExplicit = false
    var srcDir: URL
    var outDir: URL

    let scriptDirectory: URL
    let scriptName: String

    static func parse(
        arguments: [String], environment: [String: String], scriptDirectory: URL, scriptName: String
    ) throws -> CLIOptions {
        let outputBase = environment["OUTPUT_DIR"]
        let envSrc = environment["SRC_DIR"] ?? outputBase
        let envOut = environment["OUT_DIR"] ?? outputBase
        let defaultIO = scriptDirectory.appendingPathComponent("Output", isDirectory: true)

        var options = CLIOptions(
            configFile: URL(
                fileURLWithPath: environment["CONFIG_FILE"] ?? scriptDirectory.appendingPathComponent("config.txt").path
            ),
            srcDir: URL(fileURLWithPath: envSrc ?? defaultIO.path),
            outDir: URL(fileURLWithPath: envOut ?? defaultIO.path),
            scriptDirectory: scriptDirectory,
            scriptName: scriptName
        )
        options.debug = [environment["DEBUG"]].compactMap { $0 }.contains {
            ["1", "true", "yes", "on"].contains($0.lowercasedASCII)
        }
        // A config path named through CONFIG_FILE or --config is a request, not a convention: if it
        // does not exist the run must say so instead of silently using built-in defaults (#0120).
        options.configFileWasExplicit = environment["CONFIG_FILE"] != nil

        var index = 0
        func requireValue(_ flag: String) throws -> String {
            let next = index + 1
            guard next < arguments.count else {
                throw AppError("Missing value for \(flag)")
            }
            let value = arguments[next]
            // A value that looks like another option means the flag was left without one
            // (`--output-file --overwrite` used to store "--overwrite" as a filename).
            guard !value.hasPrefix("--") else {
                throw AppError("Missing value for \(flag): '\(value)' looks like another option.")
            }
            index += 1
            return value
        }

        // Exactly one action selects the run; a second action flag used to win silently.
        var actionFlag: String?
        func select(_ action: Action, _ flag: String) throws {
            if let existing = actionFlag, existing != flag {
                throw AppError(
                    "Only one action may be given; got '\(existing)' and '\(flag)'. Run \(scriptName) -help."
                )
            }
            actionFlag = flag
            options.action = action
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-bass":
                try select(.bass, argument)
            case "-album":
                try select(.album, argument)
            case "-doctor":
                try select(.doctor, argument)
            case "-fade", "-fadeflac":
                try select(.fade, argument)
            case "-fadecut":
                try select(.fadecut, argument)
            case "-fadeout":
                try select(.fadeout, argument)
            case "--hash", "-hash":
                try select(.hash, argument)
            case "-loudness":
                try select(.loudness, argument)
            case "-master":
                try select(.master, argument)
            case "-loudscan", "-loundscan":
                try select(.loudscan, argument)
            case "-noise":
                try select(.noise, argument)
            case "-silence":
                try select(.silence, argument)
            case "-short":
                try select(.short, argument)
            case "-full", "-run":
                try select(.full, argument)
            case "-run_pix":
                try select(.runPix, argument)
            case "-aipix": try select(.aipix, argument)
            case "-clean": try select(.clean, argument)
            case "-fadewav": try select(.fadewav, argument)
            case "-flactoalbum": try select(.flactoalbum, argument)
            case "-flactohash": try select(.flactohash, argument)
            case "-flactom4a": try select(.flactom4a, argument)
            case "-flactomp3": try select(.flactomp3, argument)
            case "-flactowav": try select(.flactowav, argument)
            case "-jpgtopng": try select(.jpgtopng, argument)
            case "-jpegtopng":
                throw AppError("-jpegtopng was removed. Use -jpgtopng; it reads both .jpg and .jpeg inputs.")
            case "-m4atomp4": try select(.m4atomp4, argument)
            case "-m4atoflac": try select(.m4atoflac, argument)
            case "-m4atomp3": try select(.m4atomp3, argument)
            case "-m4atowav": try select(.m4atowav, argument)
            case "-matrix", "--matrix": try select(.matrix, argument)
            case "-mp3clean": try select(.mp3clean, argument)
            case "-mp3toalbum": try select(.mp3toalbum, argument)
            case "-mp3toflac": try select(.mp3toflac, argument)
            case "-mp3tohash": try select(.mp3tohash, argument)
            case "-mp3tom4a": try select(.mp3tom4a, argument)
            case "-mp3toshort":
                throw AppError(
                    "-mp3toshort was renamed. Use -nfttoshort; it accepts any single audio-only file supported by ffmpeg."
                )
            case "-mp3towav": try select(.mp3towav, argument)
            case "-mp4toshort": try select(.mp4toshort, argument)
            case "-nfttoshort": try select(.nfttoshort, argument)
            case "-pngto2k": try select(.pngto2k, argument)
            case "-pngto3k": try select(.pngto3k, argument)
            case "-pngto3k1mb": try select(.pngto3k1mb, argument)
            case "-pngto3k5mb": try select(.pngto3k5mb, argument)
            case "-pngtojpeg":
                throw AppError(
                    "-pngtojpeg was removed. Use -pngtojpg; converter writes JPEG outputs with the preferred .jpg extension."
                )
            case "-pngtojpg": try select(.pngtojpg, argument)
            case "-pngtonft": try select(.pngtonft, argument)
            case "-pngtojpg1mb": try select(.pngtojpg1mb, argument)
            case "-pngtojpg2mb": try select(.pngtojpg2mb, argument)
            case "-pngtojpg20mb": try select(.pngtojpg20mb, argument)
            case "-visualsubs": try select(.visualsubs, argument)
            case "-wavtoalbum": try select(.wavtoalbum, argument)
            case "-wavtoflac": try select(.wavtoflac, argument)
            case "-wavtohash": try select(.wavtohash, argument)
            case "-wavtom4a": try select(.wavtom4a, argument)
            case "-wavtomp3": try select(.wavtomp3, argument)
            case "-help", "--help": try select(.help, argument)
            case "-list", "--list": try select(.list, argument)
            case "--config":
                options.configFile = URL(fileURLWithPath: try requireValue(argument))
                options.configFileWasExplicit = true
            case "--profile":
                options.profileName = try requireValue(argument)
            case "--src-dir":
                options.srcDir = URL(fileURLWithPath: try requireValue(argument))
            case "--out-dir":
                options.outDir = URL(fileURLWithPath: try requireValue(argument))
            case "--output-dir":
                let url = URL(fileURLWithPath: try requireValue(argument))
                options.srcDir = url
                options.outDir = url
            case "--image", "--image-file":
                _ = try requireValue(argument)
                throw AppError(
                    "\(argument) is no longer supported. Converter auto-discovers required image inputs from SRC_DIR/Output."
                )
            case "--audio", "--audio-file":
                _ = try requireValue(argument)
                throw AppError(
                    "\(argument) is no longer supported. Converter auto-discovers required audio inputs from SRC_DIR/Output."
                )
            case "--album-file":
                _ = try requireValue(argument)
                throw AppError(
                    "\(argument) is no longer supported. -wavtoalbum and -mp3toalbum read album.txt from the project root; -album and -flactoalbum scan SRC_DIR directly."
                )
            case "--output-file":
                options.outputFile = try requireValue(argument)
            case "--overwrite":
                options.overwrite = true
            case "--keep-full-name":
                options.keepFullName = true
            case "--lowercase-prefix":
                options.lowercasePrefix = true
            case "--recursive":
                throw AppError(
                    "--recursive is no longer supported. Converter only scans the current SRC_DIR/Output folder.")
            case "--no-recursive":
                break
            case "--continue-on-error":
                options.continueOnError = true
            case "--trailing-silence":
                options.trailingSilence = true
            case "--sharpness":
                guard let value = Double(try requireValue(argument)), value.isFinite,
                    value >= 0, value <= ProjectConfig.maximumAIPixSharpness
                else {
                    throw AppError(
                        "--sharpness requires a finite value between 0 and \(ProjectConfig.maximumAIPixSharpness)"
                    )
                }
                options.sharpnessOverride = value
            case "--sleep-seconds":
                // Bounded: a negative value silently disabled the pacing the caller asked for, and
                // an enormous one parked the run in Thread.sleep with no watchdog (#0121).
                guard let value = Double(try requireValue(argument)), value.isFinite,
                    value > 0, value <= CLIOptions.maximumSleepSeconds
                else {
                    throw AppError(
                        "--sleep-seconds requires a finite value greater than 0 and at most "
                            + "\(Int(CLIOptions.maximumSleepSeconds)) seconds")
                }
                options.sleepSeconds = value
            case "--num-dots":
                guard let value = Int(try requireValue(argument)), value > 0 else {
                    throw AppError("--num-dots requires a positive integer")
                }
                options.numDots = value
                options.usedVisualSubsOptions.insert("--num-dots")
            case "--dot-size":
                guard let value = Int(try requireValue(argument)), value > 0 else {
                    throw AppError("--dot-size requires a positive integer")
                }
                options.dotSize = value
                options.usedVisualSubsOptions.insert("--dot-size")
            case "--max-attempts":
                guard let value = Int(try requireValue(argument)), value > 0 else {
                    throw AppError("--max-attempts requires a positive integer")
                }
                options.maxAttempts = value
                options.usedVisualSubsOptions.insert("--max-attempts")
            case "--seed":
                guard let value = UInt64(try requireValue(argument)), value > 0 else {
                    throw AppError("--seed requires a positive integer")
                }
                options.seed = value
                options.usedVisualSubsOptions.insert("--seed")
            case "--open":
                options.openAfterCreate = true
                options.usedVisualSubsOptions.insert("--open")
            case "--debug", "--verbose":
                options.debug = true
            case "--":
                if index + 1 < arguments.count {
                    options.actionArgs.append(contentsOf: arguments[(index + 1)...])
                }
                index = arguments.count
                continue
            default:
                // Negative numbers (`-13`, `-5`) are values; any other dash-prefixed word is a
                // misspelled or unknown option and must not be swallowed as a positional.
                if argument.hasPrefix("-"), Double(argument) == nil {
                    throw AppError(
                        "Unknown option '\(argument)'. Run \(scriptName) -help for the list of actions and options.")
                }
                options.actionArgs.append(argument)
            }
            index += 1
        }

        if !options.actionArgs.isEmpty, !options.action.acceptsPositionalArguments {
            let stray = options.actionArgs.joined(separator: " ")
            throw AppError(
                "-\(options.action.rawValue) does not take positional arguments (got: \(stray)). Run \(scriptName) -help."
            )
        }

        if options.outputFile != nil, !options.action.acceptsOutputFile {
            let supported = Action.actionsAcceptingOutputFile.map { "-\($0.rawValue)" }.joined(separator: ", ")
            throw AppError(
                "--output-file names exactly one output file and is not supported by -\(options.action.rawValue). "
                    + "It is accepted by: \(supported).")
        }

        // --open / --num-dots / --dot-size / --max-attempts / --seed are consumed only while
        // rendering the dot overlay. Every other action used to accept and ignore them (#0155).
        if let option = options.usedVisualSubsOptions.sorted().first, options.action != .visualsubs {
            throw AppError(
                "\(option) is only supported by -visualsubs (got -\(options.action.rawValue)). "
                    + "Run \(scriptName) -help for the option list.")
        }

        if options.action == .visualsubs {
            // Two positional values used to be accepted and the second silently discarded (#0126).
            guard options.actionArgs.count <= 1 else {
                throw AppError(
                    "-visualsubs accepts at most one positional dot count (got: "
                        + "\(options.actionArgs.joined(separator: " "))).")
            }
            if options.actionArgs.count == 1, options.numDots != nil {
                throw AppError("-visualsubs received a positional dot count and --num-dots; give exactly one of them.")
            }
            let dots = options.numDots ?? options.actionArgs.first.flatMap(Int.init) ?? 0
            guard dots <= Self.maximumVisualSubsDots else {
                throw AppError(
                    "-visualsubs supports at most \(Self.maximumVisualSubsDots) dots (got \(dots)).")
            }
            guard options.maxAttempts <= Self.maximumVisualSubsAttempts else {
                throw AppError(
                    "--max-attempts supports at most \(Self.maximumVisualSubsAttempts) (got \(options.maxAttempts)).")
            }
        }

        return options
    }

    func fadeOutSpec() throws -> FadeOutSpec {
        guard actionArgs.count == 2 else {
            throw AppError(
                "'-fadeout' requires exactly two positional values: START DURATION. Example: converter -fadeout 1:30 10"
            )
        }
        let fadeStartSeconds = try parseFlexibleTimecode(actionArgs[0], label: "fade start")
        let fadeDurationSeconds = try parseFlexibleTimecode(actionArgs[1], label: "fade duration")
        guard fadeDurationSeconds > 0 else {
            throw AppError("Fade duration must be greater than zero.")
        }
        return FadeOutSpec(fadeStartSeconds: fadeStartSeconds, fadeDurationSeconds: fadeDurationSeconds)
    }

    func tailFadeSeconds(defaultSeconds: Double = 10) throws -> Double {
        guard actionArgs.count <= 1 else {
            throw AppError("'-fade' accepts at most one positional duration. Example: converter -fade 10")
        }
        guard let rawValue = actionArgs.first else {
            return defaultSeconds
        }
        let seconds = try parseFlexibleTimecode(rawValue, label: "fade duration")
        guard seconds > 0 else {
            throw AppError("Fade duration must be greater than zero.")
        }
        return seconds
    }

    func fadeCutSpec() throws -> FadeCutSpec {
        guard actionArgs.count == 2 else {
            throw AppError(
                "'-fadecut' requires two positional values: CUT_SECONDS FADE_SECONDS. Example: converter -fadecut 5 10")
        }
        let cutSeconds = try parseFlexibleTimecode(actionArgs[0], label: "cut duration")
        let fadeDurationSeconds = try parseFlexibleTimecode(actionArgs[1], label: "fade duration")
        guard fadeDurationSeconds > 0 else {
            throw AppError("Fade duration must be greater than zero.")
        }
        return FadeCutSpec(cutSeconds: cutSeconds, fadeDurationSeconds: fadeDurationSeconds)
    }

    func silenceSpec(defaultSeconds: Double = 30) throws -> SilenceSpec {
        guard actionArgs.count <= 1 else {
            throw AppError("'-silence' accepts at most one positional duration. Example: converter -silence 45")
        }
        guard let rawValue = actionArgs.first else {
            return SilenceSpec(seconds: defaultSeconds)
        }
        let seconds = try parseFlexibleTimecode(rawValue, label: "silence duration")
        guard seconds >= Self.minimumPaddingSeconds else {
            throw AppError(
                "Silence duration must be at least \(Self.minimumPaddingSeconds) seconds so the padding is measurable.")
        }
        return SilenceSpec(seconds: seconds)
    }

    func noiseSpec(defaultSeconds: Double = 30) throws -> NoiseSpec {
        guard actionArgs.count <= 1 else {
            throw AppError("'-noise' accepts at most one positional duration. Example: converter -noise 45")
        }
        guard let rawValue = actionArgs.first else {
            return NoiseSpec(seconds: defaultSeconds)
        }
        let seconds = try parseFlexibleTimecode(rawValue, label: "noise duration")
        guard seconds >= Self.minimumPaddingSeconds else {
            throw AppError(
                "Noise duration must be at least \(Self.minimumPaddingSeconds) seconds so the padding is measurable.")
        }
        return NoiseSpec(seconds: seconds)
    }

    func bassBoostSpec() throws -> BassBoostSpec {
        guard actionArgs.isEmpty || actionArgs.count == 2 else {
            throw AppError("'-bass' accepts either no values or FREQUENCY_HZ GAIN_DB. Example: converter -bass 80 5")
        }
        if actionArgs.isEmpty {
            return BassBoostSpec(
                frequencyHz: BassBoostSpec.defaultFrequencyHz,
                gainDB: BassBoostSpec.defaultGainDB
            )
        }
        guard let frequency = Double(actionArgs[0]), frequency.isFinite, frequency > 0 else {
            throw AppError("Bass frequency must be a positive number of Hz.")
        }
        guard let gain = Double(actionArgs[1]), gain.isFinite else {
            throw AppError("Bass gain must be a finite number of dB.")
        }
        return BassBoostSpec(frequencyHz: frequency, gainDB: gain)
    }

    func loudnessSpec() throws -> LoudnessSpec {
        guard actionArgs.count <= 1 else {
            throw AppError("'-loudness' accepts an optional TARGET_LUFS. Example: converter -loudness -12")
        }
        if actionArgs.isEmpty {
            return LoudnessSpec(targetLUFS: LoudnessSpec.defaultTargetLUFS)
        }
        guard let target = Double(actionArgs[0]), target.isFinite else {
            throw AppError("Loudness target must be a finite LUFS value, for example -12.")
        }
        guard target <= LoudnessSpec.maximumTargetLUFS else {
            throw AppError(
                "Loudness target must be at or below \(ffmpegNumber(LoudnessSpec.maximumTargetLUFS)) LUFS "
                    + "because ffmpeg loudnorm supports \(ffmpegNumber(LoudnessSpec.minimumTargetLUFS)) "
                    + "to \(ffmpegNumber(LoudnessSpec.maximumTargetLUFS)) LUFS."
            )
        }
        guard target >= LoudnessSpec.minimumTargetLUFS else {
            throw AppError("Loudness target is too low for practical livestream normalization: \(target) LUFS")
        }
        return LoudnessSpec(targetLUFS: target)
    }

    func printActionList() {
        let lines = [
            "Available actions:",
            "  --hash", "  -album", "  -bass", "  -doctor", "  -fade", "  -fadecut", "  -fadeout", "  -full", "  -run",
            "  -short", "  -run_pix", "  -aipix", "  -clean", "  -fadewav",
            "  -flactoalbum", "  -flactohash", "  -flactom4a", "  -flactomp3", "  -flactowav",
            "  -jpgtopng", "  -m4atoflac", "  -m4atomp3", "  -m4atomp4", "  -m4atowav",
            "  -loudscan", "  -loudness", "  -master", "  -matrix", "  -mp3clean", "  -mp3toalbum", "  -mp3toflac",
            "  -mp3tohash",
            "  -mp3tom4a", "  -mp3towav", "  -mp4toshort", "  -nfttoshort", "  -pngto2k", "  -pngto3k",
            "  -pngto3k1mb", "  -pngto3k5mb", "  -pngtojpg", "  -pngtonft", "  -pngtojpg1mb",
            "  -pngtojpg2mb", "  -pngtojpg20mb", "  -noise", "  -silence", "  -visualsubs", "  -wavtoalbum",
            "  -wavtoflac", "  -wavtohash", "  -wavtom4a", "  -wavtomp3"
        ]
        print(lines.joined(separator: "\n"))
    }

    func conversionMatrixText() -> String {
        """
        Converter format matrix

        Audio formats:
          Formats: flac, wav, mp3, m4a
          flac -> wav, mp3, m4a
          wav  -> flac, mp3, m4a
          mp3  -> flac, wav, m4a
          m4a  -> flac, wav, mp3

        Image formats:
          Formats: png, jpg/jpeg
          png      -> jpg
          jpg/jpeg -> png
          Notes:
            - JPEG input scanning always accepts both .jpg and .jpeg.
            - JPEG output writing uses the preferred .jpg extension.
            - Sized JPG exports such as _1MB/_2MB/_20MB remain available as specialized PNG -> JPG actions.

        Video formats:
          Formats currently used: mp4
          Base-format matrix is complete because mp4 is the only current video container in the project.
          Existing video transforms:
            - m4a + *_8K.png -> mp4
            - audio + image -> short mp4
            - mp4 -> short mp4
        """
    }

    func helpText() -> String {
        """
        Usage:
          \(scriptName)                 # show this help
          \(scriptName) -album
          \(scriptName) --hash
          \(scriptName) -bass
          \(scriptName) -bass 80 5
          \(scriptName) -bass 80 -5
          \(scriptName) -loudscan
          \(scriptName) -loudness
          \(scriptName) -loudness -13
          \(scriptName) -doctor
          \(scriptName) -fade 10
          \(scriptName) -fadecut 5 10
          \(scriptName) -fadeout 1:30 10
          \(scriptName) -noise
          \(scriptName) -noise 45
          \(scriptName) -silence
          \(scriptName) -silence 45
          \(scriptName) -short
          \(scriptName) -full
          \(scriptName) -flactomp3
          \(scriptName) -m4atomp4
          \(scriptName) -matrix
          \(scriptName) -visualsubs 9 --output-file dots.png

        Profiles:
          Built-in profiles: youtube_master, youtube_short, fast_preview
          Use: --profile NAME
          Default: config-driven if PROFILE is set, otherwise youtube_master

        Full run:
          Use: -full / -run
          Source directory: '\(srcDir.path)'
          Required inputs:
            - Either exactly 1 source image (.png/.jpg/.jpeg), or direct 8K PNG inputs:
              Horizontal_8K.png for the main MP4 and optional Vertical_8K.png for the short MP4.
            - If both Horizontal_8K.png and Vertical_8K.png are present, full run renders the main MP4 first,
              then renders the short directly from Vertical_8K.png.
            - If Vertical_8K.png is absent, a discovered portrait source image is used for the fitted
              short; failing that, *_NFT8K.png is used or created, centered in the portrait frame
              with black top/bottom padding.
            - Exactly 1 source audio file: .flac or .wav or .mp3. It is renamed to 1_source.<ext>
              (with its _RF64/_BW64 companions) before the run, and every deliverable is named 1.*.
          Full-run result:
            - Image deliverables: 8K/4K PNG, NFT PNGs, 3K/2K PNG, JPG exports, and both portrait
              short framings as stills: *_Short_8K.png / *_Short_CenterCut_8K.png plus _1MB/_2MB JPGs
              Direct Horizontal_8K.png/Vertical_8K.png inputs are used as-is for videos; Horizontal_8K.png still derives companion image deliverables.
            - Audio/video deliverables: WAV, M4A, MP3, main MP4, and four portrait shorts:
              _8K_Short.mp4 (fitted, black padding) and _8K_Short_CenterCut.mp4 (centre of the 8K
              master, fills the frame); each gains a _FullSong companion when the audio is longer
              than the cap, min(SHORT_MP4_CLIP_SECONDS, 58) seconds
            - External audio deliverables: *_RF64.flac, *_RF64.wav, *_BW64.wav
              These archival companions are delivery-only and are not reused as full-run source inputs.

        Album run:
          Use: -album
          Input: two or more .mp3, .wav, or .flac files in SRC_DIR plus the same full-run image inputs.
          Order: natural numeric filename order.
          Output: one loudness-normalized RF64 album WAV, then the same audio/video deliverables as -run.

        Manual actions by input type:

          Audio actions:
            --hash
              Input: any mix of .wav, .flac, .mp3, and .mp4 files in SRC_DIR
              Output: all found .wav, .flac, .mp3, and .mp4 files renamed to CRC32-based filenames
            -bass [FREQUENCY_HZ GAIN_DB]
              Input: one or more .flac, .wav, .mp3, .m4a, or .mp4 files in SRC_DIR
              Output: same-format files with bass adjustment applied; default is 0-80 Hz boosted by 5 dB; negative gain reduces bass
            -loudscan
              Input: one or more .flac, .wav, .mp3, .m4a, or .mp4 files in SRC_DIR
              Output: four terminal report lines: average, lowest, highest, and top-3 loudest average
            -loudness [TARGET_LUFS]
              Input: one or more .flac, .wav, .mp3, .m4a, or .mp4 files in SRC_DIR
              Output: same-format files normalized to TARGET_LUFS for livestream-consistent playback; default is -12 LUFS
            -master
              Input: one or more .flac, .wav, .mp3, .m4a, or .mp4 files in SRC_DIR
              Output: same-format _mastered files; stages through the internal WAV and remediates loudness
                to the mastering target (-12 LUFS default) with two-pass loudnorm when the source is out of policy
            -noise [SECONDS]
              Input: one or more .flac, .wav, .mp3, .m4a, or .mp4 files in SRC_DIR
              Output: same-format files ending in _noise_SECONDSs: noise, 2s silence, source, 2s silence, noise; noise is -12 LUFS and default is 30 seconds; SECONDS must be at least 0.5
            -silence [SECONDS]
              Input: one or more .wav, .flac, or .mp4 files in SRC_DIR
              Output: same-format files ending in _silence_SECONDSs with SECONDS of silence before and after the original media; default is 30 seconds; SECONDS must be at least 0.5
            -short
              Input: exactly 1 image (.png/.jpg/.jpeg) plus exactly 1 audio-only file supported by ffmpeg in SRC_DIR
              Output: ALAC-audio portrait shorts capped at 58 seconds — _8K_Short.mp4 fits the image into the
                frame with black padding, _8K_Short_CenterCut.mp4 crops the centre of the 8K master to fill the
                frame with no padding; each gains a _FullSong companion when the audio is longer than 58 seconds
            -flactowav
              Input: one or more .flac files in SRC_DIR
              Output: project-standard RF64 WAV files
            -flactomp3
              Input: one or more .flac files in SRC_DIR
              Output: .mp3 files
            -flactom4a
              Input: one or more .flac files in SRC_DIR
              Output: .m4a files
            -flactoalbum
              Input: one or more .flac files in SRC_DIR
              Output: one RF64 album WAV
            -flactohash
              Input: one or more .flac files in SRC_DIR
              Output: same files renamed to CRC32-based .flac names

            -m4atowav
              Input: one or more .m4a files in SRC_DIR
              Output: project-standard RF64 WAV files
            -m4atomp3
              Input: one or more .m4a files in SRC_DIR
              Output: .mp3 files
            -m4atoflac
              Input: one or more .m4a files in SRC_DIR
              Output: .flac files

            -mp3toflac
              Input: one or more .mp3 files in SRC_DIR
              Output: .flac files
            -mp3towav
              Input: one or more .mp3 files in SRC_DIR
              Output: project-standard RF64 WAV files
            -mp3tom4a
              Input: one or more .mp3 files in SRC_DIR
              Output: .m4a files
            -nfttoshort
              Input: exactly 1 audio-only file supported by ffmpeg plus exactly 1 source image (.png/.jpg/.jpeg) or exactly 1 *_8K.png in SRC_DIR
              Output: ALAC-audio portrait shorts capped at 58 seconds, preserving source loudness — _8K_Short.mp4
                uses Vertical_8K.png when present, otherwise *_NFT8K.png with black padding;
                _8K_Short_CenterCut.mp4 crops the centre of the 8K master to fill the frame; each gains a
                _FullSong companion when the audio is longer
            -mp3clean
              Input: one or more .mp3 files in SRC_DIR
              Output: same .mp3 files rewritten as audio-only MP3 with artwork, junk streams, and metadata removed
            -mp3toalbum
              Input: album.txt order file plus referenced .mp3 files
              Output: one RF64 album WAV joined in listed order without loudness normalization; use -album for a normalized directory build
            -mp3tohash
              Input: one or more .mp3 files in SRC_DIR
              Output: same files renamed to CRC32-based .mp3 names

            -wavtom4a
              Input: one or more .wav files in SRC_DIR
              Output: .m4a files
            -wavtomp3
              Input: one or more .wav files in SRC_DIR
              Output: .mp3 files
            -wavtoflac
              Input: one or more .wav files in SRC_DIR
              Output: .flac files
            -fade [SECONDS]
              Input: one or more audio files (.flac, .wav, .mp3) in SRC_DIR
              Output: full-length same-format files ending in _faded_SECONDSs after fading the final SECONDS
              Default: 10 seconds when SECONDS is omitted
              Compatibility: -fadeflac is accepted as an alias for -fade
            -fadecut CUT_SECONDS FADE_SECONDS
              Input: one or more audio files (.flac, .wav, .mp3) in SRC_DIR
              Output: same-format files ending in _fadecut_CUT_SECONDSs_FADE_SECONDSs after removing CUT_SECONDS from the end,
                then applying a normal fade over the final FADE_SECONDS of the shortened file
            -fadeout START DURATION
              Input: one or more audio files (.flac, .wav, .mp3, .m4a) in SRC_DIR
              Output: same-format files ending in _fadeout_STARTs_DURATIONs after fading from START for DURATION and truncating at START + DURATION
              Time format: seconds, MM:SS, or HH:MM:SS
            -fadewav
              Input: one or more .wav files in SRC_DIR
              Output: faded RF64 WAV files
            -wavtoalbum
              Input: album.txt order file plus referenced .wav files
              Output: one RF64 album WAV joined in listed order without loudness normalization; use -album for a normalized directory build
            -wavtohash
              Input: one or more .wav files in SRC_DIR
              Output: same files renamed to CRC32-based .wav names

          Picture actions:
            -jpgtopng
              Input: one or more .jpg or .jpeg files in SRC_DIR
              Output: .png files
            -pngtojpg
              Input: one or more .png files in SRC_DIR
              Output: .jpg files
            -aipix
              Input: one or more .png files in SRC_DIR
              Output: _8K.png and _4K.png variants
            -pngtonft
              Input: one or more *_8K.png files in SRC_DIR
              Output: _NFT8K.png, _NFT3K.png, _NFT2K.png
            -pngto3k
              Input: one or more *_8K.png files in SRC_DIR
              Output: _3K.png
            -pngto2k
              Input: one or more *_8K.png files in SRC_DIR
              Output: _2K.png
            -pngto3k1mb
              Input: one or more *_3K.png files in SRC_DIR
              Output: _1MB.jpg
            -pngto3k5mb
              Input: one or more *_3K.png files in SRC_DIR
              Output: _5MB.jpg
            -pngtojpg1mb
              Input: one or more *_8K.png files in SRC_DIR
              Output: _1MB.jpg
            -pngtojpg2mb
              Input: one or more *_8K.png files in SRC_DIR
              Output: _2MB.jpg
            -pngtojpg20mb
              Input: one or more *_8K.png files in SRC_DIR
              Output: _20MB.jpg
            -run_pix
              Input: one or more source images (.png, .jpg, .jpeg) in SRC_DIR
              Output: full image-only pipeline deliverables
            -visualsubs
              Input: dot count via --num-dots N or positional number
              Output: generated PNG image

          Video actions:
            -m4atomp4
              Input: exactly 1 *_8K.png image and exactly 1 .m4a audio
              Output: main MP4
            -mp4toshort
              Input: one or more .mp4 files in SRC_DIR
              Output: _Short.mp4 portrait clips capped at 58 seconds

          Maintenance:
            -doctor
              Input: no media files required
              Output: validates toolchain, config, encoder/filter support, directories, and optionally current source media
            -clean
              Input: no special source file requirement
              Output: removes transient/temp files from OUT_DIR
            -matrix
              Input: no source files required
              Output: prints the supported conversion matrix

        Common options:
          --config FILE
          --profile NAME
          --src-dir DIR
          --out-dir DIR
          --output-dir DIR
          --output-file FILE
            FILE must resolve directly inside OUT_DIR; subfolders are rejected.
          --overwrite
          --keep-full-name
            Keep trailing derivative markers such as _8K/_4K/_3K/_2K in image output stems.
            Default: those known markers are stripped before the new suffix is added.
          --lowercase-prefix
          --no-recursive
            Accepted for compatibility; scanning is always limited to the current SRC_DIR/Output folder.
          --continue-on-error
          --trailing-silence
          --sharpness FLOAT
          --sleep-seconds FLOAT
          --num-dots N
          --dot-size N
          --max-attempts N
          --seed N
          --open
          --debug
          -help
          -list

        Notes:
          - Required media inputs are auto-discovered from SRC_DIR. By default that is the Output folder.
          - SRC_DIR is the input scan directory. OUT_DIR is the output write directory.
          - Use --src-dir and --out-dir to override both.
          - Use --output-file FILE when a single final file should use a custom path/name.
        """
    }
}
