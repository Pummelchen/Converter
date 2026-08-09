import Foundation

struct LoudnessStaticGainPlan: Equatable {
    let sourceIntegratedLUFS: Double
    let sourcePeakDBFS: Double
    let requestedGainDB: Double
    let maxSafeBoostDB: Double
    let appliedGainDB: Double
    let peakConstrained: Bool
}

extension ConverterTool {
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
        return stem.contains("_faded") || stem.contains("_fadecut") || stem.contains("_fadeout")
    }

    func isSilenceDerivedMedia(_ file: URL) -> Bool {
        let stem = file.stem.lowercasedASCII
        guard let marker = stem.range(of: "_silence_") else {
            return false
        }
        let suffix = stem[marker.upperBound...]
        guard suffix.hasSuffix("s") else {
            return false
        }
        let numericToken = suffix.dropLast()
        return !numericToken.isEmpty && numericToken.allSatisfy { $0.isNumber || $0 == "_" }
    }

    func isNoiseDerivedMedia(_ file: URL) -> Bool {
        let stem = file.stem.lowercasedASCII
        guard let marker = stem.range(of: "_noise_") else {
            return false
        }
        let suffix = stem[marker.upperBound...]
        guard suffix.hasSuffix("s") else {
            return false
        }
        let numericToken = suffix.dropLast()
        return !numericToken.isEmpty && numericToken.allSatisfy { $0.isNumber || $0 == "_" }
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

    func audioSilenceCandidates() throws -> [URL] {
        try files(in: cli.srcDir, matchingExtensions: ["wav", "flac", "mp4"])
            .filter { !isSilenceDerivedMedia($0) }
    }

    func audioNoiseCandidates() throws -> [URL] {
        try files(in: cli.srcDir, matchingExtensions: ["flac", "wav", "mp3", "m4a", "mp4"])
            .filter { !isNoiseDerivedMedia($0) }
    }

    func fadeOutFilter(fadeStartSeconds: Double, fadeDurationSeconds: Double) -> String {
        "afade=t=out:st=\(ffmpegArg("%.6f", fadeStartSeconds)):d=\(ffmpegArg("%.6f", fadeDurationSeconds))"
    }

    func silenceAudioFilter(for spec: SilenceSpec) -> String {
        "adelay=\(spec.delayMilliseconds):all=1,apad=pad_dur=\(ffmpegArg("%.6f", spec.seconds))"
    }

    func silenceOutputSuffix(for spec: SilenceSpec) -> String {
        let safeSeconds = ffmpegNumber(spec.seconds)
            .replacingOccurrences(of: "-", with: "m")
            .replacingOccurrences(of: ".", with: "_")
        return "_silence_\(safeSeconds)s"
    }

    func silenceExpectedDuration(sourceDuration: Double, spec: SilenceSpec) -> Double {
        sourceDuration + spec.effectiveLeadingSeconds + spec.seconds
    }

    func noiseOutputSuffix(for spec: NoiseSpec) -> String {
        let safeSeconds = ffmpegNumber(spec.seconds)
            .replacingOccurrences(of: "-", with: "m")
            .replacingOccurrences(of: ".", with: "_")
        return "_noise_\(safeSeconds)s"
    }

    func noiseExpectedDuration(sourceDuration: Double, spec: NoiseSpec) -> Double {
        sourceDuration + (spec.seconds * 2) + (NoiseSpec.transitionSilenceSeconds * 2)
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
                expectedAudioCodecs: ["aac", "alac"],
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

    func preflightSilenceSource(_ source: URL) throws {
        switch source.pathExtension.lowercasedASCII {
        case "flac":
            try preflightFLACInput(source, requireNoVideo: false)
        case "wav":
            try preflightWAVInput(source, requireNoVideo: false)
        case "mp4":
            try preflightAudioInput(
                source,
                expectedContainerTokens: ["mp4", "mov"],
                expectedAudioCodecs: nil,
                requireNoVideo: false,
                requireAudible: true
            )
        default:
            throw AppError("Unsupported silence source type: \(source.path)")
        }
    }

    func preflightNoiseSource(_ source: URL) throws {
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
                expectedAudioCodecs: ["aac", "alac"],
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
            throw AppError("Unsupported noise source type: \(source.path)")
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
                expectedAudioCodecs: ["aac", "alac"],
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

    func staticLoudnessAppliedGainDB(requestedGainDB: Double, maxSafeBoostDB: Double) -> Double {
        if requestedGainDB > 0 {
            return max(0, min(requestedGainDB, maxSafeBoostDB))
        }
        return requestedGainDB
    }

    func peakDBFSForStaticLoudnessGain(_ metrics: AudioQCMetrics) throws -> Double {
        let candidates = [metrics.maxVolumeDBFS, metrics.peakLevelDBFS, metrics.truePeakDBTP]
            .compactMap { $0 }
            .filter(\.isFinite)
        if let peak = candidates.max() {
            return peak
        }
        throw AppError("Unable to measure sample peak for transparent loudness gain.")
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

    func loudnessCandidateIsPublishableFallback(_ result: AudioQCResult, policy: AudioQCPolicy) -> Bool {
        guard loudnessNonRecoverableIssues(result).isEmpty else {
            return false
        }
        guard result.metrics.integratedLUFS?.isFinite == true else {
            return false
        }
        return true
    }

    func loudnessQCFailureMessage(file: URL, result: AudioQCResult) -> String {
        "Audio QC failed for \(file.path): \(result.issues.joined(separator: "; "))"
    }

    func validateLoudnessFilterIsEQNeutral(_ filter: String) throws {
        let forbiddenFilters: Set<String> = [
            "anequalizer", "bandpass", "bandreject", "bass", "biquad",
            "equalizer", "firequalizer", "highpass", "lowpass",
            "superequalizer", "treble"
        ]
        let filterNames = filter
            .split(separator: ",")
            .compactMap { component -> String? in
                let name = component
                    .split(whereSeparator: { $0 == "=" || $0 == ":" })
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercasedASCII
                return name?.isEmpty == false ? name : nil
            }
        if let forbidden = filterNames.first(where: { forbiddenFilters.contains($0) }) {
            throw AppError("Loudness normalization must stay EQ-neutral; forbidden filter '\(forbidden)' was requested.")
        }
    }

    func staticLoudnessGainFilter(gainDB: Double) -> String {
        "volume=\(ffmpegArg("%.6f", gainDB))dB"
    }

    func staticLoudnessGainPlan(for file: URL, policy: AudioQCPolicy) throws -> LoudnessStaticGainPlan {
        let metrics = try audioQCResult(for: file, policy: loudnessPolicy(targetLUFS: policy.targetLUFS, tolerance: 99)).metrics
        guard let integrated = metrics.integratedLUFS, integrated.isFinite else {
            throw AppError("Unable to measure integrated loudness for transparent loudness gain: \(file.path)")
        }
        let peak = try peakDBFSForStaticLoudnessGain(metrics)
        let requestedGain = policy.targetLUFS - integrated
        let maxSafeBoost = policy.maxTruePeakDBTP - peak
        let appliedGain = staticLoudnessAppliedGainDB(
            requestedGainDB: requestedGain,
            maxSafeBoostDB: maxSafeBoost
        )
        return LoudnessStaticGainPlan(
            sourceIntegratedLUFS: integrated,
            sourcePeakDBFS: peak,
            requestedGainDB: requestedGain,
            maxSafeBoostDB: maxSafeBoost,
            appliedGainDB: appliedGain,
            peakConstrained: requestedGain > appliedGain + 0.05
        )
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
        guard let quietest = entries.min(by: { $0.integratedLUFS < $1.integratedLUFS }),
              let loudest = entries.max(by: { $0.integratedLUFS < $1.integratedLUFS }) else {
            throw AppError("No loudness entries to report.")
        }
        let top3 = entries
            .sorted { $0.integratedLUFS > $1.integratedLUFS }
            .prefix(3)
        let top3Average = top3.map(\.integratedLUFS).reduce(0, +) / Double(top3.count)
        return [
            "Average loudness: \(String(format: "%.2f", average)) LUFS across \(entries.count) files",
            "Lowest loudness: \(String(format: "%.2f", quietest.integratedLUFS)) LUFS (\(quietest.file.basename))",
            "Highest loudness: \(String(format: "%.2f", loudest.integratedLUFS)) LUFS (\(loudest.file.basename))",
            "Top 3 loudest average: \(String(format: "%.2f", top3Average)) LUFS"
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

    func verifyTypedAudioOutput(_ file: URL, sourceExtension: String, source: URL?, qcPolicy: AudioQCPolicy?) throws {
        switch sourceExtension.lowercasedASCII {
        case "flac":
            try verifyFLACFile(file, sampleRate: config.flacSampleRate, channels: config.flacChannels, qcPolicy: qcPolicy)
        case "wav":
            try verifyWAVStandard(file, qcPolicy: qcPolicy)
        case "mp3":
            try verifyMP3Standard(file, qcPolicy: qcPolicy)
        case "m4a":
            try verifyM4AFile(file, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: qcPolicy)
        case "mp4":
            try requireFormatNameContains(file, anyOf: ["mp4", "mov"], label: "MP4 container")
            if let source, try hasVideoStream(source) {
                try verifyVideoOutput(file)
            }
            try verifyALACAudioOutput(file, sampleRate: config.videoMP4AudioSampleRate, channels: 2, qcPolicy: qcPolicy)
        default:
            throw AppError("Unsupported output type: \(file.path)")
        }
    }

    func verifyTailFadeOutput(_ file: URL, sourceExtension: String, expectedDuration: Double) throws {
        try verifyTypedAudioOutput(file, sourceExtension: sourceExtension, source: nil, qcPolicy: nil)
        try verifyDuration(file, expectedSeconds: expectedDuration, label: "fade output")
    }

    func verifyFadeOutOutput(_ file: URL, sourceExtension: String, expectedDuration: Double) throws {
        try verifyTypedAudioOutput(file, sourceExtension: sourceExtension, source: nil, qcPolicy: nil)
        try verifyDuration(file, expectedSeconds: expectedDuration, label: "fadeout output")
    }

    func verifyBassOutput(_ file: URL, source: URL) throws {
        try verifyTypedAudioOutput(file, sourceExtension: source.pathExtension, source: source, qcPolicy: nil)
        try verifyDurationMatch(source: source, output: file)
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
            logger.info("Skip existing bass-adjusted media: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: cli.outDir, stem: output.stem, ext: ".\(output.pathExtension)")
        do {
            let sourceWAV = try makeInternalWAV(from: source, in: cli.outDir, stem: "\(source.stem).bass.source")
            defer { discardTempFile(sourceWAV) }
            let processedWAV = try processInternalWAV(
                sourceWAV,
                filter: bassFilter(for: spec),
                in: cli.outDir,
                stem: "\(source.stem).bass.processed"
            )
            defer { discardTempFile(processedWAV) }
            try encodeProcessedWAV(processedWAV, matching: source, to: temp, qcPolicy: nil)
            try verifyBassOutput(temp, source: source)
            try publishTemp(temp, to: output)
            logger.info("Created bass-adjusted media: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func loudnessOutputQCResult(_ file: URL, source: URL, policy: AudioQCPolicy) throws -> AudioQCResult {
        try verifyTypedAudioOutput(file, sourceExtension: source.pathExtension, source: source, qcPolicy: nil)
        try verifyDurationMatch(source: source, output: file)
        return try audioQCResult(for: file, policy: policy)
    }

    func verifyLoudnessOutput(_ file: URL, source: URL, policy: AudioQCPolicy) throws {
        let result = try loudnessOutputQCResult(file, source: source, policy: policy)
        if !result.passed {
            throw AppError(loudnessQCFailureMessage(file: file, result: result))
        }
    }

    func loudnessNormalizeMedia(_ source: URL, spec: LoudnessSpec) throws -> URL {
        try preflightAudioMediaSource(source)
        let policy = loudnessPolicy(targetLUFS: spec.targetLUFS)
        let output = cli.outDir
            .appendingPathComponent(source.stem + loudnessOutputSuffix(for: spec))
            .appendingPathExtension(source.pathExtension.lowercasedASCII)
        guard output.standardizedFileURL != source.standardizedFileURL else {
            throw AppError("Refusing loudness normalization because source and output resolve to the same path: \(source.path)")
        }
        if canReuseOutput(output, verifier: {
            try self.verifyLoudnessOutput(output, source: source, policy: policy)
        }) {
            logger.info("Skip existing loudness-normalized media: \(output.basename)")
            return output
        }

        let workingSource = try makeInternalWAV(from: source, in: cli.outDir, stem: "\(source.stem).loudness.source")
        defer { discardTempFile(workingSource) }

        let plan = try staticLoudnessGainPlan(for: workingSource, policy: policy)
        let filter = staticLoudnessGainFilter(gainDB: plan.appliedGainDB)
        try validateLoudnessFilterIsEQNeutral(filter)
        let temp = try makeTemp(in: cli.outDir, stem: output.stem, ext: ".\(output.pathExtension)")
        do {
            let processedWAV = try processInternalWAV(
                workingSource,
                filter: filter,
                in: cli.outDir,
                stem: "\(output.stem).loudness.processed"
            )
            defer { discardTempFile(processedWAV) }
            try encodeProcessedWAV(processedWAV, matching: source, to: temp, qcPolicy: nil)
            guard fileManager.fileExists(atPath: temp.path) else {
                throw AppError("Loudness render produced no output: \(temp.path)")
            }
            guard try fileSizeBytes(temp) > 0 else {
                throw AppError("Loudness render produced empty output: \(temp.path)")
            }
            let result = try loudnessOutputQCResult(temp, source: source, policy: policy)
            let measured = result.metrics.integratedLUFS.map { String(format: "%.2f", $0) } ?? "unknown"
            if result.passed {
                try publishTemp(temp, to: output)
                logger.info(
                    "Created loudness-normalized media: \(output.basename) [integrated=\(measured) LUFS gain=\(String(format: "%.2f", plan.appliedGainDB)) dB]"
                )
                return output
            }

            guard loudnessCandidateIsPublishableFallback(result, policy: policy) else {
                throw AppError(loudnessQCFailureMessage(file: temp, result: result))
            }
            try publishTemp(temp, to: output)
            let reason = plan.peakConstrained ? "peak-constrained" : "closest-safe"
            logger.warn(
                "Created \(reason) loudness media without compression: \(output.basename) [integrated=\(measured) LUFS target=\(String(format: "%.2f", policy.targetLUFS)) gain=\(String(format: "%.2f", plan.appliedGainDB)) dB requested=\(String(format: "%.2f", plan.requestedGainDB)) dB peak=\(String(format: "%.2f", plan.sourcePeakDBFS)) dBFS]"
            )
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func masterMedia(_ source: URL) throws -> URL {
        try preflightAudioMediaSource(source)
        let output = cli.outDir
            .appendingPathComponent("\(source.stem)_mastered")
            .appendingPathExtension(source.pathExtension.lowercasedASCII)
        guard output.standardizedFileURL != source.standardizedFileURL else {
            throw AppError("Refusing to master \(source.path): source and output resolve to the same path.")
        }
        if canReuseOutput(output, verifier: {
            try self.verifyMasteredOutput(output, source: source)
        }) {
            logger.info("Skip existing mastered media: \(output.basename)")
            return output
        }

        let sourceWAV = try makeInternalWAV(from: source, in: cli.outDir, stem: "\(source.stem).master.source")
        defer { discardTempFile(sourceWAV) }
        try masterCanonicalWAVInPlaceIfNeeded(sourceWAV)

        let temp = try makeTemp(in: cli.outDir, stem: output.stem, ext: ".\(output.pathExtension)")
        do {
            try encodeProcessedWAV(sourceWAV, matching: source, to: temp, qcPolicy: config.masteringAudioQCPolicy)
            try verifyMasteredOutput(temp, source: source)
            try publishTemp(temp, to: output)
            logger.info("Created mastered media: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func verifyMasteredOutput(_ file: URL, source: URL) throws {
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
            if try hasVideoStream(source) {
                try verifyVideoOutput(file)
            }
            try verifyALACAudioOutput(file, sampleRate: config.videoMP4AudioSampleRate, channels: 2, qcPolicy: nil)
        default:
            throw AppError("Unsupported mastered output type: \(file.path)")
        }
        try verifyDurationMatch(source: source, output: file)
        let result = try audioQCResult(for: file, policy: config.masteringAudioQCPolicy)
        if !result.passed {
            throw AppError("Mastered output failed QC for \(file.path): \(result.issues.joined(separator: "; "))")
        }
    }

    func audioSegmentMaxVolumeDBFS(file: URL, startSeconds: Double, durationSeconds: Double) throws -> Double {
        let result = try runner.run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "info",
            "-ss", ffmpegArg("%.6f", max(0, startSeconds)),
            "-t", ffmpegArg("%.6f", durationSeconds),
            "-i", file.path,
            "-map", "0:a:0",
            "-af", "volumedetect",
            "-f", "null",
            "-"
        ])
        for line in result.stderr.split(whereSeparator: \.isNewline).map(String.init).reversed() where line.contains("max_volume:") {
            let tail = line.components(separatedBy: "max_volume:").last?.trimmed ?? ""
            let rawValue = tail.components(separatedBy: " dB").first?.trimmed ?? tail
            if rawValue == "-inf" {
                return -1_000
            }
            if let value = Double(rawValue) {
                return value
            }
        }
        let fallback = try runner.run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "info",
            "-i", file.path,
            "-ss", ffmpegArg("%.6f", max(0, startSeconds)),
            "-t", ffmpegArg("%.6f", durationSeconds),
            "-map", "0:a:0",
            "-af", "astats=metadata=0:reset=0:measure_overall=Peak_level",
            "-f", "null",
            "-"
        ])
        for line in fallback.stderr.split(whereSeparator: \.isNewline).map(String.init).reversed() where line.contains("Peak level dB:") {
            let tail = line.components(separatedBy: "Peak level dB:").last?.trimmed ?? ""
            if tail == "-inf" {
                return -1_000
            }
            if let value = Double(tail) {
                return value
            }
        }
        throw AppError("Unable to verify silent audio segment in \(file.path)")
    }

    func audioSegmentIntegratedLUFS(file: URL, startSeconds: Double, durationSeconds: Double, targetLUFS: Double) throws -> Double {
        let filter = "loudnorm=I=\(ffmpegArg("%.2f", targetLUFS)):TP=\(ffmpegArg("%.2f", config.audioQCMaxTruePeakDBTP)):LRA=50.00:print_format=json"
        func runProbe(accurateSeek: Bool) throws -> ProcessResult {
            if accurateSeek {
                return try runner.run("ffmpeg", [
                    "-hide_banner", "-nostdin", "-v", "info",
                    "-i", file.path,
                    "-ss", ffmpegArg("%.6f", max(0, startSeconds)),
                    "-t", ffmpegArg("%.6f", durationSeconds),
                    "-map", "0:a:0",
                    "-af", filter,
                    "-f", "null",
                    "-"
                ])
            }
            return try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "info",
                "-ss", ffmpegArg("%.6f", max(0, startSeconds)),
                "-t", ffmpegArg("%.6f", durationSeconds),
                "-i", file.path,
                "-map", "0:a:0",
                "-af", filter,
                "-f", "null",
                "-"
            ])
        }

        let result = try runProbe(accurateSeek: false)
        let loudnorm = try? parseLoudnormJSON(from: result.stderr)
        if let integrated = parseAudioDB(loudnorm?.inputI), integrated.isFinite {
            return integrated
        }
        let accurateResult = try runProbe(accurateSeek: true)
        let accurateLoudnorm = try parseLoudnormJSON(from: accurateResult.stderr)
        guard let integrated = parseAudioDB(accurateLoudnorm.inputI), integrated.isFinite else {
            throw AppError("Unable to verify noise loudness segment in \(file.path)")
        }
        return integrated
    }

    func verifySilencePadding(_ file: URL, expectedDuration: Double, spec: SilenceSpec) throws {
        let boundaryMargin = min(0.05, spec.seconds / 4, spec.effectiveLeadingSeconds / 4)
        let leadingProbeSeconds = min(0.5, max(0, spec.effectiveLeadingSeconds - boundaryMargin))
        let trailingProbeSeconds = min(0.5, max(0, spec.seconds - boundaryMargin))
        guard leadingProbeSeconds >= 0.05, trailingProbeSeconds >= 0.05 else {
            return
        }
        let maxSilentVolumeDBFS = -80.0
        let leadingMax = try audioSegmentMaxVolumeDBFS(file: file, startSeconds: 0, durationSeconds: leadingProbeSeconds)
        if leadingMax > maxSilentVolumeDBFS {
            throw AppError("Leading silence verification failed for \(file.path): max_volume=\(String(format: "%.2f", leadingMax)) dBFS")
        }
        let trailingStart = max(0, expectedDuration - spec.seconds + boundaryMargin)
        let trailingMax = try audioSegmentMaxVolumeDBFS(file: file, startSeconds: trailingStart, durationSeconds: trailingProbeSeconds)
        if trailingMax > maxSilentVolumeDBFS {
            throw AppError("Trailing silence verification failed for \(file.path): max_volume=\(String(format: "%.2f", trailingMax)) dBFS")
        }
    }

    func verifySilenceOutput(_ file: URL, source: URL, expectedDuration: Double, spec: SilenceSpec) throws {
        try verifyTypedAudioOutput(file, sourceExtension: source.pathExtension, source: source, qcPolicy: nil)
        try verifyDuration(file, expectedSeconds: expectedDuration, label: "silence output")
        try verifySilencePadding(file, expectedDuration: expectedDuration, spec: spec)
    }

    func verifyNoisePadding(_ file: URL, expectedDuration: Double, spec: NoiseSpec) throws {
        let boundaryMargin = min(0.05, spec.seconds / 4)
        let probeSeconds = max(0, spec.seconds - (boundaryMargin * 2))
        guard probeSeconds >= 0.20 else {
            return
        }

        let targetLUFS = NoiseSpec.targetLUFS
        let tolerance = noiseLUFSTolerance(for: spec)
        let minimumAudibleDBFS = -60.0

        func verifySegment(label: String, start: Double) throws {
            let maxVolume: Double
            do {
                maxVolume = try audioSegmentMaxVolumeDBFS(file: file, startSeconds: start, durationSeconds: probeSeconds)
            } catch {
                throw AppError("\(label) noise peak verification failed for \(file.path): start=\(String(format: "%.3f", start)) duration=\(String(format: "%.3f", probeSeconds)) error=\(error.localizedDescription)")
            }
            if maxVolume <= minimumAudibleDBFS {
                throw AppError("\(label) noise verification failed for \(file.path): max_volume=\(String(format: "%.2f", maxVolume)) dBFS")
            }
            let integrated = try audioSegmentIntegratedLUFS(
                file: file,
                startSeconds: start,
                durationSeconds: probeSeconds,
                targetLUFS: targetLUFS
            )
            if abs(integrated - targetLUFS) > tolerance {
                throw AppError(
                    "\(label) noise loudness verification failed for \(file.path): integrated=\(String(format: "%.2f", integrated)) LUFS target=\(String(format: "%.2f", targetLUFS)) +/- \(String(format: "%.2f", tolerance))"
                )
            }
        }

        try verifySegment(label: "Leading", start: boundaryMargin)
        try verifySegment(label: "Trailing", start: max(0, expectedDuration - spec.seconds + boundaryMargin))

        let silenceMargin = min(0.05, NoiseSpec.transitionSilenceSeconds / 4)
        let silenceProbeSeconds = max(0, NoiseSpec.transitionSilenceSeconds - (silenceMargin * 2))
        guard silenceProbeSeconds >= 0.20 else {
            return
        }

        func verifySilenceGap(label: String, start: Double) throws {
            let probeStart = start + silenceMargin
            let maxVolume: Double
            do {
                maxVolume = try audioSegmentMaxVolumeDBFS(
                    file: file,
                    startSeconds: probeStart,
                    durationSeconds: silenceProbeSeconds
                )
            } catch {
                throw AppError("\(label) transition silence peak verification failed for \(file.path): start=\(String(format: "%.3f", probeStart)) duration=\(String(format: "%.3f", silenceProbeSeconds)) error=\(error.localizedDescription)")
            }
            if maxVolume > -55.0 {
                throw AppError("\(label) transition silence verification failed for \(file.path): max_volume=\(String(format: "%.2f", maxVolume)) dBFS")
            }
        }

        try verifySilenceGap(label: "Leading", start: spec.seconds)
        try verifySilenceGap(label: "Trailing", start: max(0, expectedDuration - spec.seconds - NoiseSpec.transitionSilenceSeconds))
    }

    func noiseLUFSTolerance(for spec: NoiseSpec) -> Double {
        if spec.seconds < 1 {
            return 8.0
        }
        if spec.seconds < 3 {
            return 4.0
        }
        return 2.0
    }

    func noiseLoudnessPolicy(for spec: NoiseSpec) -> AudioQCPolicy {
        loudnessPolicy(targetLUFS: NoiseSpec.targetLUFS, tolerance: noiseLUFSTolerance(for: spec))
    }

    func noiseGenerationSampleRate() -> Int {
        // Generate noise at the lowest delivery rate so later downsampling cannot strip power and lower LUFS.
        let deliveryRates = [
            config.mp3SampleRate,
            config.flacSampleRate,
            config.m4aSampleRate,
            config.videoMP4AudioSampleRate,
            config.shortMP4AudioSampleRate
        ].filter { $0 > 0 }
        return deliveryRates.min() ?? config.wavSampleRate
    }

    func verifyNoiseOutput(_ file: URL, source: URL, expectedDuration: Double, spec: NoiseSpec) throws {
        try verifyTypedAudioOutput(file, sourceExtension: source.pathExtension, source: source, qcPolicy: nil)
        try verifyDuration(file, expectedSeconds: expectedDuration, label: "noise output")
        try verifyNoisePadding(file, expectedDuration: expectedDuration, spec: spec)
    }

    func makeSilencePaddedWAV(from source: URL, spec: SilenceSpec, expectedDuration: Double) throws -> URL {
        let sourceWAV = try makeInternalWAV(from: source, in: cli.outDir, stem: "\(source.stem).silence.source")
        defer { discardTempFile(sourceWAV) }

        let paddedWAV = try makeTemp(in: cli.outDir, stem: "\(source.stem).silence.padded", ext: ".wav")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", sourceWAV.path,
                "-map", "0:a:0",
                "-af", silenceAudioFilter(for: spec),
                "-t", ffmpegArg("%.6f", expectedDuration),
                "-vn", "-sn", "-dn",
                "-ac", String(config.wavChannels),
                "-ar", String(config.wavSampleRate),
                "-c:a", config.wavCodec,
                "-f", "wav",
                "-rf64", "always",
                "-write_bext", String(config.wavWriteBext),
                paddedWAV.path
            ])
            try verifyWAVStandard(paddedWAV, qcPolicy: nil)
            try verifyDuration(paddedWAV, expectedSeconds: expectedDuration, label: "silence-padded WAV")
            try verifySilencePadding(paddedWAV, expectedDuration: expectedDuration, spec: spec)
            return paddedWAV
        } catch {
            discardTempFile(paddedWAV)
            throw error
        }
    }

    func makeRawNoiseSegmentWAV(spec: NoiseSpec, stem: String) throws -> URL {
        let temp = try makeTemp(in: cli.outDir, stem: stem, ext: ".wav")
        let seed = Int.random(in: 1 ... Int(Int32.max))
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-f", "lavfi",
                "-i", "anoisesrc=c=white:r=\(noiseGenerationSampleRate()):a=0.5:d=\(ffmpegArg("%.6f", spec.seconds)):s=\(seed)",
                "-map", "0:a:0",
                "-vn", "-sn", "-dn",
                "-ac", String(config.wavChannels),
                "-ar", String(config.wavSampleRate),
                "-c:a", config.wavCodec,
                "-f", "wav",
                "-rf64", "always",
                "-write_bext", String(config.wavWriteBext),
                temp.path
            ])
            try verifyWAVStandard(temp, qcPolicy: nil)
            try verifyDuration(temp, expectedSeconds: spec.seconds, label: "raw noise segment", tolerance: 0.5)
            return temp
        } catch {
            discardTempFile(temp)
            throw error
        }
    }

    func makeNormalizedNoiseSegmentWAV(spec: NoiseSpec, stem: String) throws -> URL {
        let rawNoise = try makeRawNoiseSegmentWAV(spec: spec, stem: "\(stem).raw")
        defer { discardTempFile(rawNoise) }

        let policy = noiseLoudnessPolicy(for: spec)
        let processed = try processInternalWAV(
            rawNoise,
            filter: loudnormSinglePassFilter(policy: policy),
            in: cli.outDir,
            stem: "\(stem).normalized"
        )
        do {
            try verifyWAVStandard(processed, qcPolicy: nil)
            try verifyDuration(processed, expectedSeconds: spec.seconds, label: "normalized noise segment", tolerance: 0.5)
            let result = try audioQCResult(for: processed, policy: policy)
            if !loudnessNonRecoverableIssues(result).isEmpty {
                throw AppError(loudnessQCFailureMessage(file: processed, result: result))
            }
            guard let integrated = result.metrics.integratedLUFS, abs(integrated - policy.targetLUFS) <= policy.lufsTolerance else {
                let measured = result.metrics.integratedLUFS.map { String(format: "%.2f", $0) } ?? "unknown"
                throw AppError("Noise segment loudness verification failed for \(processed.path): integrated=\(measured) LUFS target=\(String(format: "%.2f", policy.targetLUFS)) +/- \(String(format: "%.2f", policy.lufsTolerance))")
            }
            return processed
        } catch {
            discardTempFile(processed)
            throw error
        }
    }

    func makeNoisePaddedWAV(from source: URL, spec: NoiseSpec, expectedDuration: Double) throws -> URL {
        let sourceWAV = try makeInternalWAV(from: source, in: cli.outDir, stem: "\(source.stem).noise.source")
        defer { discardTempFile(sourceWAV) }
        let leadingNoise = try makeNormalizedNoiseSegmentWAV(spec: spec, stem: "\(source.stem).noise.leading")
        defer { discardTempFile(leadingNoise) }
        let trailingNoise = try makeNormalizedNoiseSegmentWAV(spec: spec, stem: "\(source.stem).noise.trailing")
        defer { discardTempFile(trailingNoise) }

        let paddedWAV = try makeTemp(in: cli.outDir, stem: "\(source.stem).noise.padded", ext: ".wav")
        let transitionSilence = "anullsrc=r=\(config.wavSampleRate):cl=stereo:d=\(ffmpegArg("%.6f", NoiseSpec.transitionSilenceSeconds))"
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", leadingNoise.path,
                "-f", "lavfi",
                "-i", transitionSilence,
                "-i", sourceWAV.path,
                "-f", "lavfi",
                "-i", transitionSilence,
                "-i", trailingNoise.path,
                "-filter_complex", "[0:a:0][1:a:0][2:a:0][3:a:0][4:a:0]concat=n=5:v=0:a=1,aformat=sample_fmts=flt:sample_rates=\(config.wavSampleRate):channel_layouts=stereo[out]",
                "-map", "[out]",
                "-vn", "-sn", "-dn",
                "-ac", String(config.wavChannels),
                "-ar", String(config.wavSampleRate),
                "-c:a", config.wavCodec,
                "-f", "wav",
                "-rf64", "always",
                "-write_bext", String(config.wavWriteBext),
                paddedWAV.path
            ])
            try verifyWAVStandard(paddedWAV, qcPolicy: nil)
            try verifyDuration(paddedWAV, expectedSeconds: expectedDuration, label: "noise-padded WAV")
            try verifyNoisePadding(paddedWAV, expectedDuration: expectedDuration, spec: spec)
            return paddedWAV
        } catch {
            discardTempFile(paddedWAV)
            throw error
        }
    }

    func encodeDurationPaddedMP4(
        source: URL,
        paddedWAV: URL,
        output: URL,
        expectedDuration: Double,
        leadingSeconds: Double,
        trailingSeconds: Double,
        label: String
    ) throws {
        try verifyWAVStandard(paddedWAV, qcPolicy: nil)
        try requireFFmpegEncoder(alacEncoderName)
        let hasVideo = try hasVideoStream(source)

        if !hasVideo {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-i", paddedWAV.path,
                "-map", "1:a:0",
                "-vn", "-sn", "-dn"
            ] + alacAudioArguments(sampleRate: config.videoMP4AudioSampleRate, channels: 2) + [
                "-map_metadata", "0",
                "-map_chapters", "0",
                "-movflags", "+faststart",
                output.path
            ])
            return
        }

        let encoders = try requireAvailableEncoderLadder(config.videoEncoderLadder, label: "\(label) MP4 video")
        let videoFilter =
            "tpad=start_duration=\(ffmpegArg("%.6f", leadingSeconds)):stop_duration=\(ffmpegArg("%.6f", trailingSeconds)):start_mode=clone:stop_mode=clone," +
            "format=\(config.videoMP4PixelFormat)," +
            "setparams=color_primaries=\(config.videoColorPrimaries):color_trc=\(config.videoColorTransfer):colorspace=\(config.videoColorSpace):range=\(ffmpegFilterRangeValue(config.videoColorRange))"

        func buildArguments(encoder: String) -> [String] {
            let normalizedEncoder = encoder.lowercasedASCII
            let videoTag = normalizedEncoder.contains("264") ? "avc1" : config.videoMP4Tag
            var args = [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-i", paddedWAV.path,
                "-map", "0:v:0",
                "-map", "1:a:0",
                "-vf", videoFilter,
                "-c:v", encoder
            ]
            if encoder.lowercasedASCII.contains("videotoolbox") {
                args += ["-q:v", config.videoMP4VTQuality]
            } else {
                args += ["-preset", config.videoMP4SoftwarePreset, "-crf", config.videoMP4SoftwareCRF]
            }
            args += [
                "-pix_fmt", config.videoMP4PixelFormat,
                "-color_primaries", config.videoColorPrimaries,
                "-color_trc", config.videoColorTransfer,
                "-colorspace", config.videoColorSpace,
                "-color_range", config.videoColorRange,
                "-tag:v", videoTag
            ]
            args += alacAudioArguments(sampleRate: config.videoMP4AudioSampleRate, channels: 2)
            args += [
                "-t", ffmpegArg("%.6f", expectedDuration),
                "-map_metadata", "0",
                "-map_chapters", "0",
                "-movflags", "+faststart"
            ]
            return args
        }

        var lastError: Error?
        for encoder in encoders {
            do {
                _ = try runner.run("ffmpeg", buildArguments(encoder: encoder) + [output.path])
                return
            } catch {
                lastError = error
                logger.warn("\(label) MP4 video encoder failed (\(encoder)): \(error.localizedDescription)")
                try? fileManager.removeItem(at: output)
            }
        }
        throw AppError("All \(label.lowercasedASCII) MP4 video encoders failed for \(output.basename): \(lastError?.localizedDescription ?? "unknown error")")
    }

    func encodeSilencePaddedMP4(source: URL, paddedWAV: URL, output: URL, expectedDuration: Double, spec: SilenceSpec) throws {
        try encodeDurationPaddedMP4(
            source: source,
            paddedWAV: paddedWAV,
            output: output,
            expectedDuration: expectedDuration,
            leadingSeconds: spec.effectiveLeadingSeconds,
            trailingSeconds: spec.seconds,
            label: "Silence"
        )
    }

    func encodeNoisePaddedMP4(source: URL, paddedWAV: URL, output: URL, expectedDuration: Double, spec: NoiseSpec) throws {
        try encodeDurationPaddedMP4(
            source: source,
            paddedWAV: paddedWAV,
            output: output,
            expectedDuration: expectedDuration,
            leadingSeconds: spec.seconds + NoiseSpec.transitionSilenceSeconds,
            trailingSeconds: spec.seconds + NoiseSpec.transitionSilenceSeconds,
            label: "Noise"
        )
    }

    func addSilenceToMedia(_ source: URL, spec: SilenceSpec) throws -> URL {
        try preflightSilenceSource(source)
        guard let sourceDuration = try mediaDuration(source) else {
            throw AppError("Unable to read source duration for silence padding: \(source.path)")
        }
        let expectedDuration = silenceExpectedDuration(sourceDuration: sourceDuration, spec: spec)
        let output = cli.outDir
            .appendingPathComponent(source.stem + silenceOutputSuffix(for: spec))
            .appendingPathExtension(source.pathExtension.lowercasedASCII)
        if canReuseOutput(output, verifier: {
            try self.verifySilenceOutput(output, source: source, expectedDuration: expectedDuration, spec: spec)
        }) {
            logger.info("Skip existing silence-padded media: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: cli.outDir, stem: output.stem, ext: ".\(output.pathExtension)")
        do {
            let paddedWAV = try makeSilencePaddedWAV(from: source, spec: spec, expectedDuration: expectedDuration)
            defer { discardTempFile(paddedWAV) }
            if source.pathExtension.lowercasedASCII == "mp4" {
                try encodeSilencePaddedMP4(source: source, paddedWAV: paddedWAV, output: temp, expectedDuration: expectedDuration, spec: spec)
            } else {
                try encodeProcessedWAV(paddedWAV, matching: source, to: temp, qcPolicy: nil)
            }
            try verifySilenceOutput(temp, source: source, expectedDuration: expectedDuration, spec: spec)
            try publishTemp(temp, to: output)
            logger.info("Created silence-padded media: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func addNoiseToMedia(_ source: URL, spec: NoiseSpec) throws -> URL {
        try preflightNoiseSource(source)
        guard let sourceDuration = try mediaDuration(source) else {
            throw AppError("Unable to read source duration for noise padding: \(source.path)")
        }
        let expectedDuration = noiseExpectedDuration(sourceDuration: sourceDuration, spec: spec)
        let output = cli.outDir
            .appendingPathComponent(source.stem + noiseOutputSuffix(for: spec))
            .appendingPathExtension(source.pathExtension.lowercasedASCII)
        if canReuseOutput(output, verifier: {
            try self.verifyNoiseOutput(output, source: source, expectedDuration: expectedDuration, spec: spec)
        }) {
            logger.info("Skip existing noise-padded media: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: cli.outDir, stem: output.stem, ext: ".\(output.pathExtension)")
        do {
            let paddedWAV = try makeNoisePaddedWAV(from: source, spec: spec, expectedDuration: expectedDuration)
            defer { discardTempFile(paddedWAV) }
            if source.pathExtension.lowercasedASCII == "mp4" {
                try encodeNoisePaddedMP4(source: source, paddedWAV: paddedWAV, output: temp, expectedDuration: expectedDuration, spec: spec)
            } else {
                try encodeProcessedWAV(paddedWAV, matching: source, to: temp, qcPolicy: nil)
            }
            try verifyNoiseOutput(temp, source: source, expectedDuration: expectedDuration, spec: spec)
            try publishTemp(temp, to: output)
            logger.info("Created noise-padded media: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
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
        let output = cli.outDir.appendingPathComponent("\(source.stem)_fadecut_\(ffmpegNumber(spec.cutSeconds))s_\(ffmpegNumber(fadeSeconds))s").appendingPathExtension(source.pathExtension.lowercasedASCII)
        if canReuseOutput(output, verifier: {
            try self.verifyTailFadeOutput(output, sourceExtension: source.pathExtension, expectedDuration: targetDuration)
        }) {
            logger.info("Skip existing fadecut audio: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: cli.outDir, stem: output.stem, ext: ".\(output.pathExtension)")
        do {
            let sourceWAV = try makeInternalWAV(from: source, in: cli.outDir, stem: "\(source.stem).fadecut.source")
            defer { discardTempFile(sourceWAV) }
            let fadeFilter = fadeOutFilter(fadeStartSeconds: fadeStart, fadeDurationSeconds: fadeSeconds)
            let processedWAV = try processInternalWAV(
                sourceWAV,
                filter: fadeFilter,
                in: cli.outDir,
                stem: "\(source.stem).fadecut.processed",
                duration: targetDuration
            )
            defer { discardTempFile(processedWAV) }
            try encodeProcessedWAV(processedWAV, matching: source, to: temp, qcPolicy: nil)
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
        let output = cli.outDir.appendingPathComponent("\(source.stem)_faded_\(ffmpegNumber(fadeSeconds))s").appendingPathExtension(source.pathExtension.lowercasedASCII)
        if canReuseOutput(output, verifier: {
            try self.verifyTailFadeOutput(output, sourceExtension: source.pathExtension, expectedDuration: duration)
        }) {
            logger.info("Skip existing faded audio: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: cli.outDir, stem: output.stem, ext: ".\(output.pathExtension)")
        do {
            let sourceWAV = try makeInternalWAV(from: source, in: cli.outDir, stem: "\(source.stem).fade.source")
            defer { discardTempFile(sourceWAV) }
            let fadeFilter = fadeOutFilter(fadeStartSeconds: fadeStart, fadeDurationSeconds: fadeSeconds)
            let processedWAV = try processInternalWAV(
                sourceWAV,
                filter: fadeFilter,
                in: cli.outDir,
                stem: "\(source.stem).fade.processed"
            )
            defer { discardTempFile(processedWAV) }
            try encodeProcessedWAV(processedWAV, matching: source, to: temp, qcPolicy: nil)
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

        let output = cli.outDir.appendingPathComponent("\(source.stem)_fadeout_\(ffmpegNumber(spec.fadeStartSeconds))s_\(ffmpegNumber(spec.fadeDurationSeconds))s").appendingPathExtension(source.pathExtension.lowercasedASCII)
        if canReuseOutput(output, verifier: {
            try self.verifyFadeOutOutput(output, sourceExtension: source.pathExtension, expectedDuration: targetDuration)
        }) {
            logger.info("Skip existing faded audio: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: cli.outDir, stem: output.stem, ext: ".\(output.pathExtension)")
        do {
            let sourceWAV = try makeInternalWAV(from: source, in: cli.outDir, stem: "\(source.stem).fadeout.source")
            defer { discardTempFile(sourceWAV) }
            let fadeFilter = fadeOutFilter(fadeStartSeconds: spec.fadeStartSeconds, fadeDurationSeconds: spec.fadeDurationSeconds)
            let processedWAV = try processInternalWAV(
                sourceWAV,
                filter: fadeFilter,
                in: cli.outDir,
                stem: "\(source.stem).fadeout.processed",
                duration: targetDuration
            )
            defer { discardTempFile(processedWAV) }
            try encodeProcessedWAV(processedWAV, matching: source, to: temp, qcPolicy: nil)
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
        let sourceWAV = try makeInternalWAV(from: source, in: cli.outDir, stem: "\(source.stem).mp3standard")
        defer { discardTempFile(sourceWAV) }
        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".mp3")
        do {
            try encodeInternalWAVToMP3(sourceWAV, output: temp, qcPolicy: nil)
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
        return UInt64((duration * Double(config.wavSampleRate * channels * 3)).rounded()) + 1_048_576
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
        try requireFFmpegEncoder(alacEncoderName)
        let output = cli.outDir.appendingPathComponent(source.stem).appendingPathExtension("m4a")
        if canReuseOutput(output, verifier: {
            try verifyM4AFile(output, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: output)
            try verifySourceLoudnessPreserved(source: source, output: output, toleranceDB: 2.0)
        }) {
            logger.info("Skip existing M4A: \(output.basename)")
            return output
        }
        let sourceWAV = try makeInternalWAV(from: source, in: cli.outDir, stem: "\(source.stem).m4a.source")
        defer { discardTempFile(sourceWAV) }
        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".m4a")
        do {
            try encodeInternalWAVToM4A(sourceWAV, output: temp, qcPolicy: nil)
            try verifyM4AFile(temp, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: temp)
            try verifySourceLoudnessPreserved(source: source, output: temp, toleranceDB: 2.0)
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
        try requireFFmpegEncoder(alacEncoderName)
        let output = cli.outDir.appendingPathComponent(source.stem).appendingPathExtension("m4a")
        if canReuseOutput(output, verifier: {
            try verifyM4AFile(output, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: output)
            try verifySourceLoudnessPreserved(source: source, output: output, toleranceDB: 2.0)
        }) {
            logger.info("Skip existing M4A: \(output.basename)")
            return output
        }
        let sourceWAV = try makeInternalWAV(from: source, in: cli.outDir, stem: "\(source.stem).m4a.source")
        defer { discardTempFile(sourceWAV) }
        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".m4a")
        do {
            try encodeInternalWAVToM4A(sourceWAV, output: temp, qcPolicy: nil)
            try verifyM4AFile(temp, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: temp)
            try verifySourceLoudnessPreserved(source: source, output: temp, toleranceDB: 2.0)
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
    func convertAudioToMP3(_ source: URL) throws -> URL {
        try preflightAudioSourceForTranscode(source)
        try requireFFmpegEncoder("libmp3lame")
        let output = cli.outDir.appendingPathComponent(source.stem).appendingPathExtension("mp3")
        if canReuseOutput(output, verifier: {
            try verifyMP3Standard(output, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: output)
            try verifySourceLoudnessPreserved(source: source, output: output)
        }) {
            logger.info("Skip existing MP3: \(output.basename)")
            return output
        }
        let sourceWAV = try makeInternalWAV(from: source, in: cli.outDir, stem: "\(source.stem).mp3.source")
        defer { discardTempFile(sourceWAV) }
        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".mp3")
        do {
            try encodeInternalWAVToMP3(sourceWAV, output: temp, qcPolicy: nil)
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

    func convertWAVToMP3(_ source: URL) throws -> URL {
        try convertAudioToMP3(source)
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
                format: .s24le,
                maxAllowedDelta: 2048
            )
        }) {
            logger.info("Skip existing FLAC: \(output.basename)")
            return output
        }
        let sourceWAV = try makeInternalWAV(from: source, in: cli.outDir, stem: "\(source.stem).flac.source")
        defer { discardTempFile(sourceWAV) }
        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".flac")
        do {
            try encodeInternalWAVToFLAC(sourceWAV, output: temp, qcPolicy: nil)
            try verifyFLACFile(temp, sampleRate: config.flacSampleRate, channels: config.flacChannels, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: temp)
            try verifyCanonicalPCMSampleEquivalence(
                source: source,
                output: temp,
                sampleRate: config.flacSampleRate,
                channels: config.flacChannels,
                label: "FLAC output",
                format: .s24le,
                maxAllowedDelta: 2048
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
        let sourceWAV = try makeInternalWAV(
            from: source,
            in: source.deletingLastPathComponent(),
            stem: "\(source.stem).notags.source",
            requireAudible: false
        )
        defer { discardTempFile(sourceWAV) }
        let temp = try makeTemp(in: source.deletingLastPathComponent(), stem: "\(source.stem).notags", ext: ".mp3")
        do {
            try encodeInternalWAVToMP3(sourceWAV, output: temp, requireAudible: false, qcPolicy: nil)
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
            let sourceWAV = try makeInternalWAV(from: source, in: cli.outDir, stem: "\(source.stem).fadewav.source")
            defer { discardTempFile(sourceWAV) }
            let processedWAV = try processInternalWAV(
                sourceWAV,
                filter: fadeOutFilter(fadeStartSeconds: fadeStart, fadeDurationSeconds: Double(config.wavFadeDur)),
                in: cli.outDir,
                stem: "\(source.stem).fadewav.processed"
            )
            defer { discardTempFile(processedWAV) }
            try encodeInternalWAVToWAV(processedWAV, output: temp, qcPolicy: nil)
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
            try verifyCanonicalPCMSampleEquivalence(source: source, output: output, label: "External FLAC", format: .s24le, maxAllowedDelta: 2048)
        }) {
            logger.info("Skip existing external FLAC: \(output.basename)")
            return output
        }

        let sourceWAV = try makeInternalWAV(from: source, in: output.deletingLastPathComponent(), stem: "\(output.stem).externalflac.source")
        defer { discardTempFile(sourceWAV) }
        let temp = try makeTemp(in: output.deletingLastPathComponent(), stem: output.stem, ext: ".flac")
        do {
            try encodeInternalWAVToFLAC(
                sourceWAV,
                output: temp,
                sampleRate: try requireAudioSampleRate(source),
                channels: try requireAudioChannels(source),
                qcPolicy: nil
            )
            try verifyFLACFile(temp, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: temp)
            try verifyCanonicalPCMSampleEquivalence(source: source, output: temp, label: "External FLAC", format: .s24le, maxAllowedDelta: 2048)
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

    func generateExternalArchivalVariants(baseName: String, highQualitySource: URL) throws {
        let rf64FLAC = cli.outDir.appendingPathComponent("\(baseName)_RF64").appendingPathExtension("flac")
        let bw64FLAC = cli.outDir.appendingPathComponent("\(baseName)_BW64").appendingPathExtension("flac")
        let rf64WAV = cli.outDir.appendingPathComponent("\(baseName)_RF64").appendingPathExtension("wav")
        let bw64WAV = cli.outDir.appendingPathComponent("\(baseName)_BW64").appendingPathExtension("wav")

        _ = try createExternalFLACVariant(source: highQualitySource, output: rf64FLAC)
        _ = try createExternalFLACVariant(source: highQualitySource, output: bw64FLAC)
        _ = try createExternalWAVVariant(source: highQualitySource, output: rf64WAV, writeBext: false)
        _ = try createExternalBW64WAVVariant(source: highQualitySource, output: bw64WAV)
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
        while true {
            let data = try handle.read(upToCount: config.crcChunkBytes)
            guard let chunk = data, !chunk.isEmpty else {
                break
            }
            crc = chunk.reduce(crc) { current, byte in
                let idx = Int((current ^ UInt32(byte)) & 0xFF)
                return table[idx] ^ (current >> 8)
            }
        }

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

    func sortAlbumAudioTracks(_ urls: [URL]) -> [URL] {
        func leadingTrackNumber(_ file: URL) -> Int? {
            let stem = file.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            let digits = stem.prefix { $0.isNumber }
            guard !digits.isEmpty else {
                return nil
            }
            return Int(digits)
        }

        func extensionRank(_ file: URL) -> Int {
            switch file.pathExtension.lowercasedASCII {
            case "flac": return 0
            case "wav": return 1
            case "mp3": return 2
            default: return 9
            }
        }

        return urls.sorted { lhs, rhs in
            let lhsStem = lhs.deletingPathExtension().lastPathComponent
            let rhsStem = rhs.deletingPathExtension().lastPathComponent
            let lhsNumber = leadingTrackNumber(lhs)
            let rhsNumber = leadingTrackNumber(rhs)
            if lhsNumber != rhsNumber {
                switch (lhsNumber, rhsNumber) {
                case let (left?, right?):
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
            }

            let stemOrder = lhsStem.localizedStandardCompare(rhsStem)
            if stemOrder != .orderedSame {
                return stemOrder == .orderedAscending
            }

            let lhsRank = extensionRank(lhs)
            let rhsRank = extensionRank(rhs)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }
    }

    func isAlbumDerivedAudio(_ file: URL) -> Bool {
        let stem = file.stem.lowercasedASCII
        return stem == "album"
            || stem == "album_from_mp3"
            || stem.hasPrefix("album.")
            || isExternalArchivalAudioVariant(file)
            || isLoudnessDerivedAudio(file)
            || isBassDerivedAudio(file)
            || isFadeDerivedAudio(file)
    }

    func albumAudioCandidates() throws -> [URL] {
        let candidates = try files(in: cli.srcDir, matchingExtensions: ["mp3", "wav", "flac"])
            .filter { !isAlbumDerivedAudio($0) }
        return sortAlbumAudioTracks(candidates)
    }

    func preflightAlbumAudioInput(_ file: URL) throws {
        switch file.pathExtension.lowercasedASCII {
        case "flac":
            try preflightFLACInput(file)
        case "wav":
            try preflightWAVInput(file)
        case "mp3":
            try preflightMP3Input(file)
        default:
            throw AppError("Unsupported album audio input: \(file.path)")
        }
    }

    func normalizeAlbumTrackToWAV(_ source: URL, index: Int, total: Int, policy: AudioQCPolicy) throws -> URL {
        try preflightAlbumAudioInput(source)
        logger.info("Album loudness normalize \(index)/\(total): \(source.basename)")
        let workingSource = try makeInternalWAV(from: source, in: cli.outDir, stem: "album.track.\(index).source.\(source.stem)")
        defer { discardTempFile(workingSource) }

        let plan = try staticLoudnessGainPlan(for: workingSource, policy: policy)
        let filter = staticLoudnessGainFilter(gainDB: plan.appliedGainDB)
        try validateLoudnessFilterIsEQNeutral(filter)
        let processed = try processInternalWAV(
            workingSource,
            filter: filter,
            in: cli.outDir,
            stem: "album.track.\(index).normalized.\(source.stem)"
        )
        do {
            try verifyWAVStandard(processed, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: processed)
            let result = try audioQCResult(for: processed, policy: policy)
            if result.passed {
                let measured = result.metrics.integratedLUFS.map { String(format: "%.2f", $0) } ?? "unknown"
                logger.info("Album track ready: \(source.basename) [integrated=\(measured) LUFS]")
                return processed
            }

            guard loudnessCandidateIsPublishableFallback(result, policy: policy) else {
                discardTempFile(processed)
                throw AppError(loudnessQCFailureMessage(file: processed, result: result))
            }
            let measured = result.metrics.integratedLUFS.map { String(format: "%.2f", $0) } ?? "unknown"
            logger.warn("Album track peak-constrained without compression: \(source.basename) [integrated=\(measured) LUFS target=\(String(format: "%.2f", policy.targetLUFS))]")
            return processed
        } catch {
            discardTempFile(processed)
            throw error
        }
    }

    func buildNumberedAlbumFromDirectory(defaultOutputName: String = "album.wav") throws -> URL {
        let tracks = try albumAudioCandidates()
        guard tracks.count >= 2 else {
            throw AppError("Album pipeline expects at least two source audio files (.mp3/.wav/.flac) in '\(cli.srcDir.path)'.")
        }

        logger.info("Album track order: \(tracks.map(\.basename).joined(separator: ", "))")
        let policy = loudnessPolicy(targetLUFS: LoudnessSpec.defaultTargetLUFS)
        var normalizedTracks: [URL] = []
        defer {
            for track in normalizedTracks {
                discardTempFile(track)
            }
        }

        for (offset, track) in tracks.enumerated() {
            normalizedTracks.append(try normalizeAlbumTrackToWAV(track, index: offset + 1, total: tracks.count, policy: policy))
        }

        let output = try resolveOutputPath(cli.outputFile ?? defaultOutputName)
        return try buildAlbum(from: normalizedTracks, output: output)
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
