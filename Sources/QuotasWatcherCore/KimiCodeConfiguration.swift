import Foundation

public struct KimiManagedProviderInfo: Equatable, Sendable {
    public let baseURL: URL
    public let credentialStorageName: String
    public let oauthKey: String
    public let oauthHost: String?

    public init(baseURL: URL, credentialStorageName: String, oauthKey: String, oauthHost: String?) {
        self.baseURL = baseURL
        self.credentialStorageName = credentialStorageName
        self.oauthKey = oauthKey
        self.oauthHost = oauthHost
    }
}

public enum KimiCodeConfiguration {
    public static func resolve(
        overrideBinaryPath: String? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processLauncher: KimiProcessLaunching = KimiProcessLauncher()
    ) async throws -> KimiManagedProviderInfo {
        let binaryURL = try KimiCodeBinaryResolver.resolve(
            overridePath: overrideBinaryPath,
            fileManager: fileManager,
            environment: environment
        )

        let arguments = KimiCodeBinaryResolver.launchArguments(for: binaryURL) + ["provider", "list", "--json"]
        let launchEnvironment = KimiCodeBinaryResolver.launchEnvironment(for: binaryURL, environment: environment)

        let result = try await processLauncher.run(
            executableURL: binaryURL,
            arguments: arguments,
            environment: launchEnvironment,
            timeout: 15
        )

        guard result.exitCode == 0 else {
            // Cap and trim stderr; it is a CLI diagnostic, never stdout JSON.
            let raw = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw KimiCodeError.providerListFailed(String(raw.prefix(200)))
        }

        return try parseProviderList(
            result.stdout,
            fileManager: fileManager,
            environment: environment
        )
    }

    static func parseProviderList(
        _ data: Data,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> KimiManagedProviderInfo {
        guard let topLevel = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KimiCodeError.providerListMalformed("top-level object is not a dictionary")
        }

        let providers: [[String: Any]]
        if let providersArray = topLevel["providers"] as? [[String: Any]] {
            providers = providersArray
        } else if let providersObject = topLevel["providers"] as? [String: [String: Any]] {
            providers = providersObject.map { id, value in
                var entry = value
                entry["id"] = id
                return entry
            }
        } else {
            providers = []
        }

        guard let managed = providers.first(where: { ($0["id"] as? String) == "managed:kimi-code" }) else {
            throw KimiCodeError.managedProviderNotFound
        }

        guard let baseURLString = managed["baseUrl"] as? String ?? managed["baseURL"] as? String,
              let baseURL = URL(string: baseURLString) else {
            throw KimiCodeError.providerListMalformed("managed provider missing baseUrl")
        }

        let oauth = managed["oauth"] as? [String: Any]

        let storage = oauth?["storage"] as? String ?? "file"
        if storage != "file" {
            throw KimiCodeError.unsupportedCredentialBackend(storage)
        }

        let rawOAuthKey = oauth?["key"] as? String
        let oauthKey = rawOAuthKey.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultOAuthKey
        // The installed toolkit persists the field as `oauthHost`; `host` is
        // tolerated only as a legacy secondary spelling.
        let oauthHost = oauth?["oauthHost"] as? String ?? oauth?["host"] as? String
        let credentialStorageName = try credentialStorageName(forOAuthKey: rawOAuthKey)

        return KimiManagedProviderInfo(
            baseURL: baseURL,
            credentialStorageName: credentialStorageName,
            oauthKey: oauthKey,
            oauthHost: oauthHost
        )
    }

    /// The toolkit's default managed OAuth slot (`KIMI_CODE_OAUTH_KEY`).
    static let defaultOAuthKey = "oauth/kimi-code"

