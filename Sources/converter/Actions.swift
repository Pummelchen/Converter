import Foundation

extension ConverterTool {
    // External RF64/BW64 deliverables are for handoff only and must never feed the full pipeline.
    func isExternalArchivalAudioVariant(_ file: URL) -> Bool {
        let stem = file.stem
        return stem.hasSuffix("_RF64") || stem.hasSuffix("_BW64")
    }

    // When a rerun sees same-stem derived audio files, prefer the highest-quality source family member.
    func rankedFullRunAudioCandidates() throws -> [URL] {
        let candidates = try files(in: cli.srcDir, matchingExtensions: ["flac", "wav", "mp3"])
            .filter { !isExternalArchivalAudioVariant($0) }
        guard candidates.count > 1 else {
            return candidates
        }

        let grouped = Dictionary(grouping: candidates) { $0.stem }
        guard grouped.count == 1, let family = grouped.values.first else {
            return candidates
        }

        let ranked = family.sorted { lhs, rhs in
            func rank(_ ext: String) -> Int {
                switch ext {
                case "flac": return 0
                case "wav": return 1
                case "mp3": return 2
                default: return 9
                }
            }

            let lhsRank = rank(lhs.pathExtension.lowercasedASCII)
            let rhsRank = rank(rhs.pathExtension.lowercasedASCII)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }

        if let preferred = ranked.first {
            logger.warn("Full pipeline found multiple same-stem audio files; auto-selecting \(preferred.basename) and ignoring derived companions.")
            return [preferred]
        }
        return candidates
    }

    @discardableResult
    func processBatch<T>(files: [URL], emptyMessage: String, failWhenEmpty: Bool, operation: (URL) throws -> T) throws -> [T] {
        if files.isEmpty {
            if failWhenEmpty {
                throw AppError(emptyMessage)
            }
            logger.info(emptyMessage)
            return []
        }

        var results: [T] = []
        var failures: [String] = []
        for file in files {
            do {
                results.append(try operation(file))
                maybeSleep()
            } catch {
                let message = error.localizedDescription
                logger.error(message)
                failures.append(message)
                if !cli.continueOnError {
                    throw error
                }
            }
        }

        if !failures.isEmpty {
            throw AppError("\(failures.count) operation(s) failed.")
        }
        return results
    }

    func resolveFullAudio() throws -> URL {
        let candidates = try rankedFullRunAudioCandidates()
        guard !candidates.isEmpty else {
            throw AppError("Full pipeline expects exactly one source audio file (.flac/.wav/.mp3) in '\(cli.srcDir.path)'.")
        }
        if candidates.count > 1 {
            throw AppError("Full pipeline expects exactly one source audio file (.flac/.wav/.mp3) in '\(cli.srcDir.path)'.")
        }
        return candidates[0]
    }

    func isNamedFullRunImage(_ file: URL) -> Bool {
        let name = file.lastPathComponent.lowercasedASCII
        return name == "horizontal_8k.png" || name == "vertical_8k.png"
    }

    func namedFullRunImage(_ basename: String) throws -> URL? {
        let direct = cli.srcDir.appendingPathComponent(basename)
        if fileManager.fileExists(atPath: direct.path) {
            return direct
        }

        let normalizedName = basename.lowercasedASCII
        let matches = try files(in: cli.srcDir) {
            $0.lastPathComponent.lowercasedASCII == normalizedName
        }
        guard matches.count <= 1 else {
            throw AppError("Expected at most one \(basename) in '\(cli.srcDir.path)'.")
        }
        return matches.first
    }

    func verifyFullRunImage(_ image: URL, width: Int, height: Int, label: String) throws {
        try preflightPNGInput(image)
        guard let dimensions = try imageDimensions(image) else {
            throw AppError("Unable to read dimensions for \(label): \(image.path)")
        }
        if dimensions.0 != width || dimensions.1 != height {
            throw AppError("\(label) must be \(width)x\(height). Got '\(dimensions.0)x\(dimensions.1)' for '\(image.path)'.")
        }
    }

    func resolveFullImage() throws -> URL {
        let candidates = try files(in: cli.srcDir, matchingExtensions: ["png", "jpg", "jpeg"])
            .filter { !isNamedFullRunImage($0) }
        guard candidates.count == 1, let source = candidates.first else {
            throw AppError("Full pipeline expects either Horizontal_8K.png for direct render or exactly one source image (.png/.jpg/.jpeg) in '\(cli.srcDir.path)'.")
        }
        return source
    }

    func existingNFT8KImage() throws -> URL? {
        let matches = try files(in: cli.srcDir) {
            $0.pathExtension.lowercasedASCII == "png" && $0.stem.hasSuffix("_NFT8K")
        }
        guard matches.count <= 1 else {
            throw AppError("Expected at most one *_NFT8K.png in '\(cli.srcDir.path)' for short rendering.")
        }
        if let nft = matches.first {
            try verifyFullRunImage(nft, width: config.image8KWidth, height: config.image8KWidth, label: "*_NFT8K.png")
        }
        return matches.first
    }

    func resolveShortRenderImage() throws -> URL {
        if let vertical = try namedFullRunImage("Vertical_8K.png") {
            try verifyFullRunImage(vertical, width: config.shortMP4ScaleW, height: config.shortMP4ScaleH, label: "Vertical_8K.png")
            return vertical
        }
        if let nft = try existingNFT8KImage() {
            return nft
        }
        if let horizontal = try namedFullRunImage("Horizontal_8K.png") {
            try verifyFullRunImage(horizontal, width: config.videoMP4Width, height: config.videoMP4Height, label: "Horizontal_8K.png")
            return try nftFrom8K(horizontal).nft8K
        }

        let existing8K = try files(in: cli.srcDir) {
            $0.pathExtension.lowercasedASCII == "png"
                && $0.stem.hasSuffix("_8K")
                && !isNamedFullRunImage($0)
        }
        if existing8K.count > 1 {
            throw AppError("Expected at most one *_8K.png in '\(cli.srcDir.path)' for short rendering.")
        }
        if let image = existing8K.first {
            try verifyFullRunImage(image, width: config.videoMP4Width, height: config.videoMP4Height, label: "*_8K.png")
            return try nftFrom8K(image).nft8K
        }

        let sourceImage = try resolveFullImage()
        let sourcePNG: URL
        let ext = sourceImage.pathExtension.lowercasedASCII
        if ext == "jpg" || ext == "jpeg" {
            logger.info("Short step: JPG -> PNG")
            sourcePNG = try convertJPGToPNG(sourceImage)
        } else {
            sourcePNG = sourceImage
        }
        logger.info("Short step: create NFT8K image")
        let eightK = try aipixFile(sourcePNG).eightK
        return try nftFrom8K(eightK).nft8K
    }

