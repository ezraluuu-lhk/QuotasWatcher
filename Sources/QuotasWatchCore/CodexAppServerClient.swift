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

public final class CodexAppServerClient {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 60) {
        self.timeout = timeout
    }

    public func fetchRateLimits() async throws -> QuotaSnapshot {
        try await Task.detached(priority: .utility) {
            try self.fetchRateLimitsBlocking()
        }.value
    }

    private func fetchRateLimitsBlocking() throws -> QuotaSnapshot {
        let command = try CodexBinaryResolver.resolve()
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

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutBuffer.append(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrBuffer.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }

        let payload = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"QuotasWatch","title":"QuotasWatch","version":"0.1.0"},"capabilities":{"experimentalApi":true}}}"#,
            #"{"id":2,"method":"account/rateLimits/read","params":null}"#
        ].joined(separator: "\n") + "\n"

        stdin.fileHandleForWriting.write(Data(payload.utf8))
        stdin.fileHandleForWriting.closeFile()

        let deadline = Date().addingTimeInterval(timeout)
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
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return try parsedResult.get()
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        throw CodexAppServerError.timeout
    }
}

public enum CodexBinaryResolver {
    public struct Command: Equatable {
        public let executableURL: URL
        public let arguments: [String]
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
}

enum JSONRPCParser {
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
