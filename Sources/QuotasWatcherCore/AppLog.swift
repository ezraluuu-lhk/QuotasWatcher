import Foundation

public final class AppLog {
    public static let shared = AppLog()

    public let fileURL: URL
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter

    public init(fileManager: FileManager = .default) {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directoryURL = baseURL.appendingPathComponent("QuotasWatcher", isDirectory: true)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileURL = directoryURL.appendingPathComponent("QuotasWatcher.log")
    }

    public func append(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    public func readText() -> String {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return text
    }
}