    func resolveDirectShortImage() throws -> URL {
        let images = try files(in: cli.srcDir, matchingExtensions: ["png", "jpg", "jpeg"])
        guard images.count == 1, let image = images.first else {
            throw AppError("Short render expects exactly one image (.png/.jpg/.jpeg) in '\(cli.srcDir.path)'.")
        }
        return image
    }

    func rankedShortAudioCandidates() throws -> [URL] {
        let candidates = try files(in: cli.srcDir, matchingExtensions: ["flac", "wav", "mp3", "m4a"])
            .filter { !isExternalArchivalAudioVariant($0) }
        guard candidates.count > 1 else {
            return candidates
        }

        let grouped = Dictionary(grouping: candidates) { $0.stem }
        guard grouped.count == 1, let family = grouped.values.first else {
            return candidates
        }

        let ranked = family.sorted { lhs, rhs in
            func rank(_ ext: String) -> Int {
                switch ext {
                case "m4a": return 0
                case "flac": return 1
                case "wav": return 2
                case "mp3": return 3
                default: return 9
                }
            }

            let lhsRank = rank(lhs.pathExtension.lowercasedASCII)
            let rhsRank = rank(rhs.pathExtension.lowercasedASCII)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }

        if let preferred = ranked.first {
            logger.warn("Short render found multiple same-stem audio files; auto-selecting \(preferred.basename) and ignoring derived companions.")
            return [preferred]
        }
        return candidates
    }

    func resolveShortAudio() throws -> URL {
        let candidates = try rankedShortAudioCandidates()
        guard candidates.count == 1, let audio = candidates.first else {
            throw AppError("Short render expects exactly one audio file (.flac/.wav/.mp3/.m4a) in '\(cli.srcDir.path)'.")
        }
        return audio
    }

    func fullRunImageArtifacts() async throws -> FullRunImageArtifacts {
        let horizontal = try namedFullRunImage("Horizontal_8K.png")
        let vertical = try namedFullRunImage("Vertical_8K.png")

        if let horizontal {
            try verifyFullRunImage(horizontal, width: config.videoMP4Width, height: config.videoMP4Height, label: "Horizontal_8K.png")
            logger.info("Full step: use Horizontal_8K.png for main MP4")
            if let vertical {
                try verifyFullRunImage(vertical, width: config.shortMP4ScaleW, height: config.shortMP4ScaleH, label: "Vertical_8K.png")
                logger.info("Full step: use Vertical_8K.png for short MP4")
            } else {
                logger.info("Full step: create NFT8K PNG for short MP4")
            }
            let generated = try await fullImagePipelineFromDirect8K(horizontal)
            let shortImage = vertical ?? generated.nft8K
            return FullRunImageArtifacts(mainVideoImage: horizontal, shortVideoImage: shortImage)
        }

        if let vertical {
            try verifyFullRunImage(vertical, width: config.shortMP4ScaleW, height: config.shortMP4ScaleH, label: "Vertical_8K.png")
            logger.info("Full step: use Vertical_8K.png for short MP4")
        }

        let sourceImage = try resolveFullImage()
        let generated = try await fullImagePipeline(sourceImage: sourceImage)
        return FullRunImageArtifacts(mainVideoImage: generated.eightK, shortVideoImage: vertical ?? generated.nft8K)
    }

    func shouldPreferM4AIntermediateForMP3Short() -> Bool {
        if config.m4aBitrate.lowercasedASCII == "lossless" {
            return true
        }
        let mp3Bitrate = parseBitrateBps(config.mp3Bitrate) ?? 0
        let m4aBitrate = parseBitrateBps(config.m4aBitrate) ?? 0
        if m4aBitrate != mp3Bitrate {
            return m4aBitrate > mp3Bitrate
        }
        if config.m4aSampleRate != config.mp3SampleRate {
            return config.m4aSampleRate > config.mp3SampleRate
        }
        if config.m4aChannels != config.mp3Channels {
            return config.m4aChannels > config.mp3Channels
        }
        return false
    }

