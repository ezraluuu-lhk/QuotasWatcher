import Foundation

public struct KimiOAuthCredential: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let expiresIn: TimeInterval
    public let scope: String?
    public let tokenType: String?

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        expiresIn: TimeInterval,
        scope: String?,
        tokenType: String?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.expiresIn = expiresIn
        self.scope = scope
        self.tokenType = tokenType
    }
}

public protocol KimiClock: Sendable {
    var now: Date { get }
    func sleep(_ interval: TimeInterval) async throws
}

public struct KimiSystemClock: KimiClock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(_ interval: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
}

public protocol KimiNetworkSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: KimiNetworkSession {}

public protocol KimiLockCoordinator: Sendable {
    /// Attempt to acquire the lock guarding the sentinel target file. The coordinator
    /// is responsible for creating the `.lock` directory used by proper-lockfile.
    /// Returns `true` if this process now owns the lock, `false` if the timeout
    /// elapsed while a live peer held it. Throws `KimiCodeError.cancelled` when
    /// the calling task is cancelled while waiting.
    func acquireLock(at sentinelURL: URL, timeout: TimeInterval) async throws -> Bool
    /// Release the lock owned by this process. Must not remove a lock this process
    /// did not acquire, nor a replacement created after this process's lock
    /// directory was deleted or stolen by a peer.
    func releaseLock(at sentinelURL: URL) async
    /// Update the lock mtime while held. Called automatically by the heartbeat in
    /// the production coordinator, but exposed for tests. Must not touch a
    /// replacement lock after ownership was compromised.
    func touchLock(at sentinelURL: URL) async
}

