import Foundation
import XCTest
@testable import converter

enum JobClass: String, Sendable {
    case image
    case audio
    case video
}

// IntegrationWorkspace builds an isolated project root that mirrors the real converter layout.
final class IntegrationWorkspace {
    let root: URL
    let output: URL
    let environment: [String: String]
    private let fileManager = FileManager.default

    init(inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment) throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("converter-tests.\(UUID().uuidString)", isDirectory: true)
        output = root.appendingPathComponent("Output", isDirectory: true)
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        try Self.defaultConfig.write(to: root.appendingPathComponent("config.txt"), atomically: true, encoding: .utf8)
        try "# test album\n".write(to: root.appendingPathComponent("album.txt"), atomically: true, encoding: .utf8)

        environment = Self.sanitizedEnvironment(inheritedEnvironment)
    }

    // audit #0031: CLIOptions.parse and ProjectConfig.load honour these host-shell overrides. A developer
    // who exports them (a common converter setup) would otherwise redirect every test at real user
    // directories, so the workspace drops them and keeps everything else (PATH above all).
    // Everything converter reads from the environment: the directory/config/debug overrides
    // (CLI.swift) and every config key, which ProjectConfig.load lets the environment override.
    // A developer exporting PROFILE or an AUDIO_QC_* key must not change what a test measures.
    static let hostOverrideKeys: Set<String> =
        Set(["OUTPUT_DIR", "SRC_DIR", "OUT_DIR", "CONFIG_FILE", "DEBUG"]).union(ProjectConfig.supportedKeys)

    static func sanitizedEnvironment(_ inherited: [String: String]) -> [String: String] {
        inherited.filter { !hostOverrideKeys.contains($0.key) }
    }

    var configFile: URL {
        root.appendingPathComponent("config.txt")
    }

    deinit {
        try? fileManager.removeItem(at: root)
    }

    static var projectRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            url.deleteLastPathComponent()
        }
        return url
    }

    static var defaultConfig: String {
        """
        PROFILE=youtube_master
        PREFLIGHT_SECONDS=1
        DURATION_TOLERANCE_SEC=1.5
        CRC_CHUNK_BYTES=262144
        WAV_SAMPLE_RATE=96000
        WAV_CODEC=pcm_s24le
        WAV_CHANNELS=2
        WAV_WRITE_BEXT=1
        MP3_SAMPLE_RATE=48000
        MP3_BITRATE=320k
        MP3_CHANNELS=2
        MP3_MIN_BITRATE_BPS=300000
        FLAC_SAMPLE_RATE=48000
        FLAC_CHANNELS=2
        FLAC_COMPRESSION_LEVEL=8
        M4A_SAMPLE_RATE=48000
        M4A_CHANNELS=2
        AUDIO_QC_TARGET_LUFS=-12
        AUDIO_QC_LUFS_TOLERANCE=12
        AUDIO_QC_MAX_TRUE_PEAK_DBTP=0
        AUDIO_QC_MAX_LOUDNESS_RANGE=30
        AUDIO_QC_MAX_DC_OFFSET=0.05
        AUDIO_QC_MAX_STEREO_IMBALANCE_DB=12
        AUDIO_QC_MAX_CLIPPED_SAMPLES=1000000
        AUDIO_QC_MINIMUM_ANALYSIS_SECONDS=3
        SHORT_AUDIO_QC_TARGET_LUFS=-12
        SHORT_AUDIO_QC_LUFS_TOLERANCE=12
        SHORT_AUDIO_QC_MAX_LOUDNESS_RANGE=30
        MASTERING_TARGET_LUFS=-12
        MASTERING_MAX_TRUE_PEAK_DBTP=-1
        MASTERING_MAX_LOUDNESS_RANGE=20
        VIDEO_MP4_ENCODER=hevc_videotoolbox
        VIDEO_MP4_ENCODER_FALLBACKS=libx264
        VIDEO_MP4_VT_QUALITY=45
        VIDEO_MP4_SOFTWARE_PRESET=medium
        VIDEO_MP4_SOFTWARE_CRF=22
        VIDEO_MP4_INPUT_FPS=2
        VIDEO_MP4_AUDIO_SAMPLE_RATE=48000
        VIDEO_MP4_WIDTH=320
        VIDEO_MP4_HEIGHT=180
        VIDEO_MP4_SCALE_FILTER=lanczos
        VIDEO_MP4_PIXEL_FORMAT=yuv420p
        VIDEO_MP4_TAG=hvc1
        VIDEO_MP4_VERIFY_CODEC=hevc
        VIDEO_COLOR_PRIMARIES=bt709
        VIDEO_COLOR_TRANSFER=bt709
        VIDEO_COLOR_SPACE=bt709
        VIDEO_COLOR_RANGE=tv
        SHORT_MP4_CLIP_SECONDS=1
        SHORT_MP4_FPS=2
        SHORT_MP4_SCALE_W=90
        SHORT_MP4_SCALE_H=160
        SHORT_MP4_VIDEO_PRESET=fast
        SHORT_MP4_VIDEO_CRF=23
        SHORT_MP4_VT_QUALITY=55
        SHORT_MP4_AUDIO_SAMPLE_RATE=48000
        SHORT_MP4_VIDEO_CODEC=libx264
        SHORT_MP4_VIDEO_FALLBACKS=h264_videotoolbox
        SHORT_MP4_PIXEL_FORMAT=yuv420p
        SHORT_MP4_VERIFY_CODEC=h264
        IMAGE_8K_WIDTH=320
        IMAGE_8K_HEIGHT=180
        IMAGE_4K_WIDTH=160
        IMAGE_4K_HEIGHT=90
        IMAGE_3K_SIZE=96
        IMAGE_2K_SIZE=64
        IMAGE_AIPIX_SHARPNESS=1.1
        IMAGE_AIPIX_FILTER=Lanczos
        IMAGE_AIPIX_PNG_COMPRESSION_LEVEL=1
        IMAGE_JPG_TO_PNG_COMPRESSION_LEVEL=0
        IMAGE_PNG_TO_JPEG_QUALITY=90
        IMAGE_JPEG_SAMPLING_FACTOR=4:4:4
        IMAGE_OUTPUT_COLORSPACE=sRGB
        IMAGE_3K_JPG_1MB_TARGET_BYTES=40000
        IMAGE_3K_JPG_5MB_TARGET_BYTES=80000
        IMAGE_8K_JPG_1MB_TARGET_BYTES=50000
        IMAGE_8K_JPG_2MB_TARGET_BYTES=90000
        IMAGE_8K_JPG_20MB_TARGET_BYTES=120000
        ALBUM_SILENCE_SECS=1
        WAV_FADE_DUR=1
        """
    }

    func logger(debug: Bool = false) -> Logger {
        Logger(scriptName: "converterTests", debugEnabled: debug)
    }

    func runner(debug: Bool = false) -> ProcessRunner {
        ProcessRunner(logger: logger(debug: debug), environment: environment, debugEnabled: debug)
    }

    func makeTool(arguments: [String] = [], debug: Bool = false) throws -> ConverterTool {
        // Pin every path inside the workspace explicitly; callers' own --src-dir/--out-dir/--config still win
        // because CLIOptions.parse applies flags in order.
        let cli = try CLIOptions.parse(
            arguments: ["--output-dir", output.path, "--config", configFile.path] + arguments,
            environment: environment,
            scriptDirectory: root,
            scriptName: "converter"
        )
        let log = logger(debug: debug)
        let config = try ProjectConfig.load(from: cli.configFile, environment: environment, cli: cli, logger: log)
        let processRunner = ProcessRunner(logger: log, environment: environment, debugEnabled: debug)
        return ConverterTool(cli: cli, config: config, logger: log, runner: processRunner, environment: environment)
    }

    func requireCommands(_ names: [String]) throws {
        let processRunner = runner()
        for name in names {
            try processRunner.requireExecutable(name)
        }
    }

    func writeAlbum(_ lines: [String]) throws {
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: root.appendingPathComponent("album.txt"), atomically: true, encoding: .utf8)
    }

    func overwriteConfig(_ text: String) throws {
        try text.write(to: root.appendingPathComponent("config.txt"), atomically: true, encoding: .utf8)
    }

    func createImage(name: String, ext: String, width: Int = 320, height: Int = 180) throws -> URL {
        let target = output.appendingPathComponent(name).appendingPathExtension(ext)
        _ = try runner().run("magick", [
            "-size", "\(width)x\(height)",
            "gradient:#1A4B8C-#E7A84B",
            target.path
        ])
        return target
    }

    // Audio fixtures are generated directly with ffmpeg so tests do not depend on converter output to build input data.
    func createAudio(
        name: String, ext: String, duration: Double = 1.2, frequency: Int = 440, sampleRate: Int = 48_000
    ) throws -> URL {
        let target = output.appendingPathComponent(name).appendingPathExtension(ext)
        let rate = String(sampleRate)
        var args = [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi",
            "-i", "sine=frequency=\(frequency):duration=\(String(format: "%.3f", duration)):sample_rate=\(rate)",
            "-ac", "2"
        ]
        switch ext.lowercased() {
        case "wav":
            args += ["-c:a", "pcm_f32le", "-ar", rate, "-f", "wav", "-rf64", "always", "-write_bext", "1", target.path]
        case "flac":
            args += ["-c:a", "flac", "-compression_level", "5", "-ar", rate, target.path]
        case "mp3":
            args += ["-c:a", "libmp3lame", "-b:a", "192k", "-ar", rate, target.path]
        case "m4a":
            args += ["-c:a", "aac", "-b:a", "192k", "-ar", rate, target.path]
        case "aac":
            args += ["-c:a", "aac", "-b:a", "192k", "-ar", rate, "-f", "adts", target.path]
        default:
            throw AppError("Unsupported test audio extension: \(ext)")
        }
        _ = try runner().run("ffmpeg", args)
        return target
    }

    // Plain RIFF WAV fixtures exercise generic WAV input support instead of the converter's internal RF64 standard.
    func createPlainRIFFWAV(name: String, duration: Double = 1.2, frequency: Int = 440, sampleRate: Int = 44_100) throws -> URL {
        let target = output.appendingPathComponent(name).appendingPathExtension("wav")
        _ = try runner().run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi",
            "-i", "sine=frequency=\(frequency):duration=\(String(format: "%.3f", duration)):sample_rate=\(sampleRate)",
            "-ac", "2",
            "-c:a", "pcm_s16le",
            "-ar", String(sampleRate),
            target.path
        ])
        return target
    }

    func createSilentAudio(name: String, ext: String, duration: Double = 1.2) throws -> URL {
        let target = output.appendingPathComponent(name).appendingPathExtension(ext)
        var args = [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi",
            "-i", "anullsrc=r=48000:cl=stereo",
            "-t", String(format: "%.3f", duration)
        ]
        switch ext.lowercased() {
        case "wav":
            args += ["-c:a", "pcm_f32le", "-ar", "48000", "-f", "wav", "-rf64", "always", "-write_bext", "1", target.path]
        case "flac":
            args += ["-c:a", "flac", "-compression_level", "5", "-ar", "48000", target.path]
        case "mp3":
            args += ["-c:a", "libmp3lame", "-b:a", "192k", "-ar", "48000", target.path]
        case "m4a":
            args += ["-c:a", "aac", "-b:a", "192k", "-ar", "48000", target.path]
        default:
            throw AppError("Unsupported silent test audio extension: \(ext)")
        }
        _ = try runner().run("ffmpeg", args)
        return target
    }

    func createHotAudio(name: String, ext: String, duration: Double = 1.2, frequency: Int = 440, gainDB: Double = 18) throws -> URL {
        let target = output.appendingPathComponent(name).appendingPathExtension(ext)
        var args = [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi",
            "-i", "sine=frequency=\(frequency):duration=\(String(format: "%.3f", duration)):sample_rate=48000",
            "-ac", "2",
            "-af", "volume=\(String(format: "%.2f", gainDB))dB"
        ]
        switch ext.lowercased() {
        case "wav":
            args += ["-c:a", "pcm_f32le", "-ar", "48000", "-f", "wav", "-rf64", "always", "-write_bext", "1", target.path]
        case "flac":
            args += ["-c:a", "flac", "-compression_level", "5", "-ar", "48000", target.path]
        case "mp3":
            args += ["-c:a", "libmp3lame", "-b:a", "192k", "-ar", "48000", target.path]
        case "m4a":
            args += ["-c:a", "aac", "-b:a", "192k", "-ar", "48000", target.path]
        default:
            throw AppError("Unsupported hot test audio extension: \(ext)")
        }
        _ = try runner().run("ffmpeg", args)
        return target
    }

    // Hard-clipped 24-bit fixture. ffmpeg's sine sits near -21 dBFS, so +24 dB drives it 3 dB
    // past full scale and the s24 quantisation turns every crest into a run of full-scale
    // samples. The sample rate is the point of the fixture.
    func createClippedAudio(
        name: String, sampleRate: Int, duration: Double = 6.0, frequency: Int = 440
    ) throws -> URL {
        let target = output.appendingPathComponent(name).appendingPathExtension("wav")
        _ = try runner().run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi",
            "-i", "sine=frequency=\(frequency):duration=\(String(format: "%.3f", duration)):sample_rate=\(sampleRate)",
            "-ac", "2",
            "-af", "volume=24dB",
            "-c:a", "pcm_s24le", "-ar", String(sampleRate), "-f", "wav", "-rf64", "always", target.path
        ])
        return target
    }

    func createVideoMP4(name: String, duration: Double, width: Int = 320, height: Int = 180, frequency: Int = 440) throws -> URL {
        let target = output.appendingPathComponent(name).appendingPathExtension("mp4")
        _ = try runner().run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi",
            "-i", "color=c=#224477:size=\(width)x\(height):rate=2:duration=\(String(format: "%.3f", duration))",
            "-f", "lavfi",
            "-i", "sine=frequency=\(frequency):duration=\(String(format: "%.3f", duration)):sample_rate=48000",
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-b:a", "192k",
            "-ar", "48000",
            "-shortest",
            target.path
        ])
        return target
    }

    // Stereo file whose right channel is digitally silent: the worst possible balance.
    func createOneChannelSilentAudio(name: String, duration: Double = 1.2) throws -> URL {
        let target = output.appendingPathComponent(name).appendingPathExtension("wav")
        _ = try runner().run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi",
            "-i", "sine=frequency=440:duration=\(String(format: "%.3f", duration)):sample_rate=48000",
            "-filter_complex", "[0:a]pan=stereo|c0=c0|c1=0*c0[a]",
            "-map", "[a]",
            "-c:a", "pcm_s24le", "-ar", "48000", "-f", "wav", "-rf64", "always", target.path
        ])
        return target
    }

    func createStereoImbalancedAudio(name: String, ext: String, duration: Double = 1.2) throws -> URL {
        let target = output.appendingPathComponent(name).appendingPathExtension(ext)
        var args = [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi",
            "-i", "sine=frequency=440:duration=\(String(format: "%.3f", duration)):sample_rate=48000",
            "-filter_complex", "[0:a]asplit=2[left][right];[left]volume=1.0[l];[right]volume=0.02[r];[l][r]join=inputs=2:channel_layout=stereo[a]",
            "-map", "[a]"
        ]
        switch ext.lowercased() {
        case "wav":
            args += ["-c:a", "pcm_f32le", "-ar", "48000", "-f", "wav", "-rf64", "always", "-write_bext", "1", target.path]
        case "flac":
            args += ["-c:a", "flac", "-compression_level", "5", "-ar", "48000", target.path]
        case "mp3":
            args += ["-c:a", "libmp3lame", "-b:a", "192k", "-ar", "48000", target.path]
        case "m4a":
            args += ["-c:a", "aac", "-b:a", "192k", "-ar", "48000", target.path]
        default:
            throw AppError("Unsupported imbalanced test audio extension: \(ext)")
        }
        _ = try runner().run("ffmpeg", args)
        return target
    }

    func createMP3WithArtwork(
        name: String, duration: Double = 1.2, frequency: Int = 440, sampleRate: Int = 48_000
    ) throws -> URL {
        let audio = try createAudio(
            name: "\(name)_audio", ext: "mp3", duration: duration, frequency: frequency, sampleRate: sampleRate)
        let cover = try createImage(name: "\(name)_cover", ext: "png", width: 320, height: 320)
        let target = output.appendingPathComponent(name).appendingPathExtension("mp3")
        _ = try runner().run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-i", audio.path,
            "-i", cover.path,
            "-map", "0:a:0",
            "-map", "1:v:0",
            "-c:a", "copy",
            "-c:v", "mjpeg",
            "-id3v2_version", "3",
            "-metadata:s:v", "title=Album cover",
            "-metadata:s:v", "comment=Cover (front)",
            target.path
        ])
        try? fileManager.removeItem(at: audio)
        return target
    }

    func createFLACWithArtwork(name: String, duration: Double = 1.2, frequency: Int = 440) throws -> URL {
        let audio = try createAudio(name: "\(name)_audio", ext: "flac", duration: duration, frequency: frequency)
        let cover = try createImage(name: "\(name)_cover", ext: "png", width: 320, height: 320)
        let target = output.appendingPathComponent(name).appendingPathExtension("flac")
        _ = try runner().run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-i", audio.path,
            "-i", cover.path,
            "-map", "0:a:0",
            "-map", "1:v:0",
            "-c:a", "copy",
            "-c:v", "png",
            "-disposition:v:0", "attached_pic",
            "-metadata:s:v", "title=Album cover",
            "-metadata:s:v", "comment=Cover (front)",
            target.path
        ])
        try? fileManager.removeItem(at: audio)
        return target
    }

    func createHotMP3WithArtwork(name: String, duration: Double = 1.2, frequency: Int = 440, gainDB: Double = 24) throws -> URL {
        let audio = output.appendingPathComponent("\(name)_audio").appendingPathExtension("mp3")
        let cover = try createImage(name: "\(name)_cover", ext: "png", width: 320, height: 320)
        let target = output.appendingPathComponent(name).appendingPathExtension("mp3")
        _ = try runner().run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi",
            "-i", "sine=frequency=\(frequency):duration=\(String(format: "%.3f", duration)):sample_rate=48000",
            "-ac", "2",
            "-af", "volume=\(String(format: "%.2f", gainDB))dB",
            "-c:a", "libmp3lame",
            "-b:a", "320k",
            "-ar", "48000",
            audio.path
        ])
        _ = try runner().run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-i", audio.path,
            "-i", cover.path,
            "-map", "0:a:0",
            "-map", "1:v:0",
            "-c:a", "copy",
            "-c:v", "mjpeg",
            "-id3v2_version", "3",
            "-metadata:s:v", "title=Album cover",
            "-metadata:s:v", "comment=Cover (front)",
            target.path
        ])
        try? fileManager.removeItem(at: audio)
        return target
    }

    func copy(_ source: URL, as newName: String, ext: String) throws -> URL {
        let target = output.appendingPathComponent(newName).appendingPathExtension(ext)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.copyItem(at: source, to: target)
        return target
    }

    func extractFirstVideoFrame(from video: URL, name: String) throws -> URL {
        let frame = output.appendingPathComponent(name).appendingPathExtension("png")
        _ = try runner().run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-i", video.path,
            "-frames:v", "1",
            frame.path
        ])
        return frame
    }

    func meanGrayValue(image: URL, crop: String) throws -> Double {
        let result = try runner().run("magick", [
            image.path,
            "-crop", crop,
            "-colorspace", "Gray",
            "-format", "%[fx:mean]",
            "info:"
        ])
        guard let value = Double(result.stdout.trimmed) else {
            throw AppError("Unable to parse mean gray value for \(image.path): \(result.stdout)")
        }
        return value
    }

    func writeGarbageFile(name: String, ext: String) throws -> URL {
        let target = output.appendingPathComponent(name).appendingPathExtension(ext)
        let payload = Data((0 ..< 4096).map { UInt8(($0 * 37) & 0xFF) })
        try payload.write(to: target)
        return target
    }

    func writeEmptyFile(name: String, ext: String) throws -> URL {
        let target = output.appendingPathComponent(name).appendingPathExtension(ext)
        try Data().write(to: target)
        return target
    }
}

