import Foundation

enum RunProfile: String, CaseIterable, Sendable {
    case youtubeMaster = "youtube_master"
    case youtubeShort = "youtube_short"
    case fastPreview = "fast_preview"
}

struct ProjectConfig {
    var profileName = RunProfile.youtubeMaster.rawValue

    var preflightSeconds = 2
    var durationToleranceSec = 2.0
    var crcChunkBytes = 8_388_608

    var wavSampleRate = 96_000
    var wavCodec = "pcm_s24le"
    var wavChannels = 2
    var wavWriteBext = 1
    let alacSampleFormat = "s32p"
    let alacBitsPerRawSample = 24

    var mp3SampleRate = 48_000
    var mp3Bitrate = "320k"
    var mp3Channels = 2
    var mp3MinBitrateBps = 300_000

    var flacSampleRate = 48_000
    var flacChannels = 2
    var flacCompressionLevel = 12

    var m4aSampleRate = 48_000
    var m4aChannels = 2

    var audioQCTargetLUFS = LoudnessSpec.defaultTargetLUFS
    var audioQCLUFSTolerance = 8.0
    var audioQCMaxTruePeakDBTP = -1.0
    var audioQCMaxLoudnessRange = 20.0
    var audioQCMaxDCOffset = 0.02
    var audioQCMaxStereoImbalanceDB = 2.0
    var audioQCMaxClippedSamples = 0
    var audioQCMinimumAnalysisSeconds = 3.0
    var shortAudioQCTargetLUFS = LoudnessSpec.defaultTargetLUFS
    var shortAudioQCLUFSTolerance = 8.0
    var shortAudioQCMaxLoudnessRange = 20.0

    var masteringTargetLUFS = LoudnessSpec.defaultTargetLUFS
    var masteringMaxTruePeakDBTP = -1.0
    var masteringMaxLoudnessRange = 20.0

    var videoMP4Encoder = "hevc_videotoolbox"
    var videoMP4EncoderFallbacks = "libx265"
    var videoMP4VTQuality = "70"
    var videoMP4SoftwarePreset = "slow"
    var videoMP4SoftwareCRF = "18"
    var videoMP4InputFPS = "2"
    var videoMP4AudioSampleRate = 48_000
    var videoMP4Width = 7680
    var videoMP4Height = 4320
    var videoMP4ScaleFilter = "lanczos"
    var videoMP4PixelFormat = "yuv420p"
    var videoMP4Tag = "hvc1"
    var videoMP4VerifyCodec = "hevc"
    var videoColorPrimaries = "bt709"
    var videoColorTransfer = "bt709"
    var videoColorSpace = "bt709"
    var videoColorRange = "tv"

    var shortMP4ClipSeconds = "58"
    var shortMP4FPS = "2"
    var shortMP4ScaleW = 4320
    var shortMP4ScaleH = 7680
    var shortMP4VideoPreset = "fast"
    var shortMP4VideoCRF = "18"
    var shortMP4VTQuality = "60"
    var shortMP4AudioSampleRate = 48_000
    var shortMP4VideoCodec = "libx264"
    var shortMP4VideoFallbacks = "h264_videotoolbox"
    var shortMP4PixelFormat = "yuv420p"
    var shortMP4VerifyCodec = "h264"

    var image8KWidth = 7680
    var image8KHeight = 4320
    var image4KWidth = 3840
    var image4KHeight = 2160
    var image3KSize = 3000
    var image2KSize = 2048
    var imageAIPixSharpness = 1.2
    // LanczosSharp measured best of the candidates on a 4x upscale; see ImagePipeline.resampleArguments.
    var imageAIPixFilter = "LanczosSharp"
    var imageAIPixPNGCompressionLevel = 1
    var imageJPGToPNGCompressionLevel = 0
    var imagePNGToJPEGQuality = 98
    var imageJpegSamplingFactor = "4:4:4"
    var imageOutputColorSpace = "sRGB"
    var image3KJPG1MBTargetBytes = 1_000_000
    var image3KJPG5MBTargetBytes = 5_190_451
    var image8KJPG1MBTargetBytes = 1_000_000
    var image8KJPG2MBTargetBytes = 2_097_152
    var image8KJPG20MBTargetBytes = 20_761_804

    var albumSilenceSecs = 2
    var wavFadeDur = 10

    // Sharpening beyond this cannot be justified visually and costs minutes per image; the
    // effective sigma is (value - 1) * 2, so 10 is already ~18.
    static let maximumAIPixSharpness = 10.0

