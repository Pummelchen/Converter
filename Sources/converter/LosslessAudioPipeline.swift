import Foundation

extension ConverterTool {
    func discardTempFile(_ temp: URL) {
        try? fileManager.removeItem(at: temp)
        state.unregister(tempFile: temp)
    }

    func internalWAVArguments(input: URL, output: URL, filter: String? = nil, duration: Double? = nil, writeBext: Bool? = nil) -> [String] {
        var args = [
            "-hide_banner", "-nostdin", "-v", "error", "-y"
        ]
        if let duration {
            args += ["-t", ffmpegArg("%.6f", duration)]
        }
        args += [
            "-i", input.path,
            "-map", "0:a:0"
        ]
        if let filter, !filter.trimmed.isEmpty {
            args += ["-af", filter]
        }
        args += [
            "-vn", "-sn", "-dn",
            "-ac", String(config.wavChannels),
            "-ar", String(config.wavSampleRate),
            "-c:a", config.wavCodec,
            "-f", "wav",
            "-rf64", "always",
            "-write_bext", writeBext == false ? "0" : String(config.wavWriteBext),
            output.path
        ]
        return args
    }

    func makeInternalWAV(
        from source: URL,
        in directory: URL? = nil,
        stem: String? = nil,
        duration: Double? = nil,
        requireAudible: Bool = true
    ) throws -> URL {
        let tempDirectory = directory ?? cli.outDir
        if let sourceDuration = try mediaDuration(source) {
            let clippedDuration = duration.map { min($0, sourceDuration) } ?? sourceDuration
            let need = estimateWAVBytes(duration: clippedDuration, channels: config.wavChannels)
            let free = try availableBytes(at: tempDirectory)
            if need > 0 && free < need {
                throw AppError("Low free space for internal WAV staging of \(source.basename): avail=\(free) need~\(need)")
            }
        }
        let temp = try makeTemp(in: tempDirectory, stem: stem ?? "\(source.stem).internal", ext: ".wav")
        do {
            _ = try runner.run("ffmpeg", internalWAVArguments(input: source, output: temp, duration: duration))
            try verifyWAVStandard(temp, requireAudible: requireAudible, qcPolicy: nil)
            if let duration {
                try verifyDuration(temp, expectedSeconds: duration, label: "internal WAV", tolerance: 0.5)
            } else {
                try verifyDurationMatch(source: source, output: temp)
            }
            return temp
        } catch {
            discardTempFile(temp)
            throw error
        }
    }

    func processInternalWAV(_ sourceWAV: URL, filter: String, in directory: URL? = nil, stem: String? = nil, duration: Double? = nil) throws -> URL {
        try verifyWAVStandard(sourceWAV, qcPolicy: nil)
        let tempDirectory = directory ?? cli.outDir
        let temp = try makeTemp(in: tempDirectory, stem: stem ?? "\(sourceWAV.stem).processed", ext: ".wav")
        do {
            _ = try runner.run("ffmpeg", internalWAVArguments(input: sourceWAV, output: temp, filter: filter, duration: duration))
            try verifyWAVStandard(temp, qcPolicy: nil)
            return temp
        } catch {
            discardTempFile(temp)
            throw error
        }
    }

    func alacAudioArguments(sampleRate: Int, channels: Int) -> [String] {
        [
            "-c:a", "alac",
            "-sample_fmt", config.alacSampleFormat,
            "-bits_per_raw_sample", String(config.alacBitsPerRawSample),
            "-ar", String(sampleRate),
            "-ac", String(channels)
        ]
    }

    func verifyALACAudioOutput(_ file: URL, sampleRate: Int, channels: Int, qcPolicy: AudioQCPolicy? = nil) throws {
        try verifyAudioOutput(
            file,
            codec: "alac",
            sampleRate: sampleRate,
            channels: channels,
            sampleFormat: config.alacSampleFormat,
            bitsPerRawSample: config.alacBitsPerRawSample,
            qcPolicy: qcPolicy
        )
    }

