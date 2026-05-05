import Foundation

extension ConverterTool {
    func ffmpegEncoderSet() throws -> Set<String> {
        let result = try runner.run("ffmpeg", ["-hide_banner", "-encoders"])
        let lines = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        return Set(lines.flatMap { line in
            line.split(whereSeparator: \.isWhitespace).dropFirst().prefix(1).map(String.init)
        })
    }

    func ffmpegFilterSet() throws -> Set<String> {
        let result = try runner.run("ffmpeg", ["-hide_banner", "-filters"])
        let lines = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        return Set(lines.compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { return nil }
            let flags = String(parts[0])
            let allowedFlags = CharacterSet(charactersIn: ".TSAVN|")
            guard !flags.isEmpty, flags.unicodeScalars.allSatisfy(allowedFlags.contains) else { return nil }
            return String(parts[1])
        })
    }

    @discardableResult
    func requireAvailableEncoderLadder(_ encoders: [String], label: String) throws -> [String] {
        let available = try ffmpegEncoderSet()
        let usable = encoders.filter { available.contains($0) }
        if usable.isEmpty {
            throw AppError("\(label) encoder ladder has no available ffmpeg encoder: \(encoders.joined(separator: ", "))")
        }
        logger.info("\(label) encoders: \(usable.joined(separator: ", "))")
        return usable
    }

    func stepDoctor() throws {
        logger.info("Doctor start")
        try ensureWritableDirectory(cli.outDir)
        if fileManager.fileExists(atPath: cli.srcDir.path) {
            try ensureDirectory(cli.srcDir)
        } else if cli.srcDir.standardizedFileURL != cli.outDir.standardizedFileURL {
            throw AppError("Doctor input directory is missing: \(cli.srcDir.path)")
        }

        for tool in ["awk", "sed", "ffmpeg", "ffprobe", "magick"] {
            try runner.requireExecutable(tool)
            logger.info("Doctor tool ok: \(tool)")
        }

        let filters = try ffmpegFilterSet()
        for filter in ["loudnorm", "astats", "volumedetect", "setparams", "bass"] {
            guard filters.contains(filter) else {
                throw AppError("Doctor missing ffmpeg filter: \(filter)")
            }
            logger.info("Doctor filter ok: \(filter)")
        }

        _ = try requireAvailableEncoderLadder(config.videoEncoderLadder, label: "Doctor main video")
        _ = try requireAvailableEncoderLadder(config.shortVideoEncoderLadder, label: "Doctor short video")
        try requireFFmpegEncoder("aac")
        logger.info("Doctor encoder ok: aac")

        let freeBytes = try availableBytes(at: cli.outDir)
        logger.info("Doctor free space: \(freeBytes) bytes")

        let imageCandidates = try? files(in: cli.srcDir, matchingExtensions: ["png", "jpg", "jpeg"])
        if let image = imageCandidates?.first, imageCandidates?.count == 1 {
            try preflightImageInput(image)
            logger.info("Doctor source image ok: \(image.basename)")
        }

        let audioCandidates = try? files(in: cli.srcDir, matchingExtensions: ["flac", "wav", "mp3", "m4a"])
        if let audio = audioCandidates?.first, audioCandidates?.count == 1 {
            switch audio.pathExtension.lowercasedASCII {
            case "flac":
                try preflightFLACInput(audio)
            case "wav":
                try preflightWAVInput(audio)
            case "mp3":
                try preflightMP3Input(audio)
            case "m4a":
                try preflightM4AInput(audio)
            default:
                break
            }
            logger.info("Doctor source audio ok: \(audio.basename)")
        }

        logger.info("Doctor complete")
    }
}
