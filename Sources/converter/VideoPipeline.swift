import Foundation

extension ConverterTool {
    // The ceiling itself lives on ProjectConfig; configuration validation uses the same constant.
    private var shortMP4AbsoluteMaximumSeconds: Double { ProjectConfig.shortMP4AbsoluteMaximumSeconds }

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

    private func mp4EncoderQualityArguments(
        encoder: String, vtQuality: String, preset: String, crf: String
    ) -> [String] {
        if encoder.lowercasedASCII.contains("videotoolbox") {
            return ["-q:v", vtQuality]
        }
        return ["-preset", preset, "-crf", crf]
    }

    private func mp4RenderTail(spec: VideoOutputSpec, tag: String?, audioStreamCopy: Bool) -> [String] {
        var args = [
            "-pix_fmt", spec.pixelFormat,
            "-color_primaries", config.videoColorPrimaries,
            "-color_trc", config.videoColorTransfer,
            "-colorspace", config.videoColorSpace,
            "-color_range", config.videoColorRange
        ]
        if let tag {
            args += ["-tag:v", tag]
        }
        // An already-standard ALAC source is copied bit-for-bit instead of decoded to a 96 kHz
        // WAV and re-encoded (#0089).
        args +=
            audioStreamCopy
            ? ["-c:a", "copy"]
            : alacAudioArguments(sampleRate: spec.audioSampleRate, channels: 2)
        args += ["-shortest", "-movflags", "+faststart"]
        return args
    }

    // True when the video's audio can be stream-copied from the source instead of round-tripped
    // through the internal WAV. The copy must satisfy the same contract the re-encode would:
    // ALAC in the project's sample format and raw bit depth, at the render's rate and channels.
    func canStreamCopyAudioIntoVideo(_ audioFile: URL, targetSampleRate: Int) throws -> Bool {
        guard ["m4a", "mp4"].contains(audioFile.pathExtension.lowercasedASCII) else { return false }
        guard try audioField(audioFile, "codec_name")?.lowercasedASCII == alacEncoderName else { return false }
        guard try audioField(audioFile, "sample_fmt")?.lowercasedASCII == config.alacSampleFormat else { return false }
        guard Int(try audioField(audioFile, "bits_per_raw_sample") ?? "") == config.alacBitsPerRawSample else {
            return false
        }
        guard let rate = try audioField(audioFile, "sample_rate").flatMap(Int.init), rate == targetSampleRate else {
            return false
        }
        guard let channels = try audioField(audioFile, "channels").flatMap(Int.init), channels == config.m4aChannels
        else {
            return false
        }
        return true
    }

    // Marks a failure that no other encoder could fix (publishing, audio/duration/loudness
    // verification, a padded audio track of the wrong length) so the ladder stops there.
    func encoderIndependent<T>(_ work: () throws -> T) throws -> T {
        do {
            return try work()
        } catch let error as AppError {
            if error.isEncoderIndependent {
                throw error
            }
            throw AppError(error.message, exitCode: error.exitCode, underlying: error, isEncoderIndependent: true)
        } catch {
            throw AppError(error.localizedDescription, underlying: error, isEncoderIndependent: true)
        }
    }

    // The one encoder ladder every MP4 render walks: try each encoder in order, stop early on a
    // failure that is not encoder-related, and report every rung that failed. Reporting only
    // the last one hides the first failure, which is usually the real cause — a later rung may
    // fail for an unrelated reason such as an encoder that cannot handle the dimensions at all.
    func withEncoderLadder<T>(_ encoders: [String], label: String, attempt: (String) throws -> T) throws -> T {
        var failures: [String] = []
        // A failure that no other encoder can fix stops the ladder; the marker has to survive into the
        // thrown error, or the caller reports "all encoders failed" and blames the wrong layer (#0134).
        var encoderIndependentFailure: (any Error)?
        for encoder in encoders {
            do {
                return try attempt(encoder)
            } catch {
                failures.append("\(encoder): \(error.localizedDescription)")
                logger.warn("\(label) encoder failed (\(encoder)): \(error.localizedDescription)")
                if (error as? AppError)?.isEncoderIndependent == true {
                    logger.warn("\(label): skipping remaining encoders — this failure is not encoder-related.")
                    encoderIndependentFailure = error
                    break
                }
            }
        }
        let detail = failures.isEmpty ? "unknown error" : failures.joined(separator: " | ")
        // The summary names every rung (callers and tests depend on that); the marker travels with it
        // so a caller does not retry work no encoder can fix (#0134).
        throw AppError(
            "All \(label) encoders failed. \(detail)",
            isEncoderIndependent: encoderIndependentFailure != nil)
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
        // When true the audio input is already the deliverable's ALAC stream and is copied.
        let audioStreamCopy: Bool
    }

