import XCTest
@testable import QuotasWatcherCore

final class KimiCodeQuotaClientTests: XCTestCase {
    private let baseInfo = KimiManagedProviderInfo(
        baseURL: URL(string: "https://api.kimi.com/coding/v1")!,
        credentialStorageName: "kimi-code",
        oauthKey: "kimi-code",
        oauthHost: nil
    )

    private let credential = KimiOAuthCredential(
        accessToken: "test-token",
        refreshToken: "refresh",
        expiresAt: Date().addingTimeInterval(3600),
        expiresIn: 3600,
        scope: nil,
        tokenType: "Bearer"
    )

    func testFetchesUsageSnapshot() async throws {
        let usageJSON = """
        {
          "usage": { "limit": "100", "remaining": "80" },
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "TIME_UNIT_MINUTE" },
              "detail": { "limit": "100", "used": "10" }
            }
          ]
        }
        """

        let networkSession = FakeNetworkSession { request in
            XCTAssertEqual(request.url?.path, "/coding/v1/usages")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(usageJSON.utf8), response)
        }

        let client = KimiCodeQuotaClient(
            configurationResolver: FakeConfigurationResolver(info: baseInfo),
            credentialProvider: FakeCredentialProvider(credential: credential),
            networkSession: networkSession,
            processLauncher: FakeProcessLauncher(),
            clock: FakeClock(now: Date()),
            log: AppLog.shared,
            usageTimeout: 8
        )

