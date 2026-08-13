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

    // What a finished render must satisfy. Shared by the reuse check and the encoder
    // ladder so a reused file and a freshly rendered one are held to the same contract.
    private struct VideoOutputSpec {
        let width: Int
        let height: Int
        let pixelFormat: String
        let fallbackVerifyCodec: String
        let audioSampleRate: Int
        let audioQCPolicy: AudioQCPolicy?
        let loudnessSource: URL
        let durationCheck: (URL) throws -> Void
    }

    // How to produce it: the only things the three render paths genuinely differ in.
    private struct VideoEncodeSpec {
        let output: URL
        let inputArguments: [String]
        let videoFilter: String
        let encoderLadder: [String]
        let vtQuality: String
        let softwarePreset: String
        let softwareCRF: String
        let tag: String?
        let tempStem: String
        let label: String
    }

    private func verifyRenderedVideo(_ url: URL, spec: VideoOutputSpec, codec: String? = nil) throws {
        try verifyVideoRender(
            url,
            width: spec.width,
            height: spec.height,
            codec: codec ?? spec.fallbackVerifyCodec,
            pixelFormat: spec.pixelFormat,
            colorPrimaries: config.videoColorPrimaries,
            colorTransfer: config.videoColorTransfer,
            colorSpace: config.videoColorSpace,
            colorRange: config.videoColorRange,
            sampleRate: spec.audioSampleRate,
            channels: 2,
            qcPolicy: spec.audioQCPolicy,
            source: spec.loudnessSource,
            durationCheck: spec.durationCheck
        )
    }

    // Walks the encoder ladder, verifying before publishing and falling through to the
    // next encoder on failure. All three render paths share this, so a fix here cannot
    // reach only two of them.
    private func renderVideoWithEncoderLadder(_ encode: VideoEncodeSpec, verifying spec: VideoOutputSpec) throws -> URL {
        var lastError: (any Error)?
        for encoder in encode.encoderLadder {
            let temp = try makeTemp(
                in: encode.output.deletingLastPathComponent(),
                stem: "\(encode.tempStem).\(encoder)",
                ext: ".mp4"
            )
            do {
                var arguments = encode.inputArguments
                arguments += ["-map", "0:v:0", "-map", "1:a:0", "-vf", encode.videoFilter, "-c:v", encoder]
                arguments += mp4EncoderQualityArguments(
                    encoder: encoder,
                    vtQuality: encode.vtQuality,
                    preset: encode.softwarePreset,
                    crf: encode.softwareCRF
                )
                arguments += mp4RenderTail(
                    pixelFormat: spec.pixelFormat,
                    colorPrimaries: config.videoColorPrimaries,
                    colorTransfer: config.videoColorTransfer,
                    colorSpace: config.videoColorSpace,
                    colorRange: config.videoColorRange,
                    tag: encode.tag,
                    sampleRate: spec.audioSampleRate,
                    channels: 2
                )
                _ = try runner.run("ffmpeg", arguments + [temp.path])
                try verifyRenderedVideo(temp, spec: spec, codec: verifyCodec(forEncoder: encoder))
                try publishTemp(temp, to: encode.output)
                logger.info("Created \(encode.label): \(encode.output.basename) [encoder=\(encoder)]")
                return encode.output
            } catch {
                lastError = error
                logger.warn("\(encode.label) encoder failed (\(encoder)): \(error.localizedDescription)")
                discardTempFile(temp)
            }
        }
        throw AppError("All \(encode.label) encoders failed for \(encode.output.basename): \(lastError?.localizedDescription ?? "unknown error")")
    }

    private func colorParameterFilter() -> String {
        "setparams=color_primaries=\(config.videoColorPrimaries):color_trc=\(config.videoColorTransfer):colorspace=\(config.videoColorSpace):range=\(ffmpegFilterRangeValue(config.videoColorRange))"
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
        let output = try resolveOutputPath(cli.outputFile ?? "\(audioFile.stem)_8K.mp4")

        let spec = VideoOutputSpec(
            width: config.videoMP4Width,
            height: config.videoMP4Height,
            pixelFormat: config.videoMP4PixelFormat,
            fallbackVerifyCodec: config.videoMP4VerifyCodec,
            audioSampleRate: config.videoMP4AudioSampleRate,
            audioQCPolicy: audioQCPolicy,
            loudnessSource: audioFile,
            durationCheck: { try self.verifyDurationMatch(source: audioFile, output: $0) }
        )

        if canReuseOutput(output, verifier: { try self.verifyRenderedVideo(output, spec: spec) }) {
            logger.info("Skip existing MP4: \(output.basename)")
            return output
        }
        try requireFFmpegEncoder(alacEncoderName)

        let encoders = try requireAvailableEncoderLadder(config.videoEncoderLadder, label: "Main video")
        let sourceWAV = try makeInternalWAV(from: audioFile, in: output.deletingLastPathComponent(), stem: "\(audioFile.stem).mainmp4.source")
        defer { discardTempFile(sourceWAV) }

        return try renderVideoWithEncoderLadder(
            VideoEncodeSpec(
                output: output,
                inputArguments: [
                    "-hide_banner", "-nostdin", "-v", "error", "-y",
                    "-loop", "1",
                    "-framerate", config.videoMP4InputFPS,
                    "-i", imageFile.path,
                    "-i", sourceWAV.path,
                    "-t", ffmpegArg("%.6f", duration)
                ],
                videoFilter:
                    "scale=\(config.videoMP4Width):\(config.videoMP4Height):flags=\(config.videoMP4ScaleFilter)," +
                    "format=\(config.videoMP4PixelFormat)," +
                    colorParameterFilter(),
                encoderLadder: encoders,
                vtQuality: config.videoMP4VTQuality,
                softwarePreset: config.videoMP4SoftwarePreset,
                softwareCRF: config.videoMP4SoftwareCRF,
                tag: config.videoMP4Tag,
                tempStem: "mainmp4",
                label: "MP4"
            ),
            verifying: spec
        )
    }

    func shortenMP4(_ input: URL, audioQCPolicy: AudioQCPolicy?) throws -> URL {
        try preflightMP4Input(input, requireAudio: true, requireAudibleAudio: true)
        try requireFFmpegEncoder(alacEncoderName)
        let shortDuration = try effectiveShortClipSeconds(for: input)
        let output = cli.outDir.appendingPathComponent(shortMP4Stem(forInputStem: input.stem)).appendingPathExtension("mp4")

        let spec = VideoOutputSpec(
            width: config.shortMP4ScaleW,
            height: config.shortMP4ScaleH,
            pixelFormat: config.shortMP4PixelFormat,
            fallbackVerifyCodec: config.shortMP4VerifyCodec,
            audioSampleRate: config.shortMP4AudioSampleRate,
            audioQCPolicy: audioQCPolicy,
            loudnessSource: input,
            durationCheck: { try self.verifyShortMP4Duration($0, source: input) }
        )

        if canReuseOutput(output, verifier: { try self.verifyRenderedVideo(output, spec: spec) }) {
            logger.info("Skip existing short MP4: \(output.basename)")
            return output
        }
        let encoders = try requireAvailableEncoderLadder(config.shortVideoEncoderLadder, label: "Short video")
        let sourceWAV = try makeInternalWAV(from: input, in: cli.outDir, stem: "\(input.stem).shortmp4.source", duration: shortDuration)
        defer { discardTempFile(sourceWAV) }

        return try renderVideoWithEncoderLadder(
            VideoEncodeSpec(
                output: output,
                inputArguments: [
                    "-hide_banner", "-nostdin", "-v", "error", "-y",
                    "-ss", "0",
                    "-t", ffmpegArg("%.6f", shortDuration),
                    "-i", input.path,
                    "-i", sourceWAV.path
                ],
                videoFilter:
                    "crop=min(iw\\,ih*9/16):ih," +
                    "fps=\(config.shortMP4FPS)," +
                    "scale=\(config.shortMP4ScaleW):\(config.shortMP4ScaleH)," +
                    "format=\(config.shortMP4PixelFormat)," +
                    colorParameterFilter(),
                encoderLadder: encoders,
                vtQuality: config.shortMP4VTQuality,
                softwarePreset: config.shortMP4VideoPreset,
                softwareCRF: config.shortMP4VideoCRF,
                tag: nil,
                tempStem: "shortmp4",
                label: "short MP4"
            ),
            verifying: spec
        )
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

        let spec = VideoOutputSpec(
            width: config.shortMP4ScaleW,
            height: config.shortMP4ScaleH,
            pixelFormat: config.shortMP4PixelFormat,
            fallbackVerifyCodec: config.shortMP4VerifyCodec,
            audioSampleRate: config.shortMP4AudioSampleRate,
            audioQCPolicy: audioQCPolicy,
            loudnessSource: audioFile,
            durationCheck: {
                try self.verifyDuration($0, expectedSeconds: shortDuration, label: verificationLabel, tolerance: 0.5)
            }
        )

        if canReuseOutput(output, verifier: { try self.verifyRenderedVideo(output, spec: spec) }) {
            logger.info("Skip existing portrait short MP4: \(output.basename)")
            return output
        }

        let encoders = try requireAvailableEncoderLadder(config.shortVideoEncoderLadder, label: "Short video")
        let sourceWAV = try makeInternalWAV(from: audioFile, in: cli.outDir, stem: "\(audioFile.stem).portraitshort.source", duration: shortDuration)
        defer { discardTempFile(sourceWAV) }

        return try renderVideoWithEncoderLadder(
            VideoEncodeSpec(
                output: output,
                inputArguments: [
                    "-hide_banner", "-nostdin", "-v", "error", "-y",
                    "-loop", "1",
                    "-framerate", config.shortMP4FPS,
                    "-i", imageFile.path,
                    "-i", sourceWAV.path,
                    "-t", ffmpegArg("%.6f", shortDuration)
                ],
                videoFilter:
                    "scale=w=\(config.shortMP4ScaleW):h=\(config.shortMP4ScaleH):force_original_aspect_ratio=decrease," +
                    "pad=\(config.shortMP4ScaleW):\(config.shortMP4ScaleH):(ow-iw)/2:(oh-ih)/2:color=black," +
                    "fps=\(config.shortMP4FPS)," +
                    "format=\(config.shortMP4PixelFormat)," +
                    colorParameterFilter(),
                encoderLadder: encoders,
                vtQuality: config.shortMP4VTQuality,
                softwarePreset: config.shortMP4VideoPreset,
                softwareCRF: config.shortMP4VideoCRF,
                tag: nil,
                tempStem: "portraitshort",
                label: "portrait short MP4"
            ),
            verifying: spec
        )
    }
}