    func fullImagePipeline(sourceImage: URL) async throws -> ImageArtifacts {
        let sourcePNG: URL
        let ext = sourceImage.pathExtension.lowercasedASCII
        if ext == "jpg" || ext == "jpeg" {
            logger.info("Full step: JPG -> PNG")
            sourcePNG = try await withImagePermit { try self.convertJPGToPNG(sourceImage) }
        } else {
            sourcePNG = sourceImage
        }

        logger.info("Full step: PNG variants")
        let variants = try await withImagePermit { try self.aipixFile(sourcePNG) }

        async let nftTask: NFTOutputs = withImagePermit {
            self.logger.info("Full step: NFT assets")
            return try self.nftFrom8K(variants.eightK)
        }

        async let twoKTask: URL = withImagePermit {
            self.logger.info("Full step: 2K PNG")
            return try self.squarePNGFrom8K(variants.eightK, size: self.config.image2KSize, label: "2K")
        }

        async let threeKTask: URL = withImagePermit {
            self.logger.info("Full step: 3K PNG")
            let threeK = try self.squarePNGFrom8K(variants.eightK, size: self.config.image3KSize, label: "3K")
            self.logger.info("Full step: 3K JPG deliverables")
            _ = try self.jpegExtentFromPNG(threeK, requiredWidth: self.config.image3KSize, requiredHeight: self.config.image3KSize, suffix: "1MB", targetBytes: self.config.image3KJPG1MBTargetBytes)
            _ = try self.jpegExtentFromPNG(threeK, requiredWidth: self.config.image3KSize, requiredHeight: self.config.image3KSize, suffix: "5MB", targetBytes: self.config.image3KJPG5MBTargetBytes)
            return threeK
        }

        async let eightKJPGTask: Void = withImagePermit {
            self.logger.info("Full step: 8K JPG deliverables")
            _ = try self.jpegExtentFromPNG(variants.eightK, requiredWidth: self.config.image8KWidth, requiredHeight: self.config.image8KHeight, suffix: "1MB", targetBytes: self.config.image8KJPG1MBTargetBytes)
            _ = try self.jpegExtentFromPNG(variants.eightK, requiredWidth: self.config.image8KWidth, requiredHeight: self.config.image8KHeight, suffix: "2MB", targetBytes: self.config.image8KJPG2MBTargetBytes)
            _ = try self.jpegExtentFromPNG(variants.eightK, requiredWidth: self.config.image8KWidth, requiredHeight: self.config.image8KHeight, suffix: "20MB", targetBytes: self.config.image8KJPG20MBTargetBytes)
        }

        let nft = try await nftTask
        let twoK = try await twoKTask
        let threeK = try await threeKTask
        _ = try await eightKJPGTask

        return ImageArtifacts(sourcePNG: sourcePNG, eightK: variants.eightK, fourK: variants.fourK, threeK: threeK, twoK: twoK, nft8K: nft.nft8K)
    }

    func fullImagePipelineFromDirect8K(_ sourcePNG: URL) async throws -> ImageArtifacts {
        logger.info("Full step: image deliverables from \(sourcePNG.basename)")

        async let fourKTask: URL = withImagePermit {
            self.logger.info("Full step: 4K PNG")
            return try self.fourKPNGFrom8K(sourcePNG)
        }

        async let nftTask: NFTOutputs = withImagePermit {
            self.logger.info("Full step: NFT assets")
            return try self.nftFrom8K(sourcePNG)
        }

        async let twoKTask: URL = withImagePermit {
            self.logger.info("Full step: 2K PNG")
            return try self.squarePNGFrom8K(sourcePNG, size: self.config.image2KSize, label: "2K")
        }

        async let threeKTask: URL = withImagePermit {
            self.logger.info("Full step: 3K PNG")
            let threeK = try self.squarePNGFrom8K(sourcePNG, size: self.config.image3KSize, label: "3K")
            self.logger.info("Full step: 3K JPG deliverables")
            _ = try self.jpegExtentFromPNG(threeK, requiredWidth: self.config.image3KSize, requiredHeight: self.config.image3KSize, suffix: "1MB", targetBytes: self.config.image3KJPG1MBTargetBytes)
            _ = try self.jpegExtentFromPNG(threeK, requiredWidth: self.config.image3KSize, requiredHeight: self.config.image3KSize, suffix: "5MB", targetBytes: self.config.image3KJPG5MBTargetBytes)
            return threeK
        }

        async let eightKJPGTask: Void = withImagePermit {
            self.logger.info("Full step: 8K JPG deliverables")
            _ = try self.jpegExtentFromPNG(sourcePNG, requiredWidth: self.config.image8KWidth, requiredHeight: self.config.image8KHeight, suffix: "1MB", targetBytes: self.config.image8KJPG1MBTargetBytes)
            _ = try self.jpegExtentFromPNG(sourcePNG, requiredWidth: self.config.image8KWidth, requiredHeight: self.config.image8KHeight, suffix: "2MB", targetBytes: self.config.image8KJPG2MBTargetBytes)
            _ = try self.jpegExtentFromPNG(sourcePNG, requiredWidth: self.config.image8KWidth, requiredHeight: self.config.image8KHeight, suffix: "20MB", targetBytes: self.config.image8KJPG20MBTargetBytes)
        }

        let fourK = try await fourKTask
        let nft = try await nftTask
        let twoK = try await twoKTask
        let threeK = try await threeKTask
        _ = try await eightKJPGTask

        return ImageArtifacts(sourcePNG: sourcePNG, eightK: sourcePNG, fourK: fourK, threeK: threeK, twoK: twoK, nft8K: nft.nft8K)
    }