    static let supportedKeys: Set<String> = [
        "PROFILE",
        "PREFLIGHT_SECONDS", "DURATION_TOLERANCE_SEC", "CRC_CHUNK_BYTES",
        "WAV_SAMPLE_RATE", "WAV_CODEC", "WAV_CHANNELS", "WAV_WRITE_BEXT",
        "MP3_SAMPLE_RATE", "MP3_BITRATE", "MP3_CHANNELS", "MP3_MIN_BITRATE_BPS",
        "FLAC_SAMPLE_RATE", "FLAC_CHANNELS", "FLAC_COMPRESSION_LEVEL",
        "M4A_SAMPLE_RATE", "M4A_CHANNELS",
        "AUDIO_QC_TARGET_LUFS", "AUDIO_QC_LUFS_TOLERANCE", "AUDIO_QC_MAX_TRUE_PEAK_DBTP",
        "AUDIO_QC_MAX_LOUDNESS_RANGE", "AUDIO_QC_MAX_DC_OFFSET", "AUDIO_QC_MAX_STEREO_IMBALANCE_DB",
        "AUDIO_QC_MAX_CLIPPED_SAMPLES", "AUDIO_QC_MINIMUM_ANALYSIS_SECONDS",
        "SHORT_AUDIO_QC_TARGET_LUFS", "SHORT_AUDIO_QC_LUFS_TOLERANCE", "SHORT_AUDIO_QC_MAX_LOUDNESS_RANGE",
        "MASTERING_TARGET_LUFS", "MASTERING_MAX_TRUE_PEAK_DBTP", "MASTERING_MAX_LOUDNESS_RANGE",
        "VIDEO_MP4_ENCODER", "VIDEO_MP4_ENCODER_FALLBACKS", "VIDEO_MP4_VT_QUALITY", "VIDEO_MP4_SOFTWARE_PRESET",
        "VIDEO_MP4_SOFTWARE_CRF", "VIDEO_MP4_INPUT_FPS",
        "VIDEO_MP4_AUDIO_SAMPLE_RATE", "VIDEO_MP4_WIDTH", "VIDEO_MP4_HEIGHT", "VIDEO_MP4_SCALE_FILTER",
        "VIDEO_MP4_PIXEL_FORMAT", "VIDEO_MP4_TAG", "VIDEO_MP4_VERIFY_CODEC",
        "VIDEO_COLOR_PRIMARIES", "VIDEO_COLOR_TRANSFER", "VIDEO_COLOR_SPACE", "VIDEO_COLOR_RANGE",
        "SHORT_MP4_CLIP_SECONDS", "SHORT_MP4_FPS", "SHORT_MP4_SCALE_W", "SHORT_MP4_SCALE_H",
        "SHORT_MP4_VIDEO_PRESET", "SHORT_MP4_VIDEO_CRF", "SHORT_MP4_VT_QUALITY",
        "SHORT_MP4_AUDIO_SAMPLE_RATE", "SHORT_MP4_VIDEO_CODEC", "SHORT_MP4_VIDEO_FALLBACKS", "SHORT_MP4_PIXEL_FORMAT",
        "SHORT_MP4_VERIFY_CODEC",
        "IMAGE_8K_WIDTH", "IMAGE_8K_HEIGHT", "IMAGE_4K_WIDTH", "IMAGE_4K_HEIGHT", "IMAGE_3K_SIZE",
        "IMAGE_2K_SIZE", "IMAGE_AIPIX_SHARPNESS", "IMAGE_AIPIX_FILTER", "IMAGE_AIPIX_PNG_COMPRESSION_LEVEL",
        "IMAGE_JPG_TO_PNG_COMPRESSION_LEVEL", "IMAGE_PNG_TO_JPEG_QUALITY", "IMAGE_JPEG_SAMPLING_FACTOR",
        "IMAGE_OUTPUT_COLORSPACE", "IMAGE_3K_JPG_1MB_TARGET_BYTES",
        "IMAGE_3K_JPG_5MB_TARGET_BYTES", "IMAGE_8K_JPG_1MB_TARGET_BYTES", "IMAGE_8K_JPG_2MB_TARGET_BYTES",
        "IMAGE_8K_JPG_20MB_TARGET_BYTES", "ALBUM_SILENCE_SECS", "WAV_FADE_DUR"
    ]

