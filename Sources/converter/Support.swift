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

func formatCommand(_ executable: String, _ arguments: [String]) -> String {
    ([executable] + arguments).map { argument in
        if argument.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) {
            return "\"" + argument.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return argument
    }.joined(separator: " ")
}
