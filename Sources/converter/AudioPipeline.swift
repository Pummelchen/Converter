import Foundation

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

    func audioFadeOutCandidates() throws -> [URL] {
        try files(in: cli.srcDir, matchingExtensions: ["flac", "wav", "mp3", "m4a"])
            .filter { !$0.stem.hasSuffix("_faded") }
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
            try verifyMP3Standard(source, qcPolicy: config.deliveryAudioQCPolicy)
            return source
        }
        if canReuseOutput(output, verifier: { try verifyMP3Standard(output, qcPolicy: config.deliveryAudioQCPolicy) }) {
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
            try verifyWAVStandard(temp, qcPolicy: config.deliveryAudioQCPolicy)
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
            try verifyWAVStandard(output, qcPolicy: config.deliveryAudioQCPolicy)
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
            try verifyWAVStandard(temp, qcPolicy: config.deliveryAudioQCPolicy)
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
            try verifyM4AFile(output, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: output)
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
            try verifyM4AFile(temp, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: temp)
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
            try verifyM4AFile(output, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: output)
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
            try verifyM4AFile(temp, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: temp)
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
            try verifyMP3Standard(output, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: output)
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
            try verifyMP3Standard(temp, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: temp)
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
            try verifyFLACFile(output, sampleRate: config.flacSampleRate, channels: config.flacChannels, requireAudible: true, qcPolicy: config.deliveryAudioQCPolicy)
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
            try verifyFLACFile(temp, sampleRate: config.flacSampleRate, channels: config.flacChannels, qcPolicy: config.deliveryAudioQCPolicy)
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
            try verifyWAVStandard(output, qcPolicy: config.deliveryAudioQCPolicy)
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
            try verifyWAVStandard(temp, qcPolicy: config.deliveryAudioQCPolicy)
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
            try verifyFLACFile(output, qcPolicy: config.deliveryAudioQCPolicy)
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
                try copyFileIntoTemp(source, temp: temp)
            } else {
                _ = try runner.run("ffmpeg", [
                    "-hide_banner", "-nostdin", "-v", "error", "-y",
                    "-i", source.path,
                    "-map", "0:a:0",
                    "-c:a", "flac",
                    "-compression_level", String(config.flacCompressionLevel),
                    temp.path
                ])
            }
            try verifyFLACFile(temp, qcPolicy: config.deliveryAudioQCPolicy)
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

    func hashRename(ext: String) throws {
        let files = try self.files(in: cli.srcDir, matchingExtensions: [ext])
        if files.isEmpty {
            logger.warn("No .\(ext) files found in '\(cli.srcDir.path)'.")
            return
        }
        for file in files {
            switch ext {
            case "flac":
                try preflightFLACInput(file)
            case "mp3":
                try preflightMP3Input(file, requireAudible: false, requireNoVideo: false)
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
        }
    }

    func hashCopyWAV() throws {
        let files = try self.files(in: cli.srcDir, matchingExtensions: ["wav"])
        if files.isEmpty {
            logger.warn("No .wav files found in '\(cli.srcDir.path)'.")
            return
        }
        for file in files {
            try preflightWAVInput(file)
            let hash = try crc32(for: file)
            let destination = cli.outDir.appendingPathComponent(hash).appendingPathExtension("wav")
            if fileManager.fileExists(atPath: destination.path), !cli.overwrite {
                logger.info("Skip existing hashed WAV: \(destination.basename)")
                continue
            }
            let temp = try makeTemp(in: cli.outDir, stem: hash, ext: ".wav")
            do {
                try copyFileIntoTemp(file, temp: temp)
                if try crc32(for: temp) != hash {
                    throw AppError("CRC verification failed for copied WAV: \(destination.path)")
                }
                try publishTemp(temp, to: destination)
                logger.info("Copied hashed WAV: \(destination.basename)")
            } catch {
                try? fileManager.removeItem(at: temp)
                state.unregister(tempFile: temp)
                throw error
            }
        }
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
            try verifyWAVStandard(temp, qcPolicy: config.deliveryAudioQCPolicy)
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
            let file = resolveExplicitPath(candidateName, baseDirectory: cli.srcDir)
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
        let output = resolveOutputPath(cli.outputFile ?? defaultOutputName)
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
        let output = resolveOutputPath(cli.outputFile ?? "album.wav")
        return try buildAlbum(from: flacs, output: output)
    }

}
