import Foundation

final class RuntimeState: @unchecked Sendable {
    private let lock = NSLock()
    private var temporaryFiles: [URL] = []

    func register(tempFile: URL) {
        lock.lock()
        temporaryFiles.append(tempFile.standardizedFileURL)
        lock.unlock()
    }

    func unregister(tempFile: URL) {
        lock.lock()
        temporaryFiles.removeAll { $0.standardizedFileURL == tempFile.standardizedFileURL }
        lock.unlock()
    }

    func cleanup(fileManager: FileManager, logger: Logger) {
        lock.lock()
        let files = temporaryFiles
        temporaryFiles.removeAll()
        lock.unlock()

        for url in files {
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
                logger.debug("Removed temp file: \(url.path)")
            }
        }
    }
}

struct FileProbeFingerprint: Hashable, Sendable {
    let path: String
    let sizeBytes: UInt64
    let modifiedAtMicros: Int64
}

struct FFprobeCacheKey: Hashable, Sendable {
    let fingerprint: FileProbeFingerprint
    let selector: String
    let entries: String
}

struct AudioQCPolicyCacheKey: Hashable, Sendable {
    let name: String
    let targetLUFS: Double
    let lufsTolerance: Double
    let maxTruePeakDBTP: Double
    let maxLoudnessRange: Double
    let maxDCOffset: Double
    let maxStereoImbalanceDB: Double
    let maxClippedSamples: Int
    let minimumAnalysisSeconds: Double

    init(_ policy: AudioQCPolicy) {
        self.name = policy.name
        self.targetLUFS = policy.targetLUFS
        self.lufsTolerance = policy.lufsTolerance
        self.maxTruePeakDBTP = policy.maxTruePeakDBTP
        self.maxLoudnessRange = policy.maxLoudnessRange
        self.maxDCOffset = policy.maxDCOffset
        self.maxStereoImbalanceDB = policy.maxStereoImbalanceDB
        self.maxClippedSamples = policy.maxClippedSamples
        self.minimumAnalysisSeconds = policy.minimumAnalysisSeconds
    }
}

struct AudioQCCacheKey: Hashable, Sendable {
    let fingerprint: FileProbeFingerprint
    let policy: AudioQCPolicyCacheKey
}

enum CachedStringValue: Sendable {
    case none
    case some(String)

    init(_ value: String?) {
        self = value.map(Self.some) ?? .none
    }

    var value: String? {
        switch self {
        case .none:
            return nil
        case .some(let value):
            return value
        }
    }
}

enum CachedDimensionsValue: Sendable {
    case none
    case some(Int, Int)

    init(_ value: (Int, Int)?) {
        if let value {
            self = .some(value.0, value.1)
        } else {
            self = .none
        }
    }

    var value: (Int, Int)? {
        switch self {
        case .none:
            return nil
        case .some(let width, let height):
            return (width, height)
        }
    }
}