    func fullAudioPreparation(sourceAudio: URL) async throws -> AudioArtifacts {
        let ext = sourceAudio.pathExtension.lowercasedASCII
        switch ext {
        case "flac":
            try preflightFLACInput(sourceAudio)
            logger.info("Full step: external RF64/BW64 audio deliverables")
            async let archivalTask: ExternalArchivalVariants = withAudioPermit {
                try self.generateExternalArchivalVariants(baseName: sourceAudio.stem, highQualitySource: sourceAudio)
            }
            let wav = try await withAudioPermit { try self.convertFLACToWAV(sourceAudio) }
            _ = try await archivalTask
            async let m4aTask: URL = withAudioPermit { try self.convertWAVToM4A(wav) }
            async let mp3Task: URL = withAudioPermit { try self.convertWAVToMP3(wav) }
            let artifacts = AudioArtifacts(source: sourceAudio, wav: wav, m4a: try await m4aTask, mp3: try await mp3Task)
            return artifacts
        case "mp3":
            try preflightMP3Input(sourceAudio)
            let wav = try await withAudioPermit { try self.convertMP3ToWAV(sourceAudio) }
            logger.info("Full step: external RF64/BW64 audio deliverables")
            async let archivalTask: ExternalArchivalVariants = withAudioPermit {
                try self.generateExternalArchivalVariants(baseName: sourceAudio.stem, highQualitySource: wav)
            }
            _ = try await archivalTask
            async let m4aTask: URL = withAudioPermit { try self.convertWAVToM4A(wav) }
            let mp3: URL
            do {
                mp3 = try ensureStandardMP3Output(from: sourceAudio)
            } catch {
                self.logger.info("Full step: rebuild MP3 to configured standard")
                mp3 = try await withAudioPermit { try self.convertWAVToMP3(wav) }
            }
            let artifacts = AudioArtifacts(source: sourceAudio, wav: wav, m4a: try await m4aTask, mp3: mp3)
            return artifacts
        case "wav":
            try preflightWAVInput(sourceAudio)
            var archivalSource = sourceAudio
            var needsNormalization = false
            do {
                try verifyWAVStandard(sourceAudio, requireAudible: true, qcPolicy: nil)
            } catch {
                needsNormalization = true
                let preservedSource = try makeTemp(in: cli.outDir, stem: "\(sourceAudio.stem).archival-source", ext: ".wav")
                try copyFileIntoTemp(sourceAudio, temp: preservedSource)
                archivalSource = preservedSource
            }
            defer {
                if archivalSource != sourceAudio {
                    try? fileManager.removeItem(at: archivalSource)
                    state.unregister(tempFile: archivalSource)
                }
            }
            let archivalSourceURL = archivalSource
            logger.info("Full step: external RF64/BW64 audio deliverables")
            async let archivalTask: ExternalArchivalVariants = withAudioPermit {
                try self.generateExternalArchivalVariants(baseName: sourceAudio.stem, highQualitySource: archivalSourceURL)
            }
            if needsNormalization {
                try normalizeWAVInPlace(sourceAudio)
            }
            try preflightWAVStandardInput(sourceAudio)
            _ = try await archivalTask
            async let m4aTask: URL = withAudioPermit { try self.convertWAVToM4A(sourceAudio) }
            async let mp3Task: URL = withAudioPermit { try self.convertWAVToMP3(sourceAudio) }
            let artifacts = AudioArtifacts(source: sourceAudio, wav: sourceAudio, m4a: try await m4aTask, mp3: try await mp3Task)
            return artifacts
        default:
            throw AppError("Unsupported audio source kind: \(ext)")
        }
    }

    func runFullProductionPipeline(sourceAudio audio: URL) async throws {
        async let imageArtifactsTask = fullRunImageArtifacts()
        async let audioArtifactsTask = fullAudioPreparation(sourceAudio: audio)

        let imageArtifacts = try await imageArtifactsTask
        let audioArtifacts = try await audioArtifactsTask

        logger.info("Full step: M4A -> MP4")
        let mainVideo = try await withVideoPermit {
            try self.renderM4AToMP4(
                imageFile: imageArtifacts.mainVideoImage,
                audioFile: audioArtifacts.m4a,
                audioQCPolicy: nil
            )
        }
        if let shortImage = imageArtifacts.shortVideoImage {
            logger.info("Full step: PNG -> Short: \(shortImage.basename)")
            _ = try await withVideoPermit {
                try self.renderM4AToShortMP4(
                    imageFile: shortImage,
                    audioFile: audioArtifacts.m4a,
                    audioQCPolicy: nil
                )
            }
        } else {
            logger.info("Full step: MP4 -> Short")
            _ = try await withVideoPermit { try self.shortenMP4(mainVideo, audioQCPolicy: nil) }
        }
        try cleanTransients()
    }

    func stepFull() async throws {
        logger.info("Full pipeline start")
        let audio = try resolveFullAudio()
        logger.info("Source audio: \(audio.basename)")
        try await runFullProductionPipeline(sourceAudio: audio)
        logger.info("Full pipeline complete")
    }

    func stepAlbum() async throws {
        logger.info("Album pipeline start")
        let album = try buildNumberedAlbumFromDirectory()
        logger.info("Album source audio: \(album.basename)")
        try await runFullProductionPipeline(sourceAudio: album)
        logger.info("Album pipeline complete")
    }

    func stepRunPix() async throws {
        let images = try files(in: cli.srcDir, matchingExtensions: ["png", "jpg", "jpeg"])
        if images.isEmpty {
            throw AppError("No source images found in '\(cli.srcDir.path)'.")
        }
        var failures = 0
        for image in images {
            do {
                logger.info("Run_pix image: \(image.basename)")
                _ = try await fullImagePipeline(sourceImage: image)
            } catch {
                failures += 1
                logger.error(error.localizedDescription)
                if !cli.continueOnError {
                    throw error
                }
            }
        }
        try cleanTransients()
        if failures > 0 {
            throw AppError("\(failures) image pipeline run(s) failed.")
        }
    }

    func stepJPGToPNG() throws {
        let files = try files(in: cli.srcDir, matchingExtensions: ["jpg", "jpeg"])
        _ = try processBatch(files: files, emptyMessage: "No JPG/JPEG files found in '\(cli.srcDir.path)'.", failWhenEmpty: false) { file in
            self.logger.info("JPG -> PNG: \(file.basename)")
            return try self.convertJPGToPNG(file)
        }
    }

    func stepPNGToJPG() throws {
        let files = try files(in: cli.srcDir, matchingExtensions: ["png"])
        _ = try processBatch(files: files, emptyMessage: "No .png files found in '\(cli.srcDir.path)'.", failWhenEmpty: false) { file in
            self.logger.info("PNG -> JPG: \(file.basename)")
            return try self.convertPNGToJPEG(file, outputExtension: "jpg")
        }
    }

    func stepAIPix() throws {
        let files = try files(in: cli.srcDir, matchingExtensions: ["png"])
        _ = try processBatch(files: files, emptyMessage: "No PNG files found in '\(cli.srcDir.path)'.", failWhenEmpty: false) { file in
            self.logger.info("PNG variants: \(file.basename)")
            return try self.aipixFile(file)
        }
    }

    func stepPNGToNFT() throws {
        let files = try files(in: cli.srcDir) { $0.pathExtension.lowercasedASCII == "png" && $0.stem.hasSuffix("_8K") }
        _ = try processBatch(files: files, emptyMessage: "No *_8K.png files found in '\(cli.srcDir.path)'.", failWhenEmpty: false) { file in
            self.logger.info("NFT assets: \(file.basename)")
            return try self.nftFrom8K(file)
        }
    }