    static func load(from url: URL, environment: [String: String], cli: CLIOptions, logger: Logger) throws -> ProjectConfig {
        var config = ProjectConfig()
        var values: [String: String] = [:]

        if FileManager.default.fileExists(atPath: url.path) {
            let text = try String(contentsOf: url, encoding: .utf8)
            for rawLine in text.split(whereSeparator: \.isNewline) {
                let line = String(rawLine).trimmed
                if line.isEmpty || line.hasPrefix("#") {
                    continue
                }
                guard let separator = line.firstIndex(of: "=") else {
                    logger.warn("Ignoring invalid config line in \(url.path): \(line)")
                    continue
                }
                let key = String(line[..<separator]).trimmed
                var value = String(line[line.index(after: separator)...]).trimmed
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value.removeFirst()
                    value.removeLast()
                } else if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
                    value.removeFirst()
                    value.removeLast()
                }
                if !supportedKeys.contains(key) {
                    // A misspelled key is the one config mistake that fails silently: the setting it was
                    // meant to change keeps its default and every output still looks plausible. A debug
                    // line is invisible in a normal run, so this is a warning naming key and file. It is
                    // not an error because the wiki promises unknown keys are skipped, and a config.txt
                    // shared with a newer converter may legitimately carry keys this build does not know.
                    logger.warn("Ignoring unknown config key '\(key)' in \(url.path)")
                    continue
                }
                values[key] = value
            }
        }

        for (key, value) in environment where supportedKeys.contains(key) {
            values[key] = value
        }

        let selectedProfile = cli.profileName?.trimmed.nonEmpty
            ?? values["PROFILE"]?.trimmed.nonEmpty
            ?? config.profileName
        try config.applyBuiltInProfile(named: selectedProfile)
        config.profileName = selectedProfile

        for (key, value) in values where key != "PROFILE" {
            try config.apply(key: key, value: value)
        }

        if let sharpness = cli.sharpnessOverride {
            config.imageAIPixSharpness = sharpness
        }

        try config.validate()
        return config
    }

    mutating func applyBuiltInProfile(named rawName: String) throws {
        guard let profile = RunProfile(rawValue: rawName) else {
            throw AppError("PROFILE must be one of: \(RunProfile.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(rawName)')")
        }

        switch profile {
        case .youtubeMaster:
            break
        case .youtubeShort:
            // The short ladder keeps its default order (libx264 first, h264_videotoolbox as the
            // fallback): VideoToolbox cannot open an H.264 session at the 4320x7680 portrait size,
            // so putting it first only burned a failing rung and a warning per variant.
            shortMP4VTQuality = "65"
            shortAudioQCTargetLUFS = LoudnessSpec.defaultTargetLUFS
            shortAudioQCLUFSTolerance = 6.0
        case .fastPreview:
            videoMP4Encoder = "h264_videotoolbox"
            videoMP4EncoderFallbacks = "libx264"
            videoMP4VerifyCodec = "h264"
            videoMP4Tag = "avc1"
            videoMP4Width = 1920
            videoMP4Height = 1080
            shortMP4VideoCodec = "h264_videotoolbox"
            shortMP4VideoFallbacks = "libx264"
            // The portrait counterpart of the 1920x1080 preview; also keeps the short render inside
            // the h264_videotoolbox session limit this profile relies on for speed.
            shortMP4ScaleW = 1080
            shortMP4ScaleH = 1920
            image8KWidth = 1920
            image8KHeight = 1080
            image4KWidth = 1280
            image4KHeight = 720
            image3KSize = 1080
            image2KSize = 720
            imagePNGToJPEGQuality = 92
        }
    }

    var videoEncoderLadder: [String] {
        uniqueStrings([videoMP4Encoder] + commaSeparatedList(videoMP4EncoderFallbacks))
    }

    var shortVideoEncoderLadder: [String] {
        uniqueStrings([shortMP4VideoCodec] + commaSeparatedList(shortMP4VideoFallbacks))
    }

    mutating func apply(key: String, value: String) throws {
        switch key {
        case "PREFLIGHT_SECONDS": preflightSeconds = try parseInt(key, value)
        case "DURATION_TOLERANCE_SEC": durationToleranceSec = try parseDouble(key, value)
        case "CRC_CHUNK_BYTES": crcChunkBytes = try parseInt(key, value)
        case "WAV_SAMPLE_RATE": wavSampleRate = try parseInt(key, value)
        case "WAV_CODEC": wavCodec = value
        case "WAV_CHANNELS": wavChannels = try parseInt(key, value)
        case "WAV_WRITE_BEXT": wavWriteBext = try parseInt(key, value)
        case "MP3_SAMPLE_RATE": mp3SampleRate = try parseInt(key, value)
        case "MP3_BITRATE": mp3Bitrate = value
        case "MP3_CHANNELS": mp3Channels = try parseInt(key, value)
        case "MP3_MIN_BITRATE_BPS": mp3MinBitrateBps = try parseInt(key, value)
        case "FLAC_SAMPLE_RATE": flacSampleRate = try parseInt(key, value)
        case "FLAC_CHANNELS": flacChannels = try parseInt(key, value)
        case "FLAC_COMPRESSION_LEVEL": flacCompressionLevel = try parseInt(key, value)
        case "M4A_SAMPLE_RATE": m4aSampleRate = try parseInt(key, value)
        case "M4A_CHANNELS": m4aChannels = try parseInt(key, value)
        case "AUDIO_QC_TARGET_LUFS": audioQCTargetLUFS = try parseDouble(key, value)
        case "AUDIO_QC_LUFS_TOLERANCE": audioQCLUFSTolerance = try parseDouble(key, value)
        case "AUDIO_QC_MAX_TRUE_PEAK_DBTP": audioQCMaxTruePeakDBTP = try parseDouble(key, value)
        case "AUDIO_QC_MAX_LOUDNESS_RANGE": audioQCMaxLoudnessRange = try parseDouble(key, value)
        case "AUDIO_QC_MAX_DC_OFFSET": audioQCMaxDCOffset = try parseDouble(key, value)
        case "AUDIO_QC_MAX_STEREO_IMBALANCE_DB": audioQCMaxStereoImbalanceDB = try parseDouble(key, value)
        case "AUDIO_QC_MAX_CLIPPED_SAMPLES": audioQCMaxClippedSamples = try parseInt(key, value)
        case "AUDIO_QC_MINIMUM_ANALYSIS_SECONDS": audioQCMinimumAnalysisSeconds = try parseDouble(key, value)
        case "SHORT_AUDIO_QC_TARGET_LUFS": shortAudioQCTargetLUFS = try parseDouble(key, value)
        case "SHORT_AUDIO_QC_LUFS_TOLERANCE": shortAudioQCLUFSTolerance = try parseDouble(key, value)
        case "SHORT_AUDIO_QC_MAX_LOUDNESS_RANGE": shortAudioQCMaxLoudnessRange = try parseDouble(key, value)
        case "MASTERING_TARGET_LUFS": masteringTargetLUFS = try parseDouble(key, value)
        case "MASTERING_MAX_TRUE_PEAK_DBTP": masteringMaxTruePeakDBTP = try parseDouble(key, value)
        case "MASTERING_MAX_LOUDNESS_RANGE": masteringMaxLoudnessRange = try parseDouble(key, value)
        case "VIDEO_MP4_ENCODER": videoMP4Encoder = value
        case "VIDEO_MP4_ENCODER_FALLBACKS": videoMP4EncoderFallbacks = value
        case "VIDEO_MP4_VT_QUALITY": videoMP4VTQuality = value
        case "VIDEO_MP4_SOFTWARE_PRESET": videoMP4SoftwarePreset = value
        case "VIDEO_MP4_SOFTWARE_CRF": videoMP4SoftwareCRF = value
        case "VIDEO_MP4_INPUT_FPS": videoMP4InputFPS = value
        case "VIDEO_MP4_AUDIO_SAMPLE_RATE": videoMP4AudioSampleRate = try parseInt(key, value)
        case "VIDEO_MP4_WIDTH": videoMP4Width = try parseInt(key, value)
        case "VIDEO_MP4_HEIGHT": videoMP4Height = try parseInt(key, value)
        case "VIDEO_MP4_SCALE_FILTER": videoMP4ScaleFilter = value
        case "VIDEO_MP4_PIXEL_FORMAT": videoMP4PixelFormat = value
        case "VIDEO_MP4_TAG": videoMP4Tag = value
        case "VIDEO_MP4_VERIFY_CODEC": videoMP4VerifyCodec = value
        case "VIDEO_COLOR_PRIMARIES": videoColorPrimaries = value
        case "VIDEO_COLOR_TRANSFER": videoColorTransfer = value
        case "VIDEO_COLOR_SPACE": videoColorSpace = value
        case "VIDEO_COLOR_RANGE": videoColorRange = value
        case "SHORT_MP4_CLIP_SECONDS": shortMP4ClipSeconds = value
        case "SHORT_MP4_FPS": shortMP4FPS = value
        case "SHORT_MP4_SCALE_W": shortMP4ScaleW = try parseInt(key, value)
        case "SHORT_MP4_SCALE_H": shortMP4ScaleH = try parseInt(key, value)
        case "SHORT_MP4_VIDEO_PRESET": shortMP4VideoPreset = value
        case "SHORT_MP4_VIDEO_CRF": shortMP4VideoCRF = value
        case "SHORT_MP4_VT_QUALITY": shortMP4VTQuality = value
        case "SHORT_MP4_AUDIO_SAMPLE_RATE": shortMP4AudioSampleRate = try parseInt(key, value)
        case "SHORT_MP4_VIDEO_CODEC": shortMP4VideoCodec = value
        case "SHORT_MP4_VIDEO_FALLBACKS": shortMP4VideoFallbacks = value
        case "SHORT_MP4_PIXEL_FORMAT": shortMP4PixelFormat = value
        case "SHORT_MP4_VERIFY_CODEC": shortMP4VerifyCodec = value
        case "IMAGE_8K_WIDTH": image8KWidth = try parseInt(key, value)
        case "IMAGE_8K_HEIGHT": image8KHeight = try parseInt(key, value)
        case "IMAGE_4K_WIDTH": image4KWidth = try parseInt(key, value)
        case "IMAGE_4K_HEIGHT": image4KHeight = try parseInt(key, value)
        case "IMAGE_3K_SIZE": image3KSize = try parseInt(key, value)
        case "IMAGE_2K_SIZE": image2KSize = try parseInt(key, value)
        case "IMAGE_AIPIX_SHARPNESS": imageAIPixSharpness = try parseDouble(key, value)
        case "IMAGE_AIPIX_FILTER": imageAIPixFilter = value
        case "IMAGE_AIPIX_PNG_COMPRESSION_LEVEL": imageAIPixPNGCompressionLevel = try parseInt(key, value)
        case "IMAGE_JPG_TO_PNG_COMPRESSION_LEVEL": imageJPGToPNGCompressionLevel = try parseInt(key, value)
        case "IMAGE_PNG_TO_JPEG_QUALITY": imagePNGToJPEGQuality = try parseInt(key, value)
        case "IMAGE_JPEG_SAMPLING_FACTOR": imageJpegSamplingFactor = value
        case "IMAGE_OUTPUT_COLORSPACE": imageOutputColorSpace = value
        case "IMAGE_3K_JPG_1MB_TARGET_BYTES": image3KJPG1MBTargetBytes = try parseInt(key, value)
        case "IMAGE_3K_JPG_5MB_TARGET_BYTES": image3KJPG5MBTargetBytes = try parseInt(key, value)
        case "IMAGE_8K_JPG_1MB_TARGET_BYTES": image8KJPG1MBTargetBytes = try parseInt(key, value)
        case "IMAGE_8K_JPG_2MB_TARGET_BYTES": image8KJPG2MBTargetBytes = try parseInt(key, value)
        case "IMAGE_8K_JPG_20MB_TARGET_BYTES": image8KJPG20MBTargetBytes = try parseInt(key, value)
        case "ALBUM_SILENCE_SECS": albumSilenceSecs = try parseInt(key, value)
        case "WAV_FADE_DUR": wavFadeDur = try parseInt(key, value)
        default:
            break
        }
    }

    func validate() throws {
        guard RunProfile(rawValue: profileName) != nil else {
            throw AppError("PROFILE must be one of: \(RunProfile.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(profileName)')")
        }
        try requirePositive(preflightSeconds, "PREFLIGHT_SECONDS")
        if durationToleranceSec < 0 {
            throw AppError("DURATION_TOLERANCE_SEC must be >= 0")
        }
        // Each CRC chunk is read into memory whole, so the upper bound keeps a typo from turning the
        // hash pass into a multi-gigabyte allocation.
        try requireRange(crcChunkBytes, 1 ... maximumCRCChunkBytes, "CRC_CHUNK_BYTES")
        try requirePositive(wavSampleRate, "WAV_SAMPLE_RATE")
        try requireChannels(wavChannels, "WAV_CHANNELS")
        let wavStandard = "internal WAV processing is fixed at 24-bit, 96 kHz, stereo"
        try requireProjectStandard(wavSampleRate, 96_000, "WAV_SAMPLE_RATE", wavStandard)
        try requireProjectStandard(wavCodec.lowercasedASCII, "pcm_s24le", "WAV_CODEC", wavStandard)
        try requireProjectStandard(wavChannels, 2, "WAV_CHANNELS", wavStandard)
        try requireRange(wavWriteBext, 0 ... 1, "WAV_WRITE_BEXT")
        try requirePositive(mp3SampleRate, "MP3_SAMPLE_RATE")
        try requireChannels(mp3Channels, "MP3_CHANNELS")
        try requirePositive(mp3MinBitrateBps, "MP3_MIN_BITRATE_BPS")
        let mp3Standard = "MP3 output is fixed at the project maximum quality: 320k, 48 kHz, stereo"
        try requireProjectStandard(mp3SampleRate, 48_000, "MP3_SAMPLE_RATE", mp3Standard)
        try requireProjectStandard(mp3Bitrate.lowercasedASCII, "320k", "MP3_BITRATE", mp3Standard)
        try requireProjectStandard(mp3Channels, 2, "MP3_CHANNELS", mp3Standard)
        try requirePositive(flacSampleRate, "FLAC_SAMPLE_RATE")
        try requireChannels(flacChannels, "FLAC_CHANNELS")
        try requireRange(flacCompressionLevel, 0 ... 12, "FLAC_COMPRESSION_LEVEL")
        try requirePositive(m4aSampleRate, "M4A_SAMPLE_RATE")
        try requireChannels(m4aChannels, "M4A_CHANNELS")
        let m4aStandard = "M4A output is fixed at ALAC, 48 kHz, stereo"
        try requireProjectStandard(m4aSampleRate, 48_000, "M4A_SAMPLE_RATE", m4aStandard)
        try requireProjectStandard(m4aChannels, 2, "M4A_CHANNELS", m4aStandard)
        if audioQCLUFSTolerance < 0 {
            throw AppError("AUDIO_QC_LUFS_TOLERANCE must be >= 0")
        }
        try requireLoudnormTarget(audioQCTargetLUFS, "AUDIO_QC_TARGET_LUFS")
        if audioQCMaxTruePeakDBTP > 0 {
            throw AppError("AUDIO_QC_MAX_TRUE_PEAK_DBTP must be <= 0")
        }
        if audioQCMaxLoudnessRange < 0 {
            throw AppError("AUDIO_QC_MAX_LOUDNESS_RANGE must be >= 0")
        }
        if audioQCMaxDCOffset < 0 {
            throw AppError("AUDIO_QC_MAX_DC_OFFSET must be >= 0")
        }
        if audioQCMaxStereoImbalanceDB < 0 {
            throw AppError("AUDIO_QC_MAX_STEREO_IMBALANCE_DB must be >= 0")
        }
        if audioQCMaxClippedSamples < 0 {
            throw AppError("AUDIO_QC_MAX_CLIPPED_SAMPLES must be >= 0")
        }
        if audioQCMinimumAnalysisSeconds <= 0 {
            throw AppError("AUDIO_QC_MINIMUM_ANALYSIS_SECONDS must be > 0")
        }
        if shortAudioQCLUFSTolerance < 0 {
            throw AppError("SHORT_AUDIO_QC_LUFS_TOLERANCE must be >= 0")
        }
        try requireLoudnormTarget(shortAudioQCTargetLUFS, "SHORT_AUDIO_QC_TARGET_LUFS")
        if shortAudioQCMaxLoudnessRange < 0 {
            throw AppError("SHORT_AUDIO_QC_MAX_LOUDNESS_RANGE must be >= 0")
        }
        try requireLoudnormTarget(masteringTargetLUFS, "MASTERING_TARGET_LUFS")
        if masteringMaxTruePeakDBTP > 0 {
            throw AppError("MASTERING_MAX_TRUE_PEAK_DBTP must be <= 0")
        }
        if masteringMaxLoudnessRange < 0 {
            throw AppError("MASTERING_MAX_LOUDNESS_RANGE must be >= 0")
        }
        try requireNonEmpty(videoMP4Encoder, "VIDEO_MP4_ENCODER")
        try requireNumericRange(videoMP4VTQuality, videoToolboxQualityRange, "VIDEO_MP4_VT_QUALITY")
        try requireNonEmpty(videoMP4SoftwarePreset, "VIDEO_MP4_SOFTWARE_PRESET")
        try requireNumericRange(videoMP4SoftwareCRF, softwareCRFRange, "VIDEO_MP4_SOFTWARE_CRF")
        try requirePositiveRateString(videoMP4InputFPS, "VIDEO_MP4_INPUT_FPS")
        try requirePositive(videoMP4AudioSampleRate, "VIDEO_MP4_AUDIO_SAMPLE_RATE")
        try requireProjectStandard(
            videoMP4AudioSampleRate, 48_000, "VIDEO_MP4_AUDIO_SAMPLE_RATE",
            "main MP4 audio is fixed at ALAC, 24-bit, 48 kHz, stereo"
        )
        try requirePositive(videoMP4Width, "VIDEO_MP4_WIDTH")
        try requirePositive(videoMP4Height, "VIDEO_MP4_HEIGHT")
        try requireNonEmpty(videoMP4ScaleFilter, "VIDEO_MP4_SCALE_FILTER")
        try requireNonEmpty(videoMP4PixelFormat, "VIDEO_MP4_PIXEL_FORMAT")
        try requireNonEmpty(videoMP4Tag, "VIDEO_MP4_TAG")
        try requireNonEmpty(videoMP4VerifyCodec, "VIDEO_MP4_VERIFY_CODEC")
        try requireNonEmpty(videoColorPrimaries, "VIDEO_COLOR_PRIMARIES")
        try requireNonEmpty(videoColorTransfer, "VIDEO_COLOR_TRANSFER")
        try requireNonEmpty(videoColorSpace, "VIDEO_COLOR_SPACE")
        try requireNonEmpty(videoColorRange, "VIDEO_COLOR_RANGE")
        // configuredShortClipSeconds reads this value through parseFlexibleTimecode, so the same parser
        // decides what is valid here: "58", "0:58" and "1:30" alike, capped by maximumTimecodeSeconds.
        // Validating with Double() instead rejected every MM:SS value the consumer would have accepted.
        let shortClipSeconds = try parseFlexibleTimecode(shortMP4ClipSeconds, label: "SHORT_MP4_CLIP_SECONDS")
        guard shortClipSeconds > 0 else {
            throw AppError("SHORT_MP4_CLIP_SECONDS must be > 0 (got '\(shortMP4ClipSeconds)')")
        }
        try requirePositiveRateString(shortMP4FPS, "SHORT_MP4_FPS")
        try requirePositive(shortMP4AudioSampleRate, "SHORT_MP4_AUDIO_SAMPLE_RATE")
        try requireProjectStandard(
            shortMP4AudioSampleRate, 48_000, "SHORT_MP4_AUDIO_SAMPLE_RATE",
            "short MP4 audio is fixed at ALAC, 24-bit, 48 kHz, stereo"
        )
        try requirePositive(shortMP4ScaleW, "SHORT_MP4_SCALE_W")
        try requirePositive(shortMP4ScaleH, "SHORT_MP4_SCALE_H")
        try requireNonEmpty(shortMP4VideoPreset, "SHORT_MP4_VIDEO_PRESET")
        try requireNumericRange(shortMP4VideoCRF, softwareCRFRange, "SHORT_MP4_VIDEO_CRF")
        try requireNumericRange(shortMP4VTQuality, videoToolboxQualityRange, "SHORT_MP4_VT_QUALITY")
        try requireNonEmpty(shortMP4VideoCodec, "SHORT_MP4_VIDEO_CODEC")
        try requireNonEmpty(shortMP4PixelFormat, "SHORT_MP4_PIXEL_FORMAT")
        try requireNonEmpty(shortMP4VerifyCodec, "SHORT_MP4_VERIFY_CODEC")
        if videoEncoderLadder.isEmpty {
            throw AppError("VIDEO_MP4 encoder ladder must not be empty")
        }
        if shortVideoEncoderLadder.isEmpty {
            throw AppError("SHORT_MP4 encoder ladder must not be empty")
        }
        try requireH264VideoToolboxPrimaryFits(
            ladder: videoEncoderLadder, width: videoMP4Width, height: videoMP4Height,
            codecKey: "VIDEO_MP4_ENCODER", sizeKeys: "VIDEO_MP4_WIDTH x VIDEO_MP4_HEIGHT"
        )
        try requireH264VideoToolboxPrimaryFits(
            ladder: shortVideoEncoderLadder, width: shortMP4ScaleW, height: shortMP4ScaleH,
            codecKey: "SHORT_MP4_VIDEO_CODEC", sizeKeys: "SHORT_MP4_SCALE_W x SHORT_MP4_SCALE_H"
        )
        try requirePositive(image8KWidth, "IMAGE_8K_WIDTH")
        try requirePositive(image8KHeight, "IMAGE_8K_HEIGHT")
        try requirePositive(image4KWidth, "IMAGE_4K_WIDTH")
        try requirePositive(image4KHeight, "IMAGE_4K_HEIGHT")
        try requirePositive(image3KSize, "IMAGE_3K_SIZE")
        try requirePositive(image2KSize, "IMAGE_2K_SIZE")
        try requireRange(imagePNGToJPEGQuality, 1 ... 100, "IMAGE_PNG_TO_JPEG_QUALITY")
        if imageAIPixSharpness < 0 {
            throw AppError("IMAGE_AIPIX_SHARPNESS must be >= 0")
        }
        if imageAIPixSharpness > Self.maximumAIPixSharpness {
            throw AppError(
                "IMAGE_AIPIX_SHARPNESS must be <= \(Self.maximumAIPixSharpness); "
                + "the effective sigma is (value - 1) * 2 and larger values cost minutes per image"
            )
        }
        try requireNonEmpty(imageAIPixFilter, "IMAGE_AIPIX_FILTER")
        // Both are ImageMagick's own 0-9 zlib level scale.
        try requireRange(imageAIPixPNGCompressionLevel, 0 ... 9, "IMAGE_AIPIX_PNG_COMPRESSION_LEVEL")
        try requireRange(imageJPGToPNGCompressionLevel, 0 ... 9, "IMAGE_JPG_TO_PNG_COMPRESSION_LEVEL")
        try requireNonEmpty(imageJpegSamplingFactor, "IMAGE_JPEG_SAMPLING_FACTOR")
        try requireNonEmpty(imageOutputColorSpace, "IMAGE_OUTPUT_COLORSPACE")
        // A zero byte target makes every JPEG size search fail after the encode work is done.
        try requirePositive(image3KJPG1MBTargetBytes, "IMAGE_3K_JPG_1MB_TARGET_BYTES")
        try requirePositive(image3KJPG5MBTargetBytes, "IMAGE_3K_JPG_5MB_TARGET_BYTES")
        try requirePositive(image8KJPG1MBTargetBytes, "IMAGE_8K_JPG_1MB_TARGET_BYTES")
        try requirePositive(image8KJPG2MBTargetBytes, "IMAGE_8K_JPG_2MB_TARGET_BYTES")
        try requirePositive(image8KJPG20MBTargetBytes, "IMAGE_8K_JPG_20MB_TARGET_BYTES")
        try requirePositive(albumSilenceSecs, "ALBUM_SILENCE_SECS")
        try requirePositive(wavFadeDur, "WAV_FADE_DUR")
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmed
        return trimmed.isEmpty ? nil : trimmed
    }
}

