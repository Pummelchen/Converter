import Foundation

extension ConverterTool {
    private var shortMP4AbsoluteMaximumSeconds: Double { 58.0 }

    func shortMP4Stem(forInputStem stem: String) -> String {
        stem.hasSuffix("_Short") ? stem : "\(stem)_Short"
    }

    func portraitShortMP4Stem(forAudioStem stem: String) -> String {
        if stem.hasSuffix("_8K_Short") {
            return stem
        }
        if stem.hasSuffix("_Short") {
            return stem
        }
        if stem.hasSuffix("_8K") {
            return "\(stem)_Short"
        }
        return "\(stem)_8K_Short"
    }

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
        let defaultName = "\(audioFile.stem)_8K.mp4"
        let output = try resolveOutputPath(cli.outputFile ?? defaultName)
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
            try verifyALACAudioOutput(output, sampleRate: config.videoMP4AudioSampleRate, channels: 2, qcPolicy: audioQCPolicy)
            try verifyDurationMatch(source: audioFile, output: output)
            try verifySourceLoudnessPreserved(source: audioFile, output: output, toleranceDB: 1.0)
        }) {
            logger.info("Skip existing MP4: \(output.basename)")
            return output
        }
        try requireFFmpegEncoder("alac")

        let encoders = try requireAvailableEncoderLadder(config.videoEncoderLadder, label: "Main video")
        let sourceWAV = try makeInternalWAV(from: audioFile, in: output.deletingLastPathComponent(), stem: "\(audioFile.stem).mainmp4.source")
        defer { discardTempFile(sourceWAV) }
        let videoFilter =
            "scale=\(config.videoMP4Width):\(config.videoMP4Height):flags=\(config.videoMP4ScaleFilter)," +
            "format=\(config.videoMP4PixelFormat)," +
            "setparams=color_primaries=\(config.videoColorPrimaries):color_trc=\(config.videoColorTransfer):colorspace=\(config.videoColorSpace):range=\(ffmpegFilterRangeValue(config.videoColorRange))"

        func buildArguments(encoder: String) -> [String] {
            var ffmpegArgs = [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-loop", "1",
                "-framerate", config.videoMP4InputFPS,
                "-i", imageFile.path,
                "-i", sourceWAV.path,
                "-t", String(format: "%.6f", duration),
                "-map", "0:v:0",
                "-map", "1:a:0",
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
            ffmpegArgs += alacAudioArguments(sampleRate: config.videoMP4AudioSampleRate, channels: 2)
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
            try verifyALACAudioOutput(temp, sampleRate: config.videoMP4AudioSampleRate, channels: 2, qcPolicy: audioQCPolicy)
            try verifyDurationMatch(source: audioFile, output: temp)
            try verifySourceLoudnessPreserved(source: audioFile, output: temp, toleranceDB: 1.0)
        }

        var lastError: Error?
        for encoder in encoders {
            let temp = try makeTemp(in: output.deletingLastPathComponent(), stem: "mainmp4.\(encoder)", ext: ".mp4")
            do {
                _ = try runner.run("ffmpeg", buildArguments(encoder: encoder) + [temp.path])
                try verifyRenderedFile(temp)
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
        try requireFFmpegEncoder("alac")
        let shortDuration = try effectiveShortClipSeconds(for: input)
        let output = cli.outDir.appendingPathComponent(shortMP4Stem(forInputStem: input.stem)).appendingPathExtension("mp4")
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
            try verifyALACAudioOutput(output, sampleRate: config.shortMP4AudioSampleRate, channels: 2, qcPolicy: audioQCPolicy)
            try verifyShortMP4Duration(output, source: input)
            try verifySourceLoudnessPreserved(source: input, output: output, toleranceDB: 1.0)
        }) {
            logger.info("Skip existing short MP4: \(output.basename)")
            return output
        }
        let encoders = try requireAvailableEncoderLadder(config.shortVideoEncoderLadder, label: "Short video")
        let sourceWAV = try makeInternalWAV(from: input, in: cli.outDir, stem: "\(input.stem).shortmp4.source", duration: shortDuration)
        defer { discardTempFile(sourceWAV) }
        let shortFilter =
            "crop=ih*9/16:ih," +
            "fps=\(config.shortMP4FPS)," +
            "scale=\(config.shortMP4ScaleW):\(config.shortMP4ScaleH)," +
            "format=\(config.shortMP4PixelFormat)," +
            "setparams=color_primaries=\(config.videoColorPrimaries):color_trc=\(config.videoColorTransfer):colorspace=\(config.videoColorSpace):range=\(ffmpegFilterRangeValue(config.videoColorRange))"

        func buildArguments(encoder: String) -> [String] {
            var ffmpegArgs = [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-ss", "0",
                "-t", String(format: "%.6f", shortDuration),
                "-i", input.path,
                "-i", sourceWAV.path,
                "-map", "0:v:0",
                "-map", "1:a:0",
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
            ffmpegArgs += alacAudioArguments(sampleRate: config.shortMP4AudioSampleRate, channels: 2)
            ffmpegArgs += ["-shortest", "-movflags", "+faststart"]
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
            try verifyALACAudioOutput(temp, sampleRate: config.shortMP4AudioSampleRate, channels: 2, qcPolicy: audioQCPolicy)
            try verifyShortMP4Duration(temp, source: input)
            try verifySourceLoudnessPreserved(source: input, output: temp, toleranceDB: 1.0)
        }

        var lastError: Error?
        for encoder in encoders {
            let temp = try makeTemp(in: cli.outDir, stem: "shortmp4.\(encoder)", ext: ".mp4")
            do {
                _ = try runner.run("ffmpeg", buildArguments(encoder: encoder) + [temp.path])
                try verifyShortFile(temp)
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

    func preflightShortAudioInput(_ file: URL) throws {
        try preflightAudioInput(file, requireNoVideo: true)
    }

    func renderM4AToShortMP4(imageFile: URL, audioFile: URL, audioQCPolicy: AudioQCPolicy?) throws -> URL {
        try preflightM4AInput(audioFile)
        return try renderAudioToShortMP4(imageFile: imageFile, audioFile: audioFile, audioQCPolicy: audioQCPolicy)
    }

    func renderAudioToShortMP4(imageFile: URL, audioFile: URL, audioQCPolicy: AudioQCPolicy?) throws -> URL {
        try preflightImageInput(imageFile)
        try preflightShortAudioInput(audioFile)

        guard let dimensions = try imageDimensions(imageFile) else {
            throw AppError("Unable to read dimensions: \(imageFile.path)")
        }
        if dimensions.0 <= 0 || dimensions.1 <= 0 {
            throw AppError("Short image dimensions must be positive. Got '\(dimensions.0)x\(dimensions.1)' for '\(imageFile.path)'.")
        }
        guard let audioDuration = try mediaDuration(audioFile) else {
            throw AppError("Unable to read numeric audio duration from: \(audioFile.path)")
        }
        try requireFFmpegEncoder("alac")
        let shortDuration = try effectiveShortClipSeconds(forDuration: audioDuration)
        let output = cli.outDir.appendingPathComponent(portraitShortMP4Stem(forAudioStem: audioFile.stem)).appendingPathExtension("mp4")
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
            try verifyALACAudioOutput(output, sampleRate: config.shortMP4AudioSampleRate, channels: 2, qcPolicy: audioQCPolicy)
            try verifyDuration(output, expectedSeconds: shortDuration, label: "portrait short MP4 output", tolerance: 0.5)
            try verifySourceLoudnessPreserved(source: audioFile, output: output, toleranceDB: 1.0)
        }) {
            logger.info("Skip existing portrait short MP4: \(output.basename)")
            return output
        }

        let encoders = try requireAvailableEncoderLadder(config.shortVideoEncoderLadder, label: "Short video")
        let sourceWAV = try makeInternalWAV(from: audioFile, in: cli.outDir, stem: "\(audioFile.stem).portraitshort.source", duration: shortDuration)
        defer { discardTempFile(sourceWAV) }
        let shortFilter =
            "scale=w=\(config.shortMP4ScaleW):h=\(config.shortMP4ScaleH):force_original_aspect_ratio=decrease," +
            "pad=\(config.shortMP4ScaleW):\(config.shortMP4ScaleH):(ow-iw)/2:(oh-ih)/2:color=black," +
            "fps=\(config.shortMP4FPS)," +
            "format=\(config.shortMP4PixelFormat)," +
            "setparams=color_primaries=\(config.videoColorPrimaries):color_trc=\(config.videoColorTransfer):colorspace=\(config.videoColorSpace):range=\(ffmpegFilterRangeValue(config.videoColorRange))"

        func buildArguments(encoder: String) -> [String] {
            var ffmpegArgs = [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-loop", "1",
                "-framerate", config.shortMP4FPS,
                "-i", imageFile.path,
                "-i", sourceWAV.path,
                "-t", String(format: "%.6f", shortDuration),
                "-map", "0:v:0",
                "-map", "1:a:0",
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
            ffmpegArgs += alacAudioArguments(sampleRate: config.shortMP4AudioSampleRate, channels: 2)
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
            try verifyALACAudioOutput(temp, sampleRate: config.shortMP4AudioSampleRate, channels: 2, qcPolicy: audioQCPolicy)
            try verifyDuration(temp, expectedSeconds: shortDuration, label: "portrait short MP4 output", tolerance: 0.5)
            try verifySourceLoudnessPreserved(source: audioFile, output: temp, toleranceDB: 1.0)
        }

        var lastError: Error?
        for encoder in encoders {
            let temp = try makeTemp(in: cli.outDir, stem: "portraitshort.\(encoder)", ext: ".mp4")
            do {
                _ = try runner.run("ffmpeg", buildArguments(encoder: encoder) + [temp.path])
                try verifyPortraitShortFile(temp)
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