    func stepPNGTo3K() throws {
        let files = try files(in: cli.srcDir) { $0.pathExtension.lowercasedASCII == "png" && $0.stem.hasSuffix("_8K") }
        _ = try processBatch(files: files, emptyMessage: "No *_8K.png files found in '\(cli.srcDir.path)'.", failWhenEmpty: false) { file in
            self.logger.info("8K -> 3K PNG: \(file.basename)")
            return try self.squarePNGFrom8K(file, size: self.config.image3KSize, label: "3K")
        }
    }

    func stepPNGTo2K() throws {
        let files = try files(in: cli.srcDir) { $0.pathExtension.lowercasedASCII == "png" && $0.stem.hasSuffix("_8K") }
        _ = try processBatch(files: files, emptyMessage: "No *_8K.png files found in '\(cli.srcDir.path)'.", failWhenEmpty: false) { file in
            self.logger.info("8K -> 2K PNG: \(file.basename)")
            return try self.squarePNGFrom8K(file, size: self.config.image2KSize, label: "2K")
        }
    }

    func stepPNGTo3K1MB() throws {
        let files = try files(in: cli.srcDir) { $0.pathExtension.lowercasedASCII == "png" && $0.stem.hasSuffix("_3K") }
        _ = try processBatch(files: files, emptyMessage: "No *_3K.png files found in '\(cli.srcDir.path)'.", failWhenEmpty: false) { file in
            self.logger.info("3K PNG -> 1MB JPG: \(file.basename)")
            return try self.jpegExtentFromPNG(file, requiredWidth: self.config.image3KSize, requiredHeight: self.config.image3KSize, suffix: "1MB", targetBytes: self.config.image3KJPG1MBTargetBytes)
        }
    }

    func stepPNGTo3K5MB() throws {
        let files = try files(in: cli.srcDir) { $0.pathExtension.lowercasedASCII == "png" && $0.stem.hasSuffix("_3K") }
        _ = try processBatch(files: files, emptyMessage: "No *_3K.png files found in '\(cli.srcDir.path)'.", failWhenEmpty: false) { file in
            self.logger.info("3K PNG -> 5MB JPG: \(file.basename)")
            return try self.jpegExtentFromPNG(file, requiredWidth: self.config.image3KSize, requiredHeight: self.config.image3KSize, suffix: "5MB", targetBytes: self.config.image3KJPG5MBTargetBytes)
        }
    }

    func stepPNGToJPG1MB() throws {
        let files = try files(in: cli.srcDir) { $0.pathExtension.lowercasedASCII == "png" && $0.stem.hasSuffix("_8K") }
        _ = try processBatch(files: files, emptyMessage: "No *_8K.png files found in '\(cli.srcDir.path)'.", failWhenEmpty: false) { file in
            self.logger.info("8K PNG -> 1MB JPG: \(file.basename)")
            return try self.jpegExtentFromPNG(file, requiredWidth: self.config.image8KWidth, requiredHeight: self.config.image8KHeight, suffix: "1MB", targetBytes: self.config.image8KJPG1MBTargetBytes)
        }
    }

    func stepPNGToJPG2MB() throws {
        let files = try files(in: cli.srcDir) { $0.pathExtension.lowercasedASCII == "png" && $0.stem.hasSuffix("_8K") }
        _ = try processBatch(files: files, emptyMessage: "No *_8K.png files found in '\(cli.srcDir.path)'.", failWhenEmpty: false) { file in
            self.logger.info("8K PNG -> 2MB JPG: \(file.basename)")
            return try self.jpegExtentFromPNG(file, requiredWidth: self.config.image8KWidth, requiredHeight: self.config.image8KHeight, suffix: "2MB", targetBytes: self.config.image8KJPG2MBTargetBytes)
        }
    }

    func stepPNGToJPG20MB() throws {
        let files = try files(in: cli.srcDir) { $0.pathExtension.lowercasedASCII == "png" && $0.stem.hasSuffix("_8K") }
        _ = try processBatch(files: files, emptyMessage: "No *_8K.png files found in '\(cli.srcDir.path)'.", failWhenEmpty: false) { file in
            self.logger.info("8K PNG -> 20MB JPG: \(file.basename)")
            return try self.jpegExtentFromPNG(file, requiredWidth: self.config.image8KWidth, requiredHeight: self.config.image8KHeight, suffix: "20MB", targetBytes: self.config.image8KJPG20MBTargetBytes)
        }
    }

    func stepFLACToWAV() throws {
        let files = try files(in: cli.srcDir, matchingExtensions: ["flac"])
        _ = try processBatch(files: files, emptyMessage: "No .flac files found in '\(cli.srcDir.path)'.", failWhenEmpty: true) { file in
            self.logger.info("FLAC -> WAV: \(file.basename)")
            return try self.convertFLACToWAV(file)
        }
    }

    func stepMP3ToWAV() throws {
        let files = try files(in: cli.srcDir, matchingExtensions: ["mp3"])
        _ = try processBatch(files: files, emptyMessage: "No .mp3 files found in '\(cli.srcDir.path)'.", failWhenEmpty: false) { file in
            self.logger.info("MP3 -> WAV: \(file.basename)")
            return try self.convertMP3ToWAV(file)
        }
    }

