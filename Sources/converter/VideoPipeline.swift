import Foundation

extension ConverterTool {
    private var shortMP4AbsoluteMaximumSeconds: Double { 58.0 }

    func configuredShortClipSeconds() throws -> Double {
        try parseFlexibleTimecode(config.shortMP4ClipSeconds, label: "SHORT_MP4_CLIP_SECONDS")
    }

    func effectiveShortClipSeconds(for input: URL) throws -> Double {
        let configured = try configuredShortClipSeconds()
        guard let inputDuration = try mediaDuration(input) else {
            throw AppError("Unable to read numeric video duration from: \(input.path)")
        }
        return min(configured, shortMP4AbsoluteMaximumSeconds, inputDuration)
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

    func renderM4AToMP4(imageFile: URL, audioFile: URL) throws -> URL {
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
            try verifyAudioOutput(output, codec: "aac", sampleRate: config.videoMP4AudioSampleRate, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: audioFile, output: output)
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

        var lastError: Error?
        for encoder in encoders {
            let temp = try makeTemp(in: output.deletingLastPathComponent(), stem: "\(output.stem).\(encoder)", ext: ".mp4")
            do {
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
                if canCopyAAC {
                    ffmpegArgs += ["-c:a", "copy"]
                } else {
                    ffmpegArgs += [
                        "-c:a", "aac",
                        "-b:a", config.videoMP4AudioBitrate,
                        "-ar", String(config.videoMP4AudioSampleRate)
                    ]
                }
                ffmpegArgs += ["-shortest", "-movflags", "+faststart", temp.path]

                _ = try runner.run("ffmpeg", ffmpegArgs)
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
                try verifyAudioOutput(temp, codec: "aac", sampleRate: config.videoMP4AudioSampleRate, qcPolicy: config.deliveryAudioQCPolicy)
                try verifyDurationMatch(source: audioFile, output: temp)
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

    func shortenMP4(_ input: URL) throws -> URL {
        try preflightMP4Input(input, requireAudio: true, requireAudibleAudio: true)
        try requireFFmpegEncoder("aac")
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
            try verifyAudioOutput(output, codec: "aac", sampleRate: config.shortMP4AudioSampleRate, qcPolicy: config.shortFormAudioQCPolicy)
            try verifyShortMP4Duration(output, source: input)
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
        var lastError: Error?
        for encoder in encoders {
            let temp = try makeTemp(in: cli.outDir, stem: "\(output.stem).\(encoder)", ext: ".mp4")
            do {
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
                    "-color_range", config.videoColorRange,
                    "-c:a", "aac",
                    "-b:a", config.shortMP4AudioBitrate,
                    "-ar", String(config.shortMP4AudioSampleRate),
                    temp.path
                ]
                _ = try runner.run("ffmpeg", ffmpegArgs)
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
                try verifyAudioOutput(temp, codec: "aac", sampleRate: config.shortMP4AudioSampleRate, qcPolicy: config.shortFormAudioQCPolicy)
                try verifyShortMP4Duration(temp, source: input)
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

}
