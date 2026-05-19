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
    case noise
    case silence
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
    case mp3toshort
    case mp3towav
    case mp4toshort
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

struct CLIOptions {
    var action: Action = .full
    var debug = false
    var verbose = false
    var overwrite = false
    var recursive = false
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
    var sleepSeconds: Double = 0
    var sharpnessOverride: Double?
    var actionArgs: [String] = []

    var configFile: URL
    var srcDir: URL
    var outDir: URL
    var srcDirExplicit: Bool
    var outDirExplicit: Bool

    let scriptDirectory: URL
    let scriptName: String

    static func parse(arguments: [String], environment: [String: String], scriptDirectory: URL, scriptName: String) throws -> CLIOptions {
        let outputBase = environment["OUTPUT_DIR"]
        let envSrc = environment["SRC_DIR"] ?? outputBase
        let envOut = environment["OUT_DIR"] ?? outputBase
        let defaultIO = scriptDirectory.appendingPathComponent("Output", isDirectory: true)

        var options = CLIOptions(
            configFile: URL(fileURLWithPath: environment["CONFIG_FILE"] ?? scriptDirectory.appendingPathComponent("config.txt").path),
            srcDir: URL(fileURLWithPath: envSrc ?? defaultIO.path),
            outDir: URL(fileURLWithPath: envOut ?? defaultIO.path),
            srcDirExplicit: environment.keys.contains("SRC_DIR") || environment.keys.contains("OUTPUT_DIR"),
            outDirExplicit: environment.keys.contains("OUT_DIR") || environment.keys.contains("OUTPUT_DIR"),
            scriptDirectory: scriptDirectory,
            scriptName: scriptName
        )
        options.debug = [environment["DEBUG"]].compactMap { $0 }.contains { ["1", "true", "yes", "on"].contains($0.lowercasedASCII) }

        var index = 0
        func requireValue(_ flag: String) throws -> String {
            let next = index + 1
            guard next < arguments.count else {
                throw AppError("Missing value for \(flag)")
            }
            index += 1
            return arguments[next]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-bass":
                options.action = .bass
            case "-album":
                options.action = .album
            case "-doctor":
                options.action = .doctor
            case "-fade", "-fadeflac":
                options.action = .fade
            case "-fadecut":
                options.action = .fadecut
            case "-fadeout":
                options.action = .fadeout
            case "--hash", "-hash":
                options.action = .hash
            case "-loudness":
                options.action = .loudness
            case "-loudscan", "-loundscan":
                options.action = .loudscan
            case "-noise":
                options.action = .noise
            case "-silence":
                options.action = .silence
            case "-full", "-run":
                options.action = .full
            case "-run_pix":
                options.action = .runPix
            case "-aipix": options.action = .aipix
            case "-clean": options.action = .clean
            case "-fadewav": options.action = .fadewav
            case "-flactoalbum": options.action = .flactoalbum
            case "-flactohash": options.action = .flactohash
            case "-flactom4a": options.action = .flactom4a
            case "-flactomp3": options.action = .flactomp3
            case "-flactowav": options.action = .flactowav
            case "-jpgtopng": options.action = .jpgtopng
            case "-jpegtopng":
                throw AppError("-jpegtopng was removed. Use -jpgtopng; it reads both .jpg and .jpeg inputs.")
            case "-m4atomp4": options.action = .m4atomp4
            case "-m4atoflac": options.action = .m4atoflac
            case "-m4atomp3": options.action = .m4atomp3
            case "-m4atowav": options.action = .m4atowav
            case "-matrix", "--matrix": options.action = .matrix
            case "-mp3clean": options.action = .mp3clean
            case "-mp3toalbum": options.action = .mp3toalbum
            case "-mp3toflac": options.action = .mp3toflac
            case "-mp3tohash": options.action = .mp3tohash
            case "-mp3tom4a": options.action = .mp3tom4a
            case "-mp3toshort": options.action = .mp3toshort
            case "-mp3towav": options.action = .mp3towav
            case "-mp4toshort": options.action = .mp4toshort
            case "-pngto2k": options.action = .pngto2k
            case "-pngto3k": options.action = .pngto3k
            case "-pngto3k1mb": options.action = .pngto3k1mb
            case "-pngto3k5mb": options.action = .pngto3k5mb
            case "-pngtojpeg":
                throw AppError("-pngtojpeg was removed. Use -pngtojpg; converter writes JPEG outputs with the preferred .jpg extension.")
            case "-pngtojpg": options.action = .pngtojpg
            case "-pngtonft": options.action = .pngtonft
            case "-pngtojpg1mb": options.action = .pngtojpg1mb
            case "-pngtojpg2mb": options.action = .pngtojpg2mb
            case "-pngtojpg20mb": options.action = .pngtojpg20mb
            case "-visualsubs": options.action = .visualsubs
            case "-wavtoalbum": options.action = .wavtoalbum
            case "-wavtoflac": options.action = .wavtoflac
            case "-wavtohash": options.action = .wavtohash
            case "-wavtom4a": options.action = .wavtom4a
            case "-wavtomp3": options.action = .wavtomp3
            case "-help", "--help": options.action = .help
            case "-list", "--list": options.action = .list
            case "--config":
                options.configFile = URL(fileURLWithPath: try requireValue(argument))
            case "--profile":
                options.profileName = try requireValue(argument)
            case "--src-dir":
                options.srcDir = URL(fileURLWithPath: try requireValue(argument))
                options.srcDirExplicit = true
            case "--out-dir":
                options.outDir = URL(fileURLWithPath: try requireValue(argument))
                options.outDirExplicit = true
            case "--output-dir":
                let path = try requireValue(argument)
                let url = URL(fileURLWithPath: path)
                options.srcDir = url
                options.outDir = url
                options.srcDirExplicit = true
                options.outDirExplicit = true
            case "--image", "--image-file":
                _ = try requireValue(argument)
                throw AppError("\(argument) is no longer supported. Converter auto-discovers required image inputs from SRC_DIR/Output.")
            case "--audio", "--audio-file":
                _ = try requireValue(argument)
                throw AppError("\(argument) is no longer supported. Converter auto-discovers required audio inputs from SRC_DIR/Output.")
            case "--album-file":
                _ = try requireValue(argument)
                throw AppError("\(argument) is no longer supported. Album actions always read album.txt from the project root.")
            case "--output-file":
                options.outputFile = try requireValue(argument)
            case "--overwrite":
                options.overwrite = true
            case "--keep-full-name":
                options.keepFullName = true
            case "--lowercase-prefix":
                options.lowercasePrefix = true
            case "--recursive":
                throw AppError("--recursive is no longer supported. Converter only scans the current SRC_DIR/Output folder.")
            case "--no-recursive":
                options.recursive = false
            case "--continue-on-error":
                options.continueOnError = true
            case "--trailing-silence":
                options.trailingSilence = true
            case "--sharpness":
                guard let value = Double(try requireValue(argument)) else {
                    throw AppError("--sharpness requires a numeric value")
                }
                options.sharpnessOverride = value
            case "--sleep-seconds":
                guard let value = Double(try requireValue(argument)) else {
                    throw AppError("--sleep-seconds requires a numeric value")
                }
                options.sleepSeconds = value
            case "--num-dots":
                guard let value = Int(try requireValue(argument)), value > 0 else {
                    throw AppError("--num-dots requires a positive integer")
                }
                options.numDots = value
            case "--dot-size":
                guard let value = Int(try requireValue(argument)), value > 0 else {
                    throw AppError("--dot-size requires a positive integer")
                }
                options.dotSize = value
            case "--max-attempts":
                guard let value = Int(try requireValue(argument)), value > 0 else {
                    throw AppError("--max-attempts requires a positive integer")
                }
                options.maxAttempts = value
            case "--seed":
                guard let value = UInt64(try requireValue(argument)) else {
                    throw AppError("--seed requires a positive integer")
                }
                options.seed = value
            case "--open":
                options.openAfterCreate = true
            case "--debug", "--verbose":
                options.debug = true
                options.verbose = true
            case "--":
                if index + 1 < arguments.count {
                    options.actionArgs.append(contentsOf: arguments[(index + 1)...])
                }
                index = arguments.count
                continue
            default:
                options.actionArgs.append(argument)
            }
            index += 1
        }