    func stepMP3ToShort() throws {
        let images = try files(in: cli.srcDir, matchingExtensions: ["png", "jpg", "jpeg"])
        let existing8K = try files(in: cli.srcDir) { $0.pathExtension.lowercasedASCII == "png" && $0.stem.hasSuffix("_8K") }
        if existing8K.count + images.count == 0 {
            throw AppError("Expected exactly one source image (.png/.jpg/.jpeg) or one *_8K.png in '\(cli.srcDir.path)'.")
        }
        let mp3Files = try files(in: cli.srcDir, matchingExtensions: ["mp3"])
        guard mp3Files.count == 1, let sourceMP3 = mp3Files.first else {
            throw AppError("Expected exactly one .mp3 file in '\(cli.srcDir.path)' for -mp3toshort.")
        }

        let image = try resolveShortRenderImage()
        logger.info("MP3 -> Short source audio: \(sourceMP3.basename)")
        logger.info("MP3 -> Short source image: \(image.basename)")

        let workingMP3 = try ensureShortReadyMP3(sourceMP3)
        if shouldPreferM4AIntermediateForMP3Short() {
            logger.info("MP3 -> Short prefers high-quality M4A intermediate")
        } else {
            logger.info("MP3 -> Short uses project-standard M4A intermediate")
        }
        let workingM4A = try convertMP3ToShortReadyM4A(workingMP3)
        guard let imageDimensions = try imageDimensions(image) else {
            throw AppError("Unable to read dimensions: \(image.path)")
        }
        guard imageDimensions.0 > 0 && imageDimensions.1 > 0 else {
            throw AppError("Short image dimensions must be positive. Got '\(imageDimensions.0)x\(imageDimensions.1)' for '\(image.path)'.")
        }
        _ = try renderM4AToShortMP4(imageFile: image, audioFile: workingM4A, audioQCPolicy: nil)
    }

    func stepShort() throws {
        let image = try resolveDirectShortImage()
        let audio = try resolveShortAudio()
        logger.info("Short source audio: \(audio.basename)")
        logger.info("Short source image: \(image.basename)")
        _ = try renderAudioToShortMP4(imageFile: image, audioFile: audio, audioQCPolicy: nil)
    }

    func stepM4AToWAV() throws {
        let files = try files(in: cli.srcDir, matchingExtensions: ["m4a"])
        _ = try processBatch(files: files, emptyMessage: "No .m4a files found in '\(cli.srcDir.path)'.", failWhenEmpty: true) { file in
            self.logger.info("M4A -> WAV: \(file.basename)")
            return try self.convertM4AToWAV(file)
        }
    }

    func stepWAVToM4A() throws {
        let files = try files(in: cli.srcDir, matchingExtensions: ["wav"])
        _ = try processBatch(files: files, emptyMessage: "No .wav files found in '\(cli.srcDir.path)'.", failWhenEmpty: true) { file in
            self.logger.info("WAV -> M4A: \(file.basename)")
            return try self.convertWAVToM4A(file)
        }
    }

    func stepFLACToM4A() throws {
        let files = try files(in: cli.srcDir, matchingExtensions: ["flac"])
        _ = try processBatch(files: files, emptyMessage: "No .flac files found in '\(cli.srcDir.path)'.", failWhenEmpty: true) { file in
            self.logger.info("FLAC -> M4A: \(file.basename)")
            return try self.convertAudioToM4A(file)
        }
    }

    func stepMP3ToM4A() throws {
        let files = try files(in: cli.srcDir, matchingExtensions: ["mp3"])
        _ = try processBatch(files: files, emptyMessage: "No .mp3 files found in '\(cli.srcDir.path)'.", failWhenEmpty: true) { file in
            self.logger.info("MP3 -> M4A: \(file.basename)")
            return try self.convertAudioToM4A(file)
        }
    }

    func stepM4AToMP3() throws {
        let files = try files(in: cli.srcDir, matchingExtensions: ["m4a"])
        _ = try processBatch(files: files, emptyMessage: "No .m4a files found in '\(cli.srcDir.path)'.", failWhenEmpty: true) { file in
            self.logger.info("M4A -> MP3: \(file.basename)")
            return try self.convertM4AToMP3(file)
        }
    }

    func stepWAVToMP3() throws {
        let files = try files(in: cli.srcDir, matchingExtensions: ["wav"])
        _ = try processBatch(files: files, emptyMessage: "No .wav files found in '\(cli.srcDir.path)'.", failWhenEmpty: true) { file in
            self.logger.info("WAV -> MP3: \(file.basename)")
            return try self.convertWAVToMP3(file)
        }
    }

    func stepFLACToMP3() throws {
        let files = try files(in: cli.srcDir, matchingExtensions: ["flac"])
        _ = try processBatch(files: files, emptyMessage: "No .flac files found in '\(cli.srcDir.path)'.", failWhenEmpty: true) { file in
            self.logger.info("FLAC -> MP3: \(file.basename)")
            return try self.convertFLACToMP3(file)
        }
    }

    func stepWAVToFLAC() throws {
        let files = try files(in: cli.srcDir, matchingExtensions: ["wav"])
        _ = try processBatch(files: files, emptyMessage: "No .wav files found in '\(cli.srcDir.path)'.", failWhenEmpty: true) { file in
            self.logger.info("WAV -> FLAC: \(file.basename)")
            return try self.convertWAVToFLAC(file)
        }
    }

    func stepMP3ToFLAC() throws {
        let files = try files(in: cli.srcDir, matchingExtensions: ["mp3"])
        _ = try processBatch(files: files, emptyMessage: "No .mp3 files found in '\(cli.srcDir.path)'.", failWhenEmpty: true) { file in
            self.logger.info("MP3 -> FLAC: \(file.basename)")
            return try self.convertMP3ToFLAC(file)
        }
    }

    func stepM4AToFLAC() throws {
        let files = try files(in: cli.srcDir, matchingExtensions: ["m4a"])
        _ = try processBatch(files: files, emptyMessage: "No .m4a files found in '\(cli.srcDir.path)'.", failWhenEmpty: true) { file in
            self.logger.info("M4A -> FLAC: \(file.basename)")
            return try self.convertM4AToFLAC(file)
        }
    }

    func stepMP3Clean() throws {
        let mp3Files = try files(in: cli.srcDir, matchingExtensions: ["mp3"])
        _ = try processBatch(files: mp3Files, emptyMessage: "No .mp3 files found in '\(cli.srcDir.path)'.", failWhenEmpty: false) { file in
            self.logger.info("Clean MP3 metadata: \(file.basename)")
            try self.cleanMP3(file)
        }
    }

