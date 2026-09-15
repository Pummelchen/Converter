import Foundation

extension ConverterTool {
    // Every magick resize goes through this. Resampling is done in linear light rather than
    // gamma-encoded sRGB, because averaging gamma-encoded values darkens edges and loses
    // energy wherever contrast is high. Measured on a 4x upscale of a detail-heavy reference,
    // LanczosSharp in linear light reconstructs the original more accurately than the
    // gamma-space Lanczos used before (PSNR 30.663 vs 30.616, RMSE 0.02930 vs 0.02946), and
    // beats Mitchell, Catrom, Lanczos2 and both EWA variants. The extra colourspace
    // conversions cost a little time, which is the intended trade.
    func resampleArguments(_ geometry: String) -> [String] {
        [
            "-colorspace", "RGB",
            "-filter", config.imageAIPixFilter,
            "-resize", geometry,
            "-colorspace", config.imageOutputColorSpace
        ]
    }

    private func aipixResizeArguments(
        source: URL,
        resizeHeight: Int,
        width: Int,
        height: Int,
        sharpness: Double,
        compressionLevel: Int
    ) -> [String] {
        var args = [
            source.path,
            "-auto-orient"
        ]
        args += resampleArguments("x\(resizeHeight)")
        args += [
            "-gravity", "center",
            "-background", "black",
            "-extent", "\(width)x\(height)"
        ]
        let sharpSigma = max(0.0, (sharpness - 1.0) * 2.0)
        if sharpSigma > 0 {
            args += ["-sharpen", ffmpegArg("0x%.3f", sharpSigma)]
        }
        args += ["-define", "png:compression-level=\(compressionLevel)", "-strip"]
        return args
    }

    // The `-jpgtopng` action: here the PNG is the requested deliverable, so it is published under
    // the source stem. Everything the full/short pipelines need is `convertJPGToPNGTemp` instead.
    func convertJPGToPNG(_ source: URL) throws -> URL {
        try preflightJPEGInput(source)
        guard let dimensions = try imageDimensions(source) else {
            throw AppError("Unable to read dimensions: \(source.path)")
        }
        let output = cli.outDir.appendingPathComponent(source.stem).appendingPathExtension("png")
        try requireDistinctOutput(output, from: source)
        if canReuseOutput(
            output, source: source,
            verifier: { try verifyImageOutput(output, width: dimensions.0, height: dimensions.1, format: "PNG") })
        {
            logger.info("Skip existing PNG: \(output.basename)")
            return output
        }
        let temp = try convertJPGToPNGTemp(source)
        do {
            try publishTemp(temp, to: output)
            logger.info("Created PNG: \(output.basename)")
            return output
        } catch {
            discardTempFile(temp)
            throw error
        }
    }

