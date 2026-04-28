import Foundation
import BW64Bridge

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

struct FullRunImageArtifacts {
    let mainVideoImage: URL
    let shortVideoImage: URL?
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
             .pngtojpg1mb, .pngtojpg2mb, .pngtojpg20mb, .runPix, .visualsubs, .full, .m4atomp4, .mp3toshort:
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
        logger.info("Profile: \(config.profileName)")
        logger.info("Scheduler profile: \(schedulerProfile.summary)")
        if cli.action == .doctor {
            try ensureWritableDirectory(cli.outDir)
            return
        }
        try ensureDirectory(cli.srcDir)
        try ensureWritableDirectory(cli.outDir)
        try ensureExecutableDependencies()
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

    func requireDirectChild(_ file: URL, of directory: URL, label: String) throws {
        let parent = file.deletingLastPathComponent().standardizedFileURL.path
        let base = directory.standardizedFileURL.path
        if parent != base {
            throw AppError("\(label) must stay directly in '\(directory.path)': \(file.path)")
        }
    }

    func resolveOutputPath(_ output: String) throws -> URL {
        let resolved = output.hasPrefix("/")
            ? URL(fileURLWithPath: output)
            : cli.outDir.appendingPathComponent(output)
        try requireDirectChild(resolved, of: cli.outDir, label: "Output path")
        return resolved
    }

    // Optional pacing between batch operations for workflows that need slower external tool churn.
    func maybeSleep() {
        guard cli.sleepSeconds > 0 else { return }
        Thread.sleep(forTimeInterval: cli.sleepSeconds)
    }

    private func discoveredFiles(in directory: URL) throws -> [URL] {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        return urls
            .filter { url in
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
                    return false
                }
                return true
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func files(in directory: URL, matchingExtensions extensions: [String]) throws -> [URL] {
        let allowed = Set(extensions.map { $0.lowercasedASCII })
        return try discoveredFiles(in: directory).filter { allowed.contains($0.pathExtension.lowercasedASCII) }
    }

    func files(in directory: URL, predicate: (URL) -> Bool) throws -> [URL] {
        try discoveredFiles(in: directory).filter(predicate)
    }

    func resolveExplicitPath(_ path: String, baseDirectory: URL) throws -> URL {
        let resolved = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : baseDirectory.appendingPathComponent(path)
        try requireDirectChild(resolved, of: baseDirectory, label: "Input path")
        return resolved
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
        let output = try resolveOutputPath(cli.outputFile ?? "\(numDots).png")
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
