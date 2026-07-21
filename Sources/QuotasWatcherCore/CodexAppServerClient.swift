import Foundation

public enum CodexAppServerError: LocalizedError, Equatable {
    case codexBinaryNotFound
    case launchFailed(String)
    case timeout
    case rpcError(String)
    case missingRateLimitResponse(String)

    public var errorDescription: String? {
        switch self {
        case .codexBinaryNotFound:
            return "Codex binary was not found."
        case .launchFailed(let message):
            return "Failed to launch Codex app-server: \(message)"
        case .timeout:
            return "Codex app-server did not respond before the timeout."
        case .rpcError(let message):
            return message
        case .missingRateLimitResponse(let details):
            return "Codex app-server did not return rate limits. \(details)"
        }
    }
}

public actor CodexAppServerClient {
    public let timeout: TimeInterval
    private let log: AppLog

    public init(timeout: TimeInterval = 60, log: AppLog = .shared) {
        self.timeout = timeout
        self.log = log
    }

    public func fetchRateLimits() async throws -> QuotaSnapshot {
        let timeout = self.timeout
        let log = self.log
        return try await Task.detached(priority: .utility) {
            try CodexAppServerClient.fetchRateLimitsBlocking(timeout: timeout, log: log)
        }.value
    }

    private static func fetchRateLimitsBlocking(timeout: TimeInterval, log: AppLog) throws -> QuotaSnapshot {
        let command = try CodexBinaryResolver.resolve()
        log.append("[Codex] Starting Codex app-server: \(command.executableURL.path) \((command.arguments + ["app-server", "--listen", "stdio://"]).joined(separator: " "))")
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments + ["app-server", "--listen", "stdio://"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdoutBuffer = LockedData()
        let stderrBuffer = LockedData()

        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = CodexBinaryResolver.launchEnvironment(for: command)

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutBuffer.append(data)
                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    log.append("[Codex] stdout: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrBuffer.append(data)
                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    log.append("[Codex] stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            log.append("[Codex] Launch failed: \(error.localizedDescription)")
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)

        do {
            try send(
                #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"QuotasWatcher","title":"QuotasWatcher","version":"0.3.0"},"capabilities":{"experimentalApi":true}}}"#,
                to: stdin
            )
            log.append("[Codex] sent: initialize id=1")
            try waitForResponse(
                id: .int(1),
                stdoutBuffer: stdoutBuffer,
                stderrBuffer: stderrBuffer,
                process: process,
                deadline: deadline,
                log: log
            )
            log.append("[Codex] received: initialize id=1")

            try send(#"{"id":2,"method":"account/rateLimits/read","params":null}"#, to: stdin)
            log.append("[Codex] sent: account/rateLimits/read id=2")
        } catch {
            cleanup(process: process, stdin: stdin, stdout: stdout, stderr: stderr)
            log.append("[Codex] Handshake failed: \(error.localizedDescription)")
            throw error
        }

        var parsedResult: Result<QuotaSnapshot, Error>?
        while Date() < deadline {
            let stdoutText = String(data: stdoutBuffer.data(), encoding: .utf8) ?? ""
            let stderrText = String(data: stderrBuffer.data(), encoding: .utf8) ?? ""
            do {
                parsedResult = .success(try JSONRPCParser.parseRateLimits(stdout: stdoutText, stderr: stderrText))
                break
            } catch CodexAppServerError.rpcError(let message) {
                parsedResult = .failure(CodexAppServerError.rpcError(message))
                break
            } catch {
                if !process.isRunning {
                    parsedResult = .failure(error)
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        if let parsedResult {
            cleanup(process: process, stdin: stdin, stdout: stdout, stderr: stderr)
            do {
                let snapshot = try parsedResult.get()
                log.append("[Codex] received: account/rateLimits/read id=2 success")
                return snapshot
            } catch {
                log.append("[Codex] received: account/rateLimits/read id=2 error: \(error.localizedDescription)")
                throw error
            }
        }

        cleanup(process: process, stdin: stdin, stdout: stdout, stderr: stderr)
        log.append("[Codex] Timed out waiting for account/rateLimits/read id=2.")
        throw CodexAppServerError.timeout
    }

    private static func send(_ json: String, to pipe: Pipe) throws {
        guard let data = (json + "\n").data(using: .utf8) else {
            return
        }
        do {
            try pipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw CodexAppServerError.launchFailed("Failed to write JSON-RPC request: \(error.localizedDescription)")
        }
    }

    private static func waitForResponse(
        id: JSONRPCRequestID,
        stdoutBuffer: LockedData,
        stderrBuffer: LockedData,
        process: Process,
        deadline: Date,
        log: AppLog
    ) throws {
        while Date() < deadline {
            let stdoutText = String(data: stdoutBuffer.data(), encoding: .utf8) ?? ""
            switch JSONRPCParser.responseStatus(stdout: stdoutText, id: id) {
            case .success:
                return
            case .error(let message):
                throw CodexAppServerError.rpcError(message)
            case .notFound:
                if !process.isRunning {
                    let stderrText = String(data: stderrBuffer.data(), encoding: .utf8) ?? ""
                    let details = stderrText.isEmpty ? "stdout: \(stdoutText)" : "stderr: \(stderrText)"
                    throw CodexAppServerError.missingRateLimitResponse(details)
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw CodexAppServerError.timeout
    }

    private static func cleanup(process: Process, stdin: Pipe, stdout: Pipe, stderr: Pipe) {
        try? stdin.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
    }
}

public enum CodexBinaryResolver {
    public struct Command: Equatable, Sendable {
        public let executableURL: URL
        public let arguments: [String]

        public init(executableURL: URL, arguments: [String]) {
            self.executableURL = executableURL
            self.arguments = arguments
        }
    }

    public static func resolve(fileManager: FileManager = .default, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Command {
        let preferredPaths = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex"
        ]

        for path in preferredPaths where fileManager.isExecutableFile(atPath: path) {
            return Command(executableURL: URL(fileURLWithPath: path), arguments: [])
        }

        if let pathValue = environment["PATH"], !pathValue.isEmpty {
            return Command(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["codex"])
        }

        throw CodexAppServerError.codexBinaryNotFound
    }

    static func launchEnvironment(
        for command: Command,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var launchEnvironment = environment
        let inheritedPaths = environment["PATH", default: ""]
            .split(separator: ":")
            .map(String.init)
        let preferredPaths = [
            command.executableURL.deletingLastPathComponent().path,
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        launchEnvironment["PATH"] = (preferredPaths + inheritedPaths).reduce(into: [String]()) { paths, path in
            if !path.isEmpty && !paths.contains(path) {
                paths.append(path)
            }
        }.joined(separator: ":")
        return launchEnvironment
    }
}

enum JSONRPCParser {
    enum ResponseStatus: Equatable {
        case success
        case error(String)
        case notFound
    }

    fileprivate static func responseStatus(stdout: String, id: JSONRPCRequestID) -> ResponseStatus {
        let decoder = JSONDecoder()
        for line in stdout.split(whereSeparator: \.isNewline).map(String.init) {
            guard line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
                  let data = line.data(using: .utf8),
                  let basic = try? decoder.decode(JSONRPCBasicMessage.self, from: data),
                  basic.id == id
            else {
                continue
            }

            if let error = basic.error {
                return .error(error.message)
            }
            return .success
        }
        return .notFound
    }

    static func parseRateLimits(stdout: String, stderr: String) throws -> QuotaSnapshot {
        let decoder = JSONDecoder()
        var lastRPCError: String?

        for line in stdout.split(whereSeparator: \.isNewline).map(String.init) {
            guard line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
                  let data = line.data(using: .utf8),
                  let basic = try? decoder.decode(JSONRPCBasicMessage.self, from: data)
            else {
                continue
            }

            if basic.id == .int(2), let error = basic.error {
                lastRPCError = error.message
                continue
            }

            if basic.id == .int(2) {
                let response = try decoder.decode(JSONRPCResult<GetAccountRateLimitsResponse>.self, from: data)
                return QuotaParser.snapshot(from: response.result)
            }
        }

        if let lastRPCError {
            throw CodexAppServerError.rpcError(lastRPCError)
        }

        let details = stderr.isEmpty ? "stdout: \(stdout)" : "stderr: \(stderr)"
        throw CodexAppServerError.missingRateLimitResponse(details)
    }
}

private final class LockedData {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private enum JSONRPCRequestID: Equatable, Decodable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }
        self = .string(try container.decode(String.self))
    }
}

private struct JSONRPCBasicMessage: Decodable {
    let id: JSONRPCRequestID?
    let error: JSONRPCErrorPayload?
}

private struct JSONRPCErrorPayload: Decodable {
    let message: String
}

private struct JSONRPCResult<Result: Decodable>: Decodable {
    let result: Result
}