    // The JPG->PNG step produces a lossless working copy for the PNG pipeline, not a deliverable.
    // It is written to a run-scoped temp so OUT_DIR does not collect an unrequested `<master>.png`
    // that a later batch action would discover as a source (#0147). The run's temp cleanup removes
    // it, including on the error path.
    func convertJPGToPNGTemp(_ source: URL) throws -> URL {
        try preflightJPEGInput(source)
        guard let dimensions = try imageDimensions(source) else {
            throw AppError("Unable to read dimensions: \(source.path)")
        }
        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".png")
        do {
            _ = try runner.run(
                "magick",
                [
                    source.path,
                    "-auto-orient",
                    "-colorspace", config.imageOutputColorSpace,
                    "-define", "png:compression-level=\(config.imageJPGToPNGCompressionLevel)",
                    "-strip",
                    temp.path
                ])
            try verifyImageOutput(temp, width: dimensions.0, height: dimensions.1, format: "PNG")
            return temp
        } catch {
            discardTempFile(temp)
            throw error
        }
    }

    // Convert a PNG source into a baseline high-quality JPEG using the requested extension.
    func convertPNGToJPEG(_ source: URL, outputExtension: String) throws -> URL {
        try preflightPNGInput(source)
        guard source.pathExtension.lowercasedASCII == "png" else {
            throw AppError("PNG -> JPEG conversion requires a .png input: \(source.path)")
        }
        let normalizedExt = outputExtension.lowercasedASCII
        guard normalizedExt == "jpg" || normalizedExt == "jpeg" else {
            throw AppError("PNG -> JPEG conversion requires .jpg or .jpeg output (got '\(outputExtension)')")
        }
        guard let dimensions = try imageDimensions(source) else {
            throw AppError("Unable to read dimensions: \(source.path)")
        }

        let output = cli.outDir.appendingPathComponent(source.stem).appendingPathExtension(normalizedExt)
        try requireDistinctOutput(output, from: source)
        if canReuseOutput(
            output,
            verifier: {
                try verifyImageOutput(output, width: dimensions.0, height: dimensions.1, format: "JPEG")
            })
        {
            logger.info("Skip existing \(normalizedExt.uppercased()) image: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".\(normalizedExt)")
        do {
            _ = try runner.run(
                "magick",
                [
                    source.path,
                    "-auto-orient",
                    "-colorspace", config.imageOutputColorSpace,
                    // Alpha has no place in JPEG: without an explicit flatten the transparent areas take
                    // ImageMagick's implicit background while ffmpeg's yuv420p conversion uses the stored
                    // RGB, so the still and the video frame disagree (#0146).
                    "-background", "black",
                    "-alpha", "remove",
                    "-alpha", "off",
                    "-sampling-factor", config.imageJpegSamplingFactor,
                    "-quality", String(config.imagePNGToJPEGQuality),
                    "-strip",
                    temp.path
                ])
            try verifyImageOutput(temp, width: dimensions.0, height: dimensions.1, format: "JPEG")
            try publishTemp(temp, to: output)
            logger.info("Created \(normalizedExt.uppercased()) image: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    // One delivery size of the AIPIX pair. Returns the published path, or the existing file when the
    // reuse verifier accepts it.
    private func aiPixTargetOutput(
        source: URL, dimensions: (Int, Int), target: AIPixTarget, prefix: String
    ) throws -> URL {
        let label = target.label
        let width = target.width
        let height = target.height
        let output = cli.outDir.appendingPathComponent("\(prefix)_\(label)").appendingPathExtension("png")
        // A source already named `<prefix>_8K`/`_4K` would otherwise resolve to its own path here
        // and be resized over itself (the audio converters have the same guard).
        try requireDistinctOutput(output, from: source)
        if canReuseOutput(
            output, source: source,
            verifier: { try verifyImageOutput(output, width: width, height: height, format: "PNG") })
        {
            logger.info("Skip existing \(label) PNG: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: cli.outDir, stem: "\(prefix)_\(label)", ext: ".png")
        do {
            if dimensions.0 == width && dimensions.1 == height {
                _ = try runner.run(
                    "magick",
                    [
                        source.path,
                        "-auto-orient",
                        "-colorspace", config.imageOutputColorSpace,
                        "-define", "png:compression-level=\(config.imageAIPixPNGCompressionLevel)",
                        "-strip",
                        temp.path
                    ])
            } else {
                let finalArgs =
                    aipixResizeArguments(
                        source: source,
                        resizeHeight: height,
                        width: width,
                        height: height,
                        sharpness: config.imageAIPixSharpness,
                        compressionLevel: config.imageAIPixPNGCompressionLevel
                    ) + [temp.path]
                _ = try runner.run("magick", finalArgs)
            }
            try verifyImageOutput(temp, width: width, height: height, format: "PNG")
            try publishTemp(temp, to: output)
            logger.info("Created \(label) PNG: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    // `deliveryPrefix` names outputs after the release rather than after the image file, so a
    // full run's deliverables all share the audio stem. Image-only actions leave it nil and
    // keep deriving names from their own source.
    func aipixFile(_ source: URL, deliveryPrefix: String? = nil) throws -> AIPixOutputs {
        try preflightPNGInput(source)
        guard let dimensions = try imageDimensions(source) else {
            throw AppError("Unable to read dimensions: \(source.path)")
        }

        let prefix = deliveryPrefix ?? imagePrefix(from: source.stem)
        let targets = [
            AIPixTarget(label: "8K", width: config.image8KWidth, height: config.image8KHeight),
            AIPixTarget(label: "4K", width: config.image4KWidth, height: config.image4KHeight)
        ]

        var outputs: [String: URL] = [:]
        for target in targets {
            outputs[target.label] = try aiPixTargetOutput(
                source: source, dimensions: dimensions, target: target, prefix: prefix
            )
        }

        guard let eightK = outputs["8K"], let fourK = outputs["4K"] else {
            throw AppError("AIPIX did not produce required outputs")
        }
        return AIPixOutputs(eightK: eightK, fourK: fourK)
    }

    func squarePNGFrom8K(_ source: URL, size: Int, label: String, deliveryPrefix: String? = nil) throws -> URL {
        try preflightPNGInput(source)
        let outputName =
            deliveryPrefix.map { "\($0)_\(label)" }
            ?? replacingTrailingSuffix(in: source.stem, suffix: "_8K", replacement: "_\(label)")
        let output = cli.outDir.appendingPathComponent(outputName).appendingPathExtension("png")
        try requireDistinctOutput(output, from: source)
        if canReuseOutput(
            output, source: source,
            verifier: { try verifyImageOutput(output, width: size, height: size, format: "PNG") })
        {
            logger.info("Skip existing \(label) PNG: \(output.basename)")
            return output
        }
        let temp = try makeTemp(in: cli.outDir, stem: outputName, ext: ".png")
        do {
            _ = try runner.run(
                "magick",
                [
                    source.path,
                    "-auto-orient"
                ] + resampleArguments("\(size)x\(size)^") + [
                    "-gravity", "center",
                    "-extent", "\(size)x\(size)",
                    "-strip",
                    temp.path
                ])
            try verifyImageOutput(temp, width: size, height: size, format: "PNG")
            try publishTemp(temp, to: output)
            logger.info("Created \(label) PNG: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func fourKPNGFrom8K(_ source: URL, deliveryPrefix: String? = nil) throws -> URL {
        try preflightPNGInput(source)
        guard let dimensions = try imageDimensions(source) else {
            throw AppError("Unable to read dimensions: \(source.path)")
        }
        if dimensions.0 != config.image8KWidth || dimensions.1 != config.image8KHeight {
            throw AppError(
                "Skipping \(source.basename): expected \(config.image8KWidth)x\(config.image8KHeight), got \(dimensions.0)x\(dimensions.1)"
            )
        }

        let outputName =
            deliveryPrefix.map { "\($0)_4K" }
            ?? replacingTrailingSuffix(in: source.stem, suffix: "_8K", replacement: "_4K")
        let output = cli.outDir.appendingPathComponent(outputName).appendingPathExtension("png")
        try requireDistinctOutput(output, from: source)
        if canReuseOutput(
            output, source: source,
            verifier: {
                try verifyImageOutput(output, width: config.image4KWidth, height: config.image4KHeight, format: "PNG")
            })
        {
            logger.info("Skip existing 4K PNG: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: cli.outDir, stem: outputName, ext: ".png")
        do {
            let finalArgs =
                aipixResizeArguments(
                    source: source,
                    resizeHeight: config.image4KHeight,
                    width: config.image4KWidth,
                    height: config.image4KHeight,
                    sharpness: config.imageAIPixSharpness,
                    compressionLevel: config.imageAIPixPNGCompressionLevel
                ) + [temp.path]
            _ = try runner.run("magick", finalArgs)
            try verifyImageOutput(temp, width: config.image4KWidth, height: config.image4KHeight, format: "PNG")
            try publishTemp(temp, to: output)
            logger.info("Created 4K PNG: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func jpegExtentFromPNG(
        _ source: URL, requiredWidth: Int, requiredHeight: Int, suffix: String, targetBytes: Int,
        outputStem: String? = nil
    ) throws -> URL {
        try preflightPNGInput(source)
        guard let dimensions = try imageDimensions(source) else {
            throw AppError("Unable to read dimensions: \(source.path)")
        }
        if dimensions.0 != requiredWidth || dimensions.1 != requiredHeight {
            throw AppError(
                "Skipping \(source.basename): expected \(requiredWidth)x\(requiredHeight), got \(dimensions.0)x\(dimensions.1)"
            )
        }

        let output = cli.outDir.appendingPathComponent(
            outputStem.map { "\($0)_\(suffix)" } ?? "\(source.stem)_\(suffix)"
        ).appendingPathExtension("jpg")
        try requireDistinctOutput(output, from: source)
        if canReuseOutput(
            output, source: source,
            verifier: {
                try verifyImageOutput(
                    output, width: requiredWidth, height: requiredHeight, format: "JPEG", maxBytes: targetBytes)
            })
        {
            logger.info("Skip existing \(suffix) JPG: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: cli.outDir, stem: "\(source.stem).\(suffix)", ext: ".jpg")
        do {
            _ = try runner.run(
                "magick",
                [
                    source.path,
                    "-auto-orient",
                    "-colorspace", config.imageOutputColorSpace,
                    // See convertPNGToJPEG: flatten explicitly so every JPEG agrees about transparency (#0146).
                    "-background", "black",
                    "-alpha", "remove",
                    "-alpha", "off",
                    "-sampling-factor", config.imageJpegSamplingFactor,
                    "-strip",
                    "-define", "jpeg:extent=\(targetBytes)",
                    temp.path
                ])
            try verifyImageOutput(
                temp, width: requiredWidth, height: requiredHeight, format: "JPEG", maxBytes: targetBytes)
            try publishTemp(temp, to: output)
            logger.info("Created \(suffix) JPG: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    // Still frames matching exactly what each portrait short shows, so the framing can be
    // reviewed or reused as artwork without pulling a frame out of the video. The geometry
    // mirrors the render filters: `.fit` resizes inside the frame and pads with black,
    // `.centerCut` covers the frame (`^`) and trims the overflow from the centre.
    // Only raw artwork is sharpened here. The fitted source is often an already-processed master
    // (the generated NFT8K) or a user-supplied Vertical_8K.png that the help promises to use
    // as-is, and sharpening either one is a second pass over pixels that were already treated.
    func portraitShortStillsArguments(from source: URL, mode: ShortFillMode, sharpenSource: Bool) -> [String] {
        let width = config.shortMP4ScaleW
        let height = config.shortMP4ScaleH
        var arguments = [source.path, "-auto-orient"]
        switch mode {
        case .fit:
            arguments += resampleArguments("\(width)x\(height)") + ["-background", "black"]
            let sharpSigma = sharpenSource ? max(0.0, (config.imageAIPixSharpness - 1.0) * 2.0) : 0
            if sharpSigma > 0 {
                arguments += ["-sharpen", ffmpegArg("0x%.3f", sharpSigma)]
            }
        case .centerCut:
            arguments += resampleArguments("\(width)x\(height)^")
        }
        arguments += [
            "-gravity", "center",
            "-extent", "\(width)x\(height)",
            "-define", "png:compression-level=\(config.imageAIPixPNGCompressionLevel)",
            "-strip"
        ]
        return arguments
    }

    struct PortraitShortStills: Sendable {
        let png: URL
        let jpg1MB: URL
        let jpg2MB: URL
        var all: [URL] { [png, jpg1MB, jpg2MB] }
    }

    @discardableResult
    func portraitShortStills(
        from source: URL, mode: ShortFillMode, prefix: String, sharpenSource: Bool
    ) throws -> PortraitShortStills {
        try preflightPNGInput(source)
        let width = config.shortMP4ScaleW
        let height = config.shortMP4ScaleH
        // Labelled by framing, then the standard 8K image suffixes, so the stills sit beside
        // the other 8K deliverables: <prefix>_Short_8K.png / <prefix>_Short_CenterCut_8K.png.
        let label = mode == .centerCut ? "Short_CenterCut" : "Short"
        let stem = "\(prefix)_\(label)_8K"

        let png = cli.outDir.appendingPathComponent(stem).appendingPathExtension("png")
        try requireDistinctOutput(png, from: source)
        if canReuseOutput(
            png, source: source, verifier: { try verifyImageOutput(png, width: width, height: height, format: "PNG") })
        {
            logger.info("Skip existing portrait still: \(png.basename)")
        } else {
            let temp = try makeTemp(in: cli.outDir, stem: stem, ext: ".png")
            do {
                let arguments =
                    portraitShortStillsArguments(from: source, mode: mode, sharpenSource: sharpenSource)
                    + [temp.path]
                _ = try runner.run("magick", arguments)
                try verifyImageOutput(temp, width: width, height: height, format: "PNG")
                try publishTemp(temp, to: png)
                logger.info("Created portrait still: \(png.basename)")
            } catch {
                discardTempFile(temp)
                throw error
            }
        }

        let oneMB = try jpegExtentFromPNG(
            png, requiredWidth: width, requiredHeight: height, suffix: "1MB",
            targetBytes: config.image8KJPG1MBTargetBytes)
        let twoMB = try jpegExtentFromPNG(
            png, requiredWidth: width, requiredHeight: height, suffix: "2MB",
            targetBytes: config.image8KJPG2MBTargetBytes)
        return PortraitShortStills(png: png, jpg1MB: oneMB, jpg2MB: twoMB)
    }

    func nftFrom8K(_ source: URL, deliveryPrefix: String? = nil) throws -> NFTOutputs {
        try preflightPNGInput(source)
        guard let dimensions = try imageDimensions(source) else {
            throw AppError("Unable to read dimensions: \(source.path)")
        }
        if dimensions.0 != config.image8KWidth || dimensions.1 != config.image8KHeight {
            throw AppError(
                "Skipping \(source.basename): expected \(config.image8KWidth)x\(config.image8KHeight), got \(dimensions.0)x\(dimensions.1)"
            )
        }

        let prefix =
            deliveryPrefix
            ?? imagePrefix(from: replacingTrailingSuffix(in: source.stem, suffix: "_8K", replacement: ""))

        let nft8K = cli.outDir.appendingPathComponent("\(prefix)_NFT8K").appendingPathExtension("png")
        let nft3K = cli.outDir.appendingPathComponent("\(prefix)_NFT3K").appendingPathExtension("png")
        let nft2K = cli.outDir.appendingPathComponent("\(prefix)_NFT2K").appendingPathExtension("png")
        for output in [nft8K, nft3K, nft2K] {
            try requireDistinctOutput(output, from: source)
        }

        if canReuseOutput(
            nft8K, source: source,
            verifier: {
                try verifyImageOutput(nft8K, width: config.image8KWidth, height: config.image8KWidth, format: "PNG")
            })
            && canReuseOutput(
                nft3K, source: source,
                verifier: {
                    try verifyImageOutput(nft3K, width: config.image3KSize, height: config.image3KSize, format: "PNG")
                })
            && canReuseOutput(
                nft2K, source: source,
                verifier: {
                    try verifyImageOutput(nft2K, width: config.image2KSize, height: config.image2KSize, format: "PNG")
                })
        {
            logger.info("Skip existing NFT set: \(prefix)")
            return NFTOutputs(nft8K: nft8K, nft3K: nft3K, nft2K: nft2K)
        }

        let temp8K = try makeTemp(in: cli.outDir, stem: "\(prefix)_NFT8K", ext: ".png")
        let temp3K = try makeTemp(in: cli.outDir, stem: "\(prefix)_NFT3K", ext: ".png")
        let temp2K = try makeTemp(in: cli.outDir, stem: "\(prefix)_NFT2K", ext: ".png")
        do {
            // NFT squares letterbox the full artwork on black (no content loss), unlike
            // squarePNGFrom8K which cover-crops to a filled square. Intentional per project policy.
            _ = try runner.run(
                "magick",
                [
                    source.path,
                    "-auto-orient",
                    "-colorspace", config.imageOutputColorSpace,
                    "-background", "black",
                    "-gravity", "center",
                    "-extent", "\(config.image8KWidth)x\(config.image8KWidth)",
                    "-strip",
                    temp8K.path
                ])
            try verifyImageOutput(temp8K, width: config.image8KWidth, height: config.image8KWidth, format: "PNG")
            _ = try runner.run(
                "magick",
                [temp8K.path] + resampleArguments("\(config.image3KSize)x\(config.image3KSize)!") + [
                    "-strip", temp3K.path
                ])
            try verifyImageOutput(temp3K, width: config.image3KSize, height: config.image3KSize, format: "PNG")
            _ = try runner.run(
                "magick",
                [temp8K.path] + resampleArguments("\(config.image2KSize)x\(config.image2KSize)!") + [
                    "-strip", temp2K.path
                ])
            try verifyImageOutput(temp2K, width: config.image2KSize, height: config.image2KSize, format: "PNG")
            try publishTemp(temp8K, to: nft8K)
            try publishTemp(temp3K, to: nft3K)
            try publishTemp(temp2K, to: nft2K)
            logger.info("Created NFT set: \(prefix)")
            return NFTOutputs(nft8K: nft8K, nft3K: nft3K, nft2K: nft2K)
        } catch {
            for temp in [temp8K, temp3K, temp2K] {
                try? fileManager.removeItem(at: temp)
                state.unregister(tempFile: temp)
            }
            throw error
        }
    }
}

// One delivery size of the AIPIX pair. A named type rather than a tuple: the target is passed
// across helpers, and a three-element tuple trips swiftlint's large_tuple rule.
private struct AIPixTarget {
    let label: String
    let width: Int
    let height: Int
}
