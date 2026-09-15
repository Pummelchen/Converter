import Foundation
import Synchronization

struct AppError: LocalizedError, CustomStringConvertible, Sendable {
    let message: String
    let exitCode: Int32
    let fileID: String
    let line: Int
    let underlyingDescription: String?
    // Set when retrying the same work with a different encoder cannot possibly help, so an
    // encoder ladder stops instead of repeating an identical failure and burying the cause.
    let isEncoderIndependent: Bool

    init(
        _ message: String,
        exitCode: Int32 = 1,
        underlying: (any Error)? = nil,
        isEncoderIndependent: Bool = false,
        fileID: String = #fileID,
        line: Int = #line
    ) {
        self.message = message
        self.exitCode = exitCode
        self.underlyingDescription = underlying.map { $0.localizedDescription }
        self.isEncoderIndependent = isEncoderIndependent
        self.fileID = fileID
        self.line = line
    }

    var errorDescription: String? { message }
    var description: String { message }
}

enum LogLevel: String {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
    case debug = "DEBUG"
}

final class Logger: Sendable {
    // DateFormatter is not thread-safe. A process-wide static guarded by the *per-instance* lock
    // meant two loggers touched the same formatter under different locks (#0150); each logger now
    // owns its formatter and every use is inside that instance's lock.
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private let lock = Mutex(())
    private let scriptName: String
    private let debugEnabled: Bool

    init(scriptName: String, debugEnabled: Bool) {
        self.scriptName = scriptName
        self.debugEnabled = debugEnabled
    }

    private func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }

    func log(_ level: LogLevel, _ message: String) {
        if level == .debug && !debugEnabled {
            return
        }
        lock.withLock { _ in
            FileHandle.standardError.write(Data("[\(timestamp())] [\(scriptName)] [\(level.rawValue)] \(message)\n".utf8))
        }
    }

    func info(_ message: String) { log(.info, message) }
    func warn(_ message: String) { log(.warn, message) }
    func error(_ message: String) { log(.error, message) }
    func debug(_ message: String) { log(.debug, message) }
}

struct SchedulerProfile: Sendable {
    let total: Int
    let image: Int
    let audio: Int
    let video: Int

    // Keep the scheduler conservative because ffmpeg and magick already use internal threading.
    static func recommended(for activeCores: Int) -> SchedulerProfile {
        let cores = max(1, activeCores)
        let total: Int
        switch cores {
        case 1 ... 4:
            total = 2
        case 5 ... 8:
            total = 3
        default:
            total = 4
        }
        return SchedulerProfile(
            total: total,
            image: min(2, total),
            audio: min(2, total),
            video: 1
        )
    }