        let snapshot = try await client.fetchQuotaSnapshot()
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 90)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 80)
    }

    func test401BecomesTokenRevokedError() async {
        let networkSession = FakeNetworkSession { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }

        let client = KimiCodeQuotaClient(
            configurationResolver: FakeConfigurationResolver(info: baseInfo),
            credentialProvider: FakeCredentialProvider(credential: credential),
            networkSession: networkSession,
            processLauncher: FakeProcessLauncher(),
            clock: FakeClock(now: Date()),
            log: AppLog.shared,
            usageTimeout: 8
        )

        do {
            _ = try await client.fetchQuotaSnapshot()
            XCTFail("Expected token revoked error")
        } catch {
            XCTAssertEqual((error as? KimiCodeError), .tokenRevoked)
        }
    }

    func test403BecomesTokenRevokedError() async {
        let networkSession = FakeNetworkSession { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }

        let client = KimiCodeQuotaClient(
            configurationResolver: FakeConfigurationResolver(info: baseInfo),
            credentialProvider: FakeCredentialProvider(credential: credential),
            networkSession: networkSession,
            processLauncher: FakeProcessLauncher(),
            clock: FakeClock(now: Date()),
            log: AppLog.shared,
            usageTimeout: 8
        )

        do {
            _ = try await client.fetchQuotaSnapshot()
            XCTFail("Expected token revoked error")
        } catch {
            XCTAssertEqual((error as? KimiCodeError), .tokenRevoked)
        }
    }

    func testOtherHTTPStatusBecomesRequestFailed() async {
        let networkSession = FakeNetworkSession { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 418,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }

        let client = KimiCodeQuotaClient(
            configurationResolver: FakeConfigurationResolver(info: baseInfo),
            credentialProvider: FakeCredentialProvider(credential: credential),
            networkSession: networkSession,
            processLauncher: FakeProcessLauncher(),
            clock: FakeClock(now: Date()),
            log: AppLog.shared,
            usageTimeout: 8
        )

        do {
            _ = try await client.fetchQuotaSnapshot()
            XCTFail("Expected request failed error")
        } catch {
            XCTAssertEqual((error as? KimiCodeError), .usageRequestFailed(418))
        }
    }

    func testInvalidJSONBecomesMalformedError() async {
        let networkSession = FakeNetworkSession { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data("not json".utf8), response)
        }

        let client = KimiCodeQuotaClient(
            configurationResolver: FakeConfigurationResolver(info: baseInfo),
            credentialProvider: FakeCredentialProvider(credential: credential),
            networkSession: networkSession,
            processLauncher: FakeProcessLauncher(),
            clock: FakeClock(now: Date()),
            log: AppLog.shared,
            usageTimeout: 8
        )

        do {
            _ = try await client.fetchQuotaSnapshot()
            XCTFail("Expected malformed error")
        } catch {
            if case .usageMalformed = error as? KimiCodeError {
                // pass
            } else {
                XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testUnexpectedPayloadBecomesParseError() async {
        let networkSession = FakeNetworkSession { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data("{\"limits\":[]}".utf8), response)
        }

        let client = KimiCodeQuotaClient(
            configurationResolver: FakeConfigurationResolver(info: baseInfo),
            credentialProvider: FakeCredentialProvider(credential: credential),
            networkSession: networkSession,
            processLauncher: FakeProcessLauncher(),
            clock: FakeClock(now: Date()),
            log: AppLog.shared,
            usageTimeout: 8
        )

        do {
            _ = try await client.fetchQuotaSnapshot()
            XCTFail("Expected parse error")
        } catch {
            if case .usageInvalidPayload = error as? KimiCodeError {
                // pass
            } else {
                XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testTransportFailureRetriesBounded() async {
        let callCount = LockedCounter()
        let networkSession = FakeNetworkSession { request in
            callCount.increment()
            throw KimiCodeError.usageTransportFailed("network down")
        }

        let client = KimiCodeQuotaClient(
            configurationResolver: FakeConfigurationResolver(info: baseInfo),
            credentialProvider: FakeCredentialProvider(credential: credential),
            networkSession: networkSession,
            processLauncher: FakeProcessLauncher(),
            clock: FakeClock(now: Date()),
            log: AppLog.shared,
            usageTimeout: 8
        )

        do {
            _ = try await client.fetchQuotaSnapshot()
            XCTFail("Expected transport failure")
        } catch {
            XCTAssertEqual(callCount.value, 3)
        }
    }

    func test429RetriesThenSucceeds() async throws {
        let callCount = LockedCounter()
        let usageJSON = """
        {
          "usage": { "limit": "100", "remaining": "80" },
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "minute" },
              "detail": { "limit": "100", "used": "10" }
            }
          ]
        }
        """

        let networkSession = FakeNetworkSession { request in
            callCount.increment()
            if callCount.value < 3 {
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(usageJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let client = KimiCodeQuotaClient(
            configurationResolver: FakeConfigurationResolver(info: baseInfo),
            credentialProvider: FakeCredentialProvider(credential: credential),
            networkSession: networkSession,
            processLauncher: FakeProcessLauncher(),
            clock: FakeClock(now: Date()),
            log: AppLog.shared,
            usageTimeout: 8
        )

        let snapshot = try await client.fetchQuotaSnapshot()
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 90)
        XCTAssertEqual(callCount.value, 3)
    }

    func testTimeoutBecomesTypedTimeoutError() async {
        let callCount = LockedCounter()
        let networkSession = FakeNetworkSession { _ in
            callCount.increment()
            throw URLError(.timedOut)
        }

        let client = KimiCodeQuotaClient(
            configurationResolver: FakeConfigurationResolver(info: baseInfo),
            credentialProvider: FakeCredentialProvider(credential: credential),
            networkSession: networkSession,
            processLauncher: FakeProcessLauncher(),
            clock: FakeClock(now: Date()),
            log: AppLog.shared,
            usageTimeout: 8
        )

        do {
            _ = try await client.fetchQuotaSnapshot()
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual((error as? KimiCodeError), .timeout)
            XCTAssertEqual(callCount.value, 3)
        }
    }

    func testCancellationStopsUsageRequest() async {
        let networkSession = FakeNetworkSession { _ in
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return (Data(), HTTPURLResponse(url: URL(string: "https://api.kimi.com/coding/v1/usages")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let client = KimiCodeQuotaClient(
            configurationResolver: FakeConfigurationResolver(info: baseInfo),
            credentialProvider: FakeCredentialProvider(credential: credential),
            networkSession: networkSession,
            processLauncher: FakeProcessLauncher(),
            clock: FakeClock(now: Date()),
            log: AppLog.shared,
            usageTimeout: 8
        )

        let task = Task {
            try await client.fetchQuotaSnapshot()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual((error as? KimiCodeError), .cancelled)
        }
    }
}