final class ResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func store(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func load() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// ConcurrencyCounter records in-flight and peak jobs so scheduler limits can be asserted in tests.
final class ConcurrencyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var activeByClass: [JobClass: Int] = [:]
    private var peakByClass: [JobClass: Int] = [:]
    private var activeTotal = 0
    private var peakTotal = 0

    func enter(_ jobClass: JobClass) {
        lock.lock()
        defer { lock.unlock() }
        activeByClass[jobClass, default: 0] += 1
        activeTotal += 1
        peakByClass[jobClass] = max(peakByClass[jobClass, default: 0], activeByClass[jobClass, default: 0])
        peakTotal = max(peakTotal, activeTotal)
    }

    func leave(_ jobClass: JobClass) {
        lock.lock()
        defer { lock.unlock() }
        activeByClass[jobClass, default: 0] = max(0, activeByClass[jobClass, default: 0] - 1)
        activeTotal = max(0, activeTotal - 1)
    }

    func peak(_ jobClass: JobClass) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return peakByClass[jobClass, default: 0]
    }

    func peakTotalCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return peakTotal
    }
}

// Hand-assembled WAV files for the chunk-walker tests (audit #0043). Every byte is placed on
// purpose — chunk order, declared sizes, pad bytes, the RF64 size placeholder — so a test can
// put a chunk id where it is only text, or a real chunk where a byte scan does not look.
enum WAVFixture {
    static let sizePlaceholder: UInt32 = 0xFFFF_FFFF

