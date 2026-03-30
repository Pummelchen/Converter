import Foundation

extension ConverterTool {
    private var shortMP4AbsoluteMaximumSeconds: Double { 58.0 }

    func configuredShortClipSeconds() throws -> Double {
        try parseFlexibleTimecode(config.shortMP4ClipSeconds, label: "SHORT_MP4_CLIP_SECONDS")
    }

    func effectiveShortClipSeconds(forDuration inputDuration: Double) throws -> Double {
        let configured = try configuredShortClipSeconds()
        return min(configured, shortMP4AbsoluteMaximumSeconds, inputDuration)
    }

    func effectiveShortClipSeconds(for input: URL) throws -> Double {
        guard let inputDuration = try mediaDuration(input) else {
            throw AppError("Unable to read numeric video duration from: \(input.path)")
        }
        return try effectiveShortClipSeconds(forDuration: inputDuration)
    }

    func verifyShortMP4Duration(_ output: URL, source: URL) throws {
        let expectedSeconds = try effectiveShortClipSeconds(for: source)
        try verifyDuration(output, expectedSeconds: expectedSeconds, label: "short MP4 output", tolerance: 0.5)
        guard let actualDuration = try mediaDuration(output) else {
            throw AppError("Unable to read numeric short MP4 duration from: \(output.path)")
        }
        if actualDuration > shortMP4AbsoluteMaximumSeconds + 0.1 {
            throw AppError(
                String(
                    format: "Short MP4 exceeds hard limit %.3fs (got %.3fs): %@",
                    shortMP4AbsoluteMaximumSeconds,
                    actualDuration,
                    output.path
                )
            )
        }
    }