        return options
    }

    func fadeOutSpec() throws -> FadeOutSpec {
        guard actionArgs.count >= 2 else {
            throw AppError("'-fadeout' requires two positional values: START DURATION. Example: converter -fadeout 1:30 10")
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
            throw AppError("'-fadecut' requires two positional values: CUT_SECONDS FADE_SECONDS. Example: converter -fadecut 5 10")
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
        guard seconds > 0 else {
            throw AppError("Silence duration must be greater than zero.")
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
        guard seconds > 0 else {
            throw AppError("Noise duration must be greater than zero.")
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
            throw AppError("Loudness target must be at or below \(ffmpegNumber(LoudnessSpec.maximumTargetLUFS)) LUFS because ffmpeg loudnorm supports \(ffmpegNumber(LoudnessSpec.minimumTargetLUFS)) to \(ffmpegNumber(LoudnessSpec.maximumTargetLUFS)) LUFS.")
        }
        guard target >= LoudnessSpec.minimumTargetLUFS else {
            throw AppError("Loudness target is too low for practical livestream normalization: \(target) LUFS")
        }
        return LoudnessSpec(targetLUFS: target)
    }

    func printActionList() {
        let lines = [
            "Available actions:",
            "  --hash", "  -album", "  -bass", "  -doctor", "  -fade", "  -fadecut", "  -fadeout", "  -full", "  -run", "  -run_pix", "  -aipix", "  -clean", "  -fadewav",
            "  -flactoalbum", "  -flactohash", "  -flactom4a", "  -flactomp3", "  -flactowav",
            "  -jpgtopng", "  -m4atoflac", "  -m4atomp3", "  -m4atomp4", "  -m4atowav",
            "  -loudscan", "  -loudness", "  -matrix", "  -mp3clean", "  -mp3toalbum", "  -mp3toflac", "  -mp3tohash",
            "  -mp3tom4a", "  -mp3toshort", "  -mp3towav", "  -mp4toshort", "  -pngto2k", "  -pngto3k",
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
            - mp4 -> short mp4
        """
    }

    func helpText() -> String {
        """
        Usage:
          \(scriptName)
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
          \(scriptName) -full
          \(scriptName) -flactomp3
          \(scriptName) -m4atomp4
          \(scriptName) -matrix
          \(scriptName) -visualsubs 9 --output-file dots.png

        Profiles:
          Built-in profiles: youtube_master, youtube_short, archive, fast_preview
          Use: --profile NAME
          Default: config-driven if PROFILE is set, otherwise youtube_master

        Full run:
          Default action with no parameter, or use: -full / -run
          Source directory: '\(srcDir.path)'
          Required inputs:
            - Either exactly 1 source image (.png/.jpg/.jpeg), or direct 8K PNG inputs:
              Horizontal_8K.png for the main MP4 and optional Vertical_8K.png for the short MP4.
            - If both Horizontal_8K.png and Vertical_8K.png are present, full run renders the main MP4 first,
              then renders the short directly from Vertical_8K.png.
            - Exactly 1 source audio file: .flac or .wav or .mp3
          Full-run result:
            - Image deliverables: 8K/4K PNG, NFT PNGs, 3K/2K PNG, JPG exports
              Direct Horizontal_8K.png/Vertical_8K.png inputs are used as-is and skip source-image derivation.
            - Audio/video deliverables: WAV, M4A, MP3, main MP4, short MP4
            - External audio deliverables: *_RF64.flac, *_RF64.wav, *_BW64.flac, *_BW64.wav
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
            -noise [SECONDS]
              Input: one or more .flac, .wav, .mp3, .m4a, or .mp4 files in SRC_DIR
              Output: same-format files ending in _noise_SECONDSs with random noise at -12 LUFS before and after the original media; default is 30 seconds
            -silence [SECONDS]
              Input: one or more .wav, .flac, or .mp4 files in SRC_DIR
              Output: same-format files ending in _silence_SECONDSs with SECONDS of silence before and after the original media; default is 30 seconds
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
            -mp3toshort
              Input: exactly 1 .mp3 file plus exactly 1 source image (.png/.jpg/.jpeg) or exactly 1 *_8K.png in SRC_DIR
              Output: short-ready MP3 normalization when needed, ALAC M4A intermediate, and ALAC-audio _Short.mp4 capped at 58 seconds; preserves source MP3 loudness; landscape 8K inputs also create a main MP4, portrait 8K inputs render the short directly
            -mp3clean
              Input: one or more .mp3 files in SRC_DIR
              Output: same .mp3 files rewritten as audio-only MP3 with artwork, junk streams, and metadata removed
            -mp3toalbum
              Input: album.txt order file plus referenced .mp3 files
              Output: one RF64 album WAV
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
              Output: full-length same-format files ending in _faded after fading the final SECONDS
              Default: 10 seconds when SECONDS is omitted
              Compatibility: -fadeflac is accepted as an alias for -fade
            -fadecut CUT_SECONDS FADE_SECONDS
              Input: one or more audio files (.flac, .wav, .mp3) in SRC_DIR
              Output: same-format files ending in _fadecut after removing CUT_SECONDS from the end,
                then applying a normal fade over the final FADE_SECONDS of the shortened file
            -fadeout START DURATION
              Input: one or more audio files (.flac, .wav, .mp3, .m4a) in SRC_DIR
              Output: same-format files ending in _faded after fading from START for DURATION and truncating at START + DURATION
              Time format: seconds, MM:SS, or HH:MM:SS
            -fadewav
              Input: one or more .wav files in SRC_DIR
              Output: faded RF64 WAV files
            -wavtoalbum
              Input: album.txt order file plus referenced .wav files
              Output: one RF64 album WAV
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
            Full source stems are now preserved by default for output safety.
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
