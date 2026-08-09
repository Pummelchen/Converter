import Foundation

extension ConverterTool {
    private var shortMP4AbsoluteMaximumSeconds: Double { 58.0 }

    /// Maps an encoder name to the ffprobe codec name used to verify its output.
    func verifyCodec(forEncoder encoder: String) -> String? {
        let name = encoder.lowercasedASCII
        if name.contains("264") {
            return "h264"
        }
        if name.contains("265") || name.contains("hevc") {
            return "hevc"
        }
        return nil
    }

    private func mp4EncoderQualityArguments(encoder: String, vtQuality: String, preset: String, crf: String) -> [String] {
        if encoder.lowercasedASCII.contains("videotoolbox") {
            return ["-q:v", vtQuality]
        }
        return ["-preset", preset, "-crf", crf]
    }

    private func mp4RenderTail(
        pixelFormat: String,
        colorPrimaries: String,
        colorTransfer: String,
        colorSpace: String,
        colorRange: String,
        tag: String?,
        sampleRate: Int,
        channels: Int
    ) -> [String] {
        var args = [
            "-pix_fmt", pixelFormat,
            "-color_primaries", colorPrimaries,
            "-color_trc", colorTransfer,
            "-colorspace", colorSpace,
            "-color_range", colorRange
        ]
        if let tag {
            args += ["-tag:v", tag]
        }
        args += alacAudioArguments(sampleRate: sampleRate, channels: channels)
        args += ["-shortest", "-movflags", "+faststart"]
        return args
    }

    private func verifyVideoRender(
        _ url: URL,
        width: Int,
        height: Int,
        codec: String,
        pixelFormat: String,
        colorPrimaries: String,
        colorTransfer: String,
        colorSpace: String,
        colorRange: String,
        sampleRate: Int,
        channels: Int,
        qcPolicy: AudioQCPolicy?,
        source: URL,
        durationCheck: (URL) throws -> Void
    ) throws {
        try verifyVideoOutput(
            url,
            width: width,
            height: height,
            codec: codec,
            pixelFormat: pixelFormat,
            colorPrimaries: colorPrimaries,
            colorTransfer: colorTransfer,
            colorSpace: colorSpace,
            colorRange: colorRange
        )
        try verifyALACAudioOutput(url, sampleRate: sampleRate, channels: channels, qcPolicy: qcPolicy)
        try durationCheck(url)
        try verifySourceLoudnessPreserved(source: source, output: url, toleranceDB: 1.0)
    }

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

