import Foundation

struct AppError: LocalizedError, CustomStringConvertible {
    let message: String
    let exitCode: Int32

    init(_ message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
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

final class Logger {
    private let lock = NSLock()
    private let scriptName: String
    private let debugEnabled: Bool

    init(scriptName: String, debugEnabled: Bool) {
        self.scriptName = scriptName
        self.debugEnabled = debugEnabled
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    func log(_ level: LogLevel, _ message: String) {
        if level == .debug && !debugEnabled {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data("[\(timestamp())] [\(scriptName)] [\(level.rawValue)] \(message)\n".utf8))
    }

    func info(_ message: String) { log(.info, message) }
    func warn(_ message: String) { log(.warn, message) }
    func error(_ message: String) { log(.error, message) }
    func debug(_ message: String) { log(.debug, message) }
}

actor AsyncSemaphore {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.limit = max(1, value)
        self.available = max(1, value)
    }

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if !waiters.isEmpty {
            let continuation = waiters.removeFirst()
            continuation.resume()
            return
        }
        available = min(limit, available + 1)
    }

    func withPermit<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        await wait()
        defer {
            signal()
        }
        return try await operation()
    }
}

enum JobClass: String, Sendable {
    case image
    case audio
    case video
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
    var isHiddenBasename: Bool { lastPathComponent.hasPrefix(".") }

    func appendingStemSuffix(_ suffix: String) -> URL {
        deletingLastPathComponent().appendingPathComponent(stem + suffix).appendingPathExtension(pathExtension)
    }
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

    var delayMilliseconds: Int {
        Int((seconds * 1000).rounded())
    }

    var effectiveLeadingSeconds: Double {
        Double(delayMilliseconds) / 1000
    }
}

struct NoiseSpec: Equatable, Sendable {
    static let targetLUFS = LoudnessSpec.defaultTargetLUFS

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

func ffmpegNumber(_ value: Double) -> String {
    if value.rounded(.towardZero) == value {
        return String(Int(value))
    }
    return String(format: "%.6f", value)
        .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
}

func parseFlexibleTimecode(_ rawValue: String, label: String) throws -> Double {
    let value = rawValue.trimmed
    guard !value.isEmpty else {
        throw AppError("\(label) is empty")
    }

    let components = value.split(separator: ":")
    guard !components.isEmpty, components.count <= 3 else {
        throw AppError("Invalid \(label) '\(rawValue)'. Use seconds, MM:SS, or HH:MM:SS.")
    }

    func parseComponent(_ component: Substring, allowFraction: Bool) throws -> Double {
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
    return seconds
}

func parseBitrateBps(_ rawValue: String) -> Int? {
    let value = rawValue.trimmed.lowercasedASCII
    guard !value.isEmpty else {
        return nil
    }
    let multiplier: Double
    let digits: String
    if value.hasSuffix("k") {
        multiplier = 1_000
        digits = String(value.dropLast())
    } else if value.hasSuffix("m") {
        multiplier = 1_000_000
        digits = String(value.dropLast())
    } else {
        multiplier = 1
        digits = value
    }
    guard let parsed = Double(digits), parsed > 0 else {
        return nil
    }
    return Int((parsed * multiplier).rounded())
}

func formatCommand(_ executable: String, _ arguments: [String]) -> String {
    ([executable] + arguments).map { argument in
        if argument.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) {
            return "\"" + argument.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return argument
    }.joined(separator: " ")
}