    // What a finished render must satisfy: geometry and codec from the spec, then the checks that
    // do not depend on the video encoder. verifyVideoRender used to take all fourteen of these as
    // separate parameters on top of this wrapper (#0073).
    private func verifyRenderedVideo(_ url: URL, spec: VideoOutputSpec, codec: String? = nil) throws {
        try verifyVideoOutput(
            url,
            width: spec.width,
            height: spec.height,
            codec: codec ?? spec.fallbackVerifyCodec,
            pixelFormat: spec.pixelFormat,
            colorPrimaries: config.videoColorPrimaries,
            colorTransfer: config.videoColorTransfer,
            colorSpace: config.videoColorSpace,
            colorRange: config.videoColorRange
        )
        // The audio track, the duration and the loudness do not depend on the video encoder:
        // a failure here must stop the ladder instead of re-rendering on every rung.
        try encoderIndependent {
            try verifyALACAudioOutput(
                url, sampleRate: spec.audioSampleRate, channels: 2, qcPolicy: spec.audioQCPolicy
            )
            try spec.durationCheck(url)
            try verifySourceLoudnessPreserved(source: spec.loudnessSource, output: url, toleranceDB: 1.0)
        }
    }

    // Walks the encoder ladder, verifying before publishing and falling through to the
    // next encoder on failure. All three render paths share this, so a fix here cannot
    // reach only two of them.
    private func renderVideoWithEncoderLadder(
        _ encode: VideoEncodeSpec, verifying spec: VideoOutputSpec
    ) throws -> URL {
        try withEncoderLadder(encode.encoderLadder, label: encode.label) { encoder in
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
                arguments += mp4RenderTail(spec: spec, tag: encode.tag, audioStreamCopy: encode.audioStreamCopy)
                _ = try runner.run("ffmpeg", arguments + [temp.path])
                try verifyRenderedVideo(temp, spec: spec, codec: verifyCodec(forEncoder: encoder))
                try encoderIndependent { try publishTemp(temp, to: encode.output) }
                logger.info("Created \(encode.label): \(encode.output.basename) [encoder=\(encoder)]")
                return encode.output
            } catch {
                discardTempFile(temp)
                throw error
            }
        }
    }

    // How the still image is mapped onto the portrait frame.
    enum ShortFillMode: Sendable {
        /// Fit the whole image inside the frame, padding the remainder with black.
        case fit
        /// Scale until the frame is covered, then trim the overflow from the centre, so the
        /// middle of the artwork fills the frame edge to edge with no padding.
        case centerCut

        var outputStemSuffix: String {
            switch self {
            case .fit: return ""
            case .centerCut: return "_CenterCut"
            }
        }

        var tempStem: String {
            switch self {
            case .fit: return "portraitshort"
            case .centerCut: return "portraitshortcentercut"
            }
        }

        var label: String {
            switch self {
            case .fit: return "portrait short MP4"
            case .centerCut: return "portrait short MP4 (centre cut)"
            }
        }
    }

    private func shortVideoFilter(mode: ShortFillMode) -> String {
        let width = config.shortMP4ScaleW
        let height = config.shortMP4ScaleH
        let framing: String
        switch mode {
        case .fit:
            // A portrait source smaller than the frame is upscaled here, so it needs the
            // configured high-quality scaler rather than ffmpeg's default.
            framing =
                "scale=w=\(width):h=\(height):force_original_aspect_ratio=decrease:flags=\(scaleQualityFlags),"
                + "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2:color=black"
        case .centerCut:
            // `increase` guarantees both axes reach the target, so the centred crop never
            // runs short and no padding is ever introduced. A centre cut usually upscales
            // (a 7680x4320 master contributes only its middle 2430x4320), so it uses the
            // configured high-quality scaler rather than the default.
            framing =
                "scale=w=\(width):h=\(height):force_original_aspect_ratio=increase:flags=\(scaleQualityFlags),"
                + "crop=\(width):\(height)"
        }
        return framing + ",fps=\(config.shortMP4FPS),format=\(config.shortMP4PixelFormat)," + colorParameterFilter()
    }

    func centerCutShortMP4Stem(_ stem: String) -> String {
        stem.hasSuffix(ShortFillMode.centerCut.outputStemSuffix)
            ? stem : stem + ShortFillMode.centerCut.outputStemSuffix
    }

    // Scaling quality flags for swscale: accurate rounding and full chroma interpolation
    // cost time and buy precision, which is the trade this pipeline wants.
    private var scaleQualityFlags: String {
        "\(config.videoMP4ScaleFilter)+accurate_rnd+full_chroma_int"
    }

    private func colorParameterFilter() -> String {
        "setparams=color_primaries=\(config.videoColorPrimaries):color_trc=\(config.videoColorTransfer):colorspace=\(config.videoColorSpace):range=\(ffmpegFilterRangeValue(config.videoColorRange))"
    }

    func shortMP4Stem(forInputStem stem: String) -> String {
        stem.hasSuffix("_Short") ? stem : "\(stem)_Short"
    }

    // -mp4toshort derives <stem>_Short plus the _CenterCut and _FullSong framings, so every
    // deliverable carries the "_Short" marker. Testing only for a trailing "_Short" re-ingested
    // the companions and produced a fresh nested deliverable on every rerun.
    func isShortMP4Deliverable(_ file: URL) -> Bool {
        file.stem.contains("_Short")
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

    // A source within this much of the cap counts as being at the cap, so a 58.005 s song does not
    // produce a full-song companion only milliseconds longer than the short (#0072).
    static let shortCompanionEpsilonSeconds = 0.01

    // True when the source runs past the capped short, so the full-length companion is rendered.
    func needsFullSongCompanion(forDuration inputDuration: Double) throws -> Bool {
        let shortDuration = try effectiveShortClipSeconds(forDuration: inputDuration)
        return inputDuration > shortDuration + Self.shortCompanionEpsilonSeconds
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

    // `outputOverride` is the resolved --output-file of a single-output action (-m4atomp4);
    // the full and album runs never pass one, so their main MP4 always keeps <stem>_8K.mp4.
    func renderM4AToMP4(
        imageFile: URL, audioFile: URL, audioQCPolicy: AudioQCPolicy?, outputOverride: URL? = nil
    ) throws -> URL {
        try preflightPNGInput(imageFile)
        try preflightM4AInput(audioFile)
        guard let dimensions = try imageDimensions(imageFile) else {
            throw AppError("Unable to read dimensions: \(imageFile.path)")
        }
        if dimensions.0 != config.videoMP4Width || dimensions.1 != config.videoMP4Height {
            throw AppError(
                "Image must be \(config.videoMP4Width)x\(config.videoMP4Height). Got '\(dimensions.0)x\(dimensions.1)' for '\(imageFile.path)'."
            )
        }
        guard let duration = try mediaDuration(audioFile) else {
            throw AppError("Unable to read numeric audio duration from: \(audioFile.path)")
        }
        let output = try outputOverride ?? resolveOutputPath("\(audioFile.stem)_8K.mp4")

        let spec = VideoOutputSpec(
            width: config.videoMP4Width,
            height: config.videoMP4Height,
            pixelFormat: config.videoMP4PixelFormat,
            fallbackVerifyCodec: config.videoMP4VerifyCodec,
            audioSampleRate: config.videoMP4AudioSampleRate,
            audioQCPolicy: try audioQCPolicy.map {
                try loudnessPreservingQCPolicy($0, source: audioFile, sampleRate: config.videoMP4AudioSampleRate)
            },
            loudnessSource: audioFile,
            durationCheck: { try self.verifyDurationMatch(source: audioFile, output: $0) }
        )

        if canReuseOutput(output, source: audioFile, verifier: { try self.verifyRenderedVideo(output, spec: spec) }) {
            logger.info("Skip existing MP4: \(output.basename)")
            return output
        }
        let encoders = try requireAvailableEncoderLadder(config.videoEncoderLadder, label: "Main video")
        let streamCopy = try canStreamCopyAudioIntoVideo(audioFile, targetSampleRate: config.videoMP4AudioSampleRate)
        if !streamCopy {
            try requireFFmpegEncoder(alacEncoderName)
        }
        let sourceWAV =
            streamCopy
            ? nil
            : try makeInternalWAV(
                from: audioFile, in: output.deletingLastPathComponent(), stem: "\(audioFile.stem).mainmp4.source")
        defer { sourceWAV.map(discardTempFile) }

        return try renderVideoWithEncoderLadder(
            VideoEncodeSpec(
                output: output,
                inputArguments: [
                    "-hide_banner", "-nostdin", "-v", "error", "-y",
                    "-loop", "1",
                    "-framerate", config.videoMP4InputFPS,
                    "-i", imageFile.path,
                    "-i", (sourceWAV ?? audioFile).path,
                    "-t", ffmpegArg("%.6f", duration)
                ],
                videoFilter:
                    "scale=\(config.videoMP4Width):\(config.videoMP4Height):flags=\(scaleQualityFlags),"
                    + "format=\(config.videoMP4PixelFormat)," + colorParameterFilter(),
                encoderLadder: encoders,
                vtQuality: config.videoMP4VTQuality,
                softwarePreset: config.videoMP4SoftwarePreset,
                softwareCRF: config.videoMP4SoftwareCRF,
                tag: config.videoMP4Tag,
                tempStem: "mainmp4",
                label: "MP4",
                audioStreamCopy: streamCopy
            ),
            verifying: spec
        )
    }

    // Every short — landscape crop, portrait fit, centre cut, full-song — delivers audio at
    // the short MP4 rate, so its source is judged in that domain (#0015).
    private func shortRenderQCPolicy(
        _ policy: AudioQCPolicy, source: URL, limitDuration: Double
    ) throws -> AudioQCPolicy {
        try loudnessPreservingQCPolicy(
            policy, source: source, limitDuration: limitDuration, sampleRate: config.shortMP4AudioSampleRate
        )
    }

    func shortenMP4(_ input: URL, audioQCPolicy: AudioQCPolicy?) throws -> URL {
        try preflightMP4Input(input, requireAudio: true, requireAudibleAudio: true)
        let shortDuration = try effectiveShortClipSeconds(for: input)
        let output = cli.outDir.appendingPathComponent(shortMP4Stem(forInputStem: input.stem)).appendingPathExtension(
            "mp4")

        let spec = VideoOutputSpec(
            width: config.shortMP4ScaleW,
            height: config.shortMP4ScaleH,
            pixelFormat: config.shortMP4PixelFormat,
            fallbackVerifyCodec: config.shortMP4VerifyCodec,
            audioSampleRate: config.shortMP4AudioSampleRate,
            audioQCPolicy: try audioQCPolicy.map {
                try shortRenderQCPolicy($0, source: input, limitDuration: shortDuration)
            },
            loudnessSource: input,
            durationCheck: { try self.verifyShortMP4Duration($0, source: input) }
        )

        if canReuseOutput(output, source: input, verifier: { try self.verifyRenderedVideo(output, spec: spec) }) {
            logger.info("Skip existing short MP4: \(output.basename)")
            return output
        }
        let encoders = try requireAvailableEncoderLadder(config.shortVideoEncoderLadder, label: "Short video")
        let streamCopy = try canStreamCopyAudioIntoVideo(input, targetSampleRate: config.shortMP4AudioSampleRate)
        if !streamCopy {
            try requireFFmpegEncoder(alacEncoderName)
        }
        let sourceWAV =
            streamCopy
            ? nil
            : try makeInternalWAV(
                from: input, in: cli.outDir, stem: "\(input.stem).shortmp4.source", duration: shortDuration)
        defer { sourceWAV.map(discardTempFile) }

        return try renderVideoWithEncoderLadder(
            VideoEncodeSpec(
                output: output,
                inputArguments: [
                    "-hide_banner", "-nostdin", "-v", "error", "-y",
                    "-ss", "0",
                    "-t", ffmpegArg("%.6f", shortDuration),
                    "-i", input.path,
                    "-i", (sourceWAV ?? input).path
                ],
                videoFilter: mp4ToShortVideoFilter(),
                encoderLadder: encoders,
                vtQuality: config.shortMP4VTQuality,
                softwarePreset: config.shortMP4VideoPreset,
                softwareCRF: config.shortMP4VideoCRF,
                tag: nil,
                tempStem: "shortmp4",
                label: "short MP4",
                audioStreamCopy: streamCopy
            ),
            verifying: spec
        )
    }

    // -mp4toshort crops a landscape source to 9:16 and upscales it to the portrait frame, so it
    // needs the same configured scaler as the other short paths instead of ffmpeg's default.
    func mp4ToShortVideoFilter() -> String {
        "crop=min(iw\\,ih*9/16):ih," + "fps=\(config.shortMP4FPS),"
            + "scale=\(config.shortMP4ScaleW):\(config.shortMP4ScaleH):flags=\(scaleQualityFlags),"
            + "format=\(config.shortMP4PixelFormat)," + colorParameterFilter()
    }

    func preflightShortAudioInput(_ file: URL) throws {
        try preflightAudioInput(file, requireNoVideo: true)
    }

    func renderAudioToShortMP4(
        imageFile: URL,
        audioFile: URL,
        audioQCPolicy: AudioQCPolicy?,
        outputStem: String? = nil,
        skipLengthCap: Bool = false,
        fillMode: ShortFillMode = .fit
    ) throws -> URL {
        try preflightImageInput(imageFile)
        try preflightShortAudioInput(audioFile)

        guard let dimensions = try imageDimensions(imageFile) else {
            throw AppError("Unable to read dimensions: \(imageFile.path)")
        }
        if dimensions.0 <= 0 || dimensions.1 <= 0 {
            throw AppError(
                "Short image dimensions must be positive. Got '\(dimensions.0)x\(dimensions.1)' for '\(imageFile.path)'."
            )
        }
        guard let audioDuration = try mediaDuration(audioFile) else {
            throw AppError("Unable to read numeric audio duration from: \(audioFile.path)")
        }
        let shortDuration = skipLengthCap ? audioDuration : try effectiveShortClipSeconds(forDuration: audioDuration)
        let verificationLabel = skipLengthCap ? "full-song \(fillMode.label) output" : "\(fillMode.label) output"
        let output = cli.outDir
            .appendingPathComponent(outputStem ?? portraitShortMP4Stem(forAudioStem: audioFile.stem))
            .appendingPathExtension("mp4")

        let spec = VideoOutputSpec(
            width: config.shortMP4ScaleW,
            height: config.shortMP4ScaleH,
            pixelFormat: config.shortMP4PixelFormat,
            fallbackVerifyCodec: config.shortMP4VerifyCodec,
            audioSampleRate: config.shortMP4AudioSampleRate,
            audioQCPolicy: try audioQCPolicy.map {
                try shortRenderQCPolicy($0, source: audioFile, limitDuration: shortDuration)
            },
            loudnessSource: audioFile,
            durationCheck: {
                try self.verifyDuration($0, expectedSeconds: shortDuration, label: verificationLabel, tolerance: 0.5)
            }
        )

        if canReuseOutput(output, source: audioFile, verifier: { try self.verifyRenderedVideo(output, spec: spec) }) {
            logger.info("Skip existing \(fillMode.label): \(output.basename)")
            return output
        }

        let encoders = try requireAvailableEncoderLadder(config.shortVideoEncoderLadder, label: "Short video")
        let streamCopy = try canStreamCopyAudioIntoVideo(audioFile, targetSampleRate: config.shortMP4AudioSampleRate)
        if !streamCopy {
            try requireFFmpegEncoder(alacEncoderName)
        }
        let sourceWAV =
            streamCopy
            ? nil
            : try makeInternalWAV(
                from: audioFile, in: cli.outDir, stem: "\(audioFile.stem).portraitshort.source", duration: shortDuration
            )
        defer { sourceWAV.map(discardTempFile) }

        return try renderVideoWithEncoderLadder(
            VideoEncodeSpec(
                output: output,
                inputArguments: [
                    "-hide_banner", "-nostdin", "-v", "error", "-y",
                    "-loop", "1",
                    "-framerate", config.shortMP4FPS,
                    "-i", imageFile.path,
                    "-i", (sourceWAV ?? audioFile).path,
                    "-t", ffmpegArg("%.6f", shortDuration)
                ],
                videoFilter: shortVideoFilter(mode: fillMode),
                encoderLadder: encoders,
                vtQuality: config.shortMP4VTQuality,
                softwarePreset: config.shortMP4VideoPreset,
                softwareCRF: config.shortMP4VideoCRF,
                tag: nil,
                tempStem: fillMode.tempStem,
                label: fillMode.label,
                audioStreamCopy: streamCopy
            ),
            verifying: spec
        )
    }
}