    func fullSongShortMP4Stem(forAudioStem stem: String) -> String {
        return "\(portraitShortMP4Stem(forAudioStem: stem))_FullSong"
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
            try verifyVideoRender(
                output,
                width: config.videoMP4Width,
                height: config.videoMP4Height,
                codec: config.videoMP4VerifyCodec,
                pixelFormat: config.videoMP4PixelFormat,
                colorPrimaries: config.videoColorPrimaries,
                colorTransfer: config.videoColorTransfer,
                colorSpace: config.videoColorSpace,
                colorRange: config.videoColorRange,
                sampleRate: config.videoMP4AudioSampleRate,
                channels: 2,
                qcPolicy: audioQCPolicy,
                source: audioFile
            ) {
                try verifyDurationMatch(source: audioFile, output: $0)
            }
        }) {
            logger.info("Skip existing MP4: \(output.basename)")
            return output
        }
        try requireFFmpegEncoder(alacEncoderName)

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
                "-t", ffmpegArg("%.6f", duration),
                "-map", "0:v:0",
                "-map", "1:a:0",
                "-vf", videoFilter,
                "-c:v", encoder
            ]
            ffmpegArgs += mp4EncoderQualityArguments(
                encoder: encoder,
                vtQuality: config.videoMP4VTQuality,
                preset: config.videoMP4SoftwarePreset,
                crf: config.videoMP4SoftwareCRF
            )
            ffmpegArgs += mp4RenderTail(
                pixelFormat: config.videoMP4PixelFormat,
                colorPrimaries: config.videoColorPrimaries,
                colorTransfer: config.videoColorTransfer,
                colorSpace: config.videoColorSpace,
                colorRange: config.videoColorRange,
                tag: config.videoMP4Tag,
                sampleRate: config.videoMP4AudioSampleRate,
                channels: 2
            )
            return ffmpegArgs
        }

        func verifyRenderedFile(_ temp: URL, codec: String) throws {
            try verifyVideoRender(
                temp,
                width: config.videoMP4Width,
                height: config.videoMP4Height,
                codec: codec,
                pixelFormat: config.videoMP4PixelFormat,
                colorPrimaries: config.videoColorPrimaries,
                colorTransfer: config.videoColorTransfer,
                colorSpace: config.videoColorSpace,
                colorRange: config.videoColorRange,
                sampleRate: config.videoMP4AudioSampleRate,
                channels: 2,
                qcPolicy: audioQCPolicy,
                source: audioFile
            ) {
                try verifyDurationMatch(source: audioFile, output: $0)
            }
        }

        var lastError: Error?
        for encoder in encoders {
            let temp = try makeTemp(in: output.deletingLastPathComponent(), stem: "mainmp4.\(encoder)", ext: ".mp4")
            do {
                _ = try runner.run("ffmpeg", buildArguments(encoder: encoder) + [temp.path])
                try verifyRenderedFile(temp, codec: verifyCodec(forEncoder: encoder) ?? config.videoMP4VerifyCodec)
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
        try requireFFmpegEncoder(alacEncoderName)
        let shortDuration = try effectiveShortClipSeconds(for: input)
        let output = cli.outDir.appendingPathComponent(shortMP4Stem(forInputStem: input.stem)).appendingPathExtension("mp4")
        if canReuseOutput(output, verifier: {
            try verifyVideoRender(
                output,
                width: config.shortMP4ScaleW,
                height: config.shortMP4ScaleH,
                codec: config.shortMP4VerifyCodec,
                pixelFormat: config.shortMP4PixelFormat,
                colorPrimaries: config.videoColorPrimaries,
                colorTransfer: config.videoColorTransfer,
                colorSpace: config.videoColorSpace,
                colorRange: config.videoColorRange,
                sampleRate: config.shortMP4AudioSampleRate,
                channels: 2,
                qcPolicy: audioQCPolicy,
                source: input
            ) {
                try verifyShortMP4Duration($0, source: input)
            }
        }) {
            logger.info("Skip existing short MP4: \(output.basename)")
            return output
        }
        let encoders = try requireAvailableEncoderLadder(config.shortVideoEncoderLadder, label: "Short video")
        let sourceWAV = try makeInternalWAV(from: input, in: cli.outDir, stem: "\(input.stem).shortmp4.source", duration: shortDuration)
        defer { discardTempFile(sourceWAV) }
        let shortFilter =
            "crop=min(iw\\,ih*9/16):ih," +
            "fps=\(config.shortMP4FPS)," +
            "scale=\(config.shortMP4ScaleW):\(config.shortMP4ScaleH)," +
            "format=\(config.shortMP4PixelFormat)," +
            "setparams=color_primaries=\(config.videoColorPrimaries):color_trc=\(config.videoColorTransfer):colorspace=\(config.videoColorSpace):range=\(ffmpegFilterRangeValue(config.videoColorRange))"

        func buildArguments(encoder: String) -> [String] {
            var ffmpegArgs = [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-ss", "0",
                "-t", ffmpegArg("%.6f", shortDuration),
                "-i", input.path,
                "-i", sourceWAV.path,
                "-map", "0:v:0",
                "-map", "1:a:0",
                "-vf", shortFilter,
                "-c:v", encoder
            ]
            ffmpegArgs += mp4EncoderQualityArguments(
                encoder: encoder,
                vtQuality: config.shortMP4VTQuality,
                preset: config.shortMP4VideoPreset,
                crf: config.shortMP4VideoCRF
            )
            ffmpegArgs += mp4RenderTail(
                pixelFormat: config.shortMP4PixelFormat,
                colorPrimaries: config.videoColorPrimaries,
                colorTransfer: config.videoColorTransfer,
                colorSpace: config.videoColorSpace,
                colorRange: config.videoColorRange,
                tag: nil,
                sampleRate: config.shortMP4AudioSampleRate,
                channels: 2
            )
            return ffmpegArgs
        }

        func verifyShortFile(_ temp: URL, codec: String) throws {
            try verifyVideoRender(
                temp,
                width: config.shortMP4ScaleW,
                height: config.shortMP4ScaleH,
                codec: codec,
                pixelFormat: config.shortMP4PixelFormat,
                colorPrimaries: config.videoColorPrimaries,
                colorTransfer: config.videoColorTransfer,
                colorSpace: config.videoColorSpace,
                colorRange: config.videoColorRange,
                sampleRate: config.shortMP4AudioSampleRate,
                channels: 2,
                qcPolicy: audioQCPolicy,
                source: input
            ) {
                try verifyShortMP4Duration($0, source: input)
            }
        }

        var lastError: Error?
        for encoder in encoders {
            let temp = try makeTemp(in: cli.outDir, stem: "shortmp4.\(encoder)", ext: ".mp4")
            do {
                _ = try runner.run("ffmpeg", buildArguments(encoder: encoder) + [temp.path])
                try verifyShortFile(temp, codec: verifyCodec(forEncoder: encoder) ?? config.shortMP4VerifyCodec)
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

    func renderAudioToShortMP4(
        imageFile: URL,
        audioFile: URL,
        audioQCPolicy: AudioQCPolicy?,
        outputStem: String? = nil,
        skipLengthCap: Bool = false
    ) throws -> URL {
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
        try requireFFmpegEncoder(alacEncoderName)
        let shortDuration = skipLengthCap ? audioDuration : try effectiveShortClipSeconds(forDuration: audioDuration)
        let verificationLabel = skipLengthCap ? "full-song portrait short MP4 output" : "portrait short MP4 output"
        let output = cli.outDir
            .appendingPathComponent(outputStem ?? portraitShortMP4Stem(forAudioStem: audioFile.stem))
            .appendingPathExtension("mp4")
        if canReuseOutput(output, verifier: {
            try verifyVideoRender(
                output,
                width: config.shortMP4ScaleW,
                height: config.shortMP4ScaleH,
                codec: config.shortMP4VerifyCodec,
                pixelFormat: config.shortMP4PixelFormat,
                colorPrimaries: config.videoColorPrimaries,
                colorTransfer: config.videoColorTransfer,
                colorSpace: config.videoColorSpace,
                colorRange: config.videoColorRange,
                sampleRate: config.shortMP4AudioSampleRate,
                channels: 2,
                qcPolicy: audioQCPolicy,
                source: audioFile
            ) {
                try verifyDuration($0, expectedSeconds: shortDuration, label: verificationLabel, tolerance: 0.5)
            }
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
                "-t", ffmpegArg("%.6f", shortDuration),
                "-map", "0:v:0",
                "-map", "1:a:0",
                "-vf", shortFilter,
                "-c:v", encoder
            ]
            ffmpegArgs += mp4EncoderQualityArguments(
                encoder: encoder,
                vtQuality: config.shortMP4VTQuality,
                preset: config.shortMP4VideoPreset,
                crf: config.shortMP4VideoCRF
            )
            ffmpegArgs += mp4RenderTail(
                pixelFormat: config.shortMP4PixelFormat,
                colorPrimaries: config.videoColorPrimaries,
                colorTransfer: config.videoColorTransfer,
                colorSpace: config.videoColorSpace,
                colorRange: config.videoColorRange,
                tag: nil,
                sampleRate: config.shortMP4AudioSampleRate,
                channels: 2
            )
            return ffmpegArgs
        }

        func verifyPortraitShortFile(_ temp: URL, codec: String) throws {
            try verifyVideoRender(
                temp,
                width: config.shortMP4ScaleW,
                height: config.shortMP4ScaleH,
                codec: codec,
                pixelFormat: config.shortMP4PixelFormat,
                colorPrimaries: config.videoColorPrimaries,
                colorTransfer: config.videoColorTransfer,
                colorSpace: config.videoColorSpace,
                colorRange: config.videoColorRange,
                sampleRate: config.shortMP4AudioSampleRate,
                channels: 2,
                qcPolicy: audioQCPolicy,
                source: audioFile
            ) {
                try verifyDuration($0, expectedSeconds: shortDuration, label: verificationLabel, tolerance: 0.5)
            }
        }

        var lastError: Error?
        for encoder in encoders {
            let temp = try makeTemp(in: cli.outDir, stem: "portraitshort.\(encoder)", ext: ".mp4")
            do {
                _ = try runner.run("ffmpeg", buildArguments(encoder: encoder) + [temp.path])
                try verifyPortraitShortFile(temp, codec: verifyCodec(forEncoder: encoder) ?? config.shortMP4VerifyCodec)
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