    static func fourCC(_ text: String) -> Data {
        Data(text.utf8)
    }

    static func uint32LE(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    static func uint64LE(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    // A chunk with its real size, padded to an even length as RIFF requires.
    static func chunk(_ chunkID: String, _ payload: Data) -> Data {
        var data = fourCC(chunkID) + uint32LE(UInt32(payload.count)) + payload
        if payload.count % 2 == 1 {
            data.append(0)
        }
        return data
    }

    // A chunk whose header carries the RF64 placeholder; its real size must come from ds64.
    static func placeholderChunk(_ chunkID: String, _ payload: Data) -> Data {
        var data = fourCC(chunkID) + uint32LE(sizePlaceholder) + payload
        if payload.count % 2 == 1 {
            data.append(0)
        }
        return data
    }

    static func pcmFormatChunk(channels: Int, sampleRate: Int, bitsPerSample: Int) -> Data {
        let blockAlign = channels * bitsPerSample / 8
        var payload = Data()
        payload += withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }
        payload += withUnsafeBytes(of: UInt16(channels).littleEndian) { Data($0) }
        payload += uint32LE(UInt32(sampleRate))
        payload += uint32LE(UInt32(sampleRate * blockAlign))
        payload += withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Data($0) }
        payload += withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Data($0) }
        return chunk("fmt ", payload)
    }

    // A 602-byte bext payload with the given text at the start of its description field.
    static func bextChunk(description: String) -> Data {
        var payload = Data(count: 602)
        let text = Data(description.utf8.prefix(256))
        payload.replaceSubrange(0 ..< text.count, with: text)
        return chunk("bext", payload)
    }

    static func ds64Chunk(
        riffSize: UInt64, dataSize: UInt64, sampleCount: UInt64, table: [(String, UInt64)] = []
    ) -> Data {
        var payload = uint64LE(riffSize) + uint64LE(dataSize) + uint64LE(sampleCount)
        payload += uint32LE(UInt32(table.count))
        for (chunkID, size) in table {
            payload += fourCC(chunkID) + uint64LE(size)
        }
        return chunk("ds64", payload)
    }

    // A plain RIFF file: the header size is the real byte count after it.
    static func riffFile(chunks: [Data]) -> Data {
        let body = chunks.reduce(Data(), +)
        return fourCC("RIFF") + uint32LE(UInt32(4 + body.count)) + fourCC("WAVE") + body
    }

    // An RF64 or BW64 file as ffmpeg and libbw64 write it: placeholder RIFF size, ds64 first
    // with the real RIFF and data sizes, the data chunk carrying the placeholder too.
    static func rf64File(
        container: String, before: [Data], dataPayload: Data, after: [Data] = [], blockAlign: Int = 6
    ) -> Data {
        let body = before.reduce(Data(), +) + placeholderChunk("data", dataPayload) + after.reduce(Data(), +)
        let ds64Length = 8 + 28
        let riffSize = UInt64(4 + ds64Length + body.count)
        let ds64 = ds64Chunk(
            riffSize: riffSize, dataSize: UInt64(dataPayload.count), sampleCount: UInt64(dataPayload.count / blockAlign)
        )
        return fourCC(container) + uint32LE(sizePlaceholder) + fourCC("WAVE") + ds64 + body
    }

    // The same header layout with the ds64 chunk left out: what the byte scan cannot tell
    // apart from a valid file when "ds64" appears as text elsewhere.
    static func rf64FileWithoutDs64(container: String, chunks: [Data]) -> Data {
        fourCC(container) + uint32LE(sizePlaceholder) + fourCC("WAVE") + chunks.reduce(Data(), +)
    }
}