    var summary: String {
        "total=\(total) image=\(image) audio=\(audio) video=\(video)"
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var lowercasedASCII: String {
        lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    var lastNonEmptyLine: String? {
        split(whereSeparator: \.isNewline).map(String.init).reversed().first { !$0.trimmed.isEmpty }
    }
}

extension URL {
    var basename: String { lastPathComponent }
    var stem: String { deletingPathExtension().lastPathComponent }
}

struct FadeOutSpec: Equatable, Sendable {
    let fadeStartSeconds: Double
    let fadeDurationSeconds: Double

    var endSeconds: Double {
        fadeStartSeconds + fadeDurationSeconds
    }
}

struct FadeCutSpec: Equatable, Sendable {
    let cutSeconds: Double
    let fadeDurationSeconds: Double
}

struct SilenceSpec: Equatable, Sendable {
    let seconds: Double

    // Saturates instead of trapping: parseFlexibleTimecode bounds every user-supplied
    // duration, so a value this large can only come from a programming error upstream and
    // must still never crash the process.
    var delayMilliseconds: Int {
        Int(exactly: (seconds * 1000).rounded()) ?? Int.max
    }

    var effectiveLeadingSeconds: Double {
        Double(delayMilliseconds) / 1000
    }
}

struct NoiseSpec: Equatable, Sendable {
    static let targetLUFS = LoudnessSpec.defaultTargetLUFS
    static let transitionSilenceSeconds = 2.0

    let seconds: Double
}

struct BassBoostSpec: Equatable, Sendable {
    static let defaultFrequencyHz = 80.0
    static let defaultGainDB = 5.0

    let frequencyHz: Double
    let gainDB: Double
}

struct LoudnessSpec: Equatable, Sendable {
    static let defaultTargetLUFS = -12.0
    static let minimumTargetLUFS = -70.0
    static let maximumTargetLUFS = -5.0

    let targetLUFS: Double
}

struct LoudnessScanEntry: Sendable {
    let file: URL
    let integratedLUFS: Double
}

struct LoudnessScanProgress: Sendable {
    let processedFiles: Int
    let totalFiles: Int
    let currentFile: URL
    let reportLines: [String]
    let isMeasuring: Bool
}

let alacEncoderName = "alac"

private let posixLocale = Locale(identifier: "en_US_POSIX")

/// Formats a value for ffmpeg/magick arguments with a fixed POSIX locale so a
/// comma-decimal system locale cannot inject invalid tokens.
func ffmpegArg(_ format: String, _ arguments: any CVarArg...) -> String {
    String(format: format, locale: posixLocale, arguments: arguments)
}

// ffmpeg's loudnorm rejects arguments outside its documented ranges — I -70..-5, TP -9..0,
// LRA 1..50 — and fails with "Error opening output files: Result too large", which surfaces
// as an unrelated-looking encoder failure several layers up. A policy can legitimately hold
// values outside those ranges: a source-relative ceiling rebased onto a master that peaks
// above 0 dBTP produces TP > 0, for example. Clamping only bounds the normalisation target
// loudnorm would apply; the measured input_i / input_tp / input_lra it reports are unaffected,
// so measurement stays exact.
enum LoudnormArgument {
    static func integrated(_ value: Double) -> String {
        ffmpegArg("%.2f", min(max(value, -70), -5))
    }

    static func truePeak(_ value: Double) -> String {
        ffmpegArg("%.2f", min(max(value, -9), 0))
    }

    static func loudnessRange(_ value: Double) -> String {
        ffmpegArg("%.2f", min(max(value, 1), 50))
    }
}

func ffmpegNumber(_ value: Double) -> String {
    // Int(exactly:) is nil for non-integral, non-finite and out-of-range values; those fall
    // through to the fixed-point formatter, which never traps.
    if let integer = Int(exactly: value) {
        return String(integer)
    }
    return String(format: "%.6f", locale: posixLocale, value)
        .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
}

// No audio duration is measured in years; anything above this is a typo or an exponent
// (`1e300`) and is rejected before it can reach integer conversions downstream.
let maximumTimecodeSeconds: Double = 366 * 86_400

func parseFlexibleTimecode(_ rawValue: String, label: String) throws -> Double {
    let value = rawValue.trimmed
    guard !value.isEmpty else {
        throw AppError("\(label) is empty")
    }

    // Colon-separated timecodes are positional, so an empty field must survive the split:
    // otherwise ":30" collapses to ["30"] and silently means 30 seconds, and "1::30" means
    // 1 minute 30 seconds. The empty-component guard below depends on this flag.
    let components = value.split(separator: ":", omittingEmptySubsequences: false)
    guard !components.isEmpty, components.count <= 3 else {
        throw AppError("Invalid \(label) '\(rawValue)'. Use seconds, MM:SS, or HH:MM:SS.")
    }

    func parseComponent(_ component: Substring, allowFraction: Bool) throws -> Double {
        try parseTimecodeComponent(component, allowFraction: allowFraction, label: label, rawValue: rawValue)
    }

    let seconds: Double
    switch components.count {
    case 1:
        seconds = try parseComponent(components[0], allowFraction: true)
    case 2:
        let minutes = try parseComponent(components[0], allowFraction: false)
        let secs = try parseComponent(components[1], allowFraction: true)
        guard secs < 60 else {
            throw AppError("Invalid \(label) '\(rawValue)'. Seconds must be below 60 when using MM:SS.")
        }
        seconds = (minutes * 60) + secs
    case 3:
        let hours = try parseComponent(components[0], allowFraction: false)
        let minutes = try parseComponent(components[1], allowFraction: false)
        let secs = try parseComponent(components[2], allowFraction: true)
        guard minutes < 60, secs < 60 else {
            throw AppError("Invalid \(label) '\(rawValue)'. Minutes and seconds must be below 60 when using HH:MM:SS.")
        }
        seconds = (hours * 3600) + (minutes * 60) + secs
    default:
        throw AppError("Invalid \(label) '\(rawValue)'.")
    }

    guard seconds.isFinite, seconds >= 0 else {
        throw AppError("Invalid \(label) '\(rawValue)'.")
    }
    guard seconds <= maximumTimecodeSeconds else {
        throw AppError("Invalid \(label) '\(rawValue)'. Durations above 366 days are not supported.")
    }
    return seconds
}

private func parseTimecodeComponent(_ component: Substring, allowFraction: Bool, label: String, rawValue: String) throws -> Double {
    let text = String(component)
    guard !text.isEmpty else {
        throw AppError("Invalid \(label) '\(rawValue)'. Empty time component.")
    }
    if allowFraction {
        guard let parsed = Double(text), parsed >= 0 else {
            throw AppError("Invalid \(label) '\(rawValue)'.")
        }
        return parsed
    }
    guard let parsed = Int(text), parsed >= 0 else {
        throw AppError("Invalid \(label) '\(rawValue)'.")
    }
    return Double(parsed)
}

func formatCommand(_ executable: String, _ arguments: [String]) -> String {
    ([executable] + arguments).map { argument in
        if argument.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) {
            return "\"" + argument.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return argument
    }.joined(separator: " ")
}