    func renderM4AToMP4(imageFile: URL, audioFile: URL, audioQCPolicy: AudioQCPolicy?) throws -> URL {
        try preflightPNGInput(imageFile)
        try preflightM4AInput(audioFile)
        guard let dimensions = try imageDimensions(imageFile) else {
            throw AppError("Unable to read dimensions: \(imageFile.path)")
        }
        if dimensions.0 != config.videoMP4Width || dimensions.1 != config.videoMP4Height {
            throw AppError("Image must be \(config.videoMP4Width)x\(config.videoMP4Height). Got '\(dimensions.0)x\(dimensions.1)' for '\(imageFile.path)'.")
        }
        guard let duration = try mediaDuration(audioFile) else {
            throw AppError("Unable to read numeric audio duration from: \(audioFile.path)")
        }
        let inputAudioCodec = try audioField(audioFile, "codec_name") ?? ""
        let inputAudioSampleRate = Int(try audioField(audioFile, "sample_rate") ?? "") ?? 0
        let canCopyAAC = inputAudioCodec == "aac" && inputAudioSampleRate == config.videoMP4AudioSampleRate
        let defaultName = "\(audioFile.stem)_8K.mp4"
        let output = resolveOutputPath(cli.outputFile ?? defaultName)
        if canReuseOutput(output, verifier: {
            try verifyVideoOutput(
                output,
                width: config.videoMP4Width,
                height: config.videoMP4Height,
                codec: config.videoMP4VerifyCodec,
                pixelFormat: config.videoMP4PixelFormat,
                colorPrimaries: config.videoColorPrimaries,
                colorTransfer: config.videoColorTransfer,
                colorSpace: config.videoColorSpace,
                colorRange: config.videoColorRange
            )
            try verifyAudioOutput(output, codec: "aac", sampleRate: config.videoMP4AudioSampleRate, qcPolicy: audioQCPolicy)
            try verifyDurationMatch(source: audioFile, output: output)
            try verifySourceLoudnessPreserved(source: audioFile, output: output)
        }) {
            logger.info("Skip existing MP4: \(output.basename)")
            return output
        }
        if !canCopyAAC {
            try requireFFmpegEncoder("aac")
        }

        let encoders = try requireAvailableEncoderLadder(config.videoEncoderLadder, label: "Main video")
        let videoFilter =
            "scale=\(config.videoMP4Width):\(config.videoMP4Height):flags=\(config.videoMP4ScaleFilter)," +
            "format=\(config.videoMP4PixelFormat)," +
            "setparams=color_primaries=\(config.videoColorPrimaries):color_trc=\(config.videoColorTransfer):colorspace=\(config.videoColorSpace):range=\(ffmpegFilterRangeValue(config.videoColorRange))"

        func buildArguments(encoder: String, audioGainDB: Double?) -> [String] {
            var ffmpegArgs = [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-loop", "1",
                "-framerate", config.videoMP4InputFPS,
                "-i", imageFile.path,
                "-i", audioFile.path,
                "-t", String(format: "%.6f", duration),
                "-vf", videoFilter,
                "-c:v", encoder
            ]
            if encoder.lowercasedASCII.contains("videotoolbox") {
                ffmpegArgs += ["-q:v", config.videoMP4VTQuality]
            } else {
                ffmpegArgs += ["-preset", config.videoMP4SoftwarePreset, "-crf", config.videoMP4SoftwareCRF]
            }
            ffmpegArgs += [
                "-pix_fmt", config.videoMP4PixelFormat,
                "-color_primaries", config.videoColorPrimaries,
                "-color_trc", config.videoColorTransfer,
                "-colorspace", config.videoColorSpace,
                "-color_range", config.videoColorRange,
                "-tag:v", config.videoMP4Tag
            ]
            if let audioGainDB, abs(audioGainDB) > 0.01 {
                ffmpegArgs += [
                    "-af", "volume=\(String(format: "%.6f", audioGainDB))dB",
                    "-c:a", "aac",
                    "-b:a", config.videoMP4AudioBitrate,
                    "-ar", String(config.videoMP4AudioSampleRate)
                ]
            } else if canCopyAAC {
                ffmpegArgs += ["-c:a", "copy"]
            } else {
                ffmpegArgs += [
                    "-c:a", "aac",
                    "-b:a", config.videoMP4AudioBitrate,
                    "-ar", String(config.videoMP4AudioSampleRate)
                ]
            }
            ffmpegArgs += ["-shortest", "-movflags", "+faststart"]
            return ffmpegArgs
        }

        func verifyRenderedFile(_ temp: URL) throws {
            try verifyVideoOutput(
                temp,
                width: config.videoMP4Width,
                height: config.videoMP4Height,
                codec: config.videoMP4VerifyCodec,
                pixelFormat: config.videoMP4PixelFormat,
                colorPrimaries: config.videoColorPrimaries,
                colorTransfer: config.videoColorTransfer,
                colorSpace: config.videoColorSpace,
                colorRange: config.videoColorRange
            )
            try verifyAudioOutput(temp, codec: "aac", sampleRate: config.videoMP4AudioSampleRate, qcPolicy: audioQCPolicy)
            try verifyDurationMatch(source: audioFile, output: temp)
            try verifySourceLoudnessPreserved(source: audioFile, output: temp)
        }

        var lastError: Error?
        for encoder in encoders {
            let temp = try makeTemp(in: output.deletingLastPathComponent(), stem: "\(output.stem).\(encoder)", ext: ".mp4")
            do {
                _ = try runner.run("ffmpeg", buildArguments(encoder: encoder, audioGainDB: nil) + [temp.path])
                do {
                    try verifyRenderedFile(temp)
                } catch {
                    let description = error.localizedDescription.lowercased()
                    guard description.contains("loudness drift") || description.contains("peak drift") else {
                        throw error
                    }
                    let correctionDB = try loudnessCompensationDB(source: audioFile, output: temp)
                    guard abs(correctionDB) > 0.01 else {
                        throw error
                    }
                    logger.warn("Main video audio loudness drift detected; retrying with \(String(format: "%.2f", correctionDB)) dB compensation")
                    try? fileManager.removeItem(at: temp)
                    state.unregister(tempFile: temp)

                    let correctedTemp = try makeTemp(in: output.deletingLastPathComponent(), stem: "\(output.stem).\(encoder).matched", ext: ".mp4")
                    do {
                        _ = try runner.run("ffmpeg", buildArguments(encoder: encoder, audioGainDB: correctionDB) + [correctedTemp.path])
                        try verifyRenderedFile(correctedTemp)
                        try publishTemp(correctedTemp, to: output)
                        logger.info("Created MP4: \(output.basename) [encoder=\(encoder), loudness-matched]")
                        return output
                    } catch {
                        try? fileManager.removeItem(at: correctedTemp)
                        state.unregister(tempFile: correctedTemp)
                        throw error
                    }
                }
                try publishTemp(temp, to: output)
                logger.info("Created MP4: \(output.basename) [encoder=\(encoder)]")
                return output
            } catch {
                lastError = error
                logger.warn("Main video encoder failed (\(encoder)): \(error.localizedDescription)")
                try? fileManager.removeItem(at: temp)
                state.unregister(tempFile: temp)
            }
        }
        throw AppError("All main video encoders failed for \(output.basename): \(lastError?.localizedDescription ?? "unknown error")")
    }

