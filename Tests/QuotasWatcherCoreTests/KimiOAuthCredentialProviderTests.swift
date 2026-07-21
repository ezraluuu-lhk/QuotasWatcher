import XCTest
@testable import QuotasWatcherCore

final class KimiOAuthCredentialProviderTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    // MARK: - Credential reading

    func testValidTokenOutsideThresholdRequiresNoRefresh() async throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        let credentialURL = writeCredential(
            accessToken: "valid",
            refreshToken: "refresh",
            expiresAt: 1000,
            expiresIn: 1000
        )

        let provider = makeProvider(clock: clock)

        let credential = try await provider.validCredential(for: managedInfo())
        XCTAssertEqual(credential.accessToken, "valid")
        XCTAssertTrue(FileManager.default.fileExists(atPath: credentialURL.path))
    }

    func testMissingCredentialYieldsCredentialNotFound() async {
        let provider = makeProvider()

        do {
            _ = try await provider.validCredential(for: managedInfo())
            XCTFail("Expected credential not found")
        } catch {
            XCTAssertEqual((error as? KimiCodeError), .credentialNotFound)
        }
    }

    func testCorruptCredentialYieldsMalformedError() async {
        let credentialsDir = tempDirectory.appendingPathComponent("credentials", isDirectory: true)
        try? FileManager.default.createDirectory(at: credentialsDir, withIntermediateDirectories: true)
        try? "not json".data(using: .utf8)?.write(to: credentialsDir.appendingPathComponent("kimi-code.json"))

        let provider = makeProvider()

        do {
            _ = try await provider.validCredential(for: managedInfo())
            XCTFail("Expected malformed error")
        } catch {
            if case .credentialMalformed = error as? KimiCodeError {
                // pass
            } else {
                XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testEmptyCredentialFileYieldsMalformedError() async {
        let credentialsDir = tempDirectory.appendingPathComponent("credentials", isDirectory: true)
        try? FileManager.default.createDirectory(at: credentialsDir, withIntermediateDirectories: true)
        try? Data().write(to: credentialsDir.appendingPathComponent("kimi-code.json"))

        let provider = makeProvider()

        do {
            _ = try await provider.validCredential(for: managedInfo())
            XCTFail("Expected malformed error")
        } catch {
            if case .credentialMalformed = error as? KimiCodeError {
                // pass
            } else {
                XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testEmptyObjectCredentialYieldsRevoked() async {
        let credentialsDir = tempDirectory.appendingPathComponent("credentials", isDirectory: true)
        try? FileManager.default.createDirectory(at: credentialsDir, withIntermediateDirectories: true)
        try? "{}".data(using: .utf8)?.write(to: credentialsDir.appendingPathComponent("kimi-code.json"))

        let provider = makeProvider()

        do {
            _ = try await provider.validCredential(for: managedInfo())
            XCTFail("Expected revoked error")
        } catch {
            XCTAssertEqual((error as? KimiCodeError), .tokenRevoked)
        }
    }

    func testRevokedTombstoneYieldsRevoked() async throws {
        // Official tombstone shape written by Kimi after an unauthorized refresh.
        writeCredential(accessToken: "", refreshToken: "", expiresAt: 0, expiresIn: 0)

        let provider = makeProvider()

        do {
            _ = try await provider.validCredential(for: managedInfo())
            XCTFail("Expected revoked error")
        } catch {
            XCTAssertEqual((error as? KimiCodeError), .tokenRevoked)
        }
    }

    func testValidTokenWithoutRefreshTokenIsUsable() async throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(accessToken: "valid", refreshToken: "", expiresAt: 1000, expiresIn: 1000)

        let provider = makeProvider(clock: clock)

        let credential = try await provider.validCredential(for: managedInfo())
        XCTAssertEqual(credential.accessToken, "valid")
    }

    func testRefreshRequiredWithoutRefreshTokenYieldsRevoked() async {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(accessToken: "old", refreshToken: "", expiresAt: 200, expiresIn: 400)

        let lock = FakeLockCoordinator()
        let provider = makeProvider(clock: clock, lockCoordinator: lock)

        do {
            _ = try await provider.validCredential(for: managedInfo())
            XCTFail("Expected revoked error")
        } catch {
            XCTAssertEqual((error as? KimiCodeError), .tokenRevoked)
            let sentinelURL = await provider.lockSentinelURL(for: managedInfo())
            let released = await lock.isReleased(sentinelURL)
            XCTAssertTrue(released)
        }
    }

    func testDefaultHomeUsedWhenNoOverride() async throws {
        let provider = KimiOAuthCredentialProvider(
            fileManager: FileManager.default,
            environment: [:],
            clock: FakeClock(now: Date()),
            networkSession: FailingNetworkSession(),
            lockCoordinator: FakeLockCoordinator()
        )

        let url = await provider.credentialFileURL(for: managedInfo())
        XCTAssertTrue(url.path.hasSuffix("/.kimi-code/credentials/kimi-code.json"), "unexpected path \(url.path)")
    }

    // MARK: - Refresh protocol

    func testTokenInsideThresholdRefreshesAndWritesAtomically() async throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        let credentialURL = writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let networkSession = FakeNetworkSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://auth.kimi.com/api/oauth/token")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            let pairs = parseForm(body)
            XCTAssertEqual(pairs["grant_type"], "refresh_token")
            XCTAssertEqual(pairs["refresh_token"], "refresh")
            XCTAssertEqual(pairs["client_id"], KimiOAuthCredentialProvider.clientID)

            let responseJSON = """
            {
              "access_token": "new_access",
              "refresh_token": "new_refresh",
              "expires_in": 3600,
              "scope": "default"
            }
            """
            return (Data(responseJSON.utf8), makeHTTPResponse(url: request.url!, statusCode: 200))
        }

        let provider = makeProvider(clock: clock, networkSession: networkSession)

        let credential = try await provider.validCredential(for: managedInfo())
        XCTAssertEqual(credential.accessToken, "new_access")
        XCTAssertEqual(credential.refreshToken, "new_refresh")

        let updatedData = try Data(contentsOf: credentialURL)
        let updatedJSON = try JSONSerialization.jsonObject(with: updatedData) as? [String: Any]
        XCTAssertEqual(updatedJSON?["access_token"] as? String, "new_access")

        let attributes = try FileManager.default.attributesOfItem(atPath: credentialURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.uint16Value ?? 0) & 0o777, 0o600)
    }

    func testWrittenCredentialRoundTripsAllFields() async throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        let credentialURL = writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let networkSession = FakeNetworkSession { request in
            let responseJSON = """
            {
              "access_token": "new_access",
              "refresh_token": "new_refresh",
              "expires_in": 3600,
              "scope": "new_scope",
              "token_type": "Bearer"
            }
            """
            return (Data(responseJSON.utf8), makeHTTPResponse(url: request.url!, statusCode: 200))
        }

        let provider = makeProvider(clock: clock, networkSession: networkSession)
        _ = try await provider.validCredential(for: managedInfo())

        let updatedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: credentialURL)) as? [String: Any]
        XCTAssertEqual(updatedJSON?["access_token"] as? String, "new_access")
        XCTAssertEqual(updatedJSON?["refresh_token"] as? String, "new_refresh")
        XCTAssertEqual(updatedJSON?["expires_in"] as? TimeInterval, 3600)
        XCTAssertEqual(updatedJSON?["expires_at"] as? TimeInterval, 3600)
        XCTAssertEqual(updatedJSON?["scope"] as? String, "new_scope")
        XCTAssertEqual(updatedJSON?["token_type"] as? String, "Bearer")
    }

    func testRefreshUsesConfiguredOAuthHost() async throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let networkSession = FakeNetworkSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://auth.example.com/api/oauth/token")
            let responseJSON = """
            {"access_token": "new", "refresh_token": "new", "expires_in": 3600}
            """
            return (Data(responseJSON.utf8), makeHTTPResponse(url: request.url!, statusCode: 200))
        }

        let provider = makeProvider(clock: clock, networkSession: networkSession)

        let info = KimiManagedProviderInfo(
            baseURL: URL(string: "https://api.kimi.com/coding/v1")!,
            credentialStorageName: "kimi-code",
            oauthKey: "kimi-code",
            oauthHost: "https://auth.example.com"
        )

        let credential = try await provider.validCredential(for: info)
        XCTAssertEqual(credential.accessToken, "new")
    }

    func testRefreshUsesEnvironmentOAuthHost() async throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let networkSession = FakeNetworkSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://env-auth.example.com/api/oauth/token")
            let responseJSON = """
            {"access_token": "new", "refresh_token": "new", "expires_in": 3600}
            """
            return (Data(responseJSON.utf8), makeHTTPResponse(url: request.url!, statusCode: 200))
        }

        let provider = KimiOAuthCredentialProvider(
            fileManager: FileManager.default,
            environment: [
                "KIMI_CODE_HOME": tempDirectory.path,
                "KIMI_CODE_OAUTH_HOST": "https://env-auth.example.com"
            ],
            clock: clock,
            networkSession: networkSession,
            lockCoordinator: FakeLockCoordinator()
        )

        let credential = try await provider.validCredential(for: managedInfo())
        XCTAssertEqual(credential.accessToken, "new")
    }

    func testFormEncodingMatchesURLSearchParams() async throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "a+b&c=d%e f\u{00e9}",
            expiresAt: 200,
            expiresIn: 400
        )

        let networkSession = FakeNetworkSession { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            // Exact URLSearchParams serialization: space → '+', unreserved
            // [A-Za-z0-9*._-] pass through, everything else percent-encoded.
            XCTAssertEqual(
                body,
                "client_id=\(KimiOAuthCredentialProvider.clientID)&grant_type=refresh_token&refresh_token=a%2Bb%26c%3Dd%25e+f%C3%A9"
            )
            let pairs = parseForm(body)
            XCTAssertEqual(pairs["refresh_token"], "a+b&c=d%e f\u{00e9}")
            let responseJSON = """
            {"access_token": "new", "refresh_token": "new", "expires_in": 3600}
            """
            return (Data(responseJSON.utf8), makeHTTPResponse(url: request.url!, statusCode: 200))
        }

        let provider = makeProvider(clock: clock, networkSession: networkSession)

        _ = try await provider.validCredential(for: managedInfo())
    }

    func testUnauthorizedRefreshYieldsRevokedError() async {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let networkSession = FakeNetworkSession { request in
            (Data(), makeHTTPResponse(url: request.url!, statusCode: 401))
        }

        let provider = makeProvider(clock: clock, networkSession: networkSession)

        do {
            _ = try await provider.validCredential(for: managedInfo())
            XCTFail("Expected revoked error")
        } catch {
            XCTAssertEqual((error as? KimiCodeError), .tokenRevoked)
        }
    }

    func testRefreshDoesNotRetry401() async {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let callCount = LockedCounter()
        let networkSession = FakeNetworkSession { request in
            callCount.increment()
            return (Data(), makeHTTPResponse(url: request.url!, statusCode: 401))
        }

        let provider = makeProvider(clock: clock, networkSession: networkSession)

        do {
            _ = try await provider.validCredential(for: managedInfo())
            XCTFail("Expected revoked error")
        } catch {
            XCTAssertEqual((error as? KimiCodeError), .tokenRevoked)
            XCTAssertEqual(callCount.value, 1)
        }
    }

    func testInvalidGrantYieldsRevokedWithoutRetry() async {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let callCount = LockedCounter()
        let networkSession = FakeNetworkSession { request in
            callCount.increment()
            let body = #"{"error": "invalid_grant"}"#
            return (Data(body.utf8), makeHTTPResponse(url: request.url!, statusCode: 400))
        }

        let provider = makeProvider(clock: clock, networkSession: networkSession)

        do {
            _ = try await provider.validCredential(for: managedInfo())
            XCTFail("Expected revoked error")
        } catch {
            XCTAssertEqual((error as? KimiCodeError), .tokenRevoked)
            XCTAssertEqual(callCount.value, 1)
        }
    }

    func testNonRetryableStatusDoesNotRetry() async {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let callCount = LockedCounter()
        let networkSession = FakeNetworkSession { request in
            callCount.increment()
            return (Data("{}".utf8), makeHTTPResponse(url: request.url!, statusCode: 400))
        }

        let provider = makeProvider(clock: clock, networkSession: networkSession)

        do {
            _ = try await provider.validCredential(for: managedInfo())
            XCTFail("Expected refresh failure")
        } catch {
            if case .tokenRefreshFailed = error as? KimiCodeError {
                // pass
            } else {
                XCTFail("Unexpected error \(error)")
            }
            XCTAssertEqual(callCount.value, 1)
        }
    }

    func testRefreshRetries429AndSucceeds() async throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let callCount = LockedCounter()
        let networkSession = FakeNetworkSession { request in
            callCount.increment()
            if callCount.value < 3 {
                return (Data(), makeHTTPResponse(url: request.url!, statusCode: 429))
            }
            let responseJSON = """
            {"access_token": "new", "refresh_token": "new", "expires_in": 3600}
            """
            return (Data(responseJSON.utf8), makeHTTPResponse(url: request.url!, statusCode: 200))
        }

        let provider = makeProvider(clock: clock, networkSession: networkSession)

        let credential = try await provider.validCredential(for: managedInfo())
        XCTAssertEqual(credential.accessToken, "new")
        XCTAssertEqual(callCount.value, 3)
    }

    func testRefreshBoundedRetryGivesUpAfterMaxAttempts() async {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let callCount = LockedCounter()
        let networkSession = FakeNetworkSession { request in
            callCount.increment()
            return (Data(), makeHTTPResponse(url: request.url!, statusCode: 503))
        }

        let provider = makeProvider(clock: clock, networkSession: networkSession)

        do {
            _ = try await provider.validCredential(for: managedInfo())
            XCTFail("Expected refresh failure")
        } catch {
            XCTAssertEqual(callCount.value, 3)
            if case .tokenRefreshFailed = error as? KimiCodeError {
                // pass
            } else {
                XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testRefreshTimeoutIsBoundedAndTyped() async {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let callCount = LockedCounter()
        let networkSession = FakeNetworkSession { _ in
            callCount.increment()
            throw URLError(.timedOut)
        }

        let provider = makeProvider(clock: clock, networkSession: networkSession)

        do {
            _ = try await provider.validCredential(for: managedInfo())
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual((error as? KimiCodeError), .timeout)
            XCTAssertEqual(callCount.value, 3)
        }
    }

    func testRefreshResponseWithMissingFieldsIsRejectedWithoutRetry() async {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let callCount = LockedCounter()
        let networkSession = FakeNetworkSession { request in
            callCount.increment()
            let responseJSON = #"{"access_token": "only_access"}"#
            return (Data(responseJSON.utf8), makeHTTPResponse(url: request.url!, statusCode: 200))
        }

        let provider = makeProvider(clock: clock, networkSession: networkSession)

        do {
            _ = try await provider.validCredential(for: managedInfo())
            XCTFail("Expected refresh failure")
        } catch {
            if case .tokenRefreshFailed = error as? KimiCodeError {
                // pass
            } else {
                XCTFail("Unexpected error \(error)")
            }
            XCTAssertEqual(callCount.value, 1)
        }
    }

    // MARK: - Lock coordination

    func testLockIsReleasedOnSuccess() async throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let lock = FakeLockCoordinator()
        let networkSession = FakeNetworkSession { request in
            let responseJSON = """
            {"access_token": "new", "refresh_token": "new", "expires_in": 3600}
            """
            return (Data(responseJSON.utf8), makeHTTPResponse(url: request.url!, statusCode: 200))
        }

        let provider = makeProvider(clock: clock, networkSession: networkSession, lockCoordinator: lock)

        let sentinelURL = await provider.lockSentinelURL(for: managedInfo())
        _ = try await provider.validCredential(for: managedInfo())
        let released = await lock.isReleased(sentinelURL)
        XCTAssertTrue(released)
        let stillAcquired = await lock.isAcquired(sentinelURL)
        XCTAssertFalse(stillAcquired)
    }

    func testLockIsReleasedOnHTTPFailure() async {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let lock = FakeLockCoordinator()
        let networkSession = FakeNetworkSession { request in
            (Data(), makeHTTPResponse(url: request.url!, statusCode: 503))
        }
        let provider = makeProvider(clock: clock, networkSession: networkSession, lockCoordinator: lock)

        let sentinelURL = await provider.lockSentinelURL(for: managedInfo())
        do {
            _ = try await provider.validCredential(for: managedInfo())
            XCTFail("Expected failure")
        } catch {
            let released = await lock.isReleased(sentinelURL)
            XCTAssertTrue(released)
        }
    }

    func testLockIsReleasedOnDecodeFailure() async {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let lock = FakeLockCoordinator()
        let networkSession = FakeNetworkSession { request in
            (Data("not json".utf8), makeHTTPResponse(url: request.url!, statusCode: 200))
        }
        let provider = makeProvider(clock: clock, networkSession: networkSession, lockCoordinator: lock)

        let sentinelURL = await provider.lockSentinelURL(for: managedInfo())
        do {
            _ = try await provider.validCredential(for: managedInfo())
            XCTFail("Expected failure")
        } catch {
            if case .tokenRefreshFailed = error as? KimiCodeError {
                // pass
            } else {
                XCTFail("Unexpected error \(error)")
            }
            let released = await lock.isReleased(sentinelURL)
            XCTAssertTrue(released)
        }
    }

    func testLockIsReleasedOnCancellation() async {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let lock = FakeLockCoordinator()
        let networkSession = FakeNetworkSession { _ in
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return (Data(), makeHTTPResponse(url: URL(string: "https://auth.kimi.com/api/oauth/token")!, statusCode: 200))
        }

        let provider = makeProvider(clock: clock, networkSession: networkSession, lockCoordinator: lock)

        let sentinelURL = await provider.lockSentinelURL(for: managedInfo())
        let task = Task {
            try await provider.validCredential(for: managedInfo())
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            // Release is awaited inside the provider, so it completed before
            // the cancellation error surfaced.
            let released = await lock.isReleased(sentinelURL)
            XCTAssertTrue(released)
        }
    }

    func testLockIsReleasedOnFilesystemFailure() async {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let home = tempDirectory!
        let lock = FakeLockCoordinator()
        let networkSession = FakeNetworkSession { request in
            // Replace the credential file with a directory so the atomic
            // rename fails deterministically.
            let credentialURL = home.appendingPathComponent("credentials/kimi-code.json")
            try? FileManager.default.removeItem(at: credentialURL)
            try? FileManager.default.createDirectory(at: credentialURL, withIntermediateDirectories: true)
            let responseJSON = """
            {"access_token": "new", "refresh_token": "new", "expires_in": 3600}
            """
            return (Data(responseJSON.utf8), makeHTTPResponse(url: request.url!, statusCode: 200))
        }
        let provider = makeProvider(clock: clock, networkSession: networkSession, lockCoordinator: lock)

        let sentinelURL = await provider.lockSentinelURL(for: managedInfo())
        do {
            _ = try await provider.validCredential(for: managedInfo())
            XCTFail("Expected failure")
        } catch {
            let released = await lock.isReleased(sentinelURL)
            XCTAssertTrue(released)
        }
    }

    func testPeerRotationDuringAcquireAvoidsRefresh() async throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let home = tempDirectory!
        let lock = FakeLockCoordinator()
        // A peer refreshes the credential while we are acquiring the lock;
        // the swap happens synchronously inside acquire, so the provider's
        // post-acquire re-read sees the rotated token deterministically.
        await lock.setOnAcquire { _ in
            writeKimiCredentialFile(
                home: home,
                accessToken: "peer_rotated",
                refreshToken: "peer_refresh",
                expiresAt: 4000,
                expiresIn: 4000
            )
        }

        let callCount = LockedCounter()
        let networkSession = FakeNetworkSession { request in
            callCount.increment()
            let responseJSON = """
            {"access_token": "new", "refresh_token": "new", "expires_in": 3600}
            """
            return (Data(responseJSON.utf8), makeHTTPResponse(url: request.url!, statusCode: 200))
        }

        let provider = makeProvider(clock: clock, networkSession: networkSession, lockCoordinator: lock)

        let credential = try await provider.validCredential(for: managedInfo())
        XCTAssertEqual(credential.accessToken, "peer_rotated")
        XCTAssertEqual(callCount.value, 0)
    }

    func testContendedLockReturnsPeerRotatedCredential() async throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let home = tempDirectory!
        let lock = FakeLockCoordinator()
        await lock.setBehavior(.fail)
        // The peer rotated the credential while holding the lock we could not
        // acquire; the wait-and-re-read path picks it up without refreshing.
        await lock.setOnAcquire { _ in
            writeKimiCredentialFile(
                home: home,
                accessToken: "peer_rotated",
                refreshToken: "peer_refresh",
                expiresAt: 4000,
                expiresIn: 4000
            )
        }

        let provider = makeProvider(clock: clock, networkSession: FailingNetworkSession(), lockCoordinator: lock)

        let credential = try await provider.validCredential(for: managedInfo())
        XCTAssertEqual(credential.accessToken, "peer_rotated")
    }

    func testContendedLockWithoutRotationYieldsLockError() async {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let lock = FakeLockCoordinator()
        await lock.setBehavior(.fail)

        let provider = makeProvider(clock: clock, networkSession: FailingNetworkSession(), lockCoordinator: lock)

        do {
            _ = try await provider.validCredential(for: managedInfo())
            XCTFail("Expected lock failure")
        } catch {
            if case .tokenRefreshFailed = error as? KimiCodeError {
                // pass
            } else {
                XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testCancellationDuringLiveLockContentionYieldsTypedCancelledError() async throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let lock = FakeLockCoordinator()
        await lock.setBehavior(.blockUntilCancelled)

        // If OAuth were contacted after cancellation, this succeeds and masks
        // the failure; the counter proves no request ever happened.
        let callCount = LockedCounter()
        let networkSession = FakeNetworkSession { request in
            callCount.increment()
            let responseJSON = """
            {"access_token": "new", "refresh_token": "new", "expires_in": 3600}
            """
            return (Data(responseJSON.utf8), makeHTTPResponse(url: request.url!, statusCode: 200))
        }

        let provider = makeProvider(clock: clock, networkSession: networkSession, lockCoordinator: lock)

        let task = Task {
            try await provider.validCredential(for: managedInfo())
        }
        // Wait until the provider is deterministically parked in the lock
        // acquisition before cancelling.
        while await lock.acquireCallCount == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual((error as? KimiCodeError), .cancelled)
        }
        XCTAssertEqual(callCount.value, 0, "OAuth must not be contacted after cancellation")
    }

    func testUnownedLockIsNotReleased() async throws {
        let lock = FakeLockCoordinator()
        let sentinelURL = tempDirectory.appendingPathComponent("oauth").appendingPathComponent("kimi-code")

        // Simulate another process owning the lock by inserting it directly.
        let lockURL = sentinelURL.appendingPathExtension("lock")
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: true)

        await lock.releaseLock(at: sentinelURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
    }

    // MARK: - Filesystem durability

    func testAtomicWritePreserves0700Directory() async throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let networkSession = FakeNetworkSession { request in
            let responseJSON = """
            {"access_token": "new", "refresh_token": "new", "expires_in": 3600}
            """
            return (Data(responseJSON.utf8), makeHTTPResponse(url: request.url!, statusCode: 200))
        }

        let provider = makeProvider(clock: clock, networkSession: networkSession)

        _ = try await provider.validCredential(for: managedInfo())

        let credentialsDir = tempDirectory.appendingPathComponent("credentials", isDirectory: true)
        let attributes = try FileManager.default.attributesOfItem(atPath: credentialsDir.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.uint16Value ?? 0) & 0o777, 0o700)
    }

    func testAtomicWriteReplacesDestinationWithoutDeletingIt() async throws {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        let credentialURL = writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let networkSession = FakeNetworkSession { request in
            let responseJSON = """
            {"access_token": "new", "refresh_token": "new", "expires_in": 3600}
            """
            return (Data(responseJSON.utf8), makeHTTPResponse(url: request.url!, statusCode: 200))
        }

        let provider = makeProvider(clock: clock, networkSession: networkSession)
        _ = try await provider.validCredential(for: managedInfo())

        // The destination was replaced by rename(2): the old token is gone,
        // the new one is present, and no temporary files remain.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: credentialURL)) as? [String: Any]
        XCTAssertEqual(json?["access_token"] as? String, "new")
        let entries = try FileManager.default.contentsOfDirectory(atPath: credentialURL.deletingLastPathComponent().path)
        XCTAssertFalse(entries.contains { $0.contains(".tmp.") })
    }

    func testAtomicWriteCleansUpTempFileWhenRenameFails() async {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        let credentialURL = writeCredential(
            accessToken: "old",
            refreshToken: "refresh",
            expiresAt: 200,
            expiresIn: 400
        )

        let networkSession = FakeNetworkSession { request in
            // Replace the credential file with a directory so rename(2) fails.
            try? FileManager.default.removeItem(at: credentialURL)
            try? FileManager.default.createDirectory(at: credentialURL, withIntermediateDirectories: true)
            let responseJSON = """
            {"access_token": "new", "refresh_token": "new", "expires_in": 3600}
            """
            return (Data(responseJSON.utf8), makeHTTPResponse(url: request.url!, statusCode: 200))
        }

        let provider = makeProvider(clock: clock, networkSession: networkSession)

        do {
            _ = try await provider.validCredential(for: managedInfo())
            XCTFail("Expected failure")
        } catch {
            let entries = try? FileManager.default.contentsOfDirectory(atPath: credentialURL.deletingLastPathComponent().path)
            XCTAssertFalse(entries?.contains { $0.contains(".tmp.") } ?? true)
            // The destination was never deleted: the directory created by the
            // fake is still there, proving the failed rename did not remove it.
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: credentialURL.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }
    }

    // MARK: - Helpers

    private func makeProvider(
        clock: KimiClock? = nil,
        networkSession: KimiNetworkSession? = nil,
        lockCoordinator: KimiLockCoordinator? = nil
    ) -> KimiOAuthCredentialProvider {
        KimiOAuthCredentialProvider(
            fileManager: FileManager.default,
            environment: ["KIMI_CODE_HOME": tempDirectory.path],
            clock: clock ?? FakeClock(now: Date()),
            networkSession: networkSession ?? FailingNetworkSession(),
            lockCoordinator: lockCoordinator ?? FakeLockCoordinator()
        )
    }

    private func managedInfo(oauthHost: String? = nil) -> KimiManagedProviderInfo {
        KimiManagedProviderInfo(
            baseURL: URL(string: "https://api.kimi.com/coding/v1")!,
            credentialStorageName: "kimi-code",
            oauthKey: "kimi-code",
            oauthHost: oauthHost
        )
    }

    @discardableResult
    private func writeCredential(accessToken: String, refreshToken: String, expiresAt: TimeInterval, expiresIn: TimeInterval) -> URL {
        writeKimiCredentialFile(
            home: tempDirectory,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            expiresIn: expiresIn
        )
    }
}

@discardableResult
func writeKimiCredentialFile(
    home: URL,
    name: String = "kimi-code",
    accessToken: String,
    refreshToken: String,
    expiresAt: TimeInterval,
    expiresIn: TimeInterval,
    scope: String? = "default",
    tokenType: String? = "Bearer"
) -> URL {
    let credentialsDir = home.appendingPathComponent("credentials", isDirectory: true)
    try? FileManager.default.createDirectory(at: credentialsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let credentialURL = credentialsDir.appendingPathComponent("\(name).json")
    var json: [String: Any] = [
        "access_token": accessToken,
        "refresh_token": refreshToken,
        "expires_at": expiresAt,
        "expires_in": expiresIn
    ]
    if let scope { json["scope"] = scope }
    if let tokenType { json["token_type"] = tokenType }
    let data = try! JSONSerialization.data(withJSONObject: json)
    try? data.write(to: credentialURL)
    return credentialURL
}

func parseForm(_ body: String) -> [String: String] {
    var pairs: [String: String] = [:]
    for component in body.split(separator: "&") {
        let parts = component.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        let key = parts[0].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? parts[0]
        let value = parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? parts[1]
        pairs[key] = value
    }
    return pairs
}
