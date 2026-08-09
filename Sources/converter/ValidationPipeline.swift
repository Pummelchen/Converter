import Foundation
import BW64Bridge

extension ConverterTool {
    // Loudness comparisons for trimmed renders must use the same leading program segment, not the full source.
    private func audioQCResultForComparison(_ file: URL, policy: AudioQCPolicy, limitDuration: Double?) throws -> AudioQCResult {
        guard let limitDuration, limitDuration > 0 else {
            return try audioQCResult(for: file, policy: policy)
        }

        if let totalDuration = try mediaDuration(file), totalDuration - limitDuration <= max(0.25, config.durationToleranceSec) {
            return try audioQCResult(for: file, policy: policy)
        }

        let temp = fileManager.temporaryDirectory
            .appendingPathComponent("converter-qc-clip.\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? fileManager.removeItem(at: temp) }
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-t", ffmpegArg("%.6f", limitDuration),
                "-i", file.path,
                "-map", "0:a:0",
                "-vn",
                "-ac", String(config.wavChannels),
                "-ar", String(config.wavSampleRate),
                "-c:a", config.wavCodec,
                "-f", "wav",
                "-rf64", "always",
                "-write_bext", String(config.wavWriteBext),
                temp.path
            ])
            return try audioQCResult(for: temp, policy: policy)
        } catch {
            throw error
        }
    }

    func verifyAudibleAudioTrack(_ file: URL) throws -> Bool {
        let fingerprint = try fileProbeFingerprint(file)
        return try probeCache.cachedAudibleResult(key: fingerprint) {
            let result = try runner.run(
                "ffmpeg",
                ["-hide_banner", "-nostdin", "-v", "info", "-i", file.path, "-map", "0:a:0", "-af", "volumedetect", "-f", "null", "-"],
                allowedExitCodes: [0]
            )
            let text = result.stderr
            guard let line = text.split(whereSeparator: \.isNewline).map(String.init).first(where: { $0.contains("max_volume:") }) else {
                throw AppError("Audibility probe produced no max_volume line for \(file.path)")
            }
            let value = line.components(separatedBy: "max_volume:").last?.trimmed.replacingOccurrences(of: " dB", with: "") ?? "0"
            if value == "-inf" {
                return false
            }
            guard let decibels = Double(value) else {
                throw AppError("Audibility probe returned unparsable volume for \(file.path): '\(value)'")
            }
            return decibels > -70
        }
    }

    func audioQCResult(for file: URL, policy: AudioQCPolicy) throws -> AudioQCResult {
        let key = AudioQCCacheKey(
            fingerprint: try fileProbeFingerprint(file),
            policy: policy
        )
        return try probeCache.cachedAudioQCResult(key: key) {
            let duration = (try mediaDuration(file)) ?? 0
            let loudnormResult = try runner.run(
                "ffmpeg",
                [
                    "-hide_banner", "-nostdin", "-v", "info",
                    "-i", file.path,
                    "-map", "0:a:0",
                    "-af", "loudnorm=I=\(ffmpegArg("%.2f", policy.targetLUFS)):TP=\(ffmpegArg("%.2f", policy.maxTruePeakDBTP)):LRA=\(ffmpegArg("%.2f", policy.maxLoudnessRange)):print_format=json",
                    "-f", "null", "-"
                ],
                allowedExitCodes: [0]
            )
            let loudnorm = try parseLoudnormJSON(from: loudnormResult.stderr)
            let astatsResult = try runner.run(
                "ffmpeg",
                [
                    "-hide_banner", "-nostdin", "-v", "info",
                    "-i", file.path,
                    "-map", "0:a:0",
                    "-af", "astats=metadata=0:reset=0:measure_overall=all",
                    "-f", "null", "-"
                ],
                allowedExitCodes: [0]
            )
            let astats = parseAstatsReport(from: astatsResult.stderr)
            let channelRMS = astats.channelMetrics.compactMap { parseAudioDB($0["RMS level dB"]) }
            let channelDC = astats.channelMetrics.compactMap { Double($0["DC offset"] ?? "") }
            let peakLevelDBFS = parseAudioDB(astats.overallMetrics["Peak level dB"])
            let peakCount = Int(Double(astats.overallMetrics["Peak count"] ?? "0") ?? 0)
            let clippedSamples = (peakLevelDBFS ?? -Double.infinity) >= 0 ? peakCount : 0
            let stereoImbalance = channelRMS.count >= 2 ? abs(channelRMS[0] - channelRMS[1]) : 0
            let dcOffset = channelDC.map(abs).max() ?? abs(Double(astats.overallMetrics["DC offset"] ?? "") ?? 0)
            let volumeDetect = try runner.run(
                "ffmpeg",
                [
                    "-hide_banner", "-nostdin", "-v", "info",
                    "-t", ffmpegArg("%.3f", max(duration, 0.5)),
                    "-i", file.path,
                    "-map", "0:a:0",
                    "-af", "volumedetect",
                    "-f", "null", "-"
                ],
                allowedExitCodes: [0]
            )
            let maxVolumeLine = volumeDetect.stderr
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .first(where: { $0.contains("max_volume:") })
            let maxVolumeDBFS = parseAudioDB(
                maxVolumeLine?
                    .components(separatedBy: "max_volume:")
                    .last?
                    .replacingOccurrences(of: " dB", with: "")
            )

            let metrics = AudioQCMetrics(
                integratedLUFS: parseAudioDB(loudnorm.inputI),
                truePeakDBTP: parseAudioDB(loudnorm.inputTp),
                loudnessRange: parseAudioDB(loudnorm.inputLra),
                dcOffset: dcOffset,
                stereoImbalanceDB: stereoImbalance,
                peakLevelDBFS: peakLevelDBFS,
                clippedSamples: clippedSamples,
                maxVolumeDBFS: maxVolumeDBFS,
                analysisLimited: duration > 0 && duration < policy.minimumAnalysisSeconds
            )

            var issues: [String] = []
            if !metrics.analysisLimited, let integratedLUFS = metrics.integratedLUFS {
                if integratedLUFS < policy.minimumLUFS || integratedLUFS > policy.maximumLUFS {
                    issues.append(
                        String(
                            format: "integrated loudness %.2f LUFS outside target %.2f +/- %.2f",
                            integratedLUFS,
                            policy.targetLUFS,
                            policy.lufsTolerance
                        )
                    )
                }
            }
            if !metrics.analysisLimited, let loudnessRange = metrics.loudnessRange, loudnessRange > policy.maxLoudnessRange {
                issues.append(String(format: "loudness range %.2f exceeds max %.2f", loudnessRange, policy.maxLoudnessRange))
            }
            if let truePeak = metrics.truePeakDBTP, truePeak > policy.maxTruePeakDBTP {
                issues.append(String(format: "true peak %.2f dBTP exceeds max %.2f", truePeak, policy.maxTruePeakDBTP))
            }
            if let dcOffset = metrics.dcOffset, dcOffset > policy.maxDCOffset {
                issues.append(String(format: "DC offset %.6f exceeds max %.6f", dcOffset, policy.maxDCOffset))
            }
            if let imbalance = metrics.stereoImbalanceDB, imbalance > policy.maxStereoImbalanceDB {
                issues.append(String(format: "stereo imbalance %.2f dB exceeds max %.2f", imbalance, policy.maxStereoImbalanceDB))
            }
            if metrics.clippedSamples > policy.maxClippedSamples {
                issues.append("clipped samples \(metrics.clippedSamples) exceed max \(policy.maxClippedSamples)")
            }

            return AudioQCResult(
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
                passed: issues.isEmpty,
                issues: issues
            )
        }
    }

    func verifyAudioQC(_ file: URL, policy: AudioQCPolicy) throws -> AudioQCResult {
        let result = try audioQCResult(for: file, policy: policy)
        if !result.passed {
            throw AppError("Audio QC failed for \(file.path): \(result.issues.joined(separator: "; "))")
        }
        return result
    }

    func loudnormMeasurement(for file: URL, policy: AudioQCPolicy) throws -> [String: String] {
        let result = try runner.run(
            "ffmpeg",
            [
                "-hide_banner", "-nostdin", "-v", "info",
                "-i", file.path,
                "-map", "0:a:0",
                "-af", "loudnorm=I=\(ffmpegArg("%.2f", policy.targetLUFS)):TP=\(ffmpegArg("%.2f", policy.maxTruePeakDBTP)):LRA=\(ffmpegArg("%.2f", policy.maxLoudnessRange)):print_format=json",
                "-f", "null", "-"
            ],
            allowedExitCodes: [0]
        )
        let payload = try parseLoudnormJSON(from: result.stderr)
        var values: [String: String] = [:]
        let measurementValues: [(String, String?)] = [
            ("input_i", payload.inputI),
            ("input_lra", payload.inputLra),
            ("input_tp", payload.inputTp),
            ("input_thresh", payload.inputThresh),
            ("target_offset", payload.targetOffset)
        ]
        for (key, raw) in measurementValues {
            guard let raw else {
                throw AppError("Loudnorm measurement missing '\(key)' for \(file.path)")
            }
            let trimmed = raw.trimmed
            guard Double(trimmed) != nil else {
                throw AppError("Loudnorm measurement '\(key)' is not numeric for \(file.path) (got='\(trimmed)')")
            }
            values[key] = trimmed
        }
        return values
    }

    func loudnormSecondPassFilter(policy: AudioQCPolicy, measurement: [String: String]) -> String? {
        guard
            let measuredI = Double(measurement["input_i"] ?? ""),
            let measuredLRA = Double(measurement["input_lra"] ?? ""),
            let measuredTP = Double(measurement["input_tp"] ?? ""),
            let measuredThresh = Double(measurement["input_thresh"] ?? ""),
            let offset = Double(measurement["target_offset"] ?? "")
        else {
            return nil
        }

        let measuredValuesAreUsable =
            (-99.0 ... 0.0).contains(measuredI) &&
            (0.0 ... 99.0).contains(measuredLRA) &&
            (-99.0 ... 99.0).contains(measuredTP) &&
            (-99.0 ... 0.0).contains(measuredThresh) &&
            (-99.0 ... 99.0).contains(offset)

        guard measuredValuesAreUsable else {
            return nil
        }

        return [
            "loudnorm=I=\(ffmpegArg("%.2f", policy.targetLUFS))",
            "TP=\(ffmpegArg("%.2f", policy.maxTruePeakDBTP))",
            "LRA=\(ffmpegArg("%.2f", policy.maxLoudnessRange))",
            "measured_I=\(ffmpegArg("%.2f", measuredI))",
            "measured_LRA=\(ffmpegArg("%.2f", measuredLRA))",
            "measured_TP=\(ffmpegArg("%.2f", measuredTP))",
            "measured_thresh=\(ffmpegArg("%.2f", measuredThresh))",
            "offset=\(ffmpegArg("%.2f", offset))",
            "linear=true",
            "print_format=summary"
        ].joined(separator: ":")
    }

    func loudnormSinglePassFilter(policy: AudioQCPolicy) -> String {
        [
            "loudnorm=I=\(ffmpegArg("%.2f", policy.targetLUFS))",
            "TP=\(ffmpegArg("%.2f", policy.maxTruePeakDBTP))",
            "LRA=\(ffmpegArg("%.2f", policy.maxLoudnessRange))",
            "linear=false",
            "print_format=summary"
        ].joined(separator: ":")
    }

    func applyMasteredWAV(_ source: URL, filter: String, policy: AudioQCPolicy) throws {
        let temp = try makeTemp(in: source.deletingLastPathComponent(), stem: "mastered", ext: ".wav")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-af", filter,
                "-ac", String(config.wavChannels),
                "-ar", String(config.wavSampleRate),
                "-c:a", config.wavCodec,
                "-f", "wav",
                "-rf64", "always",
                "-write_bext", String(config.wavWriteBext),
                temp.path
            ])
            try verifyWAVStandard(temp, qcPolicy: policy)
            try verifyDurationMatch(source: source, output: temp)
            try publishTemp(temp, to: source)
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func masterCanonicalWAVInPlaceIfNeeded(_ source: URL) throws {
        try preflightWAVInput(source)
        do {
            try preflightWAVStandardInput(source)
        } catch {
            logger.info("Normalize WAV before mastering: \(source.basename)")
            try normalizeWAVInPlace(source)
            try preflightWAVStandardInput(source)
        }
        let policy = config.masteringAudioQCPolicy
        let baselineQC = try audioQCResult(for: source, policy: policy)
        if baselineQC.passed {
            logger.info("Mastering skip: \(source.basename)")
            return
        }

        logger.info("Master WAV: \(source.basename)")
        let measurement = try loudnormMeasurement(for: source, policy: policy)
        if let secondPassFilter = loudnormSecondPassFilter(policy: policy, measurement: measurement) {
            do {
                try applyMasteredWAV(source, filter: secondPassFilter, policy: policy)
                logger.info("Mastered WAV: \(source.basename) [two-pass]")
                return
            } catch {
                logger.warn("Two-pass mastering failed for \(source.basename); retrying one-pass loudnorm: \(error)")
            }
        } else {
            logger.warn("Two-pass mastering measurement out of range for \(source.basename); using one-pass loudnorm fallback")
        }

        try applyMasteredWAV(source, filter: loudnormSinglePassFilter(policy: policy), policy: policy)
        logger.info("Mastered WAV: \(source.basename) [one-pass]")
    }

    func preflightImageInput(_ file: URL, expectedFormat: String? = nil) throws {
        guard fileManager.fileExists(atPath: file.path) else { throw AppError("Image input missing: \(file.path)") }
        guard try fileSizeBytes(file) > 0 else { throw AppError("Image input empty: \(file.path)") }
        _ = try runner.run("magick", ["identify", file.path])
        _ = try runner.run("magick", [file.path, "-resize", "1x1!", "null:"])
        let autoExpected: String?
        switch file.pathExtension.lowercasedASCII {
        case "png":
            autoExpected = "PNG"
        case "jpg", "jpeg":
            autoExpected = "JPEG"
        default:
            autoExpected = nil
        }
        if let expected = expectedFormat ?? autoExpected {
            let got = (try imageFormat(file) ?? "").lowercasedASCII
            if got != expected.lowercasedASCII {
                throw AppError("Image format mismatch for \(file.path) (got=\(got) expected=\(expected.lowercasedASCII))")
            }
        }
    }

    func preflightPNGInput(_ file: URL) throws {
        guard file.pathExtension.lowercasedASCII == "png" else {
            throw AppError("Expected .png input: \(file.path)")
        }
        try preflightImageInput(file, expectedFormat: "PNG")
    }

    func preflightJPEGInput(_ file: URL) throws {
        let ext = file.pathExtension.lowercasedASCII
        guard ext == "jpg" || ext == "jpeg" else {
            throw AppError("Expected .jpg or .jpeg input: \(file.path)")
        }
        try preflightImageInput(file, expectedFormat: "JPEG")
    }

    func preflightAudioInput(
        _ file: URL,
        seconds: Int? = nil,
        expectedContainerTokens: [String]? = nil,
        expectedAudioCodecs: [String]? = nil,
        requireNoVideo: Bool = true,
        requireAudible: Bool = true
    ) throws {
        guard fileManager.fileExists(atPath: file.path) else { throw AppError("Audio input missing: \(file.path)") }
        guard try fileSizeBytes(file) > 0 else { throw AppError("Audio input empty: \(file.path)") }
        if let expectedContainerTokens {
            try requireFormatNameContains(file, anyOf: expectedContainerTokens, label: "Audio container")
        }
        _ = try requireAudioStream(file, allowedCodecs: expectedAudioCodecs)
        if requireNoVideo {
            try requireNoVideoStream(file)
        }
        let probeSeconds = String(seconds ?? config.preflightSeconds)
        _ = try runner.run("ffmpeg", ["-hide_banner", "-nostdin", "-v", "error", "-xerror", "-t", probeSeconds, "-i", file.path, "-map", "0:a:0", "-f", "null", "-"])
        if requireAudible, !(try verifyAudibleAudioTrack(file)) {
            throw AppError("Audio verification failed: input appears silent or not meaningfully audible: \(file.path)")
        }
    }

    func preflightFLACInput(_ file: URL, requireAudible: Bool = true, requireNoVideo: Bool = false) throws {
        guard file.pathExtension.lowercasedASCII == "flac" else {
            throw AppError("Expected .flac input: \(file.path)")
        }
        try preflightAudioInput(file, expectedContainerTokens: ["flac"], expectedAudioCodecs: ["flac"], requireNoVideo: requireNoVideo, requireAudible: requireAudible)
    }

    func preflightMP3Input(_ file: URL, requireAudible: Bool = true, requireNoVideo: Bool = false) throws {
        guard file.pathExtension.lowercasedASCII == "mp3" else {
            throw AppError("Expected .mp3 input: \(file.path)")
        }
        try preflightAudioInput(file, expectedContainerTokens: ["mp3"], expectedAudioCodecs: ["mp3"], requireNoVideo: requireNoVideo, requireAudible: requireAudible)
    }

    func preflightM4AInput(_ file: URL, requireAudible: Bool = true) throws {
        guard file.pathExtension.lowercasedASCII == "m4a" else {
            throw AppError("Expected .m4a input: \(file.path)")
        }
        try preflightAudioInput(file, expectedContainerTokens: ["m4a", "mp4", "ipod", "mov"], expectedAudioCodecs: ["aac", "alac"], requireNoVideo: true, requireAudible: requireAudible)
    }

    func preflightWAVInput(_ file: URL, requireAudible: Bool = true, requireNoVideo: Bool = false) throws {
        guard file.pathExtension.lowercasedASCII == "wav" else {
            throw AppError("Expected .wav input: \(file.path)")
        }
        try verifyWAVHeader(file, expectedContainer: "ANY")
        try preflightAudioInput(file, expectedContainerTokens: ["wav"], expectedAudioCodecs: nil, requireNoVideo: requireNoVideo, requireAudible: requireAudible)
    }

    func preflightVideoInput(_ file: URL, seconds: Int? = nil, expectedContainerTokens: [String]? = nil, requireAudio: Bool = true, requireAudibleAudio: Bool = true) throws {
        guard fileManager.fileExists(atPath: file.path) else { throw AppError("Video input missing: \(file.path)") }
        guard try fileSizeBytes(file) > 0 else { throw AppError("Video input empty: \(file.path)") }
        if let expectedContainerTokens {
            try requireFormatNameContains(file, anyOf: expectedContainerTokens, label: "Video container")
        }
        _ = try requireVideoStream(file)
        if requireAudio {
            _ = try requireAudioStream(file)
        }
        let probeSeconds = String(seconds ?? config.preflightSeconds)
        _ = try runner.run("ffmpeg", ["-hide_banner", "-nostdin", "-v", "error", "-xerror", "-t", probeSeconds, "-i", file.path, "-f", "null", "-"])
        if requireAudio && requireAudibleAudio {
            let audioIsAudible = try verifyAudibleAudioTrack(file)
            if !audioIsAudible {
                throw AppError("Video verification failed: audio track appears silent or not meaningfully audible: \(file.path)")
            }
        }
    }

    func preflightMP4Input(_ file: URL, requireAudio: Bool = true, requireAudibleAudio: Bool = true) throws {
        guard file.pathExtension.lowercasedASCII == "mp4" else {
            throw AppError("Expected .mp4 input: \(file.path)")
        }
        try preflightVideoInput(file, expectedContainerTokens: ["mp4", "mov"], requireAudio: requireAudio, requireAudibleAudio: requireAudibleAudio)
    }

    func verifyImageOutput(
        _ file: URL,
        width: Int? = nil,
        height: Int? = nil,
        format: String? = nil,
        colorspace: String? = nil,
        maxBytes: Int? = nil
    ) throws {
        try preflightImageInput(file)
        guard let dimensions = try imageDimensions(file) else {
            throw AppError("Image verify probe failed: \(file.path)")
        }
        if let width, dimensions.0 != width {
            throw AppError("Image width mismatch for \(file.path) (got=\(dimensions.0) expected=\(width))")
        }
        if let height, dimensions.1 != height {
            throw AppError("Image height mismatch for \(file.path) (got=\(dimensions.1) expected=\(height))")
        }
        if let format {
            let got = try imageFormat(file)?.lowercasedASCII ?? ""
            if got != format.lowercasedASCII {
                throw AppError("Image format mismatch for \(file.path) (got=\(got) expected=\(format))")
            }
        }
        let expectedColor = colorspace ?? config.imageOutputColorSpace
        if !expectedColor.trimmed.isEmpty {
            let gotColor = try imageColorSpace(file)?.lowercasedASCII ?? ""
            if gotColor != expectedColor.lowercasedASCII {
                throw AppError("Image colorspace mismatch for \(file.path) (got=\(gotColor) expected=\(expectedColor.lowercasedASCII))")
            }
        }
        if let maxBytes {
            let size = try fileSizeBytes(file)
            if size > UInt64(maxBytes) {
                throw AppError("Image size exceeds limit for \(file.path) (got=\(size) limit=\(maxBytes))")
            }
        }
    }

    func verifyAudioOutput(
        _ file: URL,
        codec: String? = nil,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        sampleFormat: String? = nil,
        bitsPerRawSample: Int? = nil,
        requireAudible: Bool = true,
        qcPolicy: AudioQCPolicy? = nil
    ) throws {
        guard fileManager.fileExists(atPath: file.path) else { throw AppError("Audio output missing: \(file.path)") }
        guard try fileSizeBytes(file) > 0 else { throw AppError("Audio output empty: \(file.path)") }
        let gotCodec = try requireAudioStream(file)
        let gotRate = Int(try audioField(file, "sample_rate") ?? "")
        let gotChannels = Int(try audioField(file, "channels") ?? "")
        if let codec, gotCodec != codec.lowercasedASCII {
            throw AppError("Audio codec mismatch for \(file.path) (got=\(gotCodec) expected=\(codec.lowercasedASCII))")
        }
        if let sampleRate, gotRate != sampleRate {
            throw AppError("Audio sample rate mismatch for \(file.path) (got=\(String(describing: gotRate)) expected=\(sampleRate))")
        }
        if let channels, gotChannels != channels {
            throw AppError("Audio channels mismatch for \(file.path) (got=\(String(describing: gotChannels)) expected=\(channels))")
        }
        if let sampleFormat {
            let gotSampleFormat = (try audioField(file, "sample_fmt") ?? "").lowercasedASCII
            if gotSampleFormat != sampleFormat.lowercasedASCII {
                throw AppError("Audio sample format mismatch for \(file.path) (got=\(gotSampleFormat) expected=\(sampleFormat.lowercasedASCII))")
            }
        }
        if let bitsPerRawSample {
            let gotBits = Int(try audioField(file, "bits_per_raw_sample") ?? "")
            if gotBits != bitsPerRawSample {
                throw AppError("Audio raw bit depth mismatch for \(file.path) (got=\(String(describing: gotBits)) expected=\(bitsPerRawSample))")
            }
        }
        _ = try runner.run("ffmpeg", ["-hide_banner", "-nostdin", "-v", "error", "-xerror", "-i", file.path, "-map", "0:a:0", "-f", "null", "-"])
        if requireAudible {
            if !(try verifyAudibleAudioTrack(file)) {
                throw AppError("Audio verification failed: output appears silent: \(file.path)")
            }
        }
        if let qcPolicy {
            _ = try verifyAudioQC(file, policy: qcPolicy)
        }
    }

    func verifyVideoOutput(
        _ file: URL,
        width: Int? = nil,
        height: Int? = nil,
        codec: String? = nil,
        pixelFormat: String? = nil,
        colorPrimaries: String? = nil,
        colorTransfer: String? = nil,
        colorSpace: String? = nil,
        colorRange: String? = nil
    ) throws {
        guard fileManager.fileExists(atPath: file.path) else { throw AppError("Video output missing: \(file.path)") }
        guard try fileSizeBytes(file) > 0 else { throw AppError("Video output empty: \(file.path)") }
        try requireFormatNameContains(file, anyOf: ["mp4", "mov"], label: "Video container")
        let gotCodec = try requireVideoStream(file)
        let gotWidth = Int(try videoField(file, "width") ?? "")
        let gotHeight = Int(try videoField(file, "height") ?? "")
        let gotPixelFormat = (try videoField(file, "pix_fmt") ?? "").lowercasedASCII
        let gotPrimaries = (try videoField(file, "color_primaries") ?? "").lowercasedASCII
        let gotTransfer = (try videoField(file, "color_transfer") ?? "").lowercasedASCII
        let gotSpace = (try videoField(file, "color_space") ?? "").lowercasedASCII
        let gotRange = (try videoField(file, "color_range") ?? "").lowercasedASCII
        if let codec, gotCodec != codec.lowercasedASCII {
            throw AppError("Video codec mismatch for \(file.path) (got=\(gotCodec) expected=\(codec.lowercasedASCII))")
        }
        if let width, gotWidth != width {
            throw AppError("Video width mismatch for \(file.path) (got=\(String(describing: gotWidth)) expected=\(width))")
        }
        if let height, gotHeight != height {
            throw AppError("Video height mismatch for \(file.path) (got=\(String(describing: gotHeight)) expected=\(height))")
        }
        if let pixelFormat, gotPixelFormat != pixelFormat.lowercasedASCII {
            throw AppError("Video pixel format mismatch for \(file.path) (got=\(gotPixelFormat) expected=\(pixelFormat.lowercasedASCII))")
        }
        if let colorPrimaries, gotPrimaries != colorPrimaries.lowercasedASCII {
            throw AppError("Video color primaries mismatch for \(file.path) (got=\(gotPrimaries) expected=\(colorPrimaries.lowercasedASCII))")
        }
        if let colorTransfer, gotTransfer != colorTransfer.lowercasedASCII {
            throw AppError("Video color transfer mismatch for \(file.path) (got=\(gotTransfer) expected=\(colorTransfer.lowercasedASCII))")
        }
        if let colorSpace, gotSpace != colorSpace.lowercasedASCII {
            throw AppError("Video colorspace mismatch for \(file.path) (got=\(gotSpace) expected=\(colorSpace.lowercasedASCII))")
        }
        if let colorRange, gotRange != colorRange.lowercasedASCII {
            throw AppError("Video color range mismatch for \(file.path) (got=\(gotRange) expected=\(colorRange.lowercasedASCII))")
        }
        _ = try runner.run("ffmpeg", ["-hide_banner", "-nostdin", "-v", "error", "-xerror", "-i", file.path, "-f", "null", "-"])
    }

    func verifyWAVHeader(_ file: URL, expectedContainer: String = "RF64") throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 12) ?? Data()
        guard header.count >= 12 else {
            throw AppError("WAV header too short: \(file.path)")
        }
        let container = String(data: header.prefix(4), encoding: .ascii) ?? ""
        let format = String(data: header.subdata(in: 8 ..< 12), encoding: .ascii) ?? ""
        if format != "WAVE" {
            throw AppError("WAV format mismatch for \(file.path) (got='\(format)' expected='WAVE')")
        }
        if expectedContainer != "ANY" && container != expectedContainer {
            throw AppError("WAV container mismatch for \(file.path) (got='\(container)' expected='\(expectedContainer)')")
        }
    }

    func containsChunk(_ file: URL, chunkID: String, scanBytes: Int = 65_536) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: scanBytes) ?? Data()
        guard let needle = chunkID.data(using: .ascii), needle.count == 4 else {
            return false
        }
        return data.range(of: needle) != nil
    }

    func verifyExternalWAVVariant(_ file: URL, source: URL, expectBext: Bool) throws {
        try verifyExternalWAVStructure(file, expectBext: expectBext, qcPolicy: nil)
        try verifyDurationMatch(source: source, output: file)
        try verifyCanonicalPCMSampleEquivalence(
            source: source,
            output: file,
            sampleRate: config.wavSampleRate,
            channels: config.wavChannels,
            label: expectBext ? "RF64 WAV (BEXT)" : "RF64 WAV"
        )
    }

    func verifyBW64WAVVariant(_ file: URL, source: URL) throws {
        try verifyBW64WAVStructure(file, qcPolicy: nil)
        try verifyDurationMatch(source: source, output: file)
        try verifyCanonicalPCMSampleEquivalence(
            source: source,
            output: file,
            sampleRate: config.wavSampleRate,
            channels: config.wavChannels,
            label: "BW64 WAV",
            maxAllowedDifferingSamples: UInt64.max
        )
    }

    func verifyWAVStandard(_ file: URL, requireAudible: Bool = true, qcPolicy: AudioQCPolicy? = nil) throws {
        try verifyWAVHeader(file, expectedContainer: "RF64")
        try requireFormatNameContains(file, anyOf: ["wav"], label: "WAV container")
        try requireNoVideoStream(file)
        try verifyAudioOutput(file, codec: config.wavCodec, sampleRate: config.wavSampleRate, channels: config.wavChannels, requireAudible: requireAudible, qcPolicy: qcPolicy)
    }

    // Generic MP3 validation is for utility actions that should accept any structurally valid MP3.
    func verifyMP3File(_ file: URL, requireAudible: Bool = true, requireNoVideo: Bool = true, qcPolicy: AudioQCPolicy? = nil) throws {
        guard file.pathExtension.lowercasedASCII == "mp3" else {
            throw AppError("Expected .mp3 file: \(file.path)")
        }
        try requireFormatNameContains(file, anyOf: ["mp3"], label: "MP3 container")
        if requireNoVideo {
            try requireNoVideoStream(file)
        }
        try verifyAudioOutput(file, codec: "mp3", sampleRate: nil, channels: nil, requireAudible: requireAudible, qcPolicy: qcPolicy)
    }

    // Project MP3 outputs must satisfy the configured codec, sample-rate, channel, and bitrate floor.
    func verifyMP3Standard(_ file: URL, requireAudible: Bool = true, qcPolicy: AudioQCPolicy? = nil) throws {
        try verifyMP3File(file, requireAudible: requireAudible, requireNoVideo: true, qcPolicy: qcPolicy)
        let gotRate = Int(try audioField(file, "sample_rate") ?? "")
        let gotChannels = Int(try audioField(file, "channels") ?? "")
        if gotRate != config.mp3SampleRate {
            throw AppError("Audio sample rate mismatch for \(file.path) (got=\(String(describing: gotRate)) expected=\(config.mp3SampleRate))")
        }
        if gotChannels != config.mp3Channels {
            throw AppError("Audio channels mismatch for \(file.path) (got=\(String(describing: gotChannels)) expected=\(config.mp3Channels))")
        }
        let bitrate = try audioBitrateBps(file)
        if bitrate < config.mp3MinBitrateBps {
            throw AppError("MP3 bitrate below minimum (got=\(bitrate) min=\(config.mp3MinBitrateBps)): \(file.path)")
        }
    }

    func preflightWAVStandardInput(_ file: URL) throws {
        try preflightWAVInput(file, requireNoVideo: false)
        try verifyWAVHeader(file, expectedContainer: "RF64")
        try requireFormatNameContains(file, anyOf: ["wav"], label: "WAV container")
        try verifyAudioOutput(file, codec: config.wavCodec, sampleRate: config.wavSampleRate, channels: config.wavChannels, qcPolicy: nil)
    }

    func verifyFLACFile(
        _ file: URL,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        requireAudible: Bool = true,
        requireNoVideo: Bool = true,
        qcPolicy: AudioQCPolicy? = nil
    ) throws {
        try preflightFLACInput(file, requireAudible: requireAudible, requireNoVideo: requireNoVideo)
        try verifyAudioOutput(file, codec: "flac", sampleRate: sampleRate, channels: channels, requireAudible: requireAudible, qcPolicy: qcPolicy)
    }

    func verifyM4AFile(
        _ file: URL,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        requireAudible: Bool = true,
        qcPolicy: AudioQCPolicy? = nil
    ) throws {
        try preflightM4AInput(file, requireAudible: requireAudible)
        try verifyAudioOutput(
            file,
            codec: "alac",
            sampleRate: sampleRate,
            channels: channels,
            sampleFormat: config.alacSampleFormat,
            bitsPerRawSample: config.alacBitsPerRawSample,
            requireAudible: requireAudible,
            qcPolicy: qcPolicy
        )
    }

    func verifyDurationMatch(source: URL, output: URL, tolerance: Double? = nil) throws {
        guard let sourceDuration = try mediaDuration(source), let outputDuration = try mediaDuration(output) else {
            throw AppError("Duration probe failed for comparison: src='\(source.path)' out='\(output.path)'")
        }
        let delta = abs(sourceDuration - outputDuration)
        if delta > (tolerance ?? config.durationToleranceSec) {
            throw AppError("Duration mismatch exceeds tolerance: src=\(sourceDuration) out=\(outputDuration) delta=\(delta) tol=\(tolerance ?? config.durationToleranceSec)")
        }
    }

    func verifySourceLoudnessPreserved(source: URL, output: URL, toleranceDB: Double = 0.6) throws {
        let outputDuration = try mediaDuration(output)
        let sourceMetrics = try audioQCResultForComparison(source, policy: config.deliveryAudioQCPolicy, limitDuration: outputDuration).metrics
        let outputMetrics = try audioQCResult(for: output, policy: config.deliveryAudioQCPolicy).metrics

        if let sourceLUFS = sourceMetrics.integratedLUFS, let outputLUFS = outputMetrics.integratedLUFS {
            let delta = abs(sourceLUFS - outputLUFS)
            if delta > toleranceDB {
                throw AppError(
                    String(
                        format: "Audio loudness drift exceeds tolerance: src=%.2f LUFS out=%.2f LUFS delta=%.2f tol=%.2f (%@ -> %@)",
                        sourceLUFS,
                        outputLUFS,
                        delta,
                        toleranceDB,
                        source.path,
                        output.path
                    )
                )
            }
            return
        }

        let sourcePeak = sourceMetrics.maxVolumeDBFS ?? sourceMetrics.peakLevelDBFS
        let outputPeak = outputMetrics.maxVolumeDBFS ?? outputMetrics.peakLevelDBFS
        if let sourcePeak, let outputPeak {
            let delta = abs(sourcePeak - outputPeak)
            if delta > toleranceDB {
                throw AppError(
                    String(
                        format: "Audio peak drift exceeds tolerance: src=%.2f dBFS out=%.2f dBFS delta=%.2f tol=%.2f (%@ -> %@)",
                        sourcePeak,
                        outputPeak,
                        delta,
                        toleranceDB,
                        source.path,
                        output.path
                    )
                )
            }
            return
        }

        throw AppError("Unable to compare source/output loudness: \(source.path) -> \(output.path)")
    }

    func requireAudioSampleRate(_ file: URL) throws -> Int {
        guard let rawValue = try audioField(file, "sample_rate"), let sampleRate = Int(rawValue), sampleRate > 0 else {
            throw AppError("Audio sample-rate probe failed for \(file.path)")
        }
        return sampleRate
    }

    func requireAudioChannels(_ file: URL) throws -> Int {
        guard let rawValue = try audioField(file, "channels"), let channels = Int(rawValue), channels > 0 else {
            throw AppError("Audio channel probe failed for \(file.path)")
        }
        return channels
    }

    // Decode to a canonical signed 32-bit PCM stream so lossless/container variants can be compared sample-for-sample.
    func decodeAudioToCanonicalPCM(_ source: URL, output: URL, sampleRate: Int, channels: Int) throws {
        try decodeAudioToCanonicalPCM(source, output: output, sampleRate: sampleRate, channels: channels, format: .s32le)
    }

    func decodeAudioToCanonicalPCM(_ source: URL, output: URL, sampleRate: Int, channels: Int, format: CanonicalPCMFormat) throws {
        _ = try runner.run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-i", source.path,
            "-map", "0:a:0",
            "-vn",
            "-ac", String(channels),
            "-ar", String(sampleRate),
            "-f", format.ffmpegFormat,
            "-acodec", format.ffmpegCodec,
            output.path
        ])
    }

    func littleEndianSignedSample(_ data: Data, offset: Int, format: CanonicalPCMFormat) -> Int64 {
        switch format {
        case .s24le:
            let value = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
            let signed = (value & 0x800000) != 0 ? Int64(value | 0xFF00_0000) - (1 << 32) : Int64(value)
            return signed
        case .s32le:
            let value = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
            return Int64(Int32(bitPattern: value))
        }
    }

    // Compare decoded canonical PCM samples directly so container/header differences cannot hide content drift.
    func compareCanonicalPCMFiles(_ expected: URL, _ actual: URL, format: CanonicalPCMFormat) throws -> (samples: UInt64, differingSamples: UInt64, maxDelta: Int64) {
        let bytesPerSample = format.bytesPerSample
        let expectedSize = try fileSizeBytes(expected)
        let actualSize = try fileSizeBytes(actual)
        guard expectedSize == actualSize else {
            throw AppError("Canonical PCM size mismatch (expected=\(expectedSize) actual=\(actualSize))")
        }
        guard expectedSize % UInt64(bytesPerSample) == 0 else {
            throw AppError("Canonical PCM byte count is not sample-aligned: \(expected.path)")
        }

        let expectedHandle = try FileHandle(forReadingFrom: expected)
        let actualHandle = try FileHandle(forReadingFrom: actual)
        defer {
            try? expectedHandle.close()
            try? actualHandle.close()
        }

        let chunkSize = format.bytesPerSample * 65_536
        var samples: UInt64 = 0
        var differingSamples: UInt64 = 0
        var maxDelta: Int64 = 0

        while true {
            let expectedChunk = try expectedHandle.read(upToCount: chunkSize) ?? Data()
            let actualChunk = try actualHandle.read(upToCount: chunkSize) ?? Data()
            if expectedChunk.isEmpty && actualChunk.isEmpty {
                break
            }
            guard expectedChunk.count == actualChunk.count else {
                throw AppError("Canonical PCM chunk size mismatch while comparing '\(expected.path)' and '\(actual.path)'")
            }
            guard expectedChunk.count % bytesPerSample == 0 else {
                throw AppError("Canonical PCM chunk is not sample-aligned while comparing '\(expected.path)' and '\(actual.path)'")
            }

            if expectedChunk == actualChunk {
                samples += UInt64(expectedChunk.count / bytesPerSample)
                continue
            }

            for offset in stride(from: 0, to: expectedChunk.count, by: bytesPerSample) {
                let expectedSample = littleEndianSignedSample(expectedChunk, offset: offset, format: format)
                let actualSample = littleEndianSignedSample(actualChunk, offset: offset, format: format)
                let delta = abs(expectedSample - actualSample)
                if delta > 0 {
                    differingSamples += 1
                    if delta > maxDelta {
                        maxDelta = delta
                    }
                    if delta > format.maxAllowedDelta {
                        return (samples + UInt64((offset / bytesPerSample) + 1), differingSamples, maxDelta)
                    }
                }
            }

            samples += UInt64(expectedChunk.count / bytesPerSample)
        }

        return (samples, differingSamples, maxDelta)
    }

    func verifyCanonicalPCMSampleEquivalence(
        source: URL,
        output: URL,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        label: String,
        format: CanonicalPCMFormat = .s32le,
        maxAllowedDelta: Int64? = nil,
        maxAllowedDifferingSamples: UInt64? = nil
    ) throws {
        let compareSampleRate = try sampleRate ?? requireAudioSampleRate(source)
        let compareChannels = try channels ?? requireAudioChannels(source)
        let sourcePCM = try makeTemp(in: cli.outDir, stem: "\(source.stem).canonical.source", ext: ".\(format.ffmpegFormat)")
        let outputPCM = try makeTemp(in: cli.outDir, stem: "\(output.stem).canonical.output", ext: ".\(format.ffmpegFormat)")

        defer {
            for temp in [sourcePCM, outputPCM] {
                try? fileManager.removeItem(at: temp)
                state.unregister(tempFile: temp)
            }
        }

        try decodeAudioToCanonicalPCM(source, output: sourcePCM, sampleRate: compareSampleRate, channels: compareChannels, format: format)
        try decodeAudioToCanonicalPCM(output, output: outputPCM, sampleRate: compareSampleRate, channels: compareChannels, format: format)
        let comparison = try compareCanonicalPCMFiles(sourcePCM, outputPCM, format: format)
        let allowedDifferingSamples = maxAllowedDifferingSamples ?? UInt64(max(4, compareChannels * 4))
        let allowedDelta = maxAllowedDelta ?? format.maxAllowedDelta
        if comparison.differingSamples > allowedDifferingSamples || comparison.maxDelta > allowedDelta {
            let differingDescription = allowedDifferingSamples == UInt64.max ? "unlimited" : String(allowedDifferingSamples)
            throw AppError(
                "Canonical PCM mismatch for \(label): src='\(source.path)' out='\(output.path)' differing_samples=\(comparison.differingSamples) max_delta=\(comparison.maxDelta) allowed_differing=\(differingDescription) allowed_delta=\(allowedDelta) sample_rate=\(compareSampleRate) channels=\(compareChannels) canonical=\(format.ffmpegCodec)"
            )
        }
        logger.debug(
            "Canonical PCM match for \(label): samples=\(comparison.samples) differing=\(comparison.differingSamples) max_delta=\(comparison.maxDelta) rate=\(compareSampleRate) channels=\(compareChannels) canonical=\(format.ffmpegCodec)"
        )
    }

    func canReuseOutput(_ file: URL, verifier: () throws -> Void) -> Bool {
        guard !cli.overwrite, fileManager.fileExists(atPath: file.path) else {
            return false
        }
        do {
            try verifier()
            return true
        } catch {
            return false
        }
    }

    func stripTrailingDerivedImageSuffix(from stem: String) -> String {
        let orderedSuffixes = ["_NFT8K", "_NFT3K", "_NFT2K", "_20MB", "_5MB", "_2MB", "_1MB", "_8K", "_4K", "_3K", "_2K"]
        for suffix in orderedSuffixes where stem.hasSuffix(suffix) {
            let trimmed = String(stem.dropLast(suffix.count))
            return trimmed.isEmpty ? stem : trimmed
        }
        return stem
    }

    func replacingTrailingSuffix(in stem: String, suffix: String, replacement: String) -> String {
        if stem.hasSuffix(suffix) {
            return String(stem.dropLast(suffix.count)) + replacement
        }
        return stem + replacement
    }

    func imagePrefix(from stem: String) -> String {
        // Only strip known trailing derivative labels; preserve the rest of the stem verbatim.
        let normalized = cli.keepFullName ? stem : stripTrailingDerivedImageSuffix(from: stem)
        return cli.lowercasePrefix ? normalized.lowercasedASCII : normalized
    }

    func verifyExternalWAVStructure(_ file: URL, expectBext: Bool, qcPolicy: AudioQCPolicy? = nil) throws {
        try verifyWAVHeader(file, expectedContainer: "RF64")
        try requireFormatNameContains(file, anyOf: ["wav"], label: "WAV container")
        try requireNoVideoStream(file)
        try verifyAudioOutput(file, codec: config.wavCodec, sampleRate: config.wavSampleRate, channels: config.wavChannels, qcPolicy: qcPolicy)
        let hasBext = try containsChunk(file, chunkID: "bext")
        if hasBext != expectBext {
            let expected = expectBext ? "present" : "absent"
            let got = hasBext ? "present" : "absent"
            throw AppError("Broadcast metadata mismatch for \(file.path) (got=\(got) expected=\(expected))")
        }
    }

    func verifyBW64WAVStructure(_ file: URL, qcPolicy: AudioQCPolicy? = nil) throws {
        try verifyWAVHeader(file, expectedContainer: "BW64")
        if !(try containsChunk(file, chunkID: "ds64")) {
            throw AppError("BW64 ds64 chunk missing: \(file.path)")
        }
        try requireFormatNameContains(file, anyOf: ["wav"], label: "BW64 container")
        try requireNoVideoStream(file)
        try verifyAudioOutput(file, codec: "pcm_s32le", sampleRate: config.wavSampleRate, channels: config.wavChannels, qcPolicy: qcPolicy)
    }

    func writeBW64FileFromRawFloatPCM(inputPCM: URL, output: URL, channels: Int, sampleRate: Int, bitDepth: Int = 32) throws {
        var errorBuffer = Array<CChar>(repeating: 0, count: 4096)
        let status = errorBuffer.withUnsafeMutableBufferPointer { buffer -> Int32 in
            inputPCM.path.withCString { inputPath in
                output.path.withCString { outputPath in
                    bw64_write_from_f32le_file(
                        inputPath,
                        outputPath,
                        UInt16(channels),
                        UInt32(sampleRate),
                        UInt16(bitDepth),
                        buffer.baseAddress,
                        buffer.count
                    )
                }
            }
        }
        guard status == 0 else {
            let nulIndex = errorBuffer.firstIndex(of: 0) ?? errorBuffer.endIndex
            let messageBytes = errorBuffer[..<nulIndex].map { UInt8(bitPattern: $0) }
            let message = String(decoding: messageBytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                throw AppError("BW64 writer failed for \(output.path)")
            }
            throw AppError("BW64 writer failed: \(message)")
        }
    }

    func requireFFmpegEncoder(_ encoder: String) throws {
        let available = try cachedFFmpegEncoderSet()
        if !available.contains(encoder) {
            throw AppError("Required ffmpeg encoder is not available: \(encoder)")
        }
    }

}