    func shortenMP4(_ input: URL, audioQCPolicy: AudioQCPolicy?) throws -> URL {
        try preflightMP4Input(input, requireAudio: true, requireAudibleAudio: true)
        let inputAudioCodec = try audioField(input, "codec_name") ?? ""
        let inputAudioSampleRate = Int(try audioField(input, "sample_rate") ?? "") ?? 0
        let canCopyAAC = inputAudioCodec == "aac" && inputAudioSampleRate == config.shortMP4AudioSampleRate
        if !canCopyAAC {
            try requireFFmpegEncoder("aac")
        }
        let shortDuration = try effectiveShortClipSeconds(for: input)
        let output = cli.outDir.appendingPathComponent("\(input.stem)_Short").appendingPathExtension("mp4")
        if canReuseOutput(output, verifier: {
            try verifyVideoOutput(
                output,
                width: config.shortMP4ScaleW,
                height: config.shortMP4ScaleH,
                codec: config.shortMP4VerifyCodec,
                pixelFormat: config.shortMP4PixelFormat,
                colorPrimaries: config.videoColorPrimaries,
                colorTransfer: config.videoColorTransfer,
                colorSpace: config.videoColorSpace,
                colorRange: config.videoColorRange
            )
            try verifyAudioOutput(output, codec: "aac", sampleRate: config.shortMP4AudioSampleRate, qcPolicy: audioQCPolicy)
            try verifyShortMP4Duration(output, source: input)
            try verifySourceLoudnessPreserved(source: input, output: output)
        }) {
            logger.info("Skip existing short MP4: \(output.basename)")
            return output
        }
        let encoders = try requireAvailableEncoderLadder(config.shortVideoEncoderLadder, label: "Short video")
        let shortFilter =
            "crop=ih*9/16:ih," +
            "fps=\(config.shortMP4FPS)," +
            "scale=\(config.shortMP4ScaleW):\(config.shortMP4ScaleH)," +
            "format=\(config.shortMP4PixelFormat)," +
            "setparams=color_primaries=\(config.videoColorPrimaries):color_trc=\(config.videoColorTransfer):colorspace=\(config.videoColorSpace):range=\(ffmpegFilterRangeValue(config.videoColorRange))"

        func buildArguments(encoder: String, audioGainDB: Double?) -> [String] {
            var ffmpegArgs = [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-ss", "0",
                "-t", String(format: "%.6f", shortDuration),
                "-i", input.path,
                "-vf", shortFilter,
                "-c:v", encoder
            ]
            if encoder.lowercasedASCII.contains("videotoolbox") {
                ffmpegArgs += ["-q:v", config.shortMP4VTQuality]
            } else {
                ffmpegArgs += ["-preset", config.shortMP4VideoPreset, "-crf", config.shortMP4VideoCRF]
            }
            ffmpegArgs += [
                "-pix_fmt", config.shortMP4PixelFormat,
                "-color_primaries", config.videoColorPrimaries,
                "-color_trc", config.videoColorTransfer,
                "-colorspace", config.videoColorSpace,
                "-color_range", config.videoColorRange
            ]
            if let audioGainDB, abs(audioGainDB) > 0.01 {
                ffmpegArgs += [
                    "-af", "volume=\(String(format: "%.6f", audioGainDB))dB",
                    "-c:a", "aac",
                    "-b:a", config.shortMP4AudioBitrate,
                    "-ar", String(config.shortMP4AudioSampleRate)
                ]
            } else if canCopyAAC {
                ffmpegArgs += ["-c:a", "copy"]
            } else {
                ffmpegArgs += [
                    "-c:a", "aac",
                    "-b:a", config.shortMP4AudioBitrate,
                    "-ar", String(config.shortMP4AudioSampleRate)
                ]
            }
            return ffmpegArgs
        }

        func verifyShortFile(_ temp: URL) throws {
            try verifyVideoOutput(
                temp,
                width: config.shortMP4ScaleW,
                height: config.shortMP4ScaleH,
                codec: config.shortMP4VerifyCodec,
                pixelFormat: config.shortMP4PixelFormat,
                colorPrimaries: config.videoColorPrimaries,
                colorTransfer: config.videoColorTransfer,
                colorSpace: config.videoColorSpace,
                colorRange: config.videoColorRange
            )
            try verifyAudioOutput(temp, codec: "aac", sampleRate: config.shortMP4AudioSampleRate, qcPolicy: audioQCPolicy)
            try verifyShortMP4Duration(temp, source: input)
            try verifySourceLoudnessPreserved(source: input, output: temp)
        }

        var lastError: Error?
        for encoder in encoders {
            let temp = try makeTemp(in: cli.outDir, stem: "\(output.stem).\(encoder)", ext: ".mp4")
            do {
                _ = try runner.run("ffmpeg", buildArguments(encoder: encoder, audioGainDB: nil) + [temp.path])
                do {
                    try verifyShortFile(temp)
                } catch {
                    let description = error.localizedDescription.lowercased()
                    guard description.contains("loudness drift") || description.contains("peak drift") else {
                        throw error
                    }
                    let correctionDB = try loudnessCompensationDB(source: input, output: temp)
                    guard abs(correctionDB) > 0.01 else {
                        throw error
                    }
                    logger.warn("Short video audio loudness drift detected; retrying with \(String(format: "%.2f", correctionDB)) dB compensation")
                    try? fileManager.removeItem(at: temp)
                    state.unregister(tempFile: temp)

                    let correctedTemp = try makeTemp(in: cli.outDir, stem: "\(output.stem).\(encoder).matched", ext: ".mp4")
                    do {
                        _ = try runner.run("ffmpeg", buildArguments(encoder: encoder, audioGainDB: correctionDB) + [correctedTemp.path])
                        try verifyShortFile(correctedTemp)
                        try publishTemp(correctedTemp, to: output)
                        logger.info("Created short MP4: \(output.basename) [encoder=\(encoder), loudness-matched]")
                        return output
                    } catch {
                        try? fileManager.removeItem(at: correctedTemp)
                        state.unregister(tempFile: correctedTemp)
                        throw error
                    }
                }
                try publishTemp(temp, to: output)
                logger.info("Created short MP4: \(output.basename) [encoder=\(encoder)]")
                return output
            } catch {
                lastError = error
                logger.warn("Short video encoder failed (\(encoder)): \(error.localizedDescription)")
                try? fileManager.removeItem(at: temp)
                state.unregister(tempFile: temp)
            }
        }
        throw AppError("All short video encoders failed for \(output.basename): \(lastError?.localizedDescription ?? "unknown error")")
    }