// Every integer key is a count, size or rate, so a negative value is never meaningful; the message
// says so instead of calling "-1" "not an integer".
private func parseInt(_ key: String, _ value: String) throws -> Int {
    guard let parsed = Int(value) else {
        throw AppError("\(key) must be an integer (got '\(value)')")
    }
    guard parsed >= 0 else {
        throw AppError("\(key) must be a non-negative integer (got '\(value)')")
    }
    return parsed
}

private func parseDouble(_ key: String, _ value: String) throws -> Double {
    guard let parsed = Double(value), parsed.isFinite else {
        throw AppError("\(key) must be a finite number (got '\(value)')")
    }
    return parsed
}

private func requirePositive(_ value: Int, _ name: String) throws {
    if value <= 0 {
        throw AppError("\(name) must be > 0 (got '\(value)')")
    }
}

private func requireRange(_ value: Int, _ range: ClosedRange<Int>, _ name: String) throws {
    if !range.contains(value) {
        throw AppError("\(name) must be between \(range.lowerBound) and \(range.upperBound) (got '\(value)')")
    }
}

// Several outputs are fixed project standards rather than tunables; the message names the key that
// deviates and why it cannot, instead of one composite line that hides which setting is wrong.
private func requireProjectStandard<Value: Equatable>(
    _ value: Value, _ expected: Value, _ name: String, _ standard: String
) throws {
    if value != expected {
        throw AppError("\(name) must be \(expected) (got '\(value)'): \(standard)")
    }
}