final class ProbeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var ffprobeValues: [FFprobeCacheKey: CachedStringValue] = [:]
    private var imageDimensions: [FileProbeFingerprint: CachedDimensionsValue] = [:]
    private var imageFormats: [FileProbeFingerprint: CachedStringValue] = [:]
    private var imageColorSpaces: [FileProbeFingerprint: CachedStringValue] = [:]
    private var audibleAudio: [FileProbeFingerprint: Bool] = [:]
    private var audioQCResults: [AudioQCCacheKey: AudioQCResult] = [:]

    func cachedFFprobeValue(key: FFprobeCacheKey, compute: () throws -> String?) throws -> String? {
        lock.lock()
        if let cached = ffprobeValues[key] {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        let value = try compute()
        lock.lock()
        ffprobeValues[key] = CachedStringValue(value)
        lock.unlock()
        return value
    }

    func cachedImageDimensions(key: FileProbeFingerprint, compute: () throws -> (Int, Int)?) throws -> (Int, Int)? {
        lock.lock()
        if let cached = imageDimensions[key] {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        let value = try compute()
        lock.lock()
        imageDimensions[key] = CachedDimensionsValue(value)
        lock.unlock()
        return value
    }

    func cachedImageFormat(key: FileProbeFingerprint, compute: () throws -> String?) throws -> String? {
        lock.lock()
        if let cached = imageFormats[key] {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        let value = try compute()
        lock.lock()
        imageFormats[key] = CachedStringValue(value)
        lock.unlock()
        return value
    }

    func cachedImageColorSpace(key: FileProbeFingerprint, compute: () throws -> String?) throws -> String? {
        lock.lock()
        if let cached = imageColorSpaces[key] {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        let value = try compute()
        lock.lock()
        imageColorSpaces[key] = CachedStringValue(value)
        lock.unlock()
        return value
    }

    func cachedAudibleResult(key: FileProbeFingerprint, compute: () throws -> Bool) throws -> Bool {
        lock.lock()
        if let cached = audibleAudio[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let value = try compute()
        lock.lock()
        audibleAudio[key] = value
        lock.unlock()
        return value
    }

    func cachedAudioQCResult(key: AudioQCCacheKey, compute: () throws -> AudioQCResult) throws -> AudioQCResult {
        lock.lock()
        if let cached = audioQCResults[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let value = try compute()
        lock.lock()
        audioQCResults[key] = value
        lock.unlock()
        return value
    }
}

struct ImageArtifacts {
    let sourcePNG: URL
    let eightK: URL
    let fourK: URL
    let threeK: URL
    let twoK: URL
}

struct AIPixOutputs: Sendable {
    let eightK: URL
    let fourK: URL
}

struct NFTOutputs: Sendable {
    let nft8K: URL
    let nft3K: URL
    let nft2K: URL
}

struct AudioArtifacts {
    let source: URL
    let wav: URL
    let m4a: URL
    let mp3: URL?
}

struct ExternalArchivalVariants: Sendable {
    let rf64FLAC: URL
    let bw64FLAC: URL
    let rf64WAV: URL
    let bw64WAV: URL
}

enum CanonicalPCMFormat: Sendable {
    case s24le
    case s32le

    var ffmpegFormat: String {
        switch self {
        case .s24le: return "s24le"
        case .s32le: return "s32le"
        }
    }

    var ffmpegCodec: String {
        switch self {
        case .s24le: return "pcm_s24le"
        case .s32le: return "pcm_s32le"
        }
    }

    var bytesPerSample: Int {
        switch self {
        case .s24le: return 3
        case .s32le: return 4
        }
    }

    var maxAllowedDelta: Int64 {
        switch self {
        case .s24le: return 0
        case .s32le: return 256
        }
    }
}

struct VisualSubsRandom {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x1234_5678_9ABC_DEF0 : seed
    }

    mutating func next() -> UInt64 {
        state = 2862933555777941757 &* state &+ 3037000493
        return state
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }
}

final class ConverterTool: @unchecked Sendable {
    let cli: CLIOptions
    let config: ProjectConfig
    let logger: Logger
    let runner: ProcessRunner
    let environment: [String: String]
    let fileManager = FileManager.default
    let state = RuntimeState()
    let probeCache = ProbeCache()
    let schedulerProfile: SchedulerProfile
    let globalJobs: AsyncSemaphore
    let imageJobs: AsyncSemaphore
    let audioJobs: AsyncSemaphore
    let videoJobs: AsyncSemaphore
    let runToken: String

    init(cli: CLIOptions, config: ProjectConfig, logger: Logger, runner: ProcessRunner, environment: [String: String]) {
        self.cli = cli
        self.config = config
        self.logger = logger
        self.runner = runner
        self.environment = environment
        self.schedulerProfile = SchedulerProfile.recommended(for: ProcessInfo.processInfo.activeProcessorCount)
        self.globalJobs = AsyncSemaphore(value: schedulerProfile.total)
        self.imageJobs = AsyncSemaphore(value: schedulerProfile.image)
        self.audioJobs = AsyncSemaphore(value: schedulerProfile.audio)
        self.videoJobs = AsyncSemaphore(value: schedulerProfile.video)
        self.runToken = "\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString.lowercasedASCII)"
    }

    func cleanupTemps() {
        state.cleanup(fileManager: fileManager, logger: logger)
    }

    func ensureExecutableDependencies() throws {
        for tool in ["awk", "sed", "ffmpeg", "ffprobe"] {
            try runner.requireExecutable(tool)
        }
        switch cli.action {
        case .aipix, .jpgtopng, .pngtojpg, .pngtonft, .pngto2k, .pngto3k, .pngto3k1mb, .pngto3k5mb,
             .pngtojpg1mb, .pngtojpg2mb, .pngtojpg20mb, .runPix, .visualsubs, .full, .m4atomp4:
            try runner.requireExecutable("magick")
        default:
            break
        }
        switch cli.action {
        case .wavtomp3, .flactomp3, .mp3towav, .mp3tom4a, .mp3clean, .mp3toalbum, .mp3tohash, .full:
            try runner.requireExecutable("ffmpeg")
        default:
            break
        }
    }

    func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppError("Directory not found: \(url.path)")
        }
    }

    func ensureWritableDirectory(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        guard fileManager.isWritableFile(atPath: url.path) else {
            throw AppError("Directory is not writable: \(url.path)")
        }
    }

    func initializeForExecution() throws {
        if cli.action == .help || cli.action == .list || cli.action == .matrix {
            return
        }
        logger.info("Scheduler profile: \(schedulerProfile.summary)")
        try ensureDirectory(cli.srcDir)
        try ensureWritableDirectory(cli.outDir)
        try ensureExecutableDependencies()
        if cli.action == .full {
            _ = try bw64WriterURL()
        }
    }

    func withImagePermit<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await globalJobs.withPermit {
            try await self.imageJobs.withPermit {
                try operation()
            }
        }
    }

    func withAudioPermit<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await globalJobs.withPermit {
            try await self.audioJobs.withPermit {
                try operation()
            }
        }
    }

    func withVideoPermit<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await globalJobs.withPermit {
            try await self.videoJobs.withPermit {
                try operation()
            }
        }
    }

    func fileSizeBytes(_ url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize {
            return UInt64(size)
        }
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        if let size = attrs[.size] as? NSNumber {
            return size.uint64Value
        }
        throw AppError("Unable to stat file size: \(url.path)")
    }

    func fileProbeFingerprint(_ url: URL) throws -> FileProbeFingerprint {
        let standardized = url.standardizedFileURL
        let sizeBytes = try fileSizeBytes(standardized)
        let values = try standardized.resourceValues(forKeys: [.contentModificationDateKey])
        let modifiedAt = values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
        let micros = Int64((modifiedAt.timeIntervalSince1970 * 1_000_000).rounded())
        return FileProbeFingerprint(path: standardized.path, sizeBytes: sizeBytes, modifiedAtMicros: micros)
    }

    func availableBytes(at url: URL) throws -> UInt64 {
        let attrs = try fileManager.attributesOfFileSystem(forPath: url.path)
        if let free = attrs[.systemFreeSize] as? NSNumber {
            return free.uint64Value
        }
        return 0
    }

    // Hidden temp names use a run-scoped namespace so source discovery never confuses them with real inputs.
    func makeTemp(in directory: URL, stem: String, ext: String) throws -> URL {
        try ensureWritableDirectory(directory)
        let safeStem = String(stem.map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let normalizedStem = safeStem.isEmpty ? "file" : safeStem
        for _ in 0 ..< 50 {
            let candidate = directory.appendingPathComponent(".converter-tmp.\(runToken).\(normalizedStem).\(UUID().uuidString)\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) {
                if fileManager.createFile(atPath: candidate.path, contents: Data()) {
                    state.register(tempFile: candidate)
                    return candidate
                }
            }
        }
        throw AppError("Failed to create unique temporary file in '\(directory.path)' (stem='\(stem)' ext='\(ext)')")
    }

    func publishTemp(_ temp: URL, to destination: URL) throws {
        try ensureWritableDirectory(destination.deletingLastPathComponent())
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temp, to: destination)
        state.unregister(tempFile: temp)
    }

    // Temp placeholders are pre-created for atomic publishing, so copy-based producers must replace them first.
    func copyFileIntoTemp(_ source: URL, temp: URL) throws {
        if fileManager.fileExists(atPath: temp.path) {
            try fileManager.removeItem(at: temp)
        }
        try fileManager.copyItem(at: source, to: temp)
    }

    func resolveOutputPath(_ output: String) -> URL {
        if output.hasPrefix("/") {
            return URL(fileURLWithPath: output)
        }
        return cli.outDir.appendingPathComponent(output)
    }

    // Optional pacing between batch operations for workflows that need slower external tool churn.
    func maybeSleep() {
        guard cli.sleepSeconds > 0 else { return }
        Thread.sleep(forTimeInterval: cli.sleepSeconds)
    }

    func files(in directory: URL, matchingExtensions extensions: [String]) throws -> [URL] {
        let allowed = Set(extensions.map { $0.lowercasedASCII })
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            .filter { url in
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
                    return false
                }
                return allowed.contains(url.pathExtension.lowercasedASCII)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func files(in directory: URL, predicate: (URL) -> Bool) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            .filter { url in
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
                    return false
                }
                return predicate(url)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func resolveExplicitPath(_ path: String, baseDirectory: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return baseDirectory.appendingPathComponent(path)
    }

    func ffprobeValue(selector: String? = nil, entries: String, file: URL) throws -> String? {
        let normalizedSelector = selector?.isEmpty == false ? selector! : ""
        let key = FFprobeCacheKey(
            fingerprint: try fileProbeFingerprint(file),
            selector: normalizedSelector,
            entries: entries
        )
        return try probeCache.cachedFFprobeValue(key: key) {
            var args = ["-v", "error"]
            if !normalizedSelector.isEmpty {
                args += ["-select_streams", normalizedSelector]
            }
            args += ["-show_entries", entries, "-of", "default=nw=1:nk=1", file.path]
            let result = try runner.run("ffprobe", args)
            return result.stdout.split(whereSeparator: \.isNewline).map(String.init).map(\.trimmed).first { !$0.isEmpty }
        }
    }

    func mediaDuration(_ file: URL) throws -> Double? {
        guard let value = try ffprobeValue(entries: "format=duration", file: file) else {
            return nil
        }
        return Double(value)
    }

    func imageDimensions(_ file: URL) throws -> (Int, Int)? {
        let fingerprint = try fileProbeFingerprint(file)
        return try probeCache.cachedImageDimensions(key: fingerprint) {
            let result = try runner.run("magick", ["identify", "-format", "%w %h", file.path])
            let fields = result.stdout.trimmed.split(separator: " ")
            guard fields.count == 2, let width = Int(fields[0]), let height = Int(fields[1]) else {
                return nil
            }
            return (width, height)
        }
    }

    func imageFormat(_ file: URL) throws -> String? {
        let fingerprint = try fileProbeFingerprint(file)
        return try probeCache.cachedImageFormat(key: fingerprint) {
            let result = try runner.run("magick", ["identify", "-format", "%m", file.path])
            return result.stdout.trimmed.isEmpty ? nil : result.stdout.trimmed
        }
    }

    func imageColorSpace(_ file: URL) throws -> String? {
        let fingerprint = try fileProbeFingerprint(file)
        return try probeCache.cachedImageColorSpace(key: fingerprint) {
            let result = try runner.run("magick", ["identify", "-format", "%[colorspace]", file.path])
            return result.stdout.trimmed.isEmpty ? nil : result.stdout.trimmed
        }
    }

    func mediaFormatName(_ file: URL) throws -> String? {
        try ffprobeValue(entries: "format=format_name", file: file)
    }

    func audioField(_ file: URL, _ field: String) throws -> String? {
        try ffprobeValue(selector: "a:0", entries: "stream=\(field)", file: file)
    }

    func videoField(_ file: URL, _ field: String) throws -> String? {
        try ffprobeValue(selector: "v:0", entries: "stream=\(field)", file: file)
    }

    func audioBitrateBps(_ file: URL) throws -> Int {
        if let streamBitrate = try audioField(file, "bit_rate"), let bitrate = Int(streamBitrate) {
            return bitrate
        }
        if let formatBitrate = try ffprobeValue(entries: "format=bit_rate", file: file), let bitrate = Int(formatBitrate) {
            return bitrate
        }
        return 0
    }

    func parseAudioDB(_ value: String?) -> Double? {
        guard let value else { return nil }
        let trimmed = value.trimmed
        if trimmed == "-inf" {
            return nil
        }
        return Double(trimmed)
    }

    func parseLoudnormJSON(from stderr: String) throws -> [String: Any] {
        guard let start = stderr.firstIndex(of: "{"), let end = stderr.lastIndex(of: "}") else {
            throw AppError("Audio loudness probe did not return JSON output.")
        }
        let jsonText = String(stderr[start ... end])
        guard let data = jsonText.data(using: .utf8) else {
            throw AppError("Audio loudness probe JSON encoding failed.")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError("Audio loudness probe JSON parsing failed.")
        }
        return object
    }

    func parseAstatsReport(from stderr: String) -> (channelMetrics: [[String: String]], overallMetrics: [String: String]) {
        enum Section {
            case none
            case channel(Int)
            case overall
        }

        var section: Section = .none
        var channels: [Int: [String: String]] = [:]
        var overall: [String: String] = [:]

        for rawLine in stderr.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmed
            guard let payload = line.components(separatedBy: "] ").last?.trimmed, !payload.isEmpty else {
                continue
            }
            if payload == "Overall" {
                section = .overall
                continue
            }
            if payload.hasPrefix("Channel:") {
                let value = payload.components(separatedBy: ":").last?.trimmed ?? ""
                section = .channel(Int(value) ?? 0)
                continue
            }
            guard let separator = payload.firstIndex(of: ":") else {
                continue
            }
            let key = String(payload[..<separator]).trimmed
            let value = String(payload[payload.index(after: separator)...]).trimmed
            switch section {
            case .channel(let index):
                channels[index, default: [:]][key] = value
            case .overall:
                overall[key] = value
            case .none:
                continue
            }
        }

        let orderedChannels = channels.keys.sorted().map { channels[$0] ?? [:] }
        return (orderedChannels, overall)
    }

    func ffmpegFilterRangeValue(_ value: String) -> String {
        switch value.lowercasedASCII {
        case "tv":
            return "limited"
        case "pc":
            return "full"
        default:
            return value
        }
    }

    func requireFormatNameContains(_ file: URL, anyOf tokens: [String], label: String) throws {
        let got = (try mediaFormatName(file) ?? "").lowercasedASCII
        guard !got.isEmpty else {
            throw AppError("\(label) probe failed: \(file.path)")
        }
        if !tokens.contains(where: { got.contains($0.lowercasedASCII) }) {
            let expected = tokens.joined(separator: ", ")
            throw AppError("\(label) mismatch for \(file.path) (got=\(got) expected one of \(expected))")
        }
    }

    @discardableResult
    func requireAudioStream(_ file: URL, allowedCodecs: [String]? = nil) throws -> String {
        let gotCodec = (try audioField(file, "codec_name") ?? "").lowercasedASCII
        guard !gotCodec.isEmpty else {
            throw AppError("Missing audio stream: \(file.path)")
        }
        if let allowedCodecs {
            let normalized = Set(allowedCodecs.map(\.lowercasedASCII))
            if !normalized.contains(gotCodec) {
                let expected = allowedCodecs.joined(separator: ", ")
                throw AppError("Audio codec mismatch for \(file.path) (got=\(gotCodec) expected one of \(expected))")
            }
        }
        return gotCodec
    }

    @discardableResult
    func requireVideoStream(_ file: URL, allowedCodecs: [String]? = nil) throws -> String {
        let gotCodec = (try videoField(file, "codec_name") ?? "").lowercasedASCII
        guard !gotCodec.isEmpty else {
            throw AppError("Missing video stream: \(file.path)")
        }
        if let allowedCodecs {
            let normalized = Set(allowedCodecs.map(\.lowercasedASCII))
            if !normalized.contains(gotCodec) {
                let expected = allowedCodecs.joined(separator: ", ")
                throw AppError("Video codec mismatch for \(file.path) (got=\(gotCodec) expected one of \(expected))")
            }
        }
        return gotCodec
    }

    func requireNoVideoStream(_ file: URL) throws {
        let gotCodec = (try videoField(file, "codec_name") ?? "").trimmed
        if !gotCodec.isEmpty {
            throw AppError("Unexpected video stream in audio file: \(file.path)")
        }
    }

    func verifyAudibleAudioTrack(_ file: URL) throws -> Bool {
        let fingerprint = try fileProbeFingerprint(file)
        return try probeCache.cachedAudibleResult(key: fingerprint) {
            let result = try runner.run(
                "ffmpeg",
                ["-hide_banner", "-nostdin", "-v", "info", "-i", file.path, "-map", "0:a:0", "-af", "volumedetect", "-f", "null", "-"],
                allowedExitCodes: [0]
            )
            let text = result.stderr
            guard let line = text.split(whereSeparator: \.isNewline).map(String.init).first(where: { $0.contains("max_volume:") }) else {
                return true
            }
            let value = line.components(separatedBy: "max_volume:").last?.trimmed.replacingOccurrences(of: " dB", with: "") ?? "0"
            if value == "-inf" {
                return false
            }
            guard let decibels = Double(value) else {
                return true
            }
            return decibels > -70
        }
    }

    func audioQCResult(for file: URL, policy: AudioQCPolicy) throws -> AudioQCResult {
        let key = AudioQCCacheKey(
            fingerprint: try fileProbeFingerprint(file),
            policy: AudioQCPolicyCacheKey(policy)
        )
        return try probeCache.cachedAudioQCResult(key: key) {
            let duration = (try mediaDuration(file)) ?? 0
            let loudnormResult = try runner.run(
                "ffmpeg",
                [
                    "-hide_banner", "-nostdin", "-v", "info",
                    "-i", file.path,
                    "-map", "0:a:0",
                    "-af", "loudnorm=I=\(String(format: "%.2f", policy.targetLUFS)):TP=\(String(format: "%.2f", policy.maxTruePeakDBTP)):LRA=\(String(format: "%.2f", policy.maxLoudnessRange)):print_format=json",
                    "-f", "null", "-"
                ],
                allowedExitCodes: [0]
            )
            let loudnorm = try parseLoudnormJSON(from: loudnormResult.stderr)
            let astatsResult = try runner.run(
                "ffmpeg",
                [
                    "-hide_banner", "-nostdin", "-v", "info",
                    "-i", file.path,
                    "-map", "0:a:0",
                    "-af", "astats=metadata=0:reset=0:measure_overall=all",
                    "-f", "null", "-"
                ],
                allowedExitCodes: [0]
            )
            let astats = parseAstatsReport(from: astatsResult.stderr)
            let channelRMS = astats.channelMetrics.compactMap { parseAudioDB($0["RMS level dB"]) }
            let channelDC = astats.channelMetrics.compactMap { Double($0["DC offset"] ?? "") }
            let peakLevelDBFS = parseAudioDB(astats.overallMetrics["Peak level dB"])
            let peakCount = Int(Double(astats.overallMetrics["Peak count"] ?? "0") ?? 0)
            let clippedSamples = (peakLevelDBFS ?? -Double.infinity) >= 0 ? peakCount : 0
            let stereoImbalance = channelRMS.count >= 2 ? abs(channelRMS[0] - channelRMS[1]) : 0
            let dcOffset = channelDC.map(abs).max() ?? abs(Double(astats.overallMetrics["DC offset"] ?? "") ?? 0)
            let volumeDetect = try runner.run(
                "ffmpeg",
                [
                    "-hide_banner", "-nostdin", "-v", "info",
                    "-t", String(format: "%.3f", max(duration, 0.5)),
                    "-i", file.path,
                    "-map", "0:a:0",
                    "-af", "volumedetect",
                    "-f", "null", "-"
                ],
                allowedExitCodes: [0]
            )
            let maxVolumeLine = volumeDetect.stderr
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .first(where: { $0.contains("max_volume:") })
            let maxVolumeDBFS = parseAudioDB(
                maxVolumeLine?
                    .components(separatedBy: "max_volume:")
                    .last?
                    .replacingOccurrences(of: " dB", with: "")
            )

            let metrics = AudioQCMetrics(
                integratedLUFS: parseAudioDB(loudnorm["input_i"] as? String),
                truePeakDBTP: parseAudioDB(loudnorm["input_tp"] as? String),
                loudnessRange: parseAudioDB(loudnorm["input_lra"] as? String),
                dcOffset: dcOffset,
                stereoImbalanceDB: stereoImbalance,
                peakLevelDBFS: peakLevelDBFS,
                clippedSamples: clippedSamples,
                maxVolumeDBFS: maxVolumeDBFS,
                analysisLimited: duration > 0 && duration < policy.minimumAnalysisSeconds
            )

            var issues: [String] = []
            if !metrics.analysisLimited, let integratedLUFS = metrics.integratedLUFS {
                if integratedLUFS < policy.minimumLUFS || integratedLUFS > policy.maximumLUFS {
                    issues.append(
                        String(
                            format: "integrated loudness %.2f LUFS outside target %.2f +/- %.2f",
                            integratedLUFS,
                            policy.targetLUFS,
                            policy.lufsTolerance
                        )
                    )
                }
            }
            if !metrics.analysisLimited, let loudnessRange = metrics.loudnessRange, loudnessRange > policy.maxLoudnessRange {
                issues.append(String(format: "loudness range %.2f exceeds max %.2f", loudnessRange, policy.maxLoudnessRange))
            }
            if let truePeak = metrics.truePeakDBTP, truePeak > policy.maxTruePeakDBTP {
                issues.append(String(format: "true peak %.2f dBTP exceeds max %.2f", truePeak, policy.maxTruePeakDBTP))
            }
            if let dcOffset = metrics.dcOffset, dcOffset > policy.maxDCOffset {
                issues.append(String(format: "DC offset %.6f exceeds max %.6f", dcOffset, policy.maxDCOffset))
            }
            if let imbalance = metrics.stereoImbalanceDB, imbalance > policy.maxStereoImbalanceDB {
                issues.append(String(format: "stereo imbalance %.2f dB exceeds max %.2f", imbalance, policy.maxStereoImbalanceDB))
            }
            if metrics.clippedSamples > policy.maxClippedSamples {
                issues.append("clipped samples \(metrics.clippedSamples) exceed max \(policy.maxClippedSamples)")
            }

            return AudioQCResult(
                policy: policy.name,
                targetLUFS: policy.targetLUFS,
                lufsTolerance: policy.lufsTolerance,
                maxTruePeakDBTP: policy.maxTruePeakDBTP,
                maxLoudnessRange: policy.maxLoudnessRange,
                maxDCOffset: policy.maxDCOffset,
                maxStereoImbalanceDB: policy.maxStereoImbalanceDB,
                maxClippedSamples: policy.maxClippedSamples,
                minimumAnalysisSeconds: policy.minimumAnalysisSeconds,
                metrics: metrics,
                passed: issues.isEmpty,
                issues: issues
            )
        }
    }

    func verifyAudioQC(_ file: URL, policy: AudioQCPolicy) throws -> AudioQCResult {
        let result = try audioQCResult(for: file, policy: policy)
        if !result.passed {
            throw AppError("Audio QC failed for \(file.path): \(result.issues.joined(separator: "; "))")
        }
        return result
    }

    func preflightImageInput(_ file: URL, expectedFormat: String? = nil) throws {
        guard fileManager.fileExists(atPath: file.path) else { throw AppError("Image input missing: \(file.path)") }
        guard try fileSizeBytes(file) > 0 else { throw AppError("Image input empty: \(file.path)") }
        _ = try runner.run("magick", ["identify", file.path])
        _ = try runner.run("magick", [file.path, "-resize", "1x1!", "null:"])
        let autoExpected: String?
        switch file.pathExtension.lowercasedASCII {
        case "png":
            autoExpected = "PNG"
        case "jpg", "jpeg":
            autoExpected = "JPEG"
        default:
            autoExpected = nil
        }
        if let expected = expectedFormat ?? autoExpected {
            let got = (try imageFormat(file) ?? "").lowercasedASCII
            if got != expected.lowercasedASCII {
                throw AppError("Image format mismatch for \(file.path) (got=\(got) expected=\(expected.lowercasedASCII))")
            }
        }
    }

    func preflightPNGInput(_ file: URL) throws {
        guard file.pathExtension.lowercasedASCII == "png" else {
            throw AppError("Expected .png input: \(file.path)")
        }
        try preflightImageInput(file, expectedFormat: "PNG")
    }

    func preflightJPEGInput(_ file: URL) throws {
        let ext = file.pathExtension.lowercasedASCII
        guard ext == "jpg" || ext == "jpeg" else {
            throw AppError("Expected .jpg or .jpeg input: \(file.path)")
        }
        try preflightImageInput(file, expectedFormat: "JPEG")
    }

    func preflightAudioInput(
        _ file: URL,
        seconds: Int? = nil,
        expectedContainerTokens: [String]? = nil,
        expectedAudioCodecs: [String]? = nil,
        requireNoVideo: Bool = true,
        requireAudible: Bool = true
    ) throws {
        guard fileManager.fileExists(atPath: file.path) else { throw AppError("Audio input missing: \(file.path)") }
        guard try fileSizeBytes(file) > 0 else { throw AppError("Audio input empty: \(file.path)") }
        if let expectedContainerTokens {
            try requireFormatNameContains(file, anyOf: expectedContainerTokens, label: "Audio container")
        }
        _ = try requireAudioStream(file, allowedCodecs: expectedAudioCodecs)
        if requireNoVideo {
            try requireNoVideoStream(file)
        }
        let probeSeconds = String(seconds ?? config.preflightSeconds)
        _ = try runner.run("ffmpeg", ["-hide_banner", "-nostdin", "-v", "error", "-xerror", "-t", probeSeconds, "-i", file.path, "-map", "0:a:0", "-f", "null", "-"])
        if requireAudible, !(try verifyAudibleAudioTrack(file)) {
            throw AppError("Audio verification failed: input appears silent or not meaningfully audible: \(file.path)")
        }
    }

    func preflightFLACInput(_ file: URL, requireAudible: Bool = true) throws {
        guard file.pathExtension.lowercasedASCII == "flac" else {
            throw AppError("Expected .flac input: \(file.path)")
        }
        try preflightAudioInput(file, expectedContainerTokens: ["flac"], expectedAudioCodecs: ["flac"], requireNoVideo: true, requireAudible: requireAudible)
    }

    func preflightMP3Input(_ file: URL, requireAudible: Bool = true, requireNoVideo: Bool = true) throws {
        guard file.pathExtension.lowercasedASCII == "mp3" else {
            throw AppError("Expected .mp3 input: \(file.path)")
        }
        try preflightAudioInput(file, expectedContainerTokens: ["mp3"], expectedAudioCodecs: ["mp3"], requireNoVideo: requireNoVideo, requireAudible: requireAudible)
    }

    func preflightM4AInput(_ file: URL, requireAudible: Bool = true) throws {
        guard file.pathExtension.lowercasedASCII == "m4a" else {
            throw AppError("Expected .m4a input: \(file.path)")
        }
        try preflightAudioInput(file, expectedContainerTokens: ["m4a", "mp4", "ipod", "mov"], expectedAudioCodecs: ["aac"], requireNoVideo: true, requireAudible: requireAudible)
    }

    func preflightWAVInput(_ file: URL, requireAudible: Bool = true) throws {
        guard file.pathExtension.lowercasedASCII == "wav" else {
            throw AppError("Expected .wav input: \(file.path)")
        }
        try verifyWAVHeader(file, expectedContainer: "ANY")
        try preflightAudioInput(file, expectedContainerTokens: ["wav"], expectedAudioCodecs: nil, requireNoVideo: true, requireAudible: requireAudible)
    }

    func preflightVideoInput(_ file: URL, seconds: Int? = nil, expectedContainerTokens: [String]? = nil, requireAudio: Bool = true, requireAudibleAudio: Bool = true) throws {
        guard fileManager.fileExists(atPath: file.path) else { throw AppError("Video input missing: \(file.path)") }
        guard try fileSizeBytes(file) > 0 else { throw AppError("Video input empty: \(file.path)") }
        if let expectedContainerTokens {
            try requireFormatNameContains(file, anyOf: expectedContainerTokens, label: "Video container")
        }
        _ = try requireVideoStream(file)
        if requireAudio {
            _ = try requireAudioStream(file)
        }
        let probeSeconds = String(seconds ?? config.preflightSeconds)
        _ = try runner.run("ffmpeg", ["-hide_banner", "-nostdin", "-v", "error", "-xerror", "-t", probeSeconds, "-i", file.path, "-f", "null", "-"])
        let audioIsAudible = try verifyAudibleAudioTrack(file)
        if requireAudio && requireAudibleAudio && !audioIsAudible {
            throw AppError("Video verification failed: audio track appears silent or not meaningfully audible: \(file.path)")
        }
    }

    func preflightMP4Input(_ file: URL, requireAudio: Bool = true, requireAudibleAudio: Bool = true) throws {
        guard file.pathExtension.lowercasedASCII == "mp4" else {
            throw AppError("Expected .mp4 input: \(file.path)")
        }
        try preflightVideoInput(file, expectedContainerTokens: ["mp4", "mov"], requireAudio: requireAudio, requireAudibleAudio: requireAudibleAudio)
    }

    func verifyImageOutput(
        _ file: URL,
        width: Int? = nil,
        height: Int? = nil,
        format: String? = nil,
        colorspace: String? = nil,
        maxBytes: Int? = nil
    ) throws {
        try preflightImageInput(file)
        guard let dimensions = try imageDimensions(file) else {
            throw AppError("Image verify probe failed: \(file.path)")
        }
        if let width, dimensions.0 != width {
            throw AppError("Image width mismatch for \(file.path) (got=\(dimensions.0) expected=\(width))")
        }
        if let height, dimensions.1 != height {
            throw AppError("Image height mismatch for \(file.path) (got=\(dimensions.1) expected=\(height))")
        }
        if let format {
            let got = try imageFormat(file)?.lowercasedASCII ?? ""
            if got != format.lowercasedASCII {
                throw AppError("Image format mismatch for \(file.path) (got=\(got) expected=\(format))")
            }
        }
        let expectedColor = colorspace ?? config.imageOutputColorSpace
        if !expectedColor.trimmed.isEmpty {
            let gotColor = try imageColorSpace(file)?.lowercasedASCII ?? ""
            if gotColor != expectedColor.lowercasedASCII {
                throw AppError("Image colorspace mismatch for \(file.path) (got=\(gotColor) expected=\(expectedColor.lowercasedASCII))")
            }
        }
        if let maxBytes {
            let size = try fileSizeBytes(file)
            if size > UInt64(maxBytes) {
                throw AppError("Image size exceeds limit for \(file.path) (got=\(size) limit=\(maxBytes))")
            }
        }
    }

    func verifyAudioOutput(
        _ file: URL,
        codec: String? = nil,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        requireAudible: Bool = true,
        qcPolicy: AudioQCPolicy? = nil
    ) throws {
        guard fileManager.fileExists(atPath: file.path) else { throw AppError("Audio output missing: \(file.path)") }
        guard try fileSizeBytes(file) > 0 else { throw AppError("Audio output empty: \(file.path)") }
        let gotCodec = try requireAudioStream(file)
        let gotRate = Int(try audioField(file, "sample_rate") ?? "")
        let gotChannels = Int(try audioField(file, "channels") ?? "")
        if let codec, gotCodec != codec.lowercasedASCII {
            throw AppError("Audio codec mismatch for \(file.path) (got=\(gotCodec) expected=\(codec.lowercasedASCII))")
        }
        if let sampleRate, gotRate != sampleRate {
            throw AppError("Audio sample rate mismatch for \(file.path) (got=\(String(describing: gotRate)) expected=\(sampleRate))")
        }
        if let channels, gotChannels != channels {
            throw AppError("Audio channels mismatch for \(file.path) (got=\(String(describing: gotChannels)) expected=\(channels))")
        }
        _ = try runner.run("ffmpeg", ["-hide_banner", "-nostdin", "-v", "error", "-xerror", "-i", file.path, "-map", "0:a:0", "-f", "null", "-"])
        if requireAudible {
            if !(try verifyAudibleAudioTrack(file)) {
                throw AppError("Audio verification failed: output appears silent: \(file.path)")
            }
        }
        if let qcPolicy {
            _ = try verifyAudioQC(file, policy: qcPolicy)
        }
    }

    func verifyVideoOutput(
        _ file: URL,
        width: Int? = nil,
        height: Int? = nil,
        codec: String? = nil,
        pixelFormat: String? = nil,
        colorPrimaries: String? = nil,
        colorTransfer: String? = nil,
        colorSpace: String? = nil,
        colorRange: String? = nil
    ) throws {
        guard fileManager.fileExists(atPath: file.path) else { throw AppError("Video output missing: \(file.path)") }
        guard try fileSizeBytes(file) > 0 else { throw AppError("Video output empty: \(file.path)") }
        try requireFormatNameContains(file, anyOf: ["mp4", "mov"], label: "Video container")
        let gotCodec = try requireVideoStream(file)
        let gotWidth = Int(try videoField(file, "width") ?? "")
        let gotHeight = Int(try videoField(file, "height") ?? "")
        let gotPixelFormat = (try videoField(file, "pix_fmt") ?? "").lowercasedASCII
        let gotPrimaries = (try videoField(file, "color_primaries") ?? "").lowercasedASCII
        let gotTransfer = (try videoField(file, "color_transfer") ?? "").lowercasedASCII
        let gotSpace = (try videoField(file, "color_space") ?? "").lowercasedASCII
        let gotRange = (try videoField(file, "color_range") ?? "").lowercasedASCII
        if let codec, gotCodec != codec.lowercasedASCII {
            throw AppError("Video codec mismatch for \(file.path) (got=\(gotCodec) expected=\(codec.lowercasedASCII))")
        }
        if let width, gotWidth != width {
            throw AppError("Video width mismatch for \(file.path) (got=\(String(describing: gotWidth)) expected=\(width))")
        }
        if let height, gotHeight != height {
            throw AppError("Video height mismatch for \(file.path) (got=\(String(describing: gotHeight)) expected=\(height))")
        }
        if let pixelFormat, gotPixelFormat != pixelFormat.lowercasedASCII {
            throw AppError("Video pixel format mismatch for \(file.path) (got=\(gotPixelFormat) expected=\(pixelFormat.lowercasedASCII))")
        }
        if let colorPrimaries, gotPrimaries != colorPrimaries.lowercasedASCII {
            throw AppError("Video color primaries mismatch for \(file.path) (got=\(gotPrimaries) expected=\(colorPrimaries.lowercasedASCII))")
        }
        if let colorTransfer, gotTransfer != colorTransfer.lowercasedASCII {
            throw AppError("Video color transfer mismatch for \(file.path) (got=\(gotTransfer) expected=\(colorTransfer.lowercasedASCII))")
        }
        if let colorSpace, gotSpace != colorSpace.lowercasedASCII {
            throw AppError("Video colorspace mismatch for \(file.path) (got=\(gotSpace) expected=\(colorSpace.lowercasedASCII))")
        }
        if let colorRange, gotRange != colorRange.lowercasedASCII {
            throw AppError("Video color range mismatch for \(file.path) (got=\(gotRange) expected=\(colorRange.lowercasedASCII))")
        }
        _ = try runner.run("ffmpeg", ["-hide_banner", "-nostdin", "-v", "error", "-xerror", "-i", file.path, "-f", "null", "-"])
    }

    func verifyWAVHeader(_ file: URL, expectedContainer: String = "RF64") throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 12) ?? Data()
        guard header.count >= 12 else {
            throw AppError("WAV header too short: \(file.path)")
        }
        let container = String(data: header.prefix(4), encoding: .ascii) ?? ""
        let format = String(data: header.subdata(in: 8 ..< 12), encoding: .ascii) ?? ""
        if format != "WAVE" {
            throw AppError("WAV format mismatch for \(file.path) (got='\(format)' expected='WAVE')")
        }
        if expectedContainer != "ANY" && container != expectedContainer {
            throw AppError("WAV container mismatch for \(file.path) (got='\(container)' expected='\(expectedContainer)')")
        }
    }

    func containsChunk(_ file: URL, chunkID: String, scanBytes: Int = 65_536) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: scanBytes) ?? Data()
        guard let needle = chunkID.data(using: .ascii), needle.count == 4 else {
            return false
        }
        return data.range(of: needle) != nil
    }

    func verifyExternalWAVVariant(_ file: URL, source: URL, expectBext: Bool) throws {
        try verifyExternalWAVStructure(file, expectBext: expectBext, qcPolicy: config.deliveryAudioQCPolicy)
        try verifyDurationMatch(source: source, output: file)
        try verifyCanonicalPCMSampleEquivalence(
            source: source,
            output: file,
            sampleRate: config.wavSampleRate,
            channels: config.wavChannels,
            label: expectBext ? "RF64 WAV (BEXT)" : "RF64 WAV"
        )
    }

    func verifyBW64WAVVariant(_ file: URL, source: URL) throws {
        try verifyBW64WAVStructure(file, qcPolicy: config.deliveryAudioQCPolicy)
        try verifyDurationMatch(source: source, output: file)
        try verifyCanonicalPCMSampleEquivalence(
            source: source,
            output: file,
            sampleRate: config.wavSampleRate,
            channels: config.wavChannels,
            label: "BW64 WAV",
            maxAllowedDifferingSamples: UInt64.max
        )
    }

    func verifyWAVStandard(_ file: URL, requireAudible: Bool = true, qcPolicy: AudioQCPolicy? = nil) throws {
        try verifyWAVHeader(file, expectedContainer: "RF64")
        try requireFormatNameContains(file, anyOf: ["wav"], label: "WAV container")
        try requireNoVideoStream(file)
        try verifyAudioOutput(file, codec: config.wavCodec, sampleRate: config.wavSampleRate, channels: config.wavChannels, requireAudible: requireAudible, qcPolicy: qcPolicy)
    }

    // Generic MP3 validation is for utility actions that should accept any structurally valid MP3.
    func verifyMP3File(_ file: URL, requireAudible: Bool = true, requireNoVideo: Bool = true, qcPolicy: AudioQCPolicy? = nil) throws {
        guard file.pathExtension.lowercasedASCII == "mp3" else {
            throw AppError("Expected .mp3 file: \(file.path)")
        }
        try requireFormatNameContains(file, anyOf: ["mp3"], label: "MP3 container")
        if requireNoVideo {
            try requireNoVideoStream(file)
        }
        try verifyAudioOutput(file, codec: "mp3", sampleRate: nil, channels: nil, requireAudible: requireAudible, qcPolicy: qcPolicy)
    }

    // Project MP3 outputs must satisfy the configured codec, sample-rate, channel, and bitrate floor.
    func verifyMP3Standard(_ file: URL, requireAudible: Bool = true, qcPolicy: AudioQCPolicy? = nil) throws {
        try verifyMP3File(file, requireAudible: requireAudible, requireNoVideo: true, qcPolicy: qcPolicy)
        let gotRate = Int(try audioField(file, "sample_rate") ?? "")
        let gotChannels = Int(try audioField(file, "channels") ?? "")
        if gotRate != config.mp3SampleRate {
            throw AppError("Audio sample rate mismatch for \(file.path) (got=\(String(describing: gotRate)) expected=\(config.mp3SampleRate))")
        }
        if gotChannels != config.mp3Channels {
            throw AppError("Audio channels mismatch for \(file.path) (got=\(String(describing: gotChannels)) expected=\(config.mp3Channels))")
        }
        let bitrate = try audioBitrateBps(file)
        if bitrate < config.mp3MinBitrateBps {
            throw AppError("MP3 bitrate below minimum (got=\(bitrate) min=\(config.mp3MinBitrateBps)): \(file.path)")
        }
    }

    func preflightWAVStandardInput(_ file: URL) throws {
        try preflightWAVInput(file)
        try verifyWAVStandard(file, qcPolicy: nil)
    }

    func verifyFLACFile(
        _ file: URL,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        requireAudible: Bool = true,
        qcPolicy: AudioQCPolicy? = nil
    ) throws {
        try preflightFLACInput(file, requireAudible: requireAudible)
        try verifyAudioOutput(file, codec: "flac", sampleRate: sampleRate, channels: channels, requireAudible: requireAudible, qcPolicy: qcPolicy)
    }

    func verifyM4AFile(
        _ file: URL,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        requireAudible: Bool = true,
        qcPolicy: AudioQCPolicy? = nil
    ) throws {
        try preflightM4AInput(file, requireAudible: requireAudible)
        try verifyAudioOutput(file, codec: "aac", sampleRate: sampleRate, channels: channels, requireAudible: requireAudible, qcPolicy: qcPolicy)
    }

    func verifyDurationMatch(source: URL, output: URL, tolerance: Double? = nil) throws {
        guard let sourceDuration = try mediaDuration(source), let outputDuration = try mediaDuration(output) else {
            throw AppError("Duration probe failed for comparison: src='\(source.path)' out='\(output.path)'")
        }
        let delta = abs(sourceDuration - outputDuration)
        if delta > (tolerance ?? config.durationToleranceSec) {
            throw AppError("Duration mismatch exceeds tolerance: src=\(sourceDuration) out=\(outputDuration) delta=\(delta) tol=\(tolerance ?? config.durationToleranceSec)")
        }
    }

    func requireAudioSampleRate(_ file: URL) throws -> Int {
        guard let rawValue = try audioField(file, "sample_rate"), let sampleRate = Int(rawValue), sampleRate > 0 else {
            throw AppError("Audio sample-rate probe failed for \(file.path)")
        }
        return sampleRate
    }

    func requireAudioChannels(_ file: URL) throws -> Int {
        guard let rawValue = try audioField(file, "channels"), let channels = Int(rawValue), channels > 0 else {
            throw AppError("Audio channel probe failed for \(file.path)")
        }
        return channels
    }

    // Decode to a canonical signed 32-bit PCM stream so lossless/container variants can be compared sample-for-sample.
    func decodeAudioToCanonicalPCM(_ source: URL, output: URL, sampleRate: Int, channels: Int) throws {
        try decodeAudioToCanonicalPCM(source, output: output, sampleRate: sampleRate, channels: channels, format: .s32le)
    }

    func decodeAudioToCanonicalPCM(_ source: URL, output: URL, sampleRate: Int, channels: Int, format: CanonicalPCMFormat) throws {
        _ = try runner.run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-i", source.path,
            "-map", "0:a:0",
            "-vn",
            "-ac", String(channels),
            "-ar", String(sampleRate),
            "-f", format.ffmpegFormat,
            "-acodec", format.ffmpegCodec,
            output.path
        ])
    }

    func littleEndianSignedSample(_ data: Data, offset: Int, format: CanonicalPCMFormat) -> Int64 {
        switch format {
        case .s24le:
            let value = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
            let signed = (value & 0x800000) != 0 ? Int64(value | 0xFF00_0000) - (1 << 32) : Int64(value)
            return signed
        case .s32le:
            let value = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
            return Int64(Int32(bitPattern: value))
        }
    }

    // Compare decoded canonical PCM samples directly so container/header differences cannot hide content drift.
    func compareCanonicalPCMFiles(_ expected: URL, _ actual: URL, format: CanonicalPCMFormat) throws -> (samples: UInt64, differingSamples: UInt64, maxDelta: Int64) {
        let bytesPerSample = format.bytesPerSample
        let expectedSize = try fileSizeBytes(expected)
        let actualSize = try fileSizeBytes(actual)
        guard expectedSize == actualSize else {
            throw AppError("Canonical PCM size mismatch (expected=\(expectedSize) actual=\(actualSize))")
        }
        guard expectedSize % UInt64(bytesPerSample) == 0 else {
            throw AppError("Canonical PCM byte count is not sample-aligned: \(expected.path)")
        }

        let expectedHandle = try FileHandle(forReadingFrom: expected)
        let actualHandle = try FileHandle(forReadingFrom: actual)
        defer {
            try? expectedHandle.close()
            try? actualHandle.close()
        }

        let chunkSize = format.bytesPerSample * 65_536
        var samples: UInt64 = 0
        var differingSamples: UInt64 = 0
        var maxDelta: Int64 = 0

        while true {
            let expectedChunk = try expectedHandle.read(upToCount: chunkSize) ?? Data()
            let actualChunk = try actualHandle.read(upToCount: chunkSize) ?? Data()
            if expectedChunk.isEmpty && actualChunk.isEmpty {
                break
            }
            guard expectedChunk.count == actualChunk.count else {
                throw AppError("Canonical PCM chunk size mismatch while comparing '\(expected.path)' and '\(actual.path)'")
            }
            guard expectedChunk.count % bytesPerSample == 0 else {
                throw AppError("Canonical PCM chunk is not sample-aligned while comparing '\(expected.path)' and '\(actual.path)'")
            }

            if expectedChunk == actualChunk {
                samples += UInt64(expectedChunk.count / bytesPerSample)
                continue
            }

            for offset in stride(from: 0, to: expectedChunk.count, by: bytesPerSample) {
                let expectedSample = littleEndianSignedSample(expectedChunk, offset: offset, format: format)
                let actualSample = littleEndianSignedSample(actualChunk, offset: offset, format: format)
                let delta = abs(expectedSample - actualSample)
                if delta > 0 {
                    differingSamples += 1
                    if delta > maxDelta {
                        maxDelta = delta
                    }
                    if delta > format.maxAllowedDelta {
                        return (samples + UInt64((offset / bytesPerSample) + 1), differingSamples, maxDelta)
                    }
                }
            }

            samples += UInt64(expectedChunk.count / bytesPerSample)
        }

        return (samples, differingSamples, maxDelta)
    }

    func verifyCanonicalPCMSampleEquivalence(
        source: URL,
        output: URL,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        label: String,
        format: CanonicalPCMFormat = .s32le,
        maxAllowedDifferingSamples: UInt64? = nil
    ) throws {
        let compareSampleRate = try sampleRate ?? requireAudioSampleRate(source)
        let compareChannels = try channels ?? requireAudioChannels(source)
        let sourcePCM = try makeTemp(in: cli.outDir, stem: "\(source.stem).canonical.source", ext: ".\(format.ffmpegFormat)")
        let outputPCM = try makeTemp(in: cli.outDir, stem: "\(output.stem).canonical.output", ext: ".\(format.ffmpegFormat)")

        defer {
            for temp in [sourcePCM, outputPCM] {
                try? fileManager.removeItem(at: temp)
                state.unregister(tempFile: temp)
            }
        }

        try decodeAudioToCanonicalPCM(source, output: sourcePCM, sampleRate: compareSampleRate, channels: compareChannels, format: format)
        try decodeAudioToCanonicalPCM(output, output: outputPCM, sampleRate: compareSampleRate, channels: compareChannels, format: format)
        let comparison = try compareCanonicalPCMFiles(sourcePCM, outputPCM, format: format)
        let allowedDifferingSamples = maxAllowedDifferingSamples ?? UInt64(max(4, compareChannels * 4))
        if comparison.differingSamples > allowedDifferingSamples || comparison.maxDelta > format.maxAllowedDelta {
            let differingDescription = allowedDifferingSamples == UInt64.max ? "unlimited" : String(allowedDifferingSamples)
            throw AppError(
                "Canonical PCM mismatch for \(label): src='\(source.path)' out='\(output.path)' differing_samples=\(comparison.differingSamples) max_delta=\(comparison.maxDelta) allowed_differing=\(differingDescription) allowed_delta=\(format.maxAllowedDelta) sample_rate=\(compareSampleRate) channels=\(compareChannels) canonical=\(format.ffmpegCodec)"
            )
        }
        logger.debug(
            "Canonical PCM match for \(label): samples=\(comparison.samples) differing=\(comparison.differingSamples) max_delta=\(comparison.maxDelta) rate=\(compareSampleRate) channels=\(compareChannels) canonical=\(format.ffmpegCodec)"
        )
    }

    func canReuseOutput(_ file: URL, verifier: () throws -> Void) -> Bool {
        guard !cli.overwrite, fileManager.fileExists(atPath: file.path) else {
            return false
        }
        do {
            try verifier()
            return true
        } catch {
            return false
        }
    }

    func stripTrailingDerivedImageSuffix(from stem: String) -> String {
        let orderedSuffixes = ["_NFT8K", "_NFT3K", "_NFT2K", "_20MB", "_5MB", "_2MB", "_1MB", "_8K", "_4K", "_3K", "_2K"]
        for suffix in orderedSuffixes where stem.hasSuffix(suffix) {
            let trimmed = String(stem.dropLast(suffix.count))
            return trimmed.isEmpty ? stem : trimmed
        }
        return stem
    }

    func replacingTrailingSuffix(in stem: String, suffix: String, replacement: String) -> String {
        if stem.hasSuffix(suffix) {
            return String(stem.dropLast(suffix.count)) + replacement
        }
        return stem + replacement
    }

    func imagePrefix(from stem: String) -> String {
        // Only strip known trailing derivative labels; preserve the rest of the stem verbatim.
        let normalized = cli.keepFullName ? stem : stripTrailingDerivedImageSuffix(from: stem)
        return cli.lowercasePrefix ? normalized.lowercasedASCII : normalized
    }

    func verifyExternalWAVStructure(_ file: URL, expectBext: Bool, qcPolicy: AudioQCPolicy? = nil) throws {
        try verifyWAVHeader(file, expectedContainer: "RF64")
        try requireFormatNameContains(file, anyOf: ["wav"], label: "WAV container")
        try requireNoVideoStream(file)
        try verifyAudioOutput(file, codec: config.wavCodec, sampleRate: config.wavSampleRate, channels: config.wavChannels, qcPolicy: qcPolicy)
        let hasBext = try containsChunk(file, chunkID: "bext")
        if hasBext != expectBext {
            let expected = expectBext ? "present" : "absent"
            let got = hasBext ? "present" : "absent"
            throw AppError("Broadcast metadata mismatch for \(file.path) (got=\(got) expected=\(expected))")
        }
    }

    func verifyBW64WAVStructure(_ file: URL, qcPolicy: AudioQCPolicy? = nil) throws {
        try verifyWAVHeader(file, expectedContainer: "BW64")
        if !(try containsChunk(file, chunkID: "ds64")) {
            throw AppError("BW64 ds64 chunk missing: \(file.path)")
        }
        try requireFormatNameContains(file, anyOf: ["wav"], label: "BW64 container")
        try requireNoVideoStream(file)
        try verifyAudioOutput(file, codec: "pcm_s32le", sampleRate: config.wavSampleRate, channels: config.wavChannels, qcPolicy: qcPolicy)
    }

    func bw64WriterURL() throws -> URL {
        if let configuredPath = environment["CONVERTER_BW64_WRITER"] {
            let url = URL(fileURLWithPath: configuredPath).standardizedFileURL
            guard fileManager.isExecutableFile(atPath: url.path) else {
                throw AppError("True BW64 writer helper is missing: \(url.path)")
            }
            return url
        }

        let candidatePaths = [
            cli.scriptDirectory.appendingPathComponent(".converter_bw64_writer"),
            cli.scriptDirectory.appendingPathComponent("Sources/.build/release/bw64_writer"),
            cli.scriptDirectory.appendingPathComponent("Sources/.build/arm64-apple-macosx/release/bw64_writer"),
            cli.scriptDirectory.appendingPathComponent("Sources/.build/apple/Products/Release/bw64_writer")
        ].map(\.standardizedFileURL)

        if let url = candidatePaths.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return url
        }

        throw AppError(
            "True BW64 writer helper is missing. Build the project with: swift build --package-path Sources -c release"
        )
    }

    func requireFFmpegEncoder(_ encoder: String) throws {
        let result = try runner.run("ffmpeg", ["-hide_banner", "-encoders"])
        let matched = result.stdout.split(whereSeparator: \.isNewline).contains { line in
            line.split(whereSeparator: \.isWhitespace).contains { String($0) == encoder }
        }
        if !matched {
            throw AppError("Required ffmpeg encoder is not available: \(encoder)")
        }
    }

    func convertJPGToPNG(_ source: URL) throws -> URL {
        try preflightJPEGInput(source)
        guard let dimensions = try imageDimensions(source) else {
            throw AppError("Unable to read dimensions: \(source.path)")
        }
        let output = cli.outDir.appendingPathComponent(source.stem).appendingPathExtension("png")
        if canReuseOutput(output, verifier: { try verifyImageOutput(output, width: dimensions.0, height: dimensions.1, format: "PNG") }) {
            logger.info("Skip existing PNG: \(output.basename)")
            return output
        }
        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".png")
        do {
            _ = try runner.run("magick", [
                source.path,
                "-auto-orient",
                "-colorspace", config.imageOutputColorSpace,
                "-define", "png:compression-level=\(config.imageJPGToPNGCompressionLevel)",
                "-strip",
                temp.path
            ])
            try verifyImageOutput(temp, width: dimensions.0, height: dimensions.1, format: "PNG")
            try publishTemp(temp, to: output)
            logger.info("Created PNG: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
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
        if canReuseOutput(output, verifier: {
            try verifyImageOutput(output, width: dimensions.0, height: dimensions.1, format: "JPEG")
        }) {
            logger.info("Skip existing \(normalizedExt.uppercased()) image: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".\(normalizedExt)")
        do {
            _ = try runner.run("magick", [
                source.path,
                "-auto-orient",
                "-colorspace", config.imageOutputColorSpace,
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

    func aipixFile(_ source: URL) throws -> AIPixOutputs {
        try preflightPNGInput(source)
        guard let dimensions = try imageDimensions(source) else {
            throw AppError("Unable to read dimensions: \(source.path)")
        }

        let prefix = imagePrefix(from: source.stem)
        let targets: [(label: String, width: Int, height: Int)] = [
            ("8K", config.image8KWidth, config.image8KHeight),
            ("4K", config.image4KWidth, config.image4KHeight)
        ]

        var outputs: [String: URL] = [:]
        for target in targets {
            let output = cli.outDir.appendingPathComponent("\(prefix)_\(target.label)").appendingPathExtension("png")
            outputs[target.label] = output
            if canReuseOutput(output, verifier: { try verifyImageOutput(output, width: target.width, height: target.height, format: "PNG") }) {
                logger.info("Skip existing \(target.label) PNG: \(output.basename)")
                continue
            }

            let temp = try makeTemp(in: cli.outDir, stem: "\(prefix)_\(target.label)", ext: ".png")
            do {
                if dimensions.0 == target.width && dimensions.1 == target.height {
                    _ = try runner.run("magick", [
                        source.path,
                        "-auto-orient",
                        "-colorspace", config.imageOutputColorSpace,
                        "-define", "png:compression-level=\(config.imageAIPixPNGCompressionLevel)",
                        "-strip",
                        temp.path
                    ])
                } else {
                    let args = [
                        source.path,
                        "-auto-orient",
                        "-colorspace", config.imageOutputColorSpace,
                        "-filter", config.imageAIPixFilter,
                        "-resize", "x\(target.height)",
                        "-gravity", "center",
                        "-background", "black",
                        "-extent", "\(target.width)x\(target.height)"
                    ]
                    let sharpSigma = max(0.0, (config.imageAIPixSharpness - 1.0) * 2.0)
                    var finalArgs = args
                    if sharpSigma > 0 {
                        finalArgs += ["-sharpen", String(format: "0x%.3f", sharpSigma)]
                    }
                    finalArgs += ["-define", "png:compression-level=\(config.imageAIPixPNGCompressionLevel)", "-strip", temp.path]
                    _ = try runner.run("magick", finalArgs)
                }
                try verifyImageOutput(temp, width: target.width, height: target.height, format: "PNG")
                try publishTemp(temp, to: output)
                logger.info("Created \(target.label) PNG: \(output.basename)")
            } catch {
                try? fileManager.removeItem(at: temp)
                state.unregister(tempFile: temp)
                throw error
            }
        }

        guard let eightK = outputs["8K"], let fourK = outputs["4K"] else {
            throw AppError("AIPIX did not produce required outputs")
        }
        return AIPixOutputs(eightK: eightK, fourK: fourK)
    }

    func squarePNGFrom8K(_ source: URL, size: Int, label: String) throws -> URL {
        try preflightPNGInput(source)
        let base = source.stem
        let outputName = replacingTrailingSuffix(in: base, suffix: "_8K", replacement: "_\(label)")
        let output = cli.outDir.appendingPathComponent(outputName).appendingPathExtension("png")
        if canReuseOutput(output, verifier: { try verifyImageOutput(output, width: size, height: size, format: "PNG") }) {
            logger.info("Skip existing \(label) PNG: \(output.basename)")
            return output
        }
        let temp = try makeTemp(in: cli.outDir, stem: outputName, ext: ".png")
        do {
            _ = try runner.run("magick", [
                source.path,
                "-auto-orient",
                "-colorspace", config.imageOutputColorSpace,
                "-resize", "\(size)x\(size)^",
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

    func jpegExtentFromPNG(_ source: URL, requiredWidth: Int, requiredHeight: Int, suffix: String, targetBytes: Int) throws -> URL {
        try preflightPNGInput(source)
        guard let dimensions = try imageDimensions(source) else {
            throw AppError("Unable to read dimensions: \(source.path)")
        }
        if dimensions.0 != requiredWidth || dimensions.1 != requiredHeight {
            throw AppError("Skipping \(source.basename): expected \(requiredWidth)x\(requiredHeight), got \(dimensions.0)x\(dimensions.1)")
        }

        let output = cli.outDir.appendingPathComponent("\(source.stem)_\(suffix)").appendingPathExtension("jpg")
        if canReuseOutput(output, verifier: { try verifyImageOutput(output, width: requiredWidth, height: requiredHeight, format: "JPEG", maxBytes: targetBytes) }) {
            logger.info("Skip existing \(suffix) JPG: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: cli.outDir, stem: "\(source.stem).\(suffix)", ext: ".jpg")
        do {
            _ = try runner.run("magick", [
                source.path,
                "-auto-orient",
                "-colorspace", config.imageOutputColorSpace,
                "-sampling-factor", config.imageJpegSamplingFactor,
                "-strip",
                "-define", "jpeg:extent=\(targetBytes)",
                temp.path
            ])
            try verifyImageOutput(temp, width: requiredWidth, height: requiredHeight, format: "JPEG", maxBytes: targetBytes)
            try publishTemp(temp, to: output)
            logger.info("Created \(suffix) JPG: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func nftFrom8K(_ source: URL) throws -> NFTOutputs {
        try preflightPNGInput(source)
        guard let dimensions = try imageDimensions(source) else {
            throw AppError("Unable to read dimensions: \(source.path)")
        }
        if dimensions.0 != config.image8KWidth || dimensions.1 != config.image8KHeight {
            throw AppError("Skipping \(source.basename): expected \(config.image8KWidth)x\(config.image8KHeight), got \(dimensions.0)x\(dimensions.1)")
        }

        let prefix = imagePrefix(from: replacingTrailingSuffix(in: source.stem, suffix: "_8K", replacement: ""))

        let nft8K = cli.outDir.appendingPathComponent("\(prefix)_NFT8K").appendingPathExtension("png")
        let nft3K = cli.outDir.appendingPathComponent("\(prefix)_NFT3K").appendingPathExtension("png")
        let nft2K = cli.outDir.appendingPathComponent("\(prefix)_NFT2K").appendingPathExtension("png")

        if canReuseOutput(nft8K, verifier: { try verifyImageOutput(nft8K, width: config.image8KWidth, height: config.image8KWidth, format: "PNG") }) &&
            canReuseOutput(nft3K, verifier: { try verifyImageOutput(nft3K, width: config.image3KSize, height: config.image3KSize, format: "PNG") }) &&
            canReuseOutput(nft2K, verifier: { try verifyImageOutput(nft2K, width: config.image2KSize, height: config.image2KSize, format: "PNG") }) {
            logger.info("Skip existing NFT set: \(prefix)")
            return NFTOutputs(nft8K: nft8K, nft3K: nft3K, nft2K: nft2K)
        }

        let temp8K = try makeTemp(in: cli.outDir, stem: "\(prefix)_NFT8K", ext: ".png")
        let temp3K = try makeTemp(in: cli.outDir, stem: "\(prefix)_NFT3K", ext: ".png")
        let temp2K = try makeTemp(in: cli.outDir, stem: "\(prefix)_NFT2K", ext: ".png")
        do {
            _ = try runner.run("magick", [
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
            _ = try runner.run("magick", [temp8K.path, "-colorspace", config.imageOutputColorSpace, "-resize", "\(config.image3KSize)x\(config.image3KSize)!", "-strip", temp3K.path])
            try verifyImageOutput(temp3K, width: config.image3KSize, height: config.image3KSize, format: "PNG")
            _ = try runner.run("magick", [temp8K.path, "-colorspace", config.imageOutputColorSpace, "-resize", "\(config.image2KSize)x\(config.image2KSize)!", "-strip", temp2K.path])
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

    func ensureStandardMP3Output(from source: URL) throws -> URL {
        let output = cli.outDir.appendingPathComponent(source.lastPathComponent)
        if source.standardizedFileURL == output.standardizedFileURL {
            try preflightMP3Input(source)
            try verifyMP3Standard(source, qcPolicy: config.deliveryAudioQCPolicy)
            return source
        }
        if canReuseOutput(output, verifier: { try verifyMP3Standard(output, qcPolicy: config.deliveryAudioQCPolicy) }) {
            return output
        }
        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".mp3")
        do {
            try copyFileIntoTemp(source, temp: temp)
            // mp3clean is a structural cleanup pass, not a mastering/remediation step.
            try verifyMP3Standard(temp, qcPolicy: nil)
            try publishTemp(temp, to: output)
            logger.info("Created MP3: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func normalizeWAVInPlace(_ source: URL) throws {
        logger.info("Normalize WAV: \(source.basename)")
        try preflightWAVInput(source)
        let temp = try makeTemp(in: source.deletingLastPathComponent(), stem: "\(source.stem).normalized", ext: ".wav")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-ac", String(config.wavChannels),
                "-ar", String(config.wavSampleRate),
                "-c:a", config.wavCodec,
                "-f", "wav",
                "-rf64", "always",
                "-write_bext", String(config.wavWriteBext),
                temp.path
            ])
            try verifyWAVStandard(temp, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: temp)
            try verifyCanonicalPCMSampleEquivalence(
                source: source,
                output: temp,
                sampleRate: config.wavSampleRate,
                channels: config.wavChannels,
                label: "Normalized WAV"
            )
            try publishTemp(temp, to: source)
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func estimateWAVBytes(duration: Double, channels: Int) -> UInt64 {
        if duration <= 0 || channels <= 0 { return 0 }
        return UInt64((duration * Double(config.wavSampleRate * channels * 4)).rounded()) + 1_048_576
    }

    // Use the stricter WAV contract only for WAV sources; other audio inputs use generic media preflight.
    func preflightAudioSourceForTranscode(_ source: URL) throws {
        switch source.pathExtension.lowercasedASCII {
        case "wav":
            try preflightWAVInput(source)
        case "flac":
            try preflightFLACInput(source)
        case "mp3":
            try preflightMP3Input(source)
        case "m4a":
            try preflightM4AInput(source)
        default:
            throw AppError("Unsupported audio input type: \(source.path)")
        }
    }

    // Convert any supported audio source into the project WAV standard.
    func convertAudioToWAV(_ source: URL) throws -> URL {
        try preflightAudioSourceForTranscode(source)
        let output = cli.outDir.appendingPathComponent(source.stem).appendingPathExtension("wav")
        if canReuseOutput(output, verifier: {
            try verifyWAVStandard(output, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: output)
            try verifyCanonicalPCMSampleEquivalence(
                source: source,
                output: output,
                sampleRate: config.wavSampleRate,
                channels: config.wavChannels,
                label: "WAV output"
            )
        }) {
            logger.info("Skip existing WAV: \(output.basename)")
            return output
        }
        if let duration = try mediaDuration(source) {
            let need = estimateWAVBytes(duration: duration, channels: config.wavChannels)
            let free = try availableBytes(at: cli.outDir)
            if need > 0 && free < need {
                throw AppError("Low free space for \(source.basename): avail=\(free) need~\(need)")
            }
        }
        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".wav")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-ac", String(config.wavChannels),
                "-ar", String(config.wavSampleRate),
                "-c:a", config.wavCodec,
                "-f", "wav",
                "-rf64", "always",
                "-write_bext", String(config.wavWriteBext),
                temp.path
            ])
            try verifyWAVStandard(temp, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: temp)
            try verifyCanonicalPCMSampleEquivalence(
                source: source,
                output: temp,
                sampleRate: config.wavSampleRate,
                channels: config.wavChannels,
                label: "WAV output"
            )
            try publishTemp(temp, to: output)
            logger.info("Created WAV: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func convertFLACToWAV(_ source: URL) throws -> URL {
        try convertAudioToWAV(source)
    }

    func convertMP3ToWAV(_ source: URL) throws -> URL {
        try convertAudioToWAV(source)
    }

    func convertM4AToWAV(_ source: URL) throws -> URL {
        try convertAudioToWAV(source)
    }

    func convertWAVToM4A(_ source: URL) throws -> URL {
        try preflightWAVInput(source)
        try requireFFmpegEncoder("aac")
        let output = cli.outDir.appendingPathComponent(source.stem).appendingPathExtension("m4a")
        if canReuseOutput(output, verifier: {
            try verifyM4AFile(output, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: output)
        }) {
            logger.info("Skip existing M4A: \(output.basename)")
            return output
        }
        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".m4a")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-c:a", "aac",
                "-b:a", config.m4aBitrate,
                "-ar", String(config.m4aSampleRate),
                "-ac", String(config.m4aChannels),
                "-vn",
                temp.path
            ])
            try verifyM4AFile(temp, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: temp)
            try publishTemp(temp, to: output)
            logger.info("Created M4A: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func convertAudioToM4A(_ source: URL) throws -> URL {
        try preflightAudioSourceForTranscode(source)
        try requireFFmpegEncoder("aac")
        let output = cli.outDir.appendingPathComponent(source.stem).appendingPathExtension("m4a")
        if canReuseOutput(output, verifier: {
            try verifyM4AFile(output, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: output)
        }) {
            logger.info("Skip existing M4A: \(output.basename)")
            return output
        }
        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".m4a")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-c:a", "aac",
                "-b:a", config.m4aBitrate,
                "-ar", String(config.m4aSampleRate),
                "-ac", String(config.m4aChannels),
                "-vn",
                temp.path
            ])
            try verifyM4AFile(temp, sampleRate: config.m4aSampleRate, channels: config.m4aChannels, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: temp)
            try publishTemp(temp, to: output)
            logger.info("Created M4A: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    // Convert any supported audio source into project-standard MP3.
    func convertAudioToMP3(_ source: URL) throws -> URL {
        try preflightAudioSourceForTranscode(source)
        try requireFFmpegEncoder("libmp3lame")
        let output = cli.outDir.appendingPathComponent(source.stem).appendingPathExtension("mp3")
        if canReuseOutput(output, verifier: {
            try verifyMP3Standard(output, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: output)
        }) {
            logger.info("Skip existing MP3: \(output.basename)")
            return output
        }
        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".mp3")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-ar", String(config.mp3SampleRate),
                "-ac", String(config.mp3Channels),
                "-c:a", "libmp3lame",
                "-b:a", config.mp3Bitrate,
                temp.path
            ])
            try verifyMP3Standard(temp, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: temp)
            try publishTemp(temp, to: output)
            logger.info("Created MP3: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func convertWAVToMP3(_ source: URL) throws -> URL {
        try convertAudioToMP3(source)
    }

    func convertFLACToMP3(_ source: URL) throws -> URL {
        try convertAudioToMP3(source)
    }

    func convertM4AToMP3(_ source: URL) throws -> URL {
        try convertAudioToMP3(source)
    }

    // Convert any supported audio source into FLAC.
    func convertAudioToFLAC(_ source: URL) throws -> URL {
        try preflightAudioSourceForTranscode(source)
        let output = cli.outDir.appendingPathComponent(source.stem).appendingPathExtension("flac")
        if canReuseOutput(output, verifier: {
            try verifyFLACFile(output, sampleRate: config.flacSampleRate, channels: config.flacChannels, requireAudible: true, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: output)
            try verifyCanonicalPCMSampleEquivalence(
                source: source,
                output: output,
                sampleRate: config.flacSampleRate,
                channels: config.flacChannels,
                label: "FLAC output",
                format: .s24le
            )
        }) {
            logger.info("Skip existing FLAC: \(output.basename)")
            return output
        }
        let temp = try makeTemp(in: cli.outDir, stem: source.stem, ext: ".flac")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-vn",
                "-ac", String(config.flacChannels),
                "-ar", String(config.flacSampleRate),
                "-c:a", "flac",
                "-compression_level", String(config.flacCompressionLevel),
                "-map_metadata", "0",
                temp.path
            ])
            try verifyFLACFile(temp, sampleRate: config.flacSampleRate, channels: config.flacChannels, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: temp)
            try verifyCanonicalPCMSampleEquivalence(
                source: source,
                output: temp,
                sampleRate: config.flacSampleRate,
                channels: config.flacChannels,
                label: "FLAC output",
                format: .s24le
            )
            try publishTemp(temp, to: output)
            logger.info("Created FLAC: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func convertWAVToFLAC(_ source: URL) throws -> URL {
        try convertAudioToFLAC(source)
    }

    func convertMP3ToFLAC(_ source: URL) throws -> URL {
        try convertAudioToFLAC(source)
    }

    func convertM4AToFLAC(_ source: URL) throws -> URL {
        try convertAudioToFLAC(source)
    }

    func cleanMP3(_ source: URL) throws {
        try preflightMP3Input(source, requireAudible: false, requireNoVideo: false)
        let temp = try makeTemp(in: source.deletingLastPathComponent(), stem: "\(source.stem).notags", ext: ".mp3")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-vn",
                "-sn",
                "-dn",
                "-map", "0:a:0",
                "-c:a", "copy",
                "-map_metadata", "-1",
                "-map_chapters", "-1",
                temp.path
            ])
            // Metadata cleanup must preserve the original audio stream even if delivery policy would reject it.
            try verifyMP3File(temp, requireAudible: false, requireNoVideo: true, qcPolicy: nil)
            try verifyDurationMatch(source: source, output: temp)
            try publishTemp(temp, to: source)
            logger.info("Cleaned MP3 metadata: \(source.basename)")
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func fadeWAV(_ source: URL) throws -> URL {
        try preflightWAVInput(source)
        guard let duration = try mediaDuration(source) else {
            throw AppError("Unable to read numeric WAV duration from: \(source.path)")
        }
        let fadeStart = max(0, duration - Double(config.wavFadeDur))
        let output = cli.outDir.appendingPathComponent("\(source.stem)_Faded_rf64").appendingPathExtension("wav")
        if canReuseOutput(output, verifier: {
            try verifyWAVStandard(output, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: output)
        }) {
            logger.info("Skip existing faded WAV: \(output.basename)")
            return output
        }
        let temp = try makeTemp(in: cli.outDir, stem: output.stem, ext: ".wav")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-af", "afade=t=out:st=\(String(format: "%.6f", fadeStart)):d=\(config.wavFadeDur)",
                "-c:a", config.wavCodec,
                "-ar", String(config.wavSampleRate),
                "-ac", String(config.wavChannels),
                "-f", "wav",
                "-rf64", "always",
                "-write_bext", String(config.wavWriteBext),
                temp.path
            ])
            try verifyWAVStandard(temp, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: temp)
            try publishTemp(temp, to: output)
            logger.info("Created faded WAV: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func createExternalFLACVariant(source: URL, output: URL) throws -> URL {
        if canReuseOutput(output, verifier: {
            try verifyFLACFile(output, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: output)
            try verifyCanonicalPCMSampleEquivalence(source: source, output: output, label: "External FLAC", format: .s24le)
        }) {
            logger.info("Skip existing external FLAC: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: output.deletingLastPathComponent(), stem: output.stem, ext: ".flac")
        do {
            let ext = source.pathExtension.lowercasedASCII
            if ext == "flac" {
                try copyFileIntoTemp(source, temp: temp)
            } else {
                _ = try runner.run("ffmpeg", [
                    "-hide_banner", "-nostdin", "-v", "error", "-y",
                    "-i", source.path,
                    "-map", "0:a:0",
                    "-c:a", "flac",
                    "-compression_level", String(config.flacCompressionLevel),
                    temp.path
                ])
            }
            try verifyFLACFile(temp, qcPolicy: config.deliveryAudioQCPolicy)
            try verifyDurationMatch(source: source, output: temp)
            try verifyCanonicalPCMSampleEquivalence(source: source, output: temp, label: "External FLAC", format: .s24le)
            try publishTemp(temp, to: output)
            logger.info("Created external FLAC: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func createExternalWAVVariant(source: URL, output: URL, writeBext: Bool) throws -> URL {
        if canReuseOutput(output, verifier: {
            try verifyExternalWAVVariant(output, source: source, expectBext: writeBext)
        }) {
            logger.info("Skip existing external WAV: \(output.basename)")
            return output
        }

        let temp = try makeTemp(in: output.deletingLastPathComponent(), stem: output.stem, ext: ".wav")
        do {
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-i", source.path,
                "-map", "0:a:0",
                "-ac", String(config.wavChannels),
                "-ar", String(config.wavSampleRate),
                "-c:a", config.wavCodec,
                "-f", "wav",
                "-rf64", "always",
                "-write_bext", writeBext ? "1" : "0",
                temp.path
            ])
            try verifyExternalWAVVariant(temp, source: source, expectBext: writeBext)
            try publishTemp(temp, to: output)
            logger.info("Created external WAV: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func createExternalBW64WAVVariant(source: URL, output: URL) throws -> URL {
        if canReuseOutput(output, verifier: {
            try verifyBW64WAVVariant(output, source: source)
        }) {
            logger.info("Skip existing external BW64 WAV: \(output.basename)")
            return output
        }

        let helper = try bw64WriterURL()
        let temp = try makeTemp(in: output.deletingLastPathComponent(), stem: output.stem, ext: ".wav")
        do {
            _ = try runner.runPipeline(
                producerExecutable: "ffmpeg",
                producerArguments: [
                    "-hide_banner", "-nostdin", "-v", "error", "-y",
                    "-i", source.path,
                    "-map", "0:a:0",
                    "-ac", String(config.wavChannels),
                    "-ar", String(config.wavSampleRate),
                    "-f", "f32le",
                    "-acodec", "pcm_f32le",
                    "-"
                ],
                consumerExecutable: helper.path,
                consumerArguments: [
                    "--output", temp.path,
                    "--channels", String(config.wavChannels),
                    "--sample-rate", String(config.wavSampleRate),
                    "--bit-depth", "32"
                ]
            )
            try verifyBW64WAVVariant(temp, source: source)
            try publishTemp(temp, to: output)
            logger.info("Created external BW64 WAV: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func generateExternalArchivalVariants(baseName: String, highQualitySource: URL) throws -> ExternalArchivalVariants {
        let rf64FLAC = cli.outDir.appendingPathComponent("\(baseName)_RF64").appendingPathExtension("flac")
        let bw64FLAC = cli.outDir.appendingPathComponent("\(baseName)_BW64").appendingPathExtension("flac")
        let rf64WAV = cli.outDir.appendingPathComponent("\(baseName)_RF64").appendingPathExtension("wav")
        let bw64WAV = cli.outDir.appendingPathComponent("\(baseName)_BW64").appendingPathExtension("wav")

        let createdRF64FLAC = try createExternalFLACVariant(source: highQualitySource, output: rf64FLAC)
        let createdBW64FLAC = try createExternalFLACVariant(source: highQualitySource, output: bw64FLAC)
        let createdRF64WAV = try createExternalWAVVariant(source: highQualitySource, output: rf64WAV, writeBext: false)
        let createdBW64WAV = try createExternalBW64WAVVariant(source: highQualitySource, output: bw64WAV)

        return ExternalArchivalVariants(
            rf64FLAC: createdRF64FLAC,
            bw64FLAC: createdBW64FLAC,
            rf64WAV: createdRF64WAV,
            bw64WAV: createdBW64WAV
        )
    }

    func crc32(for file: URL) throws -> String {
        let polynomial: UInt32 = 0xEDB88320
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0 ..< 256 {
            var value = UInt32(index)
            for _ in 0 ..< 8 {
                value = (value & 1) == 1 ? polynomial ^ (value >> 1) : (value >> 1)
            }
            table[index] = value
        }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var crc: UInt32 = 0
        while autoreleasepool(invoking: {
            let data = try? handle.read(upToCount: config.crcChunkBytes)
            guard let chunk = data, !chunk.isEmpty else {
                return false
            }
            crc = chunk.reduce(crc) { current, byte in
                let idx = Int((current ^ UInt32(byte)) & 0xFF)
                return table[idx] ^ (current >> 8)
            }
            return true
        }) {}

        return String(format: "%08X", crc)
    }

    func hashRename(ext: String) throws {
        let files = try self.files(in: cli.srcDir, matchingExtensions: [ext])
        if files.isEmpty {
            logger.warn("No .\(ext) files found in '\(cli.srcDir.path)'.")
            return
        }
        for file in files {
            switch ext {
            case "flac":
                try preflightFLACInput(file)
            case "mp3":
                try preflightMP3Input(file, requireAudible: false, requireNoVideo: false)
            default:
                break
            }
            let hash = try crc32(for: file)
            let destination = cli.outDir.appendingPathComponent(hash).appendingPathExtension(ext)
            if file.standardizedFileURL == destination.standardizedFileURL {
                logger.info("Skip already-hashed \(ext): \(file.basename)")
                continue
            }
            if fileManager.fileExists(atPath: destination.path), !cli.overwrite {
                logger.warn("Destination exists, skipping: \(destination.basename)")
                continue
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try ensureWritableDirectory(destination.deletingLastPathComponent())
            try fileManager.moveItem(at: file, to: destination)
            logger.info("Renamed \(ext): \(file.basename) -> \(destination.basename)")
        }
    }

    func hashCopyWAV() throws {
        let files = try self.files(in: cli.srcDir, matchingExtensions: ["wav"])
        if files.isEmpty {
            logger.warn("No .wav files found in '\(cli.srcDir.path)'.")
            return
        }
        for file in files {
            try preflightWAVInput(file)
            let hash = try crc32(for: file)
            let destination = cli.outDir.appendingPathComponent(hash).appendingPathExtension("wav")
            if fileManager.fileExists(atPath: destination.path), !cli.overwrite {
                logger.info("Skip existing hashed WAV: \(destination.basename)")
                continue
            }
            let temp = try makeTemp(in: cli.outDir, stem: hash, ext: ".wav")
            do {
                try copyFileIntoTemp(file, temp: temp)
                if try crc32(for: temp) != hash {
                    throw AppError("CRC verification failed for copied WAV: \(destination.path)")
                }
                try publishTemp(temp, to: destination)
                logger.info("Copied hashed WAV: \(destination.basename)")
            } catch {
                try? fileManager.removeItem(at: temp)
                state.unregister(tempFile: temp)
                throw error
            }
        }
    }

    func sortNatural(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func buildAlbum(from entries: [URL], output: URL) throws -> URL {
        guard !entries.isEmpty else {
            throw AppError("No valid album inputs provided.")
        }
        let channelLayout = config.wavChannels == 1 ? "mono" : "stereo"
        try ensureWritableDirectory(output.deletingLastPathComponent())
        let temp = try makeTemp(in: output.deletingLastPathComponent(), stem: output.stem, ext: ".wav")

        var ffArgs: [String] = ["-hide_banner", "-nostdin", "-v", "error", "-y"]
        for file in entries {
            ffArgs += ["-i", file.path]
        }

        var filter = ""
        var concatInputs = ""
        for index in entries.indices {
            filter += "[\(index):a]aresample=\(config.wavSampleRate),aformat=sample_fmts=flt:channel_layouts=\(channelLayout)[a\(index)];"
        }
        for index in 0 ..< max(entries.count - 1, 0) {
            filter += "anullsrc=r=\(config.wavSampleRate):cl=\(channelLayout):d=\(config.albumSilenceSecs),aformat=sample_fmts=flt:channel_layouts=\(channelLayout)[s\(index)];"
        }
        for index in entries.indices {
            concatInputs += "[a\(index)]"
            if index < entries.count - 1 {
                concatInputs += "[s\(index)]"
            } else if cli.trailingSilence {
                let silenceIndex = entries.count - 1
                filter += "anullsrc=r=\(config.wavSampleRate):cl=\(channelLayout):d=\(config.albumSilenceSecs),aformat=sample_fmts=flt:channel_layouts=\(channelLayout)[s\(silenceIndex)];"
                concatInputs += "[s\(silenceIndex)]"
            }
        }

        let segments = concatInputs.filter { $0 == "[" }.count
        filter += "\(concatInputs)concat=n=\(segments):v=0:a=1[out]"
        ffArgs += [
            "-filter_complex", filter,
            "-map", "[out]",
            "-ar", String(config.wavSampleRate),
            "-ac", String(config.wavChannels),
            "-c:a", config.wavCodec,
            "-f", "wav",
            "-rf64", "always",
            "-write_bext", String(config.wavWriteBext),
            temp.path
        ]

        do {
            _ = try runner.run("ffmpeg", ffArgs)
            try verifyWAVStandard(temp, qcPolicy: config.deliveryAudioQCPolicy)
            try publishTemp(temp, to: output)
            logger.info("Created album WAV: \(output.path)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func buildAlbumFromAlbumFile(extension ext: String, defaultOutputName: String) throws -> URL {
        let albumPath = cli.scriptDirectory.appendingPathComponent("album.txt")
        guard fileManager.fileExists(atPath: albumPath.path) else {
            throw AppError("Missing album file: \(albumPath.path)")
        }
        let text = try String(contentsOf: albumPath, encoding: .utf8)
        var entries: [URL] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmed
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            let candidateName = line.lowercasedASCII.hasSuffix(".\(ext)") ? line : line + ".\(ext)"
            let file = resolveExplicitPath(candidateName, baseDirectory: cli.srcDir)
            guard fileManager.fileExists(atPath: file.path) else {
                logger.warn("Missing track, skipping: \(file.path)")
                continue
            }
            if ext == "wav" {
                try preflightWAVInput(file)
            } else {
                switch ext {
                case "mp3":
                    try preflightMP3Input(file)
                case "flac":
                    try preflightFLACInput(file)
                case "m4a":
                    try preflightM4AInput(file)
                default:
                    try preflightAudioInput(file)
                }
            }
            entries.append(file)
        }
        guard !entries.isEmpty else {
            throw AppError("No valid tracks found in '\(albumPath.path)'.")
        }
        let output = resolveOutputPath(cli.outputFile ?? defaultOutputName)
        return try buildAlbum(from: entries, output: output)
    }

    func buildAlbumFromFLACDirectory() throws -> URL {
        let flacs = try sortNatural(files(in: cli.srcDir, matchingExtensions: ["flac"]))
        if flacs.isEmpty {
            throw AppError("No .flac files found in '\(cli.srcDir.path)'.")
        }
        for file in flacs {
            try preflightFLACInput(file)
        }
        let output = resolveOutputPath(cli.outputFile ?? "album.wav")
        return try buildAlbum(from: flacs, output: output)
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
        try requireFFmpegEncoder(config.videoMP4Encoder)
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
        let temp = try makeTemp(in: output.deletingLastPathComponent(), stem: output.stem, ext: ".mp4")
        do {
            let videoFilter =
                "scale=\(config.videoMP4Width):\(config.videoMP4Height):flags=\(config.videoMP4ScaleFilter)," +
                "format=\(config.videoMP4PixelFormat)," +
                "setparams=color_primaries=\(config.videoColorPrimaries):color_trc=\(config.videoColorTransfer):colorspace=\(config.videoColorSpace):range=\(ffmpegFilterRangeValue(config.videoColorRange))"
            var ffmpegArgs = [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-loop", "1",
                "-framerate", config.videoMP4InputFPS,
                "-i", imageFile.path,
                "-i", audioFile.path,
                "-t", String(format: "%.6f", duration),
                "-vf", videoFilter,
                "-c:v", config.videoMP4Encoder,
                "-q:v", config.videoMP4VTQuality,
                "-color_primaries", config.videoColorPrimaries,
                "-color_trc", config.videoColorTransfer,
                "-colorspace", config.videoColorSpace,
                "-color_range", config.videoColorRange,
                "-tag:v", config.videoMP4Tag,
                "-shortest",
                "-movflags", "+faststart",
                temp.path
            ]
            if canCopyAAC {
                ffmpegArgs.insert(contentsOf: ["-c:a", "copy"], at: ffmpegArgs.count - 3)
            } else {
                try requireFFmpegEncoder("aac")
                ffmpegArgs.insert(contentsOf: [
                    "-c:a", "aac",
                    "-b:a", config.videoMP4AudioBitrate,
                    "-ar", String(config.videoMP4AudioSampleRate)
                ], at: ffmpegArgs.count - 3)
            }
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
            logger.info("Created MP4: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func shortenMP4(_ input: URL) throws -> URL {
        try preflightMP4Input(input, requireAudio: true, requireAudibleAudio: true)
        try requireFFmpegEncoder(config.shortMP4VideoCodec)
        try requireFFmpegEncoder("aac")
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
        }) {
            logger.info("Skip existing short MP4: \(output.basename)")
            return output
        }
        let temp = try makeTemp(in: cli.outDir, stem: output.stem, ext: ".mp4")
        do {
            let shortFilter =
                "crop=ih*9/16:ih," +
                "fps=\(config.shortMP4FPS)," +
                "scale=\(config.shortMP4ScaleW):\(config.shortMP4ScaleH)," +
                "format=\(config.shortMP4PixelFormat)," +
                "setparams=color_primaries=\(config.videoColorPrimaries):color_trc=\(config.videoColorTransfer):colorspace=\(config.videoColorSpace):range=\(ffmpegFilterRangeValue(config.videoColorRange))"
            _ = try runner.run("ffmpeg", [
                "-hide_banner", "-nostdin", "-v", "error", "-y",
                "-ss", "0",
                "-t", config.shortMP4ClipSeconds,
                "-i", input.path,
                "-vf", shortFilter,
                "-c:v", config.shortMP4VideoCodec,
                "-preset", config.shortMP4VideoPreset,
                "-crf", config.shortMP4VideoCRF,
                "-pix_fmt", config.shortMP4PixelFormat,
                "-color_primaries", config.videoColorPrimaries,
                "-color_trc", config.videoColorTransfer,
                "-colorspace", config.videoColorSpace,
                "-color_range", config.videoColorRange,
                "-c:a", "aac",
                "-b:a", config.shortMP4AudioBitrate,
                "-ar", String(config.shortMP4AudioSampleRate),
                temp.path
            ])
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
            try publishTemp(temp, to: output)
            logger.info("Created short MP4: \(output.basename)")
            return output
        } catch {
            try? fileManager.removeItem(at: temp)
            state.unregister(tempFile: temp)
            throw error
        }
    }

    func cleanTransients() throws {
        let patterns = [".w64", ".log", ".tsv"]
        let files = try fileManager.contentsOfDirectory(at: cli.outDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        for file in files {
            if patterns.contains(where: { file.lastPathComponent.hasSuffix($0) }) {
                try fileManager.removeItem(at: file)
                logger.info("Removed transient file: \(file.basename)")
            }
        }
        let all = try fileManager.contentsOfDirectory(at: cli.outDir, includingPropertiesForKeys: [.isRegularFileKey], options: [])
        for file in all where file.lastPathComponent.hasPrefix(".") && file.lastPathComponent.contains(".normalized") {
            try? fileManager.removeItem(at: file)
            logger.info("Removed transient file: \(file.basename)")
        }
    }

    func visualSubs() throws -> URL {
        try runner.requireExecutable("magick")
        let width = config.image8KWidth
        let height = config.image8KHeight
        let numDots = cli.numDots ?? Int(cli.actionArgs.first ?? "") ?? 0
        if numDots <= 0 {
            throw AppError("NUM_DOTS must be a positive integer")
        }
        if cli.dotSize <= 0 || cli.maxAttempts <= 0 {
            throw AppError("DOT_SIZE and MAX_ATTEMPTS must be positive integers")
        }
        let output = resolveOutputPath(cli.outputFile ?? "\(numDots).png")
        let radius = cli.dotSize / 2
        var rng = VisualSubsRandom(seed: cli.seed ?? UInt64(Date().timeIntervalSince1970))
        let cellSize = max(1, cli.dotSize)
        var occupancy: [String: [(Int, Int)]] = [:]

        func cellKey(x: Int, y: Int) -> String {
            "\(x):\(y)"
        }

        func isOccupied(x: Int, y: Int) -> Bool {
            let cellX = x / cellSize
            let cellY = y / cellSize
            for scanX in (cellX - 1) ... (cellX + 1) {
                for scanY in (cellY - 1) ... (cellY + 1) {
                    for other in occupancy[cellKey(x: scanX, y: scanY)] ?? [] {
                        let dx = Double(x - other.0)
                        let dy = Double(y - other.1)
                        if sqrt(dx * dx + dy * dy) < Double(cli.dotSize) {
                            return true
                        }
                    }
                }
            }
            return false
        }

        func register(x: Int, y: Int) {
            occupancy[cellKey(x: x / cellSize, y: y / cellSize), default: []].append((x, y))
        }

        let centerX = width / 2
        let centerY = height / 2
        register(x: centerX, y: centerY)
        var drawScript = "fill red\ncircle \(centerX),\(centerY) \(centerX + radius),\(centerY)\n"

        for _ in 0 ..< numDots {
            var placed = false
            for _ in 0 ..< cli.maxAttempts {
                let x = rng.nextInt(in: radius ... max(radius, width - radius - 1))
                let y = rng.nextInt(in: radius ... max(radius, height - radius - 1))
                if !isOccupied(x: x, y: y) {
                    register(x: x, y: y)
                    drawScript += "fill black\ncircle \(x),\(y) \(x + radius),\(y)\n"
                    placed = true
                    break
                }
            }
            if !placed {
                throw AppError("Could not place all dots without overlap.")
            }
        }

        try ensureWritableDirectory(output.deletingLastPathComponent())
        let drawFile = try makeTemp(in: output.deletingLastPathComponent(), stem: "visualsubs_\(numDots)", ext: ".mvg")
        let tempOutput = try makeTemp(in: output.deletingLastPathComponent(), stem: output.stem, ext: ".png")
        defer {
            try? fileManager.removeItem(at: drawFile)
            state.unregister(tempFile: drawFile)
        }
        do {
            try drawScript.write(to: drawFile, atomically: true, encoding: .utf8)
            _ = try runner.run("magick", [
                "-size", "\(width)x\(height)",
                "canvas:white",
                "-colorspace", config.imageOutputColorSpace,
                "-draw", "@\(drawFile.path)",
                tempOutput.path
            ])
            try verifyImageOutput(tempOutput, width: width, height: height, format: "PNG")
            try publishTemp(tempOutput, to: output)
            if cli.openAfterCreate {
                if let opener = try? runner.resolveExecutable(named: "open") {
                    _ = try? runner.run(opener.path, [output.path])
                }
            }
            logger.info("Created visualsubs PNG: \(output.path)")
            return output
        } catch {
            try? fileManager.removeItem(at: tempOutput)
            state.unregister(tempFile: tempOutput)
            throw error
        }
    }
}