    func stepBass() throws {
        let spec = try cli.bassBoostSpec()
        let files = try audioBassCandidates()
        _ = try processBatch(
            files: files,
            emptyMessage: "No supported audio media files (.flac, .wav, .mp3, .m4a, .mp4) found in '\(cli.srcDir.path)'.",
            failWhenEmpty: true
        ) { file in
            let mode = spec.gainDB < 0 ? "reduce" : "boost"
            self.logger.info("Bass \(mode) \(file.basename): frequency=\(ffmpegNumber(spec.frequencyHz))Hz gain=\(ffmpegNumber(spec.gainDB))dB")
            return try self.bassBoostMedia(file, spec: spec)
        }
    }

    func emitLoudScanReport(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    func stepLoudScan() throws {
        logger.info("Loudscan progress starts now. Each file prints the current four-line loudness report.")
        var printedFinalReport = false
        let finalLines = try loudScanReportLines { progress in
            if progress.isMeasuring {
                self.logger.info("Loudscan \(progress.processedFiles + 1)/\(progress.totalFiles) measuring: \(progress.currentFile.basename)")
                return
            }

            self.logger.info("Loudscan \(progress.processedFiles)/\(progress.totalFiles) files processed: \(progress.currentFile.basename)")
            self.emitLoudScanReport(progress.reportLines)
            printedFinalReport = progress.processedFiles == progress.totalFiles
        }
        if !printedFinalReport {
            emitLoudScanReport(finalLines)
        }
    }

    func stepLoudness() throws {
        let spec = try cli.loudnessSpec()
        let files = try audioLoudnessCandidates()
        guard !files.isEmpty else {
            throw AppError("No supported audio media files (.flac, .wav, .mp3, .m4a, .mp4) found in '\(cli.srcDir.path)'.")
        }

        var processed = 0
        var failures: [String] = []
        for file in files {
            try ensureDirectory(cli.srcDir)
            try ensureWritableDirectory(cli.outDir)
            do {
                logger.info("Loudness normalize \(file.basename): integrated target=\(ffmpegNumber(spec.targetLUFS)) LUFS")
                _ = try loudnessNormalizeMedia(file, spec: spec)
                processed += 1
                maybeSleep()
            } catch {
                let message = "\(file.basename): \(error.localizedDescription)"
                logger.error("Loudness normalize failed for \(message)")
                failures.append(message)
            }
        }

        guard failures.isEmpty else {
            throw AppError("Loudness normalize failed for \(failures.count)/\(files.count) file(s): \(failures.joined(separator: "; "))")
        }
        logger.info("Loudness normalize complete: processed=\(processed) failed=0")
    }

    func stepFadeWAV() throws {
        let files = try files(in: cli.srcDir, matchingExtensions: ["wav"])
        _ = try processBatch(files: files, emptyMessage: "No .wav files found in '\(cli.srcDir.path)'.", failWhenEmpty: true) { file in
            self.logger.info("Fade WAV: \(file.basename)")
            return try self.fadeWAV(file)
        }
    }

    func stepFade() throws {
        let seconds = try cli.tailFadeSeconds()
        let files = try audioTailFadeCandidates()
        _ = try processBatch(
            files: files,
            emptyMessage: "No supported audio files (.flac, .wav, .mp3) found in '\(cli.srcDir.path)'.",
            failWhenEmpty: true
        ) { file in
            self.logger.info("Fade tail \(file.basename): duration=\(self.actionTimeDisplay(seconds))")
            return try self.fadeTailAudio(file, fadeSeconds: seconds)
        }
    }

    func stepFadeCut() throws {
        let spec = try cli.fadeCutSpec()
        let files = try audioFadeCutCandidates()
        _ = try processBatch(
            files: files,
            emptyMessage: "No supported audio files (.flac, .wav, .mp3) found in '\(cli.srcDir.path)'.",
            failWhenEmpty: true
        ) { file in
            self.logger.info("Fadecut \(file.basename): cut=\(self.actionTimeDisplay(spec.cutSeconds)) fade=\(self.actionTimeDisplay(spec.fadeDurationSeconds))")
            return try self.fadeCutAudio(file, spec: spec)
        }
    }

    func stepFadeOut() throws {
        let spec = try cli.fadeOutSpec()
        let files = try audioFadeOutCandidates()
        _ = try processBatch(
            files: files,
            emptyMessage: "No supported audio files (.flac, .wav, .mp3, .m4a) found in '\(cli.srcDir.path)'.",
            failWhenEmpty: true
        ) { file in
            self.logger.info("Fadeout \(file.basename): start=\(self.actionTimeDisplay(spec.fadeStartSeconds)) duration=\(self.actionTimeDisplay(spec.fadeDurationSeconds))")
            return try self.fadeOutAudio(file, spec: spec)
        }
    }

    func stepSilence() throws {
        let spec = try cli.silenceSpec()
        let files = try audioSilenceCandidates()
        _ = try processBatch(
            files: files,
            emptyMessage: "No supported media files (.wav, .flac, .mp4) found in '\(cli.srcDir.path)'.",
            failWhenEmpty: true
        ) { file in
            self.logger.info("Add silence \(file.basename): before=\(self.actionTimeDisplay(spec.seconds)) after=\(self.actionTimeDisplay(spec.seconds))")
            return try self.addSilenceToMedia(file, spec: spec)
        }
    }

    func stepNoise() throws {
        let spec = try cli.noiseSpec()
        let files = try audioNoiseCandidates()
        _ = try processBatch(
            files: files,
            emptyMessage: "No supported media files (.flac, .wav, .mp3, .m4a, .mp4) found in '\(cli.srcDir.path)'.",
            failWhenEmpty: true
        ) { file in
            self.logger.info("Add noise \(file.basename): before=\(self.actionTimeDisplay(spec.seconds)) silence=\(self.actionTimeDisplay(NoiseSpec.transitionSilenceSeconds)) after=\(self.actionTimeDisplay(spec.seconds)) level=-12 LUFS")
            return try self.addNoiseToMedia(file, spec: spec)
        }
    }

    func actionTimeDisplay(_ seconds: Double) -> String {
        if seconds.rounded(.towardZero) == seconds {
            return String(Int(seconds))
        }
        return String(format: "%.3f", seconds)
    }

    func stepWAVToAlbum() throws {
        logger.info("Build WAV album")
        _ = try buildAlbumFromAlbumFile(extension: "wav", defaultOutputName: cli.outputFile ?? "album.rf64.wav")
    }

    func stepMP3ToAlbum() throws {
        logger.info("Build MP3 album")
        _ = try buildAlbumFromAlbumFile(extension: "mp3", defaultOutputName: cli.outputFile ?? "album_from_mp3.rf64.wav")
    }

    func stepFLACToAlbum() throws {
        logger.info("Build FLAC album")
        _ = try buildAlbumFromFLACDirectory()
    }

    func stepFLACHash() throws {
        logger.info("Hash FLAC filenames")
        try hashRename(ext: "flac")
    }

    func stepUnifiedHash() throws {
        logger.info("Hash WAV, FLAC, MP3, and MP4 filenames")
        let total =
            (try hashRename(ext: "wav", warnWhenEmpty: false)) +
            (try hashRename(ext: "flac", warnWhenEmpty: false)) +
            (try hashRename(ext: "mp3", warnWhenEmpty: false)) +
            (try hashRename(ext: "mp4", warnWhenEmpty: false))
        if total == 0 {
            logger.warn("No .wav, .flac, .mp3, or .mp4 files found in '\(cli.srcDir.path)'.")
        }
    }

    func stepMP3Hash() throws {
        logger.info("Hash MP3 filenames")
        try hashRename(ext: "mp3")
    }

    func stepWAVHash() throws {
        logger.info("Hash WAV filenames")
        try hashRename(ext: "wav")
    }

    func stepM4AToMP4() throws {
        let images = try files(in: cli.srcDir) { $0.pathExtension.lowercasedASCII == "png" && $0.stem.hasSuffix("_8K") }
        guard images.count == 1, let image = images.first else {
            throw AppError("Expected exactly one *_8K.png in '\(cli.srcDir.path)'.")
        }
        let audios = try files(in: cli.srcDir, matchingExtensions: ["m4a"])
        guard audios.count == 1, let audio = audios.first else {
            throw AppError("Expected exactly one .m4a in '\(cli.srcDir.path)'.")
        }
        logger.info("M4A -> MP4: \(audio.basename) + \(image.basename)")
        _ = try renderM4AToMP4(imageFile: image, audioFile: audio, audioQCPolicy: nil)
    }

    func stepMP4ToShort() throws {
        let files = try files(in: cli.srcDir, matchingExtensions: ["mp4"]).filter { !$0.stem.hasSuffix("_Short") }
        _ = try processBatch(files: files, emptyMessage: "No .mp4 files found in '\(cli.srcDir.path)'.", failWhenEmpty: false) { file in
            self.logger.info("MP4 -> Short: \(file.basename)")
            return try self.shortenMP4(file, audioQCPolicy: nil)
        }
    }

    func execute() async throws {
        switch cli.action {
        case .album:
            try await stepAlbum()
        case .bass:
            try stepBass()
        case .hash:
            try stepUnifiedHash()
        case .loudscan:
            try stepLoudScan()
        case .loudness:
            try stepLoudness()
        case .noise:
            try stepNoise()
        case .silence:
            try stepSilence()
        case .short:
            try stepShort()
        case .doctor:
            try stepDoctor()
        case .fade:
            try stepFade()
        case .fadecut:
            try stepFadeCut()
        case .fadeout:
            try stepFadeOut()
        case .help:
            print(cli.helpText())
        case .list:
            cli.printActionList()
        case .matrix:
            print(cli.conversionMatrixText())
        case .full:
            try await stepFull()
        case .runPix:
            try await stepRunPix()
        case .aipix:
            try stepAIPix()
        case .clean:
            try cleanTransients()
        case .fadewav:
            try stepFadeWAV()
        case .flactoalbum:
            try stepFLACToAlbum()
        case .flactohash:
            try stepFLACHash()
        case .flactom4a:
            try stepFLACToM4A()
        case .flactomp3:
            try stepFLACToMP3()
        case .flactowav:
            try stepFLACToWAV()
        case .jpgtopng:
            try stepJPGToPNG()
        case .m4atomp4:
            try stepM4AToMP4()
        case .m4atoflac:
            try stepM4AToFLAC()
        case .m4atomp3:
            try stepM4AToMP3()
        case .m4atowav:
            try stepM4AToWAV()
        case .mp3clean:
            try stepMP3Clean()
        case .mp3toalbum:
            try stepMP3ToAlbum()
        case .mp3toflac:
            try stepMP3ToFLAC()
        case .mp3tohash:
            try stepMP3Hash()
        case .mp3tom4a:
            try stepMP3ToM4A()
        case .mp3toshort:
            try stepMP3ToShort()
        case .mp3towav:
            try stepMP3ToWAV()
        case .mp4toshort:
            try stepMP4ToShort()
        case .pngto2k:
            try stepPNGTo2K()
        case .pngto3k:
            try stepPNGTo3K()
        case .pngto3k1mb:
            try stepPNGTo3K1MB()
        case .pngto3k5mb:
            try stepPNGTo3K5MB()
        case .pngtojpg:
            try stepPNGToJPG()
        case .pngtonft:
            try stepPNGToNFT()
        case .pngtojpg1mb:
            try stepPNGToJPG1MB()
        case .pngtojpg2mb:
            try stepPNGToJPG2MB()
        case .pngtojpg20mb:
            try stepPNGToJPG20MB()
        case .visualsubs:
            _ = try visualSubs()
        case .wavtoalbum:
            try stepWAVToAlbum()
        case .wavtoflac:
            try stepWAVToFLAC()
        case .wavtohash:
            try stepWAVHash()
        case .wavtom4a:
            try stepWAVToM4A()
        case .wavtomp3:
            try stepWAVToMP3()
        }
    }
}