private func requireChannels(_ value: Int, _ name: String) throws {
    if !(1 ... 2).contains(value) {
        throw AppError("\(name) must be 1 or 2 (got '\(value)')")
    }
}

private func requireLoudnormTarget(_ value: Double, _ name: String) throws {
    guard value.isFinite else {
        throw AppError("\(name) must be finite")
    }
    guard value >= LoudnessSpec.minimumTargetLUFS, value <= LoudnessSpec.maximumTargetLUFS else {
        throw AppError("\(name) must be between \(ffmpegNumber(LoudnessSpec.minimumTargetLUFS)) and \(ffmpegNumber(LoudnessSpec.maximumTargetLUFS)) LUFS")
    }
}

private func requireNonEmpty(_ value: String, _ name: String) throws {
    if value.trimmed.isEmpty {
        throw AppError("\(name) must not be empty")
    }
}

// ffmpeg's h264/hevc_videotoolbox take -q:v 1-100 and libx264/libx265 take -crf 0-51; either
// silently clamps or errors deep inside the encoder, so the bounds are enforced here by name.
private let videoToolboxQualityRange: ClosedRange<Double> = 1 ... 100
private let softwareCRFRange: ClosedRange<Double> = 0 ... 51
// 64 MiB reads comfortably in one call while bounding the buffer a CRC pass allocates.
private let maximumCRCChunkBytes = 64 * 1_048_576