    func encodeInternalWAVToM4A(_ wav: URL, output: URL, qcPolicy: AudioQCPolicy? = nil) throws {
        try verifyWAVStandard(wav, qcPolicy: nil)
        try requireFFmpegEncoder(alacEncoderName)
        _ = try runner.run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-i", wav.path,
            "-map", "0:a:0",
            "-vn", "-sn", "-dn"
        ] + alacAudioArguments(sampleRate: config.m4aSampleRate, channels: config.m4aChannels) + [
            "-map_metadata", "-1",
            output.path
        ])
        try verifyM4AFile(output, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: qcPolicy)
    }

    func encodeInternalWAVToMP3(_ wav: URL, output: URL, requireAudible: Bool = true, qcPolicy: AudioQCPolicy? = nil) throws {
        try verifyWAVStandard(wav, requireAudible: requireAudible, qcPolicy: nil)
        try requireFFmpegEncoder("libmp3lame")
        _ = try runner.run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-i", wav.path,
            "-map", "0:a:0",
            "-vn", "-sn", "-dn",
            "-ar", String(config.mp3SampleRate),
            "-ac", String(config.mp3Channels),
            "-c:a", "libmp3lame",
            "-b:a", config.mp3Bitrate,
            "-map_metadata", "-1",
            output.path
        ])
        try verifyMP3Standard(output, requireAudible: requireAudible, qcPolicy: qcPolicy)
    }

    func encodeInternalWAVToFLAC(
        _ wav: URL,
        output: URL,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        qcPolicy: AudioQCPolicy? = nil
    ) throws {
        try verifyWAVStandard(wav, qcPolicy: nil)
        let outputSampleRate = sampleRate ?? config.flacSampleRate
        let outputChannels = channels ?? config.flacChannels
        _ = try runner.run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-i", wav.path,
            "-map", "0:a:0",
            "-vn", "-sn", "-dn",
            "-ac", String(outputChannels),
            "-ar", String(outputSampleRate),
            "-c:a", "flac",
            "-compression_level", String(config.flacCompressionLevel),
            "-map_metadata", "-1",
            output.path
        ])
        try verifyFLACFile(output, sampleRate: outputSampleRate, channels: outputChannels, qcPolicy: qcPolicy)
    }

    func encodeInternalWAVToWAV(_ wav: URL, output: URL, qcPolicy: AudioQCPolicy? = nil) throws {
        try verifyWAVStandard(wav, qcPolicy: nil)
        _ = try runner.run("ffmpeg", internalWAVArguments(input: wav, output: output))
        try verifyWAVStandard(output, qcPolicy: qcPolicy)
    }

    func encodeInternalWAVToMP4AudioWithVideo(sourceVideo: URL, wav: URL, output: URL, audioSampleRate: Int, qcPolicy: AudioQCPolicy? = nil) throws {
        try verifyWAVStandard(wav, qcPolicy: nil)
        try requireFFmpegEncoder(alacEncoderName)
        _ = try runner.run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-i", sourceVideo.path,
            "-i", wav.path,
            "-map", "0:v:0?",
            "-map", "1:a:0",
            "-c:v", "copy"
        ] + alacAudioArguments(sampleRate: audioSampleRate, channels: 2) + [
            "-sn", "-dn",
            "-map_metadata", "0",
            "-map_chapters", "0",
            "-shortest",
            "-movflags", "+faststart",
            output.path
        ])
        try requireFormatNameContains(output, anyOf: ["mp4", "mov"], label: "MP4 container")
        if try hasVideoStream(sourceVideo) {
            try requireVideoStream(output)
        }
        try verifyALACAudioOutput(output, sampleRate: audioSampleRate, channels: 2, qcPolicy: qcPolicy)
    }

    func encodeProcessedWAV(_ wav: URL, matching source: URL, to output: URL, qcPolicy: AudioQCPolicy? = nil) throws {
        switch output.pathExtension.lowercasedASCII {
        case "flac":
            try encodeInternalWAVToFLAC(wav, output: output, qcPolicy: qcPolicy)
        case "wav":
            try encodeInternalWAVToWAV(wav, output: output, qcPolicy: qcPolicy)
        case "mp3":
            try encodeInternalWAVToMP3(wav, output: output, qcPolicy: qcPolicy)
        case "m4a":
            try encodeInternalWAVToM4A(wav, output: output, qcPolicy: qcPolicy)
        case "mp4":
            try encodeInternalWAVToMP4AudioWithVideo(
                sourceVideo: source,
                wav: wav,
                output: output,
                audioSampleRate: config.videoMP4AudioSampleRate,
                qcPolicy: qcPolicy
            )
        default:
            throw AppError("Unsupported output type for processed WAV: \(output.path)")
        }
    }
}