public actor KimiFileLockCoordinator: KimiLockCoordinator {
    public static let staleThreshold: TimeInterval = 5
    public static let heartbeatInterval: TimeInterval = 2.5

    /// Concrete acquisition identity of the lock directory this process created.
    /// proper-lockfile tracks an mtime generation for the same purpose; comparing
    /// (device, inode) is strictly stronger here because a peer that deletes and
    /// recreates the directory always gets a different inode, while the mtime
    /// updates from our own heartbeat never change it.
    private struct LockIdentity: Equatable {
        let device: Int
        let inode: Int
    }

    private let fileManager: FileManager
    private var acquiredLocks: [URL: LockIdentity] = [:]
    private var heartbeatTasks: [URL: Task<Void, Never>] = [:]

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func acquireLock(at sentinelURL: URL, timeout: TimeInterval) async throws -> Bool {
        let parent = sentinelURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        // proper-lockfile locks a sentinel target file; the actual lock directory
        // is `${target}.lock`. Ensure the sentinel exists so the path is stable.
        if !fileManager.fileExists(atPath: sentinelURL.path) {
            fileManager.createFile(
                atPath: sentinelURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }

        let lockURL = lockURL(for: sentinelURL)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            try throwIfCancelled()

            do {
                try fileManager.createDirectory(at: lockURL, withIntermediateDirectories: false)
            } catch {
                try throwIfCancelled()

                // The lock is held by someone else. Break it only when it is
                // demonstrably stale (mtime older than Kimi's five-second rule),
                // checked twice so a live heartbeat is never mistaken for stale.
                breakLockIfStale(lockURL)
                try await sleepUnlessCancelled(nanoseconds: 100_000_000)
                continue
            }

            // We created the directory, so it is ours. Refresh mtime/permissions
            // and record the acquisition identity that every later heartbeat and
            // release must re-verify before touching the path.
            try? fileManager.setAttributes(
                [.modificationDate: Date(), .posixPermissions: 0o700],
                ofItemAtPath: lockURL.path
            )
            guard let identity = currentIdentity(of: lockURL) else {
                // Vanished between creation and stat; a peer is interfering.
                try await sleepUnlessCancelled(nanoseconds: 100_000_000)
                continue
            }
            acquiredLocks[lockURL] = identity
            startHeartbeat(for: lockURL)
            return true
        }

        return false
    }

    public func releaseLock(at sentinelURL: URL) async {
        let lockURL = lockURL(for: sentinelURL)
        guard let identity = acquiredLocks.removeValue(forKey: lockURL) else {
            // Never remove a lock this process did not acquire.
            return
        }

        heartbeatTasks[lockURL]?.cancel()
        heartbeatTasks.removeValue(forKey: lockURL)

        guard currentIdentity(of: lockURL) == identity else {
            // Ownership was compromised: the directory we acquired was deleted
            // or replaced by a peer. Never remove the replacement.
            return
        }
        try? fileManager.removeItem(at: lockURL)
    }

    public func touchLock(at sentinelURL: URL) async {
        touchIfOwned(lockURL(for: sentinelURL))
    }

    private func lockURL(for sentinelURL: URL) -> URL {
        sentinelURL.appendingPathExtension("lock")
    }

    private func startHeartbeat(for lockURL: URL) {
        heartbeatTasks[lockURL] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await self?.touchIfOwned(lockURL)
            }
        }
    }

    /// Refresh the lock mtime only while the on-disk directory is still the one
    /// this process acquired. If it disappeared or was replaced, mark ownership
    /// compromised, stop the heartbeat, and never touch the replacement.
    private func touchIfOwned(_ lockURL: URL) {
        guard let identity = acquiredLocks[lockURL] else { return }
        guard currentIdentity(of: lockURL) == identity else {
            heartbeatTasks[lockURL]?.cancel()
            heartbeatTasks.removeValue(forKey: lockURL)
            acquiredLocks.removeValue(forKey: lockURL)
            return
        }
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: lockURL.path
        )
    }

    private func currentIdentity(of lockURL: URL) -> LockIdentity? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: lockURL.path),
              let device = attributes[.systemNumber] as? Int,
              let inode = attributes[.systemFileNumber] as? Int else {
            return nil
        }
        return LockIdentity(device: device, inode: inode)
    }

    private func breakLockIfStale(_ lockURL: URL) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: lockURL.path),
              let modificationDate = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modificationDate) > Self.staleThreshold else {
            return
        }
        // Re-stat immediately before removal so a lock refreshed or replaced
        // since the first check is never deleted.
        guard let freshAttributes = try? fileManager.attributesOfItem(atPath: lockURL.path),
              let freshDate = freshAttributes[.modificationDate] as? Date,
              Date().timeIntervalSince(freshDate) > Self.staleThreshold else {
            return
        }
        try? fileManager.removeItem(at: lockURL)
    }

    private func throwIfCancelled() throws {
        if Task.isCancelled {
            throw KimiCodeError.cancelled
        }
    }

    private func sleepUnlessCancelled(nanoseconds: UInt64) async throws {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            throw KimiCodeError.cancelled
        }
    }
}