private func requireNumericRange(_ value: String, _ range: ClosedRange<Double>, _ name: String) throws {
    try requireNonEmpty(value, name)
    guard let parsed = Double(value), parsed.isFinite else {
        throw AppError("\(name) must be numeric (got '\(value)')")
    }
    guard range.contains(parsed) else {
        let bounds = "\(ffmpegNumber(range.lowerBound)) and \(ffmpegNumber(range.upperBound))"
        throw AppError("\(name) must be between \(bounds) (got '\(value)')")
    }
}

private func requirePositiveRateString(_ value: String, _ name: String) throws {
    try requireNonEmpty(value, name)
    if let parsed = Double(value), parsed > 0 {
        return
    }
    let parts = value.split(separator: "/")
    if parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), numerator > 0, denominator > 0 {
        return
    }
    throw AppError("\(name) must be a positive number or ratio (got '\(value)')")
}

// VideoToolbox refuses to open an H.264 compression session above 4096 pixels on either axis:
// `ffmpeg -f lavfi -i color=size=4320x7680 -frames:v 1 -c:v h264_videotoolbox -f null -` fails with
// "Cannot create compression session: -12903" (4096x4096 encodes; 4098x4096 and 4096x4098 do not).
// hevc_videotoolbox has no such limit at 8K, so only the H.264 encoder is checked.
private let h264VideoToolboxMaxDimension = 4096

// A primary encoder that can never open a session at the configured size is a configuration
// error, not something to discover through a failing rung and a warning on every render.
private func requireH264VideoToolboxPrimaryFits(
    ladder: [String], width: Int, height: Int, codecKey: String, sizeKeys: String
) throws {
    guard ladder.first == "h264_videotoolbox", max(width, height) > h264VideoToolboxMaxDimension else {
        return
    }
    throw AppError(
        "\(codecKey)=h264_videotoolbox cannot encode \(width)x\(height) (\(sizeKeys)): VideoToolbox H.264 "
            + "sessions are limited to \(h264VideoToolboxMaxDimension) pixels per dimension. "
            + "Use libx264 as the primary encoder and list h264_videotoolbox as a fallback."
    )
}

private func commaSeparatedList(_ value: String) -> [String] {
    value
        .split(separator: ",")
        .map { String($0).trimmed }
        .filter { !$0.isEmpty }
}

private func uniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values.map(\.trimmed).filter({ !$0.isEmpty }) {
        if seen.insert(value).inserted {
            result.append(value)
        }
    }
    return result
}