    func renderM4AToShortMP4(imageFile: URL, audioFile: URL, audioQCPolicy: AudioQCPolicy?) throws -> URL {
        try preflightPNGInput(imageFile)
        try preflightM4AInput(audioFile)

        guard let dimensions = try imageDimensions(imageFile) else {
            throw AppError("Unable to read dimensions: \(imageFile.path)")
        }
        if dimensions.0 != config.shortMP4ScaleW || dimensions.1 != config.shortMP4ScaleH {
            throw AppError("Short image must be \(config.shortMP4ScaleW)x\(config.shortMP4ScaleH). Got '\(dimensions.0)x\(dimensions.1)' for '\(imageFile.path)'.")
        }
        guard let audioDuration = try mediaDuration(audioFile) else {
            throw AppError("Unable to read numeric audio duration from: \(audioFile.path)")
        }
        let inputAudioCodec = try audioField(audioFile, "codec_name") ?? ""
        let inputAudioSampleRate = Int(try audioField(audioFile, "sample_rate") ?? "") ?? 0
        let canCopyAAC = inputAudioCodec == "aac" && inputAudioSampleRate == config.shortMP4AudioSampleRate
        if !canCopyAAC {
            try requireFFmpegEncoder("aac")
        }
        let shortDuration = try effectiveShortClipSeconds(forDuration: audioDuration)
        let output = cli.outDir.appendingPathComponent("\(audioFile.stem)_8K_Short").appendingPathExtension("mp4")
        if canReuseOutput(output, verifier: {
            try verifyVideoOutput(
                output,
                width: config.shortMP4ScaleW,
                height: config.shortMP4ScaleH,
                codec: config.shortMP4VerifyCodec,
                pixelFormat: config.shortMP4PixelFormat,
                colorPrimaries: config.videoColorPrimaries,
                colorTransfer: config.videoColorTransfer,
                colorSpace: config.videoColorSpace,
                colorRange: config.videoColorRange
            )
            try verifyAudioOutput(output, codec: "aac", sampleRate: config.shortMP4AudioSampleRate, qcPolicy: audioQCPolicy)
            try verifyDuration(output, expectedSeconds: shortDuration, label: "portrait short MP4 output", tolerance: 0.5)
            try verifySourceLoudnessPreserved(source: audioFile, output: output)
        }) {
            logger.info("Skip existing portrait short MP4: \(output.basename)")
            return output
        }

        let encoders = try requireAvailableEncoderLadder(config.shortVideoEncoderLadder, label: "Short video")
        let shortFilter =
            "scale=\(config.shortMP4ScaleW):\(config.shortMP4ScaleH)," +
            "fps=\(config.shortMP4FPS)," +
            "format=\(config.shortMP4PixelFormat)," +
            "setparams=color_primaries=\(config.videoColorPrimaries):color_trc=\(config.videoColorTransfer):colorspace=\(config.videoColorSpace):range=\(ffmpegFilterRangeValue(config.videoColorRange))"

        func buildArguments(encoder: String, audioGainDB: Double?) -> [String] {
            var ffmpegArgs = [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-loop", "1",
                "-framerate", config.shortMP4FPS,
                "-i", imageFile.path,
                "-i", audioFile.path,
                "-t", String(format: "%.6f", shortDuration),
                "-vf", shortFilter,
                "-c:v", encoder
            ]
            if encoder.lowercasedASCII.contains("videotoolbox") {
                ffmpegArgs += ["-q:v", config.shortMP4VTQuality]
            } else {
                ffmpegArgs += ["-preset", config.shortMP4VideoPreset, "-crf", config.shortMP4VideoCRF]
            }
            ffmpegArgs += [
                "-pix_fmt", config.shortMP4PixelFormat,
                "-color_primaries", config.videoColorPrimaries,
                "-color_trc", config.videoColorTransfer,
                "-colorspace", config.videoColorSpace,
                "-color_range", config.videoColorRange,
                "-shortest",
                "-movflags", "+faststart"
            ]
            if let audioGainDB, abs(audioGainDB) > 0.01 {
                ffmpegArgs += [
                    "-af", "volume=\(String(format: "%.6f", audioGainDB))dB",
                    "-c:a", "aac",
                    "-b:a", config.shortMP4AudioBitrate,
                    "-ar", String(config.shortMP4AudioSampleRate)
                ]
            } else if canCopyAAC {
                ffmpegArgs += ["-c:a", "copy"]
            } else {
                ffmpegArgs += [
                    "-c:a", "aac",
                    "-b:a", config.shortMP4AudioBitrate,
                    "-ar", String(config.shortMP4AudioSampleRate)
                ]
            }
            return ffmpegArgs
        }

        func verifyPortraitShortFile(_ temp: URL) throws {
            try verifyVideoOutput(
                temp,
                width: config.shortMP4ScaleW,
                height: config.shortMP4ScaleH,
                codec: config.shortMP4VerifyCodec,
                pixelFormat: config.shortMP4PixelFormat,
                colorPrimaries: config.videoColorPrimaries,
                colorTransfer: config.videoColorTransfer,
                colorSpace: config.videoColorSpace,
                colorRange: config.videoColorRange
            )
            try verifyAudioOutput(temp, codec: "aac", sampleRate: config.shortMP4AudioSampleRate, qcPolicy: audioQCPolicy)
            try verifyDuration(temp, expectedSeconds: shortDuration, label: "portrait short MP4 output", tolerance: 0.5)
            try verifySourceLoudnessPreserved(source: audioFile, output: temp)
        }

        var lastError: Error?
        for encoder in encoders {
            let temp = try makeTemp(in: cli.outDir, stem: "\(output.stem).\(encoder)", ext: ".mp4")
            do {
                _ = try runner.run("ffmpeg", buildArguments(encoder: encoder, audioGainDB: nil) + [temp.path])
                do {
                    try verifyPortraitShortFile(temp)
                } catch {
                    let description = error.localizedDescription.lowercased()
                    guard description.contains("loudness drift") || description.contains("peak drift") else {
                        throw error
                    }
                    let correctionDB = try loudnessCompensationDB(source: audioFile, output: temp)
                    guard abs(correctionDB) > 0.01 else {
                        throw error
                    }
                    logger.warn("Portrait short audio loudness drift detected; retrying with \(String(format: "%.2f", correctionDB)) dB compensation")
                    try? fileManager.removeItem(at: temp)
                    state.unregister(tempFile: temp)

                    let correctedTemp = try makeTemp(in: cli.outDir, stem: "\(output.stem).\(encoder).matched", ext: ".mp4")
                    do {
                        _ = try runner.run("ffmpeg", buildArguments(encoder: encoder, audioGainDB: correctionDB) + [correctedTemp.path])
                        try verifyPortraitShortFile(correctedTemp)
                        try publishTemp(correctedTemp, to: output)
                        logger.info("Created portrait short MP4: \(output.basename) [encoder=\(encoder), loudness-matched]")
                        return output
                    } catch {
                        try? fileManager.removeItem(at: correctedTemp)
                        state.unregister(tempFile: correctedTemp)
                        throw error
                    }
                }
                try publishTemp(temp, to: output)
                logger.info("Created portrait short MP4: \(output.basename) [encoder=\(encoder)]")
                return output
            } catch {
                lastError = error
                logger.warn("Portrait short video encoder failed (\(encoder)): \(error.localizedDescription)")
                try? fileManager.removeItem(at: temp)
                state.unregister(tempFile: temp)
            }
        }
        throw AppError("All portrait short video encoders failed for \(output.basename): \(lastError?.localizedDescription ?? "unknown error")")
    }

}