// Counts real invocations of one external tool (audit #0047, #0052). A wrapper script placed
// ahead of the tool on PATH appends its argument line to a log and then execs the real binary,
// so what is counted is exactly what ran and production code needs no counting hook. Build the
// workspace with `environment` so its ProcessRunner resolves the wrapper.
final class CommandInvocationLog {
    let environment: [String: String]
    private let directory: URL
    private let logFile: URL

    init(recording tool: String, inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let base = IntegrationWorkspace.sanitizedEnvironment(inheritedEnvironment)
        guard let real = DependencyBootstrapper.executableURL(named: tool, environment: base) else {
            throw AppError("CommandInvocationLog: '\(tool)' is not available on PATH")
        }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("converter-shim.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logFile = directory.appendingPathComponent("\(tool).log")
        let shim = directory.appendingPathComponent(tool)
        let script = "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(logFile.path)'\nexec '\(real.path)' \"$@\"\n"
        try script.write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        var withShim = base
        withShim["PATH"] = ([directory.path] + (base["PATH"] ?? "").split(separator: ":").map(String.init))
            .joined(separator: ":")
        environment = withShim
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    // Forgets everything recorded so far, so fixture creation is not counted with the code under test.
    func reset() throws {
        try Data().write(to: logFile)
    }

    // One argument line per invocation, in the order they ran.
    func invocations() throws -> [String] {
        guard FileManager.default.fileExists(atPath: logFile.path) else {
            return []
        }
        return try String(contentsOf: logFile, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    func count(containing needle: String) throws -> Int {
        try invocations().filter { $0.contains(needle) }.count
    }
}
