import Foundation

private struct LoudnessRenderCandidate {
    let temp: URL
    let result: AudioQCResult
}

extension ConverterTool {
    func mp3NeedsShortPreparation(_ source: URL) -> Bool {
        do {
            try preflightMP3Input(source, requireNoVideo: false)
            let sampleRate = Int(try audioField(source, "sample_rate") ?? "") ?? 0
            let channels = Int(try audioField(source, "channels") ?? "") ?? 0
            let bitrate = try audioBitrateBps(source)
            let hasOnlyAudio: Bool
            do {
                try requireNoVideoStream(source)
                hasOnlyAudio = true
            } catch {
                hasOnlyAudio = false
            }
            return sampleRate != config.mp3SampleRate
                || channels != config.mp3Channels
                || bitrate < config.mp3MinBitrateBps
                || !hasOnlyAudio
        } catch {
            return true
        }
    }

    func ensureShortReadyMP3(_ source: URL) throws -> URL {
        try preflightMP3Input(source, requireNoVideo: false)
        try requireFFmpegEncoder("libmp3lame")

        let output = cli.outDir.appendingPathComponent(source.lastPathComponent)
        if source.standardizedFileURL == output.standardizedFileURL, !mp3NeedsShortPreparation(source) {
            logger.info("MP3 short source already at project standard: \(source.basename)")
            return source
        }
        if source.standardizedFileURL != output.standardizedFileURL,
           canReuseOutput(output, verifier: {
               try verifyMP3Standard(output, qcPolicy: nil)
               try verifyDurationMatch(source: source, output: output)
               try verifySourceLoudnessPreserved(source: source, output: output)
           }) {
            logger.info("Reuse short-ready MP3: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".mp3")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-ar", String(config.mp3SampleRate),
                "-ac", String(config.mp3Channels),
                "-c:a", "libmp3lame",
                "-b:a", config.mp3Bitrate,
                temp.path
            ])
            try verifyMP3Standard(temp, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: temp)
            try verifySourceLoudnessPreserved(source: source, output: temp)
            try publishTemp(temp, to: output)
            logger.info("Prepared MP3 for short: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func convertMP3ToShortReadyM4A(_ source: URL) throws -> URL {
        try preflightMP3Input(source, requireNoVideo: false)
        try requireFFmpegEncoder("aac")
        let output = cli.outDir.appendingPathComponent(source.stem).appendingPathExtension("m4a")
        if canReuseOutput(output, verifier: {
            try verifyM4AFile(output, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: output)
            try verifySourceLoudnessPreserved(source: source, output: output)
        }) {
            logger.info("Reuse short-ready M4A: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".m4a")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-c:a", "aac",
                "-b:a", config.m4aBitrate,
                "-ar", String(config.m4aSampleRate),
                "-ac", String(config.m4aChannels),
                "-vn",
                temp.path
            ])
            try verifyM4AFile(temp, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: temp)
            try verifySourceLoudnessPreserved(source: source, output: temp)
            try publishTemp(temp, to: output)
            logger.info("Prepared M4A for short: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func verifyDuration(_ file: URL, expectedSeconds: Double, label: String, tolerance: Double? = nil) throws {
        guard let actualDuration = try mediaDuration(file) else {
            throw AppError("Duration probe failed for \(label): \(file.path)")
        }
        let allowedTolerance = tolerance ?? config.durationToleranceSec
        let delta = abs(actualDuration - expectedSeconds)
        if delta > allowedTolerance {
            throw AppError("Duration mismatch for \(label): got=\(actualDuration) expected=\(expectedSeconds) delta=\(delta) tol=\(allowedTolerance)")
        }
    }

    func isFadeDerivedAudio(_ file: URL) -> Bool {
        let stem = file.stem.lowercasedASCII
        return stem.hasSuffix("_faded")
            || stem.hasSuffix("_faded_rf64")
            || stem.hasSuffix("_fadecut")
    }

    func isBassDerivedAudio(_ file: URL) -> Bool {
        let stem = file.stem.lowercasedASCII
        return stem.hasSuffix("_bass")
            || (stem.contains("_bass_") && stem.hasSuffix("db"))
    }

    func audioBassCandidates() throws -> [URL] {
        try files(in: cli.srcDir, matchingExtensions: ["flac", "wav", "mp3", "m4a", "mp4"])
            .filter { !isBassDerivedAudio($0) }
    }

    func isLoudnessDerivedAudio(_ file: URL) -> Bool {
        file.stem.lowercasedASCII.contains("_loudness_")
    }

    func audioLoudnessCandidates(includeDerived: Bool = false) throws -> [URL] {
        let candidates = try files(in: cli.srcDir, matchingExtensions: ["flac", "wav", "mp3", "m4a", "mp4"])
        return includeDerived ? candidates : candidates.filter { !isLoudnessDerivedAudio($0) }
    }

    func audioFadeOutCandidates() throws -> [URL] {
        try files(in: cli.srcDir, matchingExtensions: ["flac", "wav", "mp3", "m4a"])
            .filter { !isFadeDerivedAudio($0) }
    }

    func audioTailFadeCandidates() throws -> [URL] {
        try files(in: cli.srcDir, matchingExtensions: ["flac", "wav", "mp3"])
            .filter { !isFadeDerivedAudio($0) }
    }

    func audioFadeCutCandidates() throws -> [URL] {
        try files(in: cli.srcDir, matchingExtensions: ["flac", "wav", "mp3"])
            .filter { !isFadeDerivedAudio($0) }
    }

    func preflightFadeOutSource(_ source: URL) throws {
        switch source.pathExtension.lowercasedASCII {
        case "flac":
            try preflightFLACInput(source)
        case "wav":
            try preflightWAVInput(source)
        case "mp3":
            try preflightMP3Input(source, requireNoVideo: false)
        case "m4a":
            guard source.pathExtension.lowercasedASCII == "m4a" else {
                throw AppError("Expected .m4a input: \(source.path)")
            }
            try preflightAudioInput(
                source,
                expectedContainerTokens: ["m4a", "mp4", "ipod", "mov"],
                expectedAudioCodecs: ["aac"],
                requireNoVideo: false,
                requireAudible: true
            )
        default:
            throw AppError("Unsupported fadeout source type: \(source.path)")
        }
    }

    func preflightTailFadeSource(_ source: URL) throws {
        switch source.pathExtension.lowercasedASCII {
        case "flac":
            try preflightFLACInput(source, requireNoVideo: false)
        case "wav":
            try preflightWAVInput(source, requireNoVideo: false)
        case "mp3":
            try preflightMP3Input(source, requireNoVideo: false)
        default:
            throw AppError("Unsupported fade source type: \(source.path)")
        }
    }

    func preflightAudioMediaSource(_ source: URL) throws {
        switch source.pathExtension.lowercasedASCII {
        case "flac":
            try preflightFLACInput(source, requireNoVideo: false)
        case "wav":
            try preflightWAVInput(source, requireNoVideo: false)
        case "mp3":
            try preflightMP3Input(source, requireNoVideo: false)
        case "m4a":
            try preflightAudioInput(
                source,
                expectedContainerTokens: ["m4a", "mp4", "ipod", "mov"],
                expectedAudioCodecs: ["aac"],
                requireNoVideo: false,
                requireAudible: true
            )
        case "mp4":
            try preflightAudioInput(
                source,
                expectedContainerTokens: ["mp4", "mov"],
                expectedAudioCodecs: nil,
                requireNoVideo: false,
                requireAudible: true
            )
        default:
            throw AppError("Unsupported bass source type: \(source.path)")
        }
    }

    func bassOutputSuffix(for spec: BassBoostSpec) -> String {
        if spec == BassBoostSpec(frequencyHz: BassBoostSpec.defaultFrequencyHz, gainDB: BassBoostSpec.defaultGainDB) {
            return "_bass"
        }
        func safeComponent(_ value: Double) -> String {
            ffmpegNumber(value)
                .replacingOccurrences(of: "-", with: "m")
                .replacingOccurrences(of: ".", with: "_")
        }
        return "_bass_\(safeComponent(spec.frequencyHz))Hz_\(safeComponent(spec.gainDB))dB"
    }

    func bassFilter(for spec: BassBoostSpec) -> String {
        "bass=f=\(ffmpegNumber(spec.frequencyHz)):g=\(ffmpegNumber(spec.gainDB)):t=h:w=\(ffmpegNumber(spec.frequencyHz)):p=2:precision=f64"
    }

    func loudnessPolicy(targetLUFS: Double, tolerance: Double = 0.8) -> AudioQCPolicy {
        AudioQCPolicy(
            name: "loudness-normalize",
            targetLUFS: targetLUFS,
            lufsTolerance: tolerance,
            maxTruePeakDBTP: config.audioQCMaxTruePeakDBTP,
            maxLoudnessRange: 50,
            maxDCOffset: config.audioQCMaxDCOffset,
            maxStereoImbalanceDB: max(config.audioQCMaxStereoImbalanceDB, 99),
            maxClippedSamples: max(config.audioQCMaxClippedSamples, 1_000_000),
            minimumAnalysisSeconds: 0.25
        )
    }

    func loudnessRenderPolicy(targetLUFS: Double, truePeakHeadroomDB: Double) -> AudioQCPolicy {
        let policy = loudnessPolicy(targetLUFS: targetLUFS)
        return AudioQCPolicy(
            name: policy.name,
            targetLUFS: policy.targetLUFS,
            lufsTolerance: policy.lufsTolerance,
            maxTruePeakDBTP: policy.maxTruePeakDBTP - max(0, truePeakHeadroomDB),
            maxLoudnessRange: policy.maxLoudnessRange,
            maxDCOffset: policy.maxDCOffset,
            maxStereoImbalanceDB: policy.maxStereoImbalanceDB,
            maxClippedSamples: policy.maxClippedSamples,
            minimumAnalysisSeconds: policy.minimumAnalysisSeconds
        )
    }

    func loudnessTruePeakHeadroomAttempts(for source: URL) -> [Double] {
        switch source.pathExtension.lowercasedASCII {
        case "mp3", "m4a", "mp4":
            return [0, 1, 2, 3]
        default:
            return [0]
        }
    }

    func loudnessMaxRenderAttempts(for source: URL) -> Int {
        switch source.pathExtension.lowercasedASCII {
        case "mp3", "m4a", "mp4":
            return 8
        default:
            return 5
        }
    }

    func clampedLoudnessValue(_ value: Double, lowerBound: Double, upperBound: Double) -> Double {
        min(max(value, lowerBound), upperBound)
    }

    func loudnessDeviation(_ result: AudioQCResult, policy: AudioQCPolicy) -> Double? {
        guard let integrated = result.metrics.integratedLUFS, integrated.isFinite else {
            return nil
        }
        return abs(integrated - policy.targetLUFS)
    }

    func loudnessTruePeakExcess(_ result: AudioQCResult, policy: AudioQCPolicy) -> Double? {
        guard let truePeak = result.metrics.truePeakDBTP, truePeak.isFinite, truePeak > policy.maxTruePeakDBTP else {
            return nil
        }
        return truePeak - policy.maxTruePeakDBTP
    }

    func isIntegratedLoudnessIssue(_ issue: String) -> Bool {
        issue.lowercasedASCII.contains("integrated loudness")
    }

    func isTruePeakIssue(_ issue: String) -> Bool {
        issue.lowercasedASCII.contains("true peak")
    }

    func loudnessNonRecoverableIssues(_ result: AudioQCResult) -> [String] {
        result.issues.filter { !isIntegratedLoudnessIssue($0) && !isTruePeakIssue($0) }
    }

    func loudnessCandidateScore(_ result: AudioQCResult, policy: AudioQCPolicy) -> Double {
        let deviation = loudnessDeviation(result, policy: policy) ?? 99
        let truePeakPenalty = (loudnessTruePeakExcess(result, policy: policy) ?? 0) * 50
        return deviation + truePeakPenalty + Double(loudnessNonRecoverableIssues(result).count) * 1_000
    }

    func loudnessCandidateIsPublishableFallback(_ result: AudioQCResult, policy: AudioQCPolicy) -> Bool {
        guard loudnessNonRecoverableIssues(result).isEmpty else {
            return false
        }
        guard loudnessTruePeakExcess(result, policy: policy) == nil else {
            return false
        }
        guard let deviation = loudnessDeviation(result, policy: policy) else {
            return false
        }
        return deviation <= max(1.0, policy.lufsTolerance * 1.25)
    }

    func shouldUseLimitedLoudnessRecovery(correctionDB: Double?, truePeakExcess: Double?, policy: AudioQCPolicy) -> Bool {
        guard let correctionDB, truePeakExcess != nil else {
            return false
        }
        return correctionDB > policy.lufsTolerance
    }

    func loudnessQCFailureMessage(file: URL, result: AudioQCResult) -> String {
        "Audio QC failed for \(file.path): \(result.issues.joined(separator: "; "))"
    }

    func linearAmplitude(fromDecibels decibels: Double) -> Double {
        pow(10, decibels / 20)
    }

    func loudnessLimitedRecoveryFilter(policy: AudioQCPolicy, recoveryGainDB: Double, limiterCeilingDBTP: Double) -> String {
        let limiterLimit = clampedLoudnessValue(linearAmplitude(fromDecibels: limiterCeilingDBTP), lowerBound: 0.01, upperBound: 1)
        return [
            loudnormSinglePassFilter(policy: policy),
            "volume=\(String(format: "%.2f", recoveryGainDB))dB",
            "alimiter=limit=\(String(format: "%.6f", limiterLimit)):level=false"
        ].joined(separator: ",")
    }

    func loudnessOutputSuffix(for spec: LoudnessSpec) -> String {
        let safeTarget = ffmpegNumber(spec.targetLUFS)
            .replacingOccurrences(of: "-", with: "m")
            .replacingOccurrences(of: ".", with: "_")
        return "_loudness_\(safeTarget)LUFS"
    }

    func loudnessMeasurement(for file: URL) throws -> LoudnessScanEntry {
        try preflightAudioMediaSource(file)
        let result = try audioQCResult(for: file, policy: loudnessPolicy(targetLUFS: config.audioQCTargetLUFS, tolerance: 99))
        guard let integrated = result.metrics.integratedLUFS, integrated.isFinite else {
            throw AppError("Unable to measure integrated loudness for \(file.path)")
        }
        return LoudnessScanEntry(file: file, integratedLUFS: integrated)
    }

    func loudScanReportLines(entries: [LoudnessScanEntry]) throws -> [String] {
        guard !entries.isEmpty else {
            throw AppError("No loudness entries to report.")
        }
        let average = entries.map(\.integratedLUFS).reduce(0, +) / Double(entries.count)
        let quietest = entries.min { $0.integratedLUFS < $1.integratedLUFS }!
        let loudest = entries.max { $0.integratedLUFS < $1.integratedLUFS }!
        let top3 = entries
            .sorted { $0.integratedLUFS > $1.integratedLUFS }
            .prefix(3)
        let top3Average = top3.map(\.integratedLUFS).reduce(0, +) / Double(top3.count)
        return [
            String(format: "Average loudness: %.2f LUFS across %d files", average, entries.count),
            String(format: "Lowest loudness: %.2f LUFS (%@)", quietest.integratedLUFS, quietest.file.basename),
            String(format: "Highest loudness: %.2f LUFS (%@)", loudest.integratedLUFS, loudest.file.basename),
            String(format: "Top 3 loudest average: %.2f LUFS", top3Average)
        ]
    }

    // Emits optional progress around each expensive loudness probe so long scans do not appear stalled.
    func loudScanReportLines(progress: ((LoudnessScanProgress) -> Void)? = nil) throws -> [String] {
        let files = try audioLoudnessCandidates(includeDerived: true)
        guard !files.isEmpty else {
            throw AppError("No supported audio media files (.flac, .wav, .mp3, .m4a, .mp4) found in '\(cli.srcDir.path)'.")
        }

        var entries: [LoudnessScanEntry] = []
        entries.reserveCapacity(files.count)
        for (index, file) in files.enumerated() {
            progress?(LoudnessScanProgress(
                processedFiles: index,
                totalFiles: files.count,
                currentFile: file,
                reportLines: [],
                isMeasuring: true
            ))

            entries.append(try loudnessMeasurement(for: file))
            progress?(LoudnessScanProgress(
                processedFiles: index + 1,
                totalFiles: files.count,
                currentFile: file,
                reportLines: try loudScanReportLines(entries: entries),
                isMeasuring: false
            ))
        }
        return try loudScanReportLines(entries: entries)
    }

    func verifyTailFadeOutput(_ file: URL, sourceExtension: String, expectedDuration: Double) throws {
        switch sourceExtension.lowercasedASCII {
        case "flac":
            try verifyFLACFile(file, sampleRate: config.flacSampleRate, channels: config.flacChannels, qcPolicy: nil)
        case "wav":
            try verifyWAVStandard(file, qcPolicy: nil)
        case "mp3":
            try verifyMP3Standard(file, qcPolicy: nil)
        default:
            throw AppError("Unsupported fade output type: \(file.path)")
        }
        try verifyDuration(file, expectedSeconds: expectedDuration, label: "fade output")
    }

    func verifyFadeOutOutput(_ file: URL, sourceExtension: String, expectedDuration: Double) throws {
        switch sourceExtension.lowercasedASCII {
        case "flac":
            try verifyFLACFile(file, sampleRate: config.flacSampleRate, channels: config.flacChannels, qcPolicy: nil)
        case "wav":
            try verifyWAVStandard(file, qcPolicy: nil)
        case "mp3":
            try verifyMP3Standard(file, qcPolicy: nil)
        case "m4a":
            try verifyM4AFile(file, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: nil)
        default:
            throw AppError("Unsupported fadeout output type: \(file.path)")
        }
        try verifyDuration(file, expectedSeconds: expectedDuration, label: "fadeout output")
    }

    func verifyBassOutput(_ file: URL, source: URL) throws {
        switch source.pathExtension.lowercasedASCII {
        case "flac":
            try verifyFLACFile(file, sampleRate: config.flacSampleRate, channels: config.flacChannels, qcPolicy: nil)
        case "wav":
            try verifyWAVStandard(file, qcPolicy: nil)
        case "mp3":
            try verifyMP3Standard(file, qcPolicy: nil)
        case "m4a":
            try verifyM4AFile(file, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: nil)
        case "mp4":
            try requireFormatNameContains(file, anyOf: ["mp4", "mov"], label: "MP4 container")
            if (try? requireVideoStream(source)) != nil {
                try verifyVideoOutput(file)
            }
            try verifyAudioOutput(file, codec: "aac", sampleRate: config.videoMP4AudioSampleRate, qcPolicy: nil)
        default:
            throw AppError("Unsupported bass output type: \(file.path)")
        }
        try verifyDurationMatch(source: source, output: file)
    }

    func makeBassFFmpegArguments(source: URL, spec: BassBoostSpec, output: URL) throws -> [String] {
        let filter = bassFilter(for: spec)
        switch source.pathExtension.lowercasedASCII {
        case "flac":
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-af", filter,
                "-vn", "-sn", "-dn",
                "-ac", String(config.flacChannels),
                "-ar", String(config.flacSampleRate),
                "-c:a", "flac",
                "-compression_level", String(config.flacCompressionLevel),
                output.path
            ]
        case "wav":
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-af", filter,
                "-vn", "-sn", "-dn",
                "-ac", String(config.wavChannels),
                "-ar", String(config.wavSampleRate),
                "-c:a", config.wavCodec,
                "-f", "wav",
                "-rf64", "always",
                "-write_bext", String(config.wavWriteBext),
                output.path
            ]
        case "mp3":
            try requireFFmpegEncoder("libmp3lame")
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-af", filter,
                "-vn", "-sn", "-dn",
                "-ar", String(config.mp3SampleRate),
                "-ac", String(config.mp3Channels),
                "-c:a", "libmp3lame",
                "-b:a", config.mp3Bitrate,
                output.path
            ]
        case "m4a":
            try requireFFmpegEncoder("aac")
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-af", filter,
                "-c:a", "aac",
                "-b:a", config.m4aBitrate,
                "-ar", String(config.m4aSampleRate),
                "-ac", String(config.m4aChannels),
                "-vn",
                output.path
            ]
        case "mp4":
            try requireFFmpegEncoder("aac")
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:v:0?",
                "-map", "0:a:0",
                "-af", filter,
                "-c:v", "copy",
                "-c:a", "aac",
                "-b:a", config.videoMP4AudioBitrate,
                "-ar", String(config.videoMP4AudioSampleRate),
                "-sn", "-dn",
                "-map_metadata", "0",
                "-map_chapters", "0",
                "-movflags", "+faststart",
                output.path
            ]
        default:
            throw AppError("Unsupported bass source type: \(source.path)")
        }
    }

    func bassBoostMedia(_ source: URL, spec: BassBoostSpec) throws -> URL {
        try preflightAudioMediaSource(source)
        let filters = try ffmpegFilterSet()
        guard filters.contains("bass") else {
            throw AppError("Required ffmpeg filter is not available: bass")
        }

        let output = cli.outDir
            .appendingPathComponent(source.stem + bassOutputSuffix(for: spec))
            .appendingPathExtension(source.pathExtension.lowercasedASCII)
        if canReuseOutput(output, verifier: {
            try self.verifyBassOutput(output, source: source)
        }) {
            logger.info("Skip existing bass-boosted media: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: cli.outDir, stem: output.stem, ext: ".\(output.pathExtension)")
        do {
            _ = try runner.run("ffmpeg", try makeBassFFmpegArguments(source: source, spec: spec, output: temp))
            try verifyBassOutput(temp, source: source)
            try publishTemp(temp, to: output)
            logger.info("Created bass-boosted media: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func loudnessOutputQCResult(_ file: URL, source: URL, policy: AudioQCPolicy) throws -> AudioQCResult {
        switch source.pathExtension.lowercasedASCII {
        case "flac":
            try verifyFLACFile(file, sampleRate: config.flacSampleRate, channels: config.flacChannels, qcPolicy: nil)
        case "wav":
            try verifyWAVStandard(file, qcPolicy: nil)
        case "mp3":
            try verifyMP3Standard(file, qcPolicy: nil)
        case "m4a":
            try verifyM4AFile(file, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: nil)
        case "mp4":
            try requireFormatNameContains(file, anyOf: ["mp4", "mov"], label: "MP4 container")
            if (try? requireVideoStream(source)) != nil {
                try verifyVideoOutput(file)
            }
            try verifyAudioOutput(file, codec: "aac", sampleRate: config.videoMP4AudioSampleRate, qcPolicy: nil)
        default:
            throw AppError("Unsupported loudness output type: \(file.path)")
        }
        try verifyDurationMatch(source: source, output: file)
        return try audioQCResult(for: file, policy: policy)
    }

    func verifyLoudnessOutput(_ file: URL, source: URL, policy: AudioQCPolicy) throws {
        let result = try loudnessOutputQCResult(file, source: source, policy: policy)
        if !result.passed {
            throw AppError(loudnessQCFailureMessage(file: file, result: result))
        }
    }

    func makeLoudnessFFmpegArguments(source: URL, filter: String, output: URL) throws -> [String] {
        switch source.pathExtension.lowercasedASCII {
        case "flac":
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-af", filter,
                "-vn", "-sn", "-dn",
                "-ac", String(config.flacChannels),
                "-ar", String(config.flacSampleRate),
                "-c:a", "flac",
                "-compression_level", String(config.flacCompressionLevel),
                output.path
            ]
        case "wav":
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-af", filter,
                "-vn", "-sn", "-dn",
                "-ac", String(config.wavChannels),
                "-ar", String(config.wavSampleRate),
                "-c:a", config.wavCodec,
                "-f", "wav",
                "-rf64", "always",
                "-write_bext", String(config.wavWriteBext),
                output.path
            ]
        case "mp3":
            try requireFFmpegEncoder("libmp3lame")
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-af", filter,
                "-vn", "-sn", "-dn",
                "-ar", String(config.mp3SampleRate),
                "-ac", String(config.mp3Channels),
                "-c:a", "libmp3lame",
                "-b:a", config.mp3Bitrate,
                output.path
            ]
        case "m4a":
            try requireFFmpegEncoder("aac")
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-af", filter,
                "-c:a", "aac",
                "-b:a", config.m4aBitrate,
                "-ar", String(config.m4aSampleRate),
                "-ac", String(config.m4aChannels),
                "-vn",
                output.path
            ]
        case "mp4":
            try requireFFmpegEncoder("aac")
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:v:0?",
                "-map", "0:a:0",
                "-af", filter,
                "-c:v", "copy",
                "-c:a", "aac",
                "-b:a", config.videoMP4AudioBitrate,
                "-ar", String(config.videoMP4AudioSampleRate),
                "-sn", "-dn",
                "-map_metadata", "0",
                "-map_chapters", "0",
                "-movflags", "+faststart",
                output.path
            ]
        default:
            throw AppError("Unsupported loudness source type: \(source.path)")
        }
    }

    func loudnessNormalizeMedia(_ source: URL, spec: LoudnessSpec) throws -> URL {
        try preflightAudioMediaSource(source)
        let policy = loudnessPolicy(targetLUFS: spec.targetLUFS)
        let output = cli.outDir
            .appendingPathComponent(source.stem + loudnessOutputSuffix(for: spec))
            .appendingPathExtension(source.pathExtension.lowercasedASCII)
        if canReuseOutput(output, verifier: {
            try self.verifyLoudnessOutput(output, source: source, policy: policy)
        }) {
            logger.info("Skip existing loudness-normalized media: \(output.basename)")
            return output
        }

        let headroomAttempts = loudnessTruePeakHeadroomAttempts(for: source)
        let maxAttempts = loudnessMaxRenderAttempts(for: source)
        let minimumRenderTarget = max(-70, spec.targetLUFS - 12)
        let maximumRenderTarget = min(0, spec.targetLUFS + 12)
        var renderTargetLUFS = spec.targetLUFS
        var truePeakHeadroomDB = headroomAttempts.first ?? 0
        var recoveryGainDB: Double?
        var limiterCeilingDBTP = policy.maxTruePeakDBTP - 1
        var bestCandidate: LoudnessRenderCandidate?
        var lastError: Error?
        var lastResult: AudioQCResult?
        var seenSettings = Set<String>()

        func discardTemp(_ temp: URL) {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
        }

        func keepIfBest(_ candidate: LoudnessRenderCandidate) {
            guard loudnessCandidateIsPublishableFallback(candidate.result, policy: policy) else {
                discardTemp(candidate.temp)
                return
            }
            if let bestCandidate {
                let candidateScore = loudnessCandidateScore(candidate.result, policy: policy)
                let bestScore = loudnessCandidateScore(bestCandidate.result, policy: policy)
                guard candidateScore < bestScore else {
                    discardTemp(candidate.temp)
                    return
                }
                discardTemp(bestCandidate.temp)
            }
            bestCandidate = candidate
        }

        for attempt in 1 ... maxAttempts {
            let settingKey: String
            if let recoveryGainDB {
                settingKey = "limited|\(String(format: "%.3f", recoveryGainDB))|\(String(format: "%.3f", limiterCeilingDBTP))"
            } else {
                settingKey = "linear|\(String(format: "%.3f", renderTargetLUFS))|\(String(format: "%.3f", truePeakHeadroomDB))"
            }
            if seenSettings.contains(settingKey) {
                if let gain = recoveryGainDB {
                    recoveryGainDB = clampedLoudnessValue(gain + 0.1, lowerBound: -12, upperBound: 12)
                } else {
                    renderTargetLUFS = clampedLoudnessValue(renderTargetLUFS + 0.1, lowerBound: minimumRenderTarget, upperBound: maximumRenderTarget)
                }
            }
            seenSettings.insert(settingKey)

            let renderPolicy = loudnessRenderPolicy(targetLUFS: renderTargetLUFS, truePeakHeadroomDB: truePeakHeadroomDB)
            let filter: String
            if let recoveryGainDB {
                filter = loudnessLimitedRecoveryFilter(
                    policy: policy,
                    recoveryGainDB: recoveryGainDB,
                    limiterCeilingDBTP: limiterCeilingDBTP
                )
            } else {
                let measurement = try loudnormMeasurement(for: source, policy: renderPolicy)
                filter = loudnormSecondPassFilter(policy: renderPolicy, measurement: measurement) ?? loudnormSinglePassFilter(policy: renderPolicy)
            }
            let temp = try makeTemp(in: cli.outDir, stem: output.stem, ext: ".\(output.pathExtension)")
            do {
                _ = try runner.run("ffmpeg", try makeLoudnessFFmpegArguments(source: source, filter: filter, output: temp))
                let result = try loudnessOutputQCResult(temp, source: source, policy: policy)
                lastResult = result
                if result.passed {
                    if let bestCandidate {
                        discardTemp(bestCandidate.temp)
                    }
                    bestCandidate = nil
                    try publishTemp(temp, to: output)
                    let measured = result.metrics.integratedLUFS.map { String(format: "%.2f", $0) } ?? "unknown"
                    logger.info("Created loudness-normalized media: \(output.basename) [integrated=\(measured) LUFS]")
                    return output
                }

                keepIfBest(LoudnessRenderCandidate(
                    temp: temp,
                    result: result
                ))

                let integrated = result.metrics.integratedLUFS
                let correctionDB = integrated.map { policy.targetLUFS - $0 }
                let truePeakExcess = loudnessTruePeakExcess(result, policy: policy)
                if let correctionDB, let truePeakExcess, shouldUseLimitedLoudnessRecovery(correctionDB: correctionDB, truePeakExcess: truePeakExcess, policy: policy) {
                    recoveryGainDB = clampedLoudnessValue(
                        (recoveryGainDB ?? 0) + correctionDB,
                        lowerBound: -12,
                        upperBound: 12
                    )
                    limiterCeilingDBTP = min(
                        limiterCeilingDBTP,
                        policy.maxTruePeakDBTP - max(1.0, truePeakExcess + 0.25)
                    )
                } else if let gain = recoveryGainDB, let correctionDB {
                    if abs(correctionDB) > max(0.05, policy.lufsTolerance / 4) {
                        recoveryGainDB = clampedLoudnessValue(gain + correctionDB, lowerBound: -12, upperBound: 12)
                    }
                    if let truePeakExcess {
                        limiterCeilingDBTP -= max(0.5, truePeakExcess + 0.25)
                    }
                } else if recoveryGainDB != nil {
                    if let truePeakExcess {
                        limiterCeilingDBTP -= max(0.5, truePeakExcess + 0.25)
                    }
                } else {
                    if let correctionDB, abs(correctionDB) > max(0.05, policy.lufsTolerance / 4) {
                        renderTargetLUFS = clampedLoudnessValue(
                            renderTargetLUFS + correctionDB,
                            lowerBound: minimumRenderTarget,
                            upperBound: maximumRenderTarget
                        )
                    }
                    if let truePeakExcess {
                        truePeakHeadroomDB = clampedLoudnessValue(
                            truePeakHeadroomDB + max(0.5, truePeakExcess + 0.25),
                            lowerBound: 0,
                            upperBound: 12
                        )
                    }
                }

                let measured = integrated.map { String(format: "%.2f", $0) } ?? "unknown"
                let nextCeiling = loudnessRenderPolicy(targetLUFS: renderTargetLUFS, truePeakHeadroomDB: truePeakHeadroomDB).maxTruePeakDBTP
                let modeDescription = recoveryGainDB.map {
                    "limited_recovery gain=\(String(format: "%.2f", $0))dB limiter=\(String(format: "%.2f", limiterCeilingDBTP))dB"
                } ?? "linear next_render_target=\(String(format: "%.2f", renderTargetLUFS)) LUFS next_tp_ceiling=\(String(format: "%.2f", nextCeiling)) dBTP"
                logger.warn(
                    "Loudness QC retry \(attempt)/\(maxAttempts) for \(source.basename): measured=\(measured) LUFS target=\(String(format: "%.2f", policy.targetLUFS)) mode=\(modeDescription)"
                )
            } catch {
                discardTemp(temp)
                if let bestCandidate {
                    discardTemp(bestCandidate.temp)
                }
                lastError = error
                throw error
            }
        }

        if let bestCandidate {
            try publishTemp(bestCandidate.temp, to: output)
            let measured = bestCandidate.result.metrics.integratedLUFS.map { String(format: "%.2f", $0) } ?? "unknown"
            let deviation = loudnessDeviation(bestCandidate.result, policy: policy) ?? 0
            logger.warn(
                "Created closest safe loudness-normalized media: \(output.basename) [integrated=\(measured) LUFS target=\(String(format: "%.2f", policy.targetLUFS)) deviation=\(String(format: "%.2f", deviation)) dB]"
            )
            return output
        }

        if let lastResult {
            throw AppError(loudnessQCFailureMessage(file: output, result: lastResult))
        }
        throw lastError ?? AppError("Unable to create loudness-normalized media: \(source.path)")
    }

    func makeTailFadeFFmpegArguments(source: URL, fadeStartSeconds: Double, fadeDurationSeconds: Double, output: URL) throws -> [String] {
        let fadeFilter = "afade=t=out:st=\(String(format: "%.6f", fadeStartSeconds)):d=\(String(format: "%.6f", fadeDurationSeconds))"
        switch source.pathExtension.lowercasedASCII {
        case "flac":
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-af", fadeFilter,
                "-vn", "-sn", "-dn",
                "-ac", String(config.flacChannels),
                "-ar", String(config.flacSampleRate),
                "-c:a", "flac",
                "-compression_level", String(config.flacCompressionLevel),
                output.path
            ]
        case "wav":
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-af", fadeFilter,
                "-vn", "-sn", "-dn",
                "-ac", String(config.wavChannels),
                "-ar", String(config.wavSampleRate),
                "-c:a", config.wavCodec,
                "-f", "wav",
                "-rf64", "always",
                "-write_bext", String(config.wavWriteBext),
                output.path
            ]
        case "mp3":
            try requireFFmpegEncoder("libmp3lame")
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-af", fadeFilter,
                "-vn", "-sn", "-dn",
                "-ar", String(config.mp3SampleRate),
                "-ac", String(config.mp3Channels),
                "-c:a", "libmp3lame",
                "-b:a", config.mp3Bitrate,
                output.path
            ]
        default:
            throw AppError("Unsupported fade source type: \(source.path)")
        }
    }

    func makeFadeCutFFmpegArguments(source: URL, targetDuration: Double, fadeStartSeconds: Double, fadeDurationSeconds: Double, output: URL) throws -> [String] {
        let fadeFilter = "afade=t=out:st=\(String(format: "%.6f", fadeStartSeconds)):d=\(String(format: "%.6f", fadeDurationSeconds))"
        let targetSeconds = String(format: "%.6f", targetDuration)
        switch source.pathExtension.lowercasedASCII {
        case "flac":
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-t", targetSeconds,
                "-af", fadeFilter,
                "-vn", "-sn", "-dn",
                "-ac", String(config.flacChannels),
                "-ar", String(config.flacSampleRate),
                "-c:a", "flac",
                "-compression_level", String(config.flacCompressionLevel),
                output.path
            ]
        case "wav":
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-t", targetSeconds,
                "-af", fadeFilter,
                "-vn", "-sn", "-dn",
                "-ac", String(config.wavChannels),
                "-ar", String(config.wavSampleRate),
                "-c:a", config.wavCodec,
                "-f", "wav",
                "-rf64", "always",
                "-write_bext", String(config.wavWriteBext),
                output.path
            ]
        case "mp3":
            try requireFFmpegEncoder("libmp3lame")
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-t", targetSeconds,
                "-af", fadeFilter,
                "-vn", "-sn", "-dn",
                "-ar", String(config.mp3SampleRate),
                "-ac", String(config.mp3Channels),
                "-c:a", "libmp3lame",
                "-b:a", config.mp3Bitrate,
                output.path
            ]
        default:
            throw AppError("Unsupported fadecut source type: \(source.path)")
        }
    }

    func makeFadeOutFFmpegArguments(source: URL, targetDuration: Double, fadeStartSeconds: Double, fadeDurationSeconds: Double, output: URL) throws -> [String] {
        let fadeFilter = "afade=t=out:st=\(String(format: "%.6f", fadeStartSeconds)):d=\(String(format: "%.6f", fadeDurationSeconds))"
        let targetSeconds = String(format: "%.6f", targetDuration)
        switch source.pathExtension.lowercasedASCII {
        case "flac":
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-t", targetSeconds,
                "-af", fadeFilter,
                "-vn",
                "-ac", String(config.flacChannels),
                "-ar", String(config.flacSampleRate),
                "-c:a", "flac",
                "-compression_level", String(config.flacCompressionLevel),
                output.path
            ]
        case "wav":
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-t", targetSeconds,
                "-af", fadeFilter,
                "-ac", String(config.wavChannels),
                "-ar", String(config.wavSampleRate),
                "-c:a", config.wavCodec,
                "-f", "wav",
                "-rf64", "always",
                "-write_bext", String(config.wavWriteBext),
                output.path
            ]
        case "mp3":
            try requireFFmpegEncoder("libmp3lame")
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-t", targetSeconds,
                "-af", fadeFilter,
                "-ar", String(config.mp3SampleRate),
                "-ac", String(config.mp3Channels),
                "-c:a", "libmp3lame",
                "-b:a", config.mp3Bitrate,
                output.path
            ]
        case "m4a":
            try requireFFmpegEncoder("aac")
            return [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-t", targetSeconds,
                "-af", fadeFilter,
                "-c:a", "aac",
                "-b:a", config.m4aBitrate,
                "-ar", String(config.m4aSampleRate),
                "-ac", String(config.m4aChannels),
                "-vn",
                output.path
            ]
        default:
            throw AppError("Unsupported fadeout source type: \(source.path)")
        }
    }

    func fadeCutAudio(_ source: URL, spec: FadeCutSpec) throws -> URL {
        try preflightTailFadeSource(source)
        guard let duration = try mediaDuration(source) else {
            throw AppError("Unable to read source duration for fadecut: \(source.path)")
        }
        let targetDuration = duration - spec.cutSeconds
        guard targetDuration > 0 else {
            throw AppError("Fadecut would remove the entire audio file: cut=\(spec.cutSeconds)s duration=\(duration)s for \(source.basename)")
        }

        let fadeSeconds = min(spec.fadeDurationSeconds, targetDuration)
        let fadeStart = max(0, targetDuration - fadeSeconds)
        let output = cli.outDir.appendingPathComponent("\(source.stem)_fadecut").appendingPathExtension(source.pathExtension.lowercasedASCII)
        if canReuseOutput(output, verifier: {
            try self.verifyTailFadeOutput(output, sourceExtension: source.pathExtension, expectedDuration: targetDuration)
        }) {
            logger.info("Skip existing fadecut audio: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: cli.outDir, stem: output.stem, ext: ".\(output.pathExtension)")
        do {
            _ = try runner.run("ffmpeg", try makeFadeCutFFmpegArguments(
                source: source,
                targetDuration: targetDuration,
                fadeStartSeconds: fadeStart,
                fadeDurationSeconds: fadeSeconds,
                output: temp
            ))
            try verifyTailFadeOutput(temp, sourceExtension: source.pathExtension, expectedDuration: targetDuration)
            try publishTemp(temp, to: output)
            logger.info("Created fadecut audio: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func fadeTailAudio(_ source: URL, fadeSeconds requestedFadeSeconds: Double) throws -> URL {
        try preflightTailFadeSource(source)
        guard let duration = try mediaDuration(source) else {
            throw AppError("Unable to read source duration for fade: \(source.path)")
        }
        guard duration > 0 else {
            throw AppError("Audio duration must be greater than zero for fade: \(source.path)")
        }

        let fadeSeconds = min(requestedFadeSeconds, duration)
        let fadeStart = max(0, duration - fadeSeconds)
        let output = cli.outDir.appendingPathComponent("\(source.stem)_faded").appendingPathExtension(source.pathExtension.lowercasedASCII)
        if canReuseOutput(output, verifier: {
            try self.verifyTailFadeOutput(output, sourceExtension: source.pathExtension, expectedDuration: duration)
        }) {
            logger.info("Skip existing faded audio: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: cli.outDir, stem: output.stem, ext: ".\(output.pathExtension)")
        do {
            _ = try runner.run("ffmpeg", try makeTailFadeFFmpegArguments(
                source: source,
                fadeStartSeconds: fadeStart,
                fadeDurationSeconds: fadeSeconds,
                output: temp
            ))
            try verifyTailFadeOutput(temp, sourceExtension: source.pathExtension, expectedDuration: duration)
            try publishTemp(temp, to: output)
            logger.info("Created faded audio: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func fadeOutAudio(_ source: URL, spec: FadeOutSpec) throws -> URL {
        try preflightFadeOutSource(source)
        guard let sourceDuration = try mediaDuration(source) else {
            throw AppError("Unable to read source duration for fadeout: \(source.path)")
        }
        let targetDuration = spec.endSeconds
        let allowedSourceOverrun = 0.05
        guard spec.fadeStartSeconds < sourceDuration else {
            throw AppError("Fade start \(spec.fadeStartSeconds)s is beyond source duration \(sourceDuration)s for \(source.basename)")
        }
        if targetDuration - sourceDuration > allowedSourceOverrun {
            throw AppError("Fade end \(targetDuration)s exceeds source duration \(sourceDuration)s for \(source.basename)")
        }

        let output = cli.outDir.appendingPathComponent("\(source.stem)_faded").appendingPathExtension(source.pathExtension.lowercasedASCII)
        if canReuseOutput(output, verifier: {
            try self.verifyFadeOutOutput(output, sourceExtension: source.pathExtension, expectedDuration: targetDuration)
        }) {
            logger.info("Skip existing faded audio: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: cli.outDir, stem: output.stem, ext: ".\(output.pathExtension)")
        do {
            _ = try runner.run("ffmpeg", try makeFadeOutFFmpegArguments(
                source: source,
                targetDuration: targetDuration,
                fadeStartSeconds: spec.fadeStartSeconds,
                fadeDurationSeconds: spec.fadeDurationSeconds,
                output: temp
            ))
            try verifyFadeOutOutput(temp, sourceExtension: source.pathExtension, expectedDuration: targetDuration)
            try publishTemp(temp, to: output)
            logger.info("Created faded audio: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func ensureStandardMP3Output(from source: URL) throws -> URL {
        let output = cli.outDir.appendingPathComponent(source.lastPathComponent)
        if source.standardizedFileURL == output.standardizedFileURL {
            try preflightMP3Input(source)
            try verifyMP3Standard(source, qcPolicy: nil)
            return source
        }
        if canReuseOutput(output, verifier: { try verifyMP3Standard(output, qcPolicy: nil) }) {
            return output
        }
        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".mp3")
        do {
            try copyFileIntoTemp(source, temp: temp)
            // mp3clean is a structural cleanup pass, not a mastering/remediation step.
            try verifyMP3Standard(temp, qcPolicy: nil)
            try publishTemp(temp, to: output)
            logger.info("Created MP3: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func normalizeWAVInPlace(_ source: URL) throws {
        logger.info("Normalize WAV: \(source.basename)")
        try preflightWAVInput(source)
        let temp = try makeTemp(in: source.deletingLastPathComponent(), stem: "\(source.stem).normalized", ext: ".wav")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-ac", String(config.wavChannels),
                "-ar", String(config.wavSampleRate),
                "-c:a", config.wavCodec,
                "-f", "wav",
                "-rf64", "always",
                "-write_bext", String(config.wavWriteBext),
                temp.path
            ])
            try verifyWAVStandard(temp, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: temp)
            try verifyCanonicalPCMSampleEquivalence(
                source: source,
                output: temp,
                sampleRate: config.wavSampleRate,
                channels: config.wavChannels,
                label: "Normalized WAV"
            )
            try publishTemp(temp, to: source)
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func estimateWAVBytes(duration: Double, channels: Int) -> UInt64 {
        if duration <= 0 || channels <= 0 { return 0 }
        return UInt64((duration * Double(config.wavSampleRate * channels * 4)).rounded()) + 1_048_576
    }

    // Use the stricter WAV contract only for WAV sources; other audio inputs use generic media preflight.
    func preflightAudioSourceForTranscode(_ source: URL) throws {
        switch source.pathExtension.lowercasedASCII {
        case "wav":
            try preflightWAVInput(source)
        case "flac":
            try preflightFLACInput(source)
        case "mp3":
            try preflightMP3Input(source)
        case "m4a":
            try preflightM4AInput(source)
        default:
            throw AppError("Unsupported audio input type: \(source.path)")
        }
    }

    // Convert any supported audio source into the project WAV standard.
    func convertAudioToWAV(_ source: URL) throws -> URL {
        try preflightAudioSourceForTranscode(source)
        let output = cli.outDir.appendingPathComponent(source.stem).appendingPathExtension("wav")
        if canReuseOutput(output, verifier: {
            try verifyWAVStandard(output, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: output)
            try verifyCanonicalPCMSampleEquivalence(
                source: source,
                output: output,
                sampleRate: config.wavSampleRate,
                channels: config.wavChannels,
                label: "WAV output"
            )
        }) {
            logger.info("Skip existing WAV: \(output.basename)")
            return output
        }
        if let duration = try mediaDuration(source) {
            let need = estimateWAVBytes(duration: duration, channels: config.wavChannels)
            let free = try availableBytes(at: cli.outDir)
            if need > 0 && free < need {
                throw AppError("Low free space for \(source.basename): avail=\(free) need~\(need)")
            }
        }
        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".wav")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-ac", String(config.wavChannels),
                "-ar", String(config.wavSampleRate),
                "-c:a", config.wavCodec,
                "-f", "wav",
                "-rf64", "always",
                "-write_bext", String(config.wavWriteBext),
                temp.path
            ])
            try verifyWAVStandard(temp, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: temp)
            try verifyCanonicalPCMSampleEquivalence(
                source: source,
                output: temp,
                sampleRate: config.wavSampleRate,
                channels: config.wavChannels,
                label: "WAV output"
            )
            try publishTemp(temp, to: output)
            logger.info("Created WAV: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func convertFLACToWAV(_ source: URL) throws -> URL {
        try convertAudioToWAV(source)
    }

    func convertMP3ToWAV(_ source: URL) throws -> URL {
        try convertAudioToWAV(source)
    }

    func convertM4AToWAV(_ source: URL) throws -> URL {
        try convertAudioToWAV(source)
    }

    func convertWAVToM4A(_ source: URL) throws -> URL {
        try preflightWAVInput(source)
        try requireFFmpegEncoder("aac")
        let output = cli.outDir.appendingPathComponent(source.stem).appendingPathExtension("m4a")
        if canReuseOutput(output, verifier: {
            try verifyM4AFile(output, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: output)
            try verifySourceLoudnessPreserved(source: source, output: output)
        }) {
            logger.info("Skip existing M4A: \(output.basename)")
            return output
        }
        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".m4a")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-c:a", "aac",
                "-b:a", config.m4aBitrate,
                "-ar", String(config.m4aSampleRate),
                "-ac", String(config.m4aChannels),
                "-vn",
                temp.path
            ])
            try verifyM4AFile(temp, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: temp)
            try verifySourceLoudnessPreserved(source: source, output: temp)
            try publishTemp(temp, to: output)
            logger.info("Created M4A: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func convertAudioToM4A(_ source: URL) throws -> URL {
        try preflightAudioSourceForTranscode(source)
        try requireFFmpegEncoder("aac")
        let output = cli.outDir.appendingPathComponent(source.stem).appendingPathExtension("m4a")
        if canReuseOutput(output, verifier: {
            try verifyM4AFile(output, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: output)
            try verifySourceLoudnessPreserved(source: source, output: output)
        }) {
            logger.info("Skip existing M4A: \(output.basename)")
            return output
        }
        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".m4a")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-c:a", "aac",
                "-b:a", config.m4aBitrate,
                "-ar", String(config.m4aSampleRate),
                "-ac", String(config.m4aChannels),
                "-vn",
                temp.path
            ])
            try verifyM4AFile(temp, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: temp)
            try verifySourceLoudnessPreserved(source: source, output: temp)
            try publishTemp(temp, to: output)
            logger.info("Created M4A: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    // Convert any supported audio source into project-standard MP3.
    func convertAudioToMP3(_ source: URL, forceRebuild: Bool = false) throws -> URL {
        try preflightAudioSourceForTranscode(source)
        try requireFFmpegEncoder("libmp3lame")
        let output = cli.outDir.appendingPathComponent(source.stem).appendingPathExtension("mp3")
        if !forceRebuild, canReuseOutput(output, verifier: {
            try verifyMP3Standard(output, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: output)
            try verifySourceLoudnessPreserved(source: source, output: output)
        }) {
            logger.info("Skip existing MP3: \(output.basename)")
            return output
        }
        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".mp3")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-ar", String(config.mp3SampleRate),
                "-ac", String(config.mp3Channels),
                "-c:a", "libmp3lame",
                "-b:a", config.mp3Bitrate,
                temp.path
            ])
            try verifyMP3Standard(temp, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: temp)
            try verifySourceLoudnessPreserved(source: source, output: temp)
            try publishTemp(temp, to: output)
            logger.info("Created MP3: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func convertWAVToMP3(_ source: URL, forceRebuild: Bool = false) throws -> URL {
        try convertAudioToMP3(source, forceRebuild: forceRebuild)
    }

    func convertFLACToMP3(_ source: URL) throws -> URL {
        try convertAudioToMP3(source)
    }

    func convertM4AToMP3(_ source: URL) throws -> URL {
        try convertAudioToMP3(source)
    }

    // Convert any supported audio source into FLAC.
    func convertAudioToFLAC(_ source: URL) throws -> URL {
        try preflightAudioSourceForTranscode(source)
        let output = cli.outDir.appendingPathComponent(source.stem).appendingPathExtension("flac")
        if canReuseOutput(output, verifier: {
            try verifyFLACFile(output, sampleRate: config.flacSampleRate, channels: config.flacChannels, requireAudible: true, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: output)
            try verifyCanonicalPCMSampleEquivalence(
                source: source,
                output: output,
                sampleRate: config.flacSampleRate,
                channels: config.flacChannels,
                label: "FLAC output",
                format: .s24le
            )
        }) {
            logger.info("Skip existing FLAC: \(output.basename)")
            return output
        }
        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".flac")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-vn",
                "-ac", String(config.flacChannels),
                "-ar", String(config.flacSampleRate),
                "-c:a", "flac",
                "-compression_level", String(config.flacCompressionLevel),
                "-map_metadata", "0",
                temp.path
            ])
            try verifyFLACFile(temp, sampleRate: config.flacSampleRate, channels: config.flacChannels, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: temp)
            try verifyCanonicalPCMSampleEquivalence(
                source: source,
                output: temp,
                sampleRate: config.flacSampleRate,
                channels: config.flacChannels,
                label: "FLAC output",
                format: .s24le
            )
            try publishTemp(temp, to: output)
            logger.info("Created FLAC: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func convertWAVToFLAC(_ source: URL) throws -> URL {
        try convertAudioToFLAC(source)
    }

    func convertMP3ToFLAC(_ source: URL) throws -> URL {
        try convertAudioToFLAC(source)
    }

    func convertM4AToFLAC(_ source: URL) throws -> URL {
        try convertAudioToFLAC(source)
    }

    func cleanMP3(_ source: URL) throws {
        try preflightMP3Input(source, requireAudible: false, requireNoVideo: false)
        let temp = try makeTemp(in: source.deletingLastPathComponent(), stem: "\(source.stem).notags", ext: ".mp3")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-vn",
                "-sn",
                "-dn",
                "-map", "0:a:0",
                "-c:a", "copy",
                "-map_metadata", "-1",
                "-map_chapters", "-1",
                temp.path
            ])
            // Metadata cleanup must preserve the original audio stream even if delivery policy would reject it.
            try verifyMP3File(temp, requireAudible: false, requireNoVideo: true, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: temp)
            try publishTemp(temp, to: source)
            logger.info("Cleaned MP3 metadata: \(source.basename)")
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func fadeWAV(_ source: URL) throws -> URL {
        try preflightWAVInput(source)
        guard let duration = try mediaDuration(source) else {
            throw AppError("Unable to read numeric WAV duration from: \(source.path)")
        }
        let fadeStart = max(0, duration - Double(config.wavFadeDur))
        let output = cli.outDir.appendingPathComponent("\(source.stem)_Faded_rf64").appendingPathExtension("wav")
        if canReuseOutput(output, verifier: {
            try verifyWAVStandard(output, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: output)
        }) {
            logger.info("Skip existing faded WAV: \(output.basename)")
            return output
        }
        let temp = try makeTemp(in: cli.outDir, stem: output.stem, ext: ".wav")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-af", "afade=t=out:st=\(String(format: "%.6f", fadeStart)):d=\(config.wavFadeDur)",
                "-c:a", config.wavCodec,
                "-ar", String(config.wavSampleRate),
                "-ac", String(config.wavChannels),
                "-f", "wav",
                "-rf64", "always",
                "-write_bext", String(config.wavWriteBext),
                temp.path
            ])
            try verifyWAVStandard(temp, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: temp)
            try publishTemp(temp, to: output)
            logger.info("Created faded WAV: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func createExternalFLACVariant(source: URL, output: URL) throws -> URL {
        if canReuseOutput(output, verifier: {
            try verifyFLACFile(output, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: output)
            try verifyCanonicalPCMSampleEquivalence(source: source, output: output, label: "External FLAC", format: .s24le)
        }) {
            logger.info("Skip existing external FLAC: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: output.deletingLastPathComponent(), stem: output.stem, ext: ".flac")
        do {
            let ext = source.pathExtension.lowercasedASCII
            if ext == "flac" {
                _ = try runner.run("ffmpeg", [
                    "-hide_banner", "-nostdin", "-v", "error", "-y",
                    "-i", source.path,
                    "-map", "0:a:0",
                    "-vn",
                    "-c:a", "copy",
                    "-map_metadata", "0",
                    temp.path
                ])
            } else {
                _ = try runner.run("ffmpeg", [
                    "-hide_banner", "-nostdin", "-v", "error", "-y",
                    "-i", source.path,
                    "-map", "0:a:0",
                    "-vn",
                    "-c:a", "flac",
                    "-compression_level", String(config.flacCompressionLevel),
                    temp.path
                ])
            }
            try verifyFLACFile(temp, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: temp)
            try verifyCanonicalPCMSampleEquivalence(source: source, output: temp, label: "External FLAC", format: .s24le)
            try publishTemp(temp, to: output)
            logger.info("Created external FLAC: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func createExternalWAVVariant(source: URL, output: URL, writeBext: Bool) throws -> URL {
        if canReuseOutput(output, verifier: {
            try verifyExternalWAVVariant(output, source: source, expectBext: writeBext)
        }) {
            logger.info("Skip existing external WAV: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: output.deletingLastPathComponent(), stem: output.stem, ext: ".wav")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-ac", String(config.wavChannels),
                "-ar", String(config.wavSampleRate),
                "-c:a", config.wavCodec,
                "-f", "wav",
                "-rf64", "always",
                "-write_bext", writeBext ? "1" : "0",
                temp.path
            ])
            try verifyExternalWAVVariant(temp, source: source, expectBext: writeBext)
            try publishTemp(temp, to: output)
            logger.info("Created external WAV: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func createExternalBW64WAVVariant(source: URL, output: URL) throws -> URL {
        if canReuseOutput(output, verifier: {
            try verifyBW64WAVVariant(output, source: source)
        }) {
            logger.info("Skip existing external BW64 WAV: \(output.basename)")
            return output
        }

        let rawPCM = try makeTemp(in: output.deletingLastPathComponent(), stem: output.stem, ext: ".f32le")
        let temp = try makeTemp(in: output.deletingLastPathComponent(), stem: output.stem, ext: ".wav")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-ac", String(config.wavChannels),
                "-ar", String(config.wavSampleRate),
                "-f", "f32le",
                "-acodec", "pcm_f32le",
                rawPCM.path
            ])
            try writeBW64FileFromRawFloatPCM(
                inputPCM: rawPCM,
                output: temp,
                channels: config.wavChannels,
                sampleRate: config.wavSampleRate,
                bitDepth: 32
            )
            try verifyBW64WAVVariant(temp, source: source)
            try publishTemp(temp, to: output)
            try? fileManager.removeItem(at: rawPCM)
            state.unregister(tempFile: rawPCM)
            logger.info("Created external BW64 WAV: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: rawPCM)
            state.unregister(tempFile: rawPCM)
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func generateExternalArchivalVariants(baseName: String, highQualitySource: URL) throws -> ExternalArchivalVariants {
        let rf64FLAC = cli.outDir.appendingPathComponent("\(baseName)_RF64").appendingPathExtension("flac")
        let bw64FLAC = cli.outDir.appendingPathComponent("\(baseName)_BW64").appendingPathExtension("flac")
        let rf64WAV = cli.outDir.appendingPathComponent("\(baseName)_RF64").appendingPathExtension("wav")
        let bw64WAV = cli.outDir.appendingPathComponent("\(baseName)_BW64").appendingPathExtension("wav")

        let createdRF64FLAC = try createExternalFLACVariant(source: highQualitySource, output: rf64FLAC)
        let createdBW64FLAC = try createExternalFLACVariant(source: highQualitySource, output: bw64FLAC)
        let createdRF64WAV = try createExternalWAVVariant(source: highQualitySource, output: rf64WAV, writeBext: false)
        let createdBW64WAV = try createExternalBW64WAVVariant(source: highQualitySource, output: bw64WAV)

        return ExternalArchivalVariants(
            rf64FLAC: createdRF64FLAC,
            bw64FLAC: createdBW64FLAC,
            rf64WAV: createdRF64WAV,
            bw64WAV: createdBW64WAV
        )
    }

    func crc32(for file: URL) throws -> String {
        let polynomial: UInt32 = 0xEDB88320
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0 ..< 256 {
            var value = UInt32(index)
            for _ in 0 ..< 8 {
                value = (value & 1) == 1 ? polynomial ^ (value >> 1) : (value >> 1)
            }
            table[index] = value
        }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var crc: UInt32 = 0
        while autoreleasepool(invoking: {
            let data = try? handle.read(upToCount: config.crcChunkBytes)
            guard let chunk = data, !chunk.isEmpty else {
                return false
            }
            crc = chunk.reduce(crc) { current, byte in
                let idx = Int((current ^ UInt32(byte)) & 0xFF)
                return table[idx] ^ (current >> 8)
            }
            return true
        }) {}

        return String(format: "%08X", crc)
    }

    @discardableResult
    func hashRename(ext: String, warnWhenEmpty: Bool = true) throws -> Int {
        let files = try self.files(in: cli.srcDir, matchingExtensions: [ext])
        if files.isEmpty {
            if warnWhenEmpty {
                logger.warn("No .\(ext) files found in '\(cli.srcDir.path)'.")
            }
            return 0
        }
        var processed = 0
        for file in files {
            switch ext {
            case "flac":
                try preflightFLACInput(file)
            case "mp3":
                try preflightMP3Input(file, requireAudible: false, requireNoVideo: false)
            case "wav":
                try preflightWAVInput(file)
            case "mp4":
                try preflightMP4Input(file, requireAudio: false, requireAudibleAudio: false)
            default:
                break
            }
            let hash = try crc32(for: file)
            let destination = cli.outDir.appendingPathComponent(hash).appendingPathExtension(ext)
            if file.standardizedFileURL == destination.standardizedFileURL {
                logger.info("Skip already-hashed \(ext): \(file.basename)")
                continue
            }
            if fileManager.fileExists(atPath: destination.path), !cli.overwrite {
                logger.warn("Destination exists, skipping: \(destination.basename)")
                continue
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try ensureWritableDirectory(destination.deletingLastPathComponent())
            try fileManager.moveItem(at: file, to: destination)
            logger.info("Renamed \(ext): \(file.basename) -> \(destination.basename)")
            processed += 1
        }
        return processed
    }

    func sortNatural(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func buildAlbum(from entries: [URL], output: URL) throws -> URL {
        guard !entries.isEmpty else {
            throw AppError("No valid album inputs provided.")
        }
        let channelLayout = config.wavChannels == 1 ? "mono" : "stereo"
        try ensureWritableDirectory(output.deletingLastPathComponent())
        let temp = try makeTemp(in: output.deletingLastPathComponent(), stem: output.stem, ext: ".wav")

        var ffArgs: [String] = ["-hide_banner", "-nostdin", "-v", "error", "-y"]
        for file in entries {
            ffArgs += ["-i", file.path]
        }

        var filter = ""
        var concatInputs = ""
        for index in entries.indices {
            filter += "[\(index):a]aresample=\(config.wavSampleRate),aformat=sample_fmts=flt:channel_layouts=\(channelLayout)[a\(index)];"
        }
        for index in 0 ..< max(entries.count - 1, 0) {
            filter += "anullsrc=r=\(config.wavSampleRate):cl=\(channelLayout):d=\(config.albumSilenceSecs),aformat=sample_fmts=flt:channel_layouts=\(channelLayout)[s\(index)];"
        }
        for index in entries.indices {
            concatInputs += "[a\(index)]"
            if index < entries.count - 1 {
                concatInputs += "[s\(index)]"
            } else if cli.trailingSilence {
                let silenceIndex = entries.count - 1
                filter += "anullsrc=r=\(config.wavSampleRate):cl=\(channelLayout):d=\(config.albumSilenceSecs),aformat=sample_fmts=flt:channel_layouts=\(channelLayout)[s\(silenceIndex)];"
                concatInputs += "[s\(silenceIndex)]"
            }
        }

        let segments = concatInputs.filter { $0 == "[" }.count
        filter += "\(concatInputs)concat=n=\(segments):v=0:a=1[out]"
        ffArgs += [
            "-filter_complex", filter,
            "-map", "[out]",
            "-ar", String(config.wavSampleRate),
            "-ac", String(config.wavChannels),
            "-c:a", config.wavCodec,
            "-f", "wav",
            "-rf64", "always",
            "-write_bext", String(config.wavWriteBext),
            temp.path
        ]

        do {
            _ = try runner.run("ffmpeg", ffArgs)
            try verifyWAVStandard(temp, qcPolicy: nil)
            try publishTemp(temp, to: output)
            logger.info("Created album WAV: \(output.path)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func buildAlbumFromAlbumFile(extension ext: String, defaultOutputName: String) throws -> URL {
        let albumPath = cli.scriptDirectory.appendingPathComponent("album.txt")
        guard fileManager.fileExists(atPath: albumPath.path) else {
            throw AppError("Missing album file: \(albumPath.path)")
        }
        let text = try String(contentsOf: albumPath, encoding: .utf8)
        var entries: [URL] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmed
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            let candidateName = line.lowercasedASCII.hasSuffix(".\(ext)") ? line : line + ".\(ext)"
            let file = try resolveExplicitPath(candidateName, baseDirectory: cli.srcDir)
            guard fileManager.fileExists(atPath: file.path) else {
                logger.warn("Missing track, skipping: \(file.path)")
                continue
            }
            if ext == "wav" {
                try preflightWAVInput(file)
            } else {
                switch ext {
                case "mp3":
                    try preflightMP3Input(file)
                case "flac":
                    try preflightFLACInput(file)
                case "m4a":
                    try preflightM4AInput(file)
                default:
                    try preflightAudioInput(file)
                }
            }
            entries.append(file)
        }
        guard !entries.isEmpty else {
            throw AppError("No valid tracks found in '\(albumPath.path)'.")
        }
        let output = try resolveOutputPath(cli.outputFile ?? defaultOutputName)
        return try buildAlbum(from: entries, output: output)
    }

    func buildAlbumFromFLACDirectory() throws -> URL {
        let flacs = try sortNatural(files(in: cli.srcDir, matchingExtensions: ["flac"]))
        if flacs.isEmpty {
            throw AppError("No .flac files found in '\(cli.srcDir.path)'.")
        }
        for file in flacs {
            try preflightFLACInput(file)
        }
        let output = try resolveOutputPath(cli.outputFile ?? "album.wav")
        return try buildAlbum(from: flacs, output: output)
    }

}
