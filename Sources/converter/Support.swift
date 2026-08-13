import Foundation
import Synchronization

struct AppError: LocalizedError, CustomStringConvertible, Sendable {
    let message: String
    let exitCode: Int32
    let fileID: String
    let line: Int
    let underlyingDescription: String?

    init(
        _ message: String,
        exitCode: Int32 = 1,
        underlying: (any Error)? = nil,
        fileID: String = #fileID,
        line: Int = #line
    ) {
        self.message = message
        self.exitCode = exitCode
        self.underlyingDescription = underlying.map { $0.localizedDescription }
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
    private static let timestampFormatter: DateFormatter = {
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
        Self.timestampFormatter.string(from: Date())
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

actor AsyncSemaphore {
    // Waiters are identified so cancellation resumes the task that was actually
    // cancelled. Resuming positionally strands the cancelled task in the queue and
    // fails an unrelated one, which is reachable whenever `async let` siblings are
    // torn down after one of them throws.
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let limit: Int
    private var available: Int
    private var waiters: [Waiter] = []
    private var cancelledBeforeSuspension: Set<UUID> = []

    init(value: Int) {
        self.limit = max(1, value)
        self.available = max(1, value)
    }

    func wait() async throws {
        if available > 0 {
            available -= 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(id: id, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func enqueue(id: UUID, continuation: CheckedContinuation<Void, any Error>) {
        // The cancellation handler can run before suspension completes; honor it here.
        if cancelledBeforeSuspension.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }
        waiters.append(Waiter(id: id, continuation: continuation))
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            // Cancellation raced ahead of enqueue; enqueue() will observe this marker.
            cancelledBeforeSuspension.insert(id)
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    func signal() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume()
            return
        }
        available = min(limit, available + 1)
    }

    func withPermit<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await wait()
        defer {
            signal()
        }
        return try await operation()
    }
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

    var delayMilliseconds: Int {
        Int((seconds * 1000).rounded())
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

func ffmpegNumber(_ value: Double) -> String {
    if value.rounded(.towardZero) == value {
        return String(Int(value))
    }
    return String(format: "%.6f", locale: posixLocale, value)
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

func formatCommand(_ executable: String, _ arguments: [String]) -> String {
    ([executable] + arguments).map { argument in
        if argument.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) {
            return "\"" + argument.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return argument
    }.joined(separator: " ")
}