public actor KimiOAuthCredentialProvider {
    public static let defaultOAuthHost = "https://auth.kimi.com"
    public static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    /// Bounded coordination/transport policy mirroring Kimi 0.26.0:
    /// three refresh attempts, official retryable statuses, 1s/2s backoff.
    static let lockAcquisitionTimeout: TimeInterval = 10
    static let refreshMaxAttempts = 3
    static let retryableRefreshStatuses: Set<Int> = [429, 500, 502, 503]
    static let refreshRequestTimeout: TimeInterval = 15

    private let fileManager: FileManager
    private let environment: [String: String]
    private let clock: KimiClock
    private let networkSession: KimiNetworkSession
    private let lockCoordinator: KimiLockCoordinator
    private let log: AppLog

    public init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        clock: KimiClock = KimiSystemClock(),
        networkSession: KimiNetworkSession = URLSession.shared,
        lockCoordinator: KimiLockCoordinator = KimiFileLockCoordinator(),
        log: AppLog = .shared
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.clock = clock
        self.networkSession = networkSession
        self.lockCoordinator = lockCoordinator
        self.log = log
    }

    public func validCredential(for info: KimiManagedProviderInfo) async throws -> KimiOAuthCredential {
        let credentialURL = credentialFileURL(for: info)

        guard fileManager.fileExists(atPath: credentialURL.path) else {
            throw KimiCodeError.credentialNotFound
        }

        let credential = try readCredential(from: credentialURL)

        if !shouldRefresh(credential) {
            return credential
        }

        let sentinelURL = lockSentinelURL(for: info)
        let acquired: Bool
        do {
            acquired = try await lockCoordinator.acquireLock(at: sentinelURL, timeout: Self.lockAcquisitionTimeout)
        } catch let error as KimiCodeError {
            // The production coordinator throws typed cancellation itself.
            throw error
        } catch is CancellationError {
            // Any other coordinator that propagates raw cancellation while
            // waiting on a live peer lock still surfaces typed cancellation.
            throw KimiCodeError.cancelled
        }

        guard acquired else {
            if Task.isCancelled {
                throw KimiCodeError.cancelled
            }
            // Another process owns the lock. Wait briefly and re-read; the peer
            // may have rotated the credential while we were waiting.
            try? await clock.sleep(0.2)
            if Task.isCancelled {
                throw KimiCodeError.cancelled
            }
            if let rotated = try? readCredential(from: credentialURL), !shouldRefresh(rotated) {
                return rotated
            }
            throw KimiCodeError.tokenRefreshFailed("Could not acquire Kimi credential lock")
        }

        // The lock is owned by this process from here on; it must be released
        // exactly once, awaited, on every success and failure path.
        do {
            // Re-read after acquiring: a peer may already have rotated the
            // credential while we waited, making our own refresh unnecessary.
            let afterLockCredential = try readCredential(from: credentialURL)
            let result: KimiOAuthCredential
            if !shouldRefresh(afterLockCredential) {
                result = afterLockCredential
            } else {
                guard !afterLockCredential.refreshToken.isEmpty else {
                    throw KimiCodeError.tokenRevoked
                }
                let refreshed = try await refreshCredential(afterLockCredential, info: info)
                try atomicallyWriteCredential(refreshed, to: credentialURL)
                result = refreshed
            }
            await lockCoordinator.releaseLock(at: sentinelURL)
            return result
        } catch {
            await lockCoordinator.releaseLock(at: sentinelURL)
            throw error
        }
    }

    public func credentialFileURL(for info: KimiManagedProviderInfo) -> URL {
        kimiCodeHomeURL()
            .appendingPathComponent("credentials", isDirectory: true)
            .appendingPathComponent("\(info.credentialStorageName).json")
    }

    public func lockSentinelURL(for info: KimiManagedProviderInfo) -> URL {
        kimiCodeHomeURL()
            .appendingPathComponent("oauth", isDirectory: true)
            .appendingPathComponent(info.credentialStorageName)
    }

    private func kimiCodeHomeURL() -> URL {
        if let override = environment["KIMI_CODE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code", isDirectory: true)
    }

    private func readCredential(from url: URL) throws -> KimiOAuthCredential {
        guard let data = fileManager.contents(atPath: url.path) else {
            throw KimiCodeError.credentialNotFound
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KimiCodeError.credentialMalformed("credential file is not valid JSON")
        }

        // Mirror the official classification: a record whose access token is
        // missing or empty (including Kimi's revoked tombstone) is a revoked
        // credential, not a corrupt one.
        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw KimiCodeError.tokenRevoked
        }

        // A missing refresh token is tolerated here, matching the official
        // wire decoder; it only becomes an error when a refresh is required.
        let refreshToken = json["refresh_token"] as? String ?? ""

        let expiresAt: Date
        if let expiresAtTimestamp = json["expires_at"] as? TimeInterval {
            expiresAt = Date(timeIntervalSince1970: expiresAtTimestamp)
        } else if let expiresIn = json["expires_in"] as? TimeInterval {
            let createdAt = (json["created_at"] as? TimeInterval) ?? clock.now.timeIntervalSince1970
            expiresAt = Date(timeIntervalSince1970: createdAt + expiresIn)
        } else {
            throw KimiCodeError.credentialMalformed("missing expires_at")
        }

        let expiresIn = json["expires_in"] as? TimeInterval ?? expiresAt.timeIntervalSince(clock.now)

        return KimiOAuthCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            expiresIn: expiresIn,
            scope: json["scope"] as? String,
            tokenType: json["token_type"] as? String
        )
    }

    private func shouldRefresh(_ credential: KimiOAuthCredential) -> Bool {
        // Official rule: expires_at == 0 marks a non-expiring record.
        guard credential.expiresAt.timeIntervalSince1970 > 0 else {
            return false
        }
        let remaining = credential.expiresAt.timeIntervalSince(clock.now)
        let threshold = max(300, credential.expiresIn / 2)
        return remaining < threshold
    }

    private func refreshCredential(_ credential: KimiOAuthCredential, info: KimiManagedProviderInfo) async throws -> KimiOAuthCredential {
        let oauthHost = effectiveOAuthHost(for: info)
        guard var endpointComponents = URLComponents(string: oauthHost) else {
            throw KimiCodeError.tokenRefreshFailed("invalid OAuth host")
        }
        endpointComponents.path = endpointComponents.path
            .appending("/api/oauth/token")
            .replacingOccurrences(of: #"/+"#, with: "/", options: .regularExpression)
        guard let tokenEndpoint = endpointComponents.url else {
            throw KimiCodeError.tokenRefreshFailed("invalid OAuth host")
        }

        // Same field order as the official URLSearchParams body.
        let body = formEncodedBody([
            ("client_id", Self.clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", credential.refreshToken)
        ])

        let maxAttempts = Self.refreshMaxAttempts
        let retryableStatuses = Self.retryableRefreshStatuses
        var lastTransportError: Error?

        for attempt in 0..<maxAttempts {
            if Task.isCancelled {
                throw KimiCodeError.cancelled
            }

            var request = URLRequest(url: tokenEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = body
            request.timeoutInterval = Self.refreshRequestTimeout

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await networkSession.data(for: request)
            } catch is CancellationError {
                throw KimiCodeError.cancelled
            } catch {
                // Transport-level failure: bounded retry with official backoff.
                lastTransportError = error
                if attempt < maxAttempts - 1 {
                    log.append("[Kimi] Token refresh transport failed; will retry")
                    try? await clock.sleep(pow(2.0, Double(attempt)))
                    continue
                }
                break
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw KimiCodeError.tokenRefreshFailed("invalid response")
            }

            // Revocation is never retried: official behavior treats 401/403 and
            // an `invalid_grant` error payload as terminal.
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 || responseHasInvalidGrant(data) {
                log.append("[Kimi] Token refresh unauthorized (HTTP \(httpResponse.statusCode)); session appears revoked")
                throw KimiCodeError.tokenRevoked
            }

            if retryableStatuses.contains(httpResponse.statusCode) {
                if attempt < maxAttempts - 1 {
                    log.append("[Kimi] Token refresh returned HTTP \(httpResponse.statusCode); will retry")
                    try? await clock.sleep(pow(2.0, Double(attempt)))
                    continue
                }
                log.append("[Kimi] Token refresh returned HTTP \(httpResponse.statusCode) after \(maxAttempts) attempts")
                throw KimiCodeError.tokenRefreshFailed("HTTP \(httpResponse.statusCode)")
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                log.append("[Kimi] Token refresh returned HTTP \(httpResponse.statusCode)")
                throw KimiCodeError.tokenRefreshFailed("HTTP \(httpResponse.statusCode)")
            }

            return try parseRefreshResponse(data, previousCredential: credential)
        }

        log.append("[Kimi] Token refresh failed after \(maxAttempts) attempts")
        if let urlError = lastTransportError as? URLError, urlError.code == .timedOut {
            throw KimiCodeError.timeout
        }
        throw KimiCodeError.tokenRefreshFailed("transport failure")
    }

    /// Official non-retryable condition: an OAuth `invalid_grant` error payload.
    private func responseHasInvalidGrant(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["error"] as? String == "invalid_grant"
    }

    private func parseRefreshResponse(_ data: Data, previousCredential: KimiOAuthCredential) throws -> KimiOAuthCredential {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KimiCodeError.tokenRefreshFailed("invalid JSON response")
        }

        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty,
              let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty,
              let expiresIn = parseNumber(json["expires_in"]), expiresIn.isFinite, expiresIn > 0 else {
            throw KimiCodeError.tokenRefreshFailed("missing required token fields")
        }

        let newExpiresAt = clock.now.addingTimeInterval(expiresIn)

        return KimiOAuthCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: newExpiresAt,
            expiresIn: expiresIn,
            scope: json["scope"] as? String ?? previousCredential.scope,
            tokenType: json["token_type"] as? String ?? previousCredential.tokenType
        )
    }

    private func effectiveOAuthHost(for info: KimiManagedProviderInfo) -> String {
        let host = info.oauthHost
            ?? environment["KIMI_CODE_OAUTH_HOST"]
            ?? environment["KIMI_OAUTH_HOST"]
            ?? Self.defaultOAuthHost
        return host.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
    }

    /// Durable, atomic credential replacement mirroring Kimi's FileTokenStorage:
    /// secure the directory as 0700, write a same-directory temporary file as
    /// 0600, fsync it, then atomically `rename(2)` over the destination (which
    /// replaces an existing file without a missing-file window), fsync the
    /// directory, and remove the temporary file on any failure.
    private func atomicallyWriteCredential(_ credential: KimiOAuthCredential, to url: URL) throws {
        let directory = url.deletingLastPathComponent()

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Ensure the credential directory remains 0700.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        var json: [String: Any] = [
            "access_token": credential.accessToken,
            "refresh_token": credential.refreshToken,
            "expires_at": credential.expiresAt.timeIntervalSince1970,
            "expires_in": credential.expiresIn
        ]
        if let scope = credential.scope { json["scope"] = scope }
        if let tokenType = credential.tokenType { json["token_type"] = tokenType }

        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let temporaryURL = directory.appendingPathComponent(
            "\(url.lastPathComponent).tmp.\(getpid()).\(UUID().uuidString)"
        )

        do {
            guard fileManager.createFile(
                atPath: temporaryURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw KimiCodeError.tokenRefreshFailed("could not create temp credential file")
            }

            let handle = try FileHandle(forWritingTo: temporaryURL)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            // rename(2) atomically replaces the destination on the same
            // filesystem; the destination is never deleted beforehand.
            guard rename(temporaryURL.path, url.path) == 0 else {
                throw KimiCodeError.tokenRefreshFailed("could not replace credential file (errno \(errno))")
            }

            // fsync the directory so the rename is durable.
            if let dirHandle = try? FileHandle(forReadingFrom: directory) {
                try? dirHandle.synchronize()
                try? dirHandle.close()
            }

            // Ensure the destination file has 0600 permissions.
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func parseNumber(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let double = Double(string) { return double }
        return nil
    }

    /// Serializes ordered key/value pairs exactly like the official
    /// `URLSearchParams(...).toString()`: space becomes `+`, ASCII
    /// alphanumerics and `*` `-` `.` `_` pass through, and every other byte of
    /// the UTF-8 representation is percent-encoded with uppercase hex.
    private func formEncodedBody(_ parameters: [(String, String)]) -> Data {
        Data(
            parameters
                .map { "\(formEncode($0.0))=\(formEncode($0.1))" }
                .joined(separator: "&")
                .utf8
        )
    }

    private func formEncode(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.utf8.count)
        for scalar in string.unicodeScalars {
            if isFormUnreserved(scalar) {
                result.append(String(scalar))
            } else if scalar == " " {
                result.append("+")
            } else {
                for byte in scalar.utf8 {
                    result.append("%")
                    result.append(Self.uppercaseHex[Int(byte >> 4)])
                    result.append(Self.uppercaseHex[Int(byte & 0x0F)])
                }
            }
        }
        return result
    }

    private static let uppercaseHex: [Character] = Array("0123456789ABCDEF")

    private func isFormUnreserved(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "*", "-", ".", "_":
            return true
        default:
            return false
        }
    }
}
