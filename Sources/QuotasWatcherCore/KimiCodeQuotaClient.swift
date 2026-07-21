import Foundation

public actor KimiCodeQuotaClient: QuotaProvider {
    public let id: QuotaProviderID = .kimi

    private let overrideBinaryPath: String?
    private let fileManager: FileManager
    private let environment: [String: String]
    private let configurationResolver: KimiConfigurationResolving
    private let credentialProvider: KimiOAuthCredentialResolving
    private let networkSession: KimiNetworkSession
    private let processLauncher: KimiProcessLaunching
    private let clock: KimiClock
    private let log: AppLog
    private let usageTimeout: TimeInterval

    public init(
        overrideBinaryPath: String? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        networkSession: KimiNetworkSession = URLSession.shared,
        processLauncher: KimiProcessLaunching = KimiProcessLauncher(),
        usageTimeout: TimeInterval = 8
    ) {
        self.init(
            overrideBinaryPath: overrideBinaryPath,
            fileManager: fileManager,
            environment: environment,
            configurationResolver: KimiCodeConfigurationResolver(),
            credentialProvider: KimiOAuthCredentialProvider(
                fileManager: fileManager,
                environment: environment,
                networkSession: networkSession
            ),
            networkSession: networkSession,
            processLauncher: processLauncher,
            clock: KimiSystemClock(),
            log: .shared,
            usageTimeout: usageTimeout
        )
    }

    public init(
        overrideBinaryPath: String? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configurationResolver: KimiConfigurationResolving,
        credentialProvider: KimiOAuthCredentialResolving,
        networkSession: KimiNetworkSession,
        processLauncher: KimiProcessLaunching,
        clock: KimiClock,
        log: AppLog,
        usageTimeout: TimeInterval
    ) {
        self.overrideBinaryPath = overrideBinaryPath
        self.fileManager = fileManager
        self.environment = environment
        self.configurationResolver = configurationResolver
        self.credentialProvider = credentialProvider
        self.networkSession = networkSession
        self.processLauncher = processLauncher
        self.clock = clock
        self.log = log
        self.usageTimeout = usageTimeout
    }

    public func fetchQuotaSnapshot() async throws -> QuotaSnapshot {
        if Task.isCancelled {
            throw KimiCodeError.cancelled
        }

        let info: KimiManagedProviderInfo
        do {
            info = try await configurationResolver.resolve(
                overrideBinaryPath: overrideBinaryPath,
                fileManager: fileManager,
                environment: environment,
                processLauncher: processLauncher
            )
            log.append("[Kimi] Resolved managed provider at host \(info.baseURL.host ?? "unknown")")
        } catch {
            log.append("[Kimi] Failed to resolve managed provider: \(error.localizedDescription)")
            throw error
        }

        let credential: KimiOAuthCredential
        do {
            credential = try await credentialProvider.validCredential(for: info)
            log.append("[Kimi] Loaded valid OAuth credential")
        } catch {
            log.append("[Kimi] Failed to load valid credential: \(error.localizedDescription)")
            throw error
        }

        let usageURL = info.baseURL.appendingPathComponent("usages")
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = usageTimeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await performUsageRequest(request)
        } catch {
            log.append("[Kimi] Usage request transport failed")
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw KimiCodeError.usageTransportFailed("invalid response")
        }

        log.append("[Kimi] Usage response status \(httpResponse.statusCode)")

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw KimiCodeError.tokenRevoked
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw KimiCodeError.usageRequestFailed(httpResponse.statusCode)
        }

        do {
            let usageResponse = try JSONDecoder().decode(KimiUsageResponse.self, from: data)
            let snapshot = try KimiQuotaParser.snapshot(from: usageResponse, fetchedAt: clock.now)
            log.append("[Kimi] Parsed usage snapshot successfully")
            return snapshot
        } catch let error as KimiCodeError {
            log.append("[Kimi] Usage parsing failed: \(error.localizedDescription)")
            throw error
        } catch {
            log.append("[Kimi] Usage parsing failed: \(error.localizedDescription)")
            throw KimiCodeError.usageMalformed(error.localizedDescription)
        }
    }

    private func performUsageRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let maxAttempts = 3
        let retryableStatuses: Set<Int> = [429, 500, 502, 503]
        var lastTransportError: Error?

        for attempt in 0..<maxAttempts {
            if Task.isCancelled {
                throw KimiCodeError.cancelled
            }

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await networkSession.data(for: request)
            } catch is CancellationError {
                throw KimiCodeError.cancelled
            } catch {
                lastTransportError = error
                if attempt < maxAttempts - 1 {
                    log.append("[Kimi] Usage request transport failed; will retry")
                    try? await clock.sleep(pow(2.0, Double(attempt)))
                    continue
                }
                break
            }

            if let httpResponse = response as? HTTPURLResponse,
               retryableStatuses.contains(httpResponse.statusCode),
               attempt < maxAttempts - 1 {
                log.append("[Kimi] Usage request returned HTTP \(httpResponse.statusCode); will retry")
                try? await clock.sleep(pow(2.0, Double(attempt)))
                continue
            }

            return (data, response)
        }

        if let error = lastTransportError as? KimiCodeError {
            throw error
        }
        if let urlError = lastTransportError as? URLError, urlError.code == .timedOut {
            throw KimiCodeError.timeout
        }
        throw KimiCodeError.usageTransportFailed("transport failure")
    }
}

public protocol KimiConfigurationResolving: Sendable {
    func resolve(
        overrideBinaryPath: String?,
        fileManager: FileManager,
        environment: [String: String],
        processLauncher: KimiProcessLaunching
    ) async throws -> KimiManagedProviderInfo
}

public struct KimiCodeConfigurationResolver: KimiConfigurationResolving {
    public init() {}

    public func resolve(
        overrideBinaryPath: String?,
        fileManager: FileManager,
        environment: [String: String],
        processLauncher: KimiProcessLaunching
    ) async throws -> KimiManagedProviderInfo {
        try await KimiCodeConfiguration.resolve(
            overrideBinaryPath: overrideBinaryPath,
            fileManager: fileManager,
            environment: environment,
            processLauncher: processLauncher
        )
    }
}

public protocol KimiOAuthCredentialResolving: Sendable {
    func validCredential(for info: KimiManagedProviderInfo) async throws -> KimiOAuthCredential
}

extension KimiOAuthCredentialProvider: KimiOAuthCredentialResolving {}