    /// Mirrors the official `resolveKimiTokenStorageName` from the installed
    /// Kimi toolkit (`packages/oauth/src/toolkit.ts`):
    ///
    /// - a missing key defaults to `oauth/kimi-code`;
    /// - `kimi-code` and `oauth/kimi-code` both map to `kimi-code`;
    /// - a scoped `oauth/<name>` key maps to `<name>`;
    /// - a safe bare name maps to itself;
    /// - anything else is rejected.
    ///
    /// Scoped and bare names are additionally validated so a malformed key can
    /// never resolve to a credential path outside Kimi's credential directory.
    static func credentialStorageName(forOAuthKey key: String?) throws -> String {
        guard let key, !key.isEmpty else {
            return "kimi-code"
        }
        if key == "kimi-code" || key == defaultOAuthKey {
            return "kimi-code"
        }
        if key.hasPrefix("oauth/") {
            let scoped = String(key.dropFirst(defaultOAuthKeyPrefix.count))
            guard isSafeStorageName(scoped) else {
                throw KimiCodeError.providerListMalformed("managed provider has an invalid OAuth token key")
            }
            return scoped
        }
        guard isSafeStorageName(key) else {
            throw KimiCodeError.providerListMalformed("managed provider has an invalid OAuth token key")
        }
        return key
    }

    private static let defaultOAuthKeyPrefix = "oauth/"

    /// A storage name becomes `<home>/credentials/<name>.json`, so it must be a
    /// single safe path component: non-empty, no leading dot, and no
    /// slash/backslash/colon that could traverse or split the path.
    private static func isSafeStorageName(_ name: String) -> Bool {
        !name.isEmpty
            && !name.hasPrefix(".")
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains(":")
    }
}

public protocol KimiProcessLaunching: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> KimiProcessResult
}

public struct KimiProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public final class KimiProcessLauncher: KimiProcessLaunching {
    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> KimiProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stdoutBuffer = LockedPipeBuffer(handle: stdout.fileHandleForReading)
        let stderrBuffer = LockedPipeBuffer(handle: stderr.fileHandleForReading)

        stdout.fileHandleForReading.readabilityHandler = { _ in
            stdoutBuffer.readAvailable()
        }
        stderr.fileHandleForReading.readabilityHandler = { _ in
            stderrBuffer.readAvailable()
        }

        return try await withTaskCancellationHandler {
            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                throw KimiCodeError.launchFailed(error.localizedDescription)
            }

            let deadline = Date().addingTimeInterval(timeout)
            do {
                // Poll cooperatively: no thread is blocked while waiting, so
                // cancellation and the deadline both take effect promptly.
                while process.isRunning {
                    if Task.isCancelled {
                        throw KimiCodeError.cancelled
                    }
                    if Date() >= deadline {
                        throw KimiCodeError.timeout
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            } catch {
                stopReading(stdout, stderr)
                await terminate(process)
                if let kimiError = error as? KimiCodeError {
                    throw kimiError
                }
                if error is CancellationError {
                    throw KimiCodeError.cancelled
                }
                throw error
            }

            stopReading(stdout, stderr)
            // The child exited, so both pipe write ends are closed. A fast
            // process can exit before its final readability callback ran;
            // drain the remaining bytes to EOF synchronously so parsing never
            // sees truncated stdout/stderr. Both reads are serialized with the
            // callbacks inside the locked buffers, so chunks stay ordered.
            stdoutBuffer.drainToEnd()
            stderrBuffer.drainToEnd()
            return KimiProcessResult(
                exitCode: process.terminationStatus,
                stdout: stdoutBuffer.data(),
                stderr: stderrBuffer.data()
            )
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private func stopReading(_ stdout: Pipe, _ stderr: Pipe) {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
    }

    /// SIGTERM first, then SIGKILL if the child ignores it; never blocks a
    /// cooperative thread with `waitUntilExit`.
    private func terminate(_ process: Process) async {
        if process.isRunning {
            process.terminate()
        }
        for _ in 0..<200 where process.isRunning {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

/// Serializes pipe reads and buffer appends under one lock so readability
/// callbacks and the final EOF drain can never interleave a chunk out of
/// order. The buffer holds process output only; it is never logged.
private final class LockedPipeBuffer {
    private let lock = NSLock()
    private let handle: FileHandle
    private var storage = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    /// Called from the readability handler when data is known to be available.
    func readAvailable() {
        lock.lock()
        defer { lock.unlock() }
        let data = handle.availableData
        if !data.isEmpty {
            storage.append(data)
        }
    }

    /// Reads everything remaining through end-of-file. Must only be called
    /// after the child exited (the write end is closed), where it returns
    /// promptly with the bytes the readability callbacks had not consumed yet.
    func drainToEnd() {
        lock.lock()
        defer { lock.unlock() }
        let data = handle.readDataToEndOfFile()
        if !data.isEmpty {
            storage.append(data)
        }
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
