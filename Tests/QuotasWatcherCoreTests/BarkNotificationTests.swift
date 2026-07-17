import Foundation
import XCTest
@testable import QuotasWatcherCore

final class BarkNotificationTests: XCTestCase {
    func testDetectsScheduledFiveHourResetWhenResetDateAdvances() {
        let previous = snapshot(
            fiveHour: limit(.fiveHour, remaining: 100, reset: 1_000),
            weekly: nil,
            fetchedAt: 900
        )
        let current = snapshot(
            fiveHour: limit(.fiveHour, remaining: 100, reset: 2_000),
            weekly: nil,
            fetchedAt: 1_010
        )

        XCTAssertEqual(
            QuotaResetDetector.events(previous: previous, current: current),
            [QuotaResetEvent(
                kind: .fiveHourReset,
                changes: [QuotaResetChange(
                    kind: .fiveHour,
                    previousRemainingPercent: 100,
                    currentRemainingPercent: 100
                )]
            )]
        )
    }

    func testDetectsScheduledWeeklyReset() {
        let previous = snapshot(
            fiveHour: nil,
            weekly: limit(.weekly, remaining: 20, reset: 1_000),
            fetchedAt: 900
        )
        let current = snapshot(
            fiveHour: nil,
            weekly: limit(.weekly, remaining: 95, reset: 10_000),
            fetchedAt: 1_010
        )

        XCTAssertEqual(
            QuotaResetDetector.events(previous: previous, current: current).map(\.kind),
            [.weeklyReset]
        )
    }

    func testCombinesEarlyLargeIncreasesIntoOtherReset() {
        let previous = snapshot(
            fiveHour: limit(.fiveHour, remaining: 20, reset: 10_000),
            weekly: limit(.weekly, remaining: 30, reset: 20_000),
            fetchedAt: 1_000
        )
        let current = snapshot(
            fiveHour: limit(.fiveHour, remaining: 80, reset: 30_000),
            weekly: limit(.weekly, remaining: 45, reset: 40_000),
            fetchedAt: 1_100
        )

        let events = QuotaResetDetector.events(previous: previous, current: current)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .otherReset)
        XCTAssertEqual(events.first?.changes.map(\.kind), [.fiveHour, .weekly])
    }

    func testIgnoresEarlyIncreaseBelowThreshold() {
        let previous = snapshot(
            fiveHour: limit(.fiveHour, remaining: 20, reset: 10_000),
            weekly: nil,
            fetchedAt: 1_000
        )
        let current = snapshot(
            fiveHour: limit(.fiveHour, remaining: 29.9, reset: 20_000),
            weekly: nil,
            fetchedAt: 1_100
        )

        XCTAssertTrue(QuotaResetDetector.events(previous: previous, current: current).isEmpty)
    }

    func testTreatsIncreaseInsideBoundaryAsScheduledOnlyWhenResetDateAdvances() {
        let previous = snapshot(
            fiveHour: limit(.fiveHour, remaining: 20, reset: 1_000),
            weekly: nil,
            fetchedAt: 600
        )
        let current = snapshot(
            fiveHour: limit(.fiveHour, remaining: 90, reset: 1_000),
            weekly: nil,
            fetchedAt: 750
        )

        XCTAssertTrue(QuotaResetDetector.events(previous: previous, current: current).isEmpty)
    }

    func testDetectsStrongOtherResetEvidenceAcrossTwoHourGap() {
        let previous = snapshot(
            fiveHour: nil,
            weekly: limit(.weekly, remaining: 63, reset: 20_000),
            fetchedAt: 0
        )
        let current = snapshot(
            fiveHour: nil,
            weekly: limit(.weekly, remaining: 100, reset: 100_000),
            fetchedAt: 2 * 60 * 60
        )

        XCTAssertEqual(
            QuotaResetDetector.events(previous: previous, current: current).map(\.kind),
            [.otherReset]
        )
    }

    func testRequiresResetDateToAdvanceForOtherReset() {
        let previous = snapshot(
            fiveHour: limit(.fiveHour, remaining: 20, reset: 20_000),
            weekly: nil,
            fetchedAt: 0
        )
        let current = snapshot(
            fiveHour: limit(.fiveHour, remaining: 100, reset: 20_000),
            weekly: nil,
            fetchedAt: 2 * 60 * 60
        )

        XCTAssertTrue(QuotaResetDetector.events(previous: previous, current: current).isEmpty)
    }

    func testIgnoresOtherResetEvidenceAfterSixHourGap() {
        let previous = snapshot(
            fiveHour: limit(.fiveHour, remaining: 20, reset: 100_000),
            weekly: nil,
            fetchedAt: 0
        )
        let current = snapshot(
            fiveHour: limit(.fiveHour, remaining: 100, reset: 200_000),
            weekly: nil,
            fetchedAt: 6 * 60 * 60 + 1
        )

        XCTAssertTrue(QuotaResetDetector.events(previous: previous, current: current).isEmpty)
    }

    func testIgnoresScheduledResetAfterThirtyMinuteGap() {
        let previous = snapshot(
            fiveHour: limit(.fiveHour, remaining: 20, reset: 1_000),
            weekly: nil,
            fetchedAt: 0
        )
        let current = snapshot(
            fiveHour: limit(.fiveHour, remaining: 100, reset: 5_000),
            weekly: nil,
            fetchedAt: 30 * 60 + 1
        )

        XCTAssertTrue(QuotaResetDetector.events(previous: previous, current: current).isEmpty)
    }

    func testDetectsResetBankIncreaseAcrossLongObservationGap() {
        let previous = snapshot(
            fiveHour: nil,
            weekly: nil,
            fetchedAt: 0,
            availableResetCount: 2
        )
        let current = snapshot(
            fiveHour: nil,
            weekly: nil,
            fetchedAt: 3_600,
            availableResetCount: 4
        )

        XCTAssertEqual(
            QuotaResetDetector.events(previous: previous, current: current),
            [QuotaResetEvent(
                kind: .resetBankIncrease,
                resetBankChange: ResetBankChange(previousCount: 2, currentCount: 4)
            )]
        )
    }

    func testDoesNotReportResetBankWhenCountIsUnavailableOrDoesNotIncrease() {
        let baseline = snapshot(
            fiveHour: nil,
            weekly: nil,
            fetchedAt: 0,
            availableResetCount: 3
        )
        let unchanged = snapshot(
            fiveHour: nil,
            weekly: nil,
            fetchedAt: 100,
            availableResetCount: 3
        )
        let decreased = snapshot(
            fiveHour: nil,
            weekly: nil,
            fetchedAt: 100,
            availableResetCount: 2
        )
        let unavailable = snapshot(
            fiveHour: nil,
            weekly: nil,
            fetchedAt: 100,
            availableResetCount: nil
        )

        XCTAssertTrue(QuotaResetDetector.events(previous: baseline, current: unchanged).isEmpty)
        XCTAssertTrue(QuotaResetDetector.events(previous: baseline, current: decreased).isEmpty)
        XCTAssertTrue(QuotaResetDetector.events(previous: baseline, current: unavailable).isEmpty)
    }

    func testPersistsSettingsAndLastObservation() throws {
        let suiteName = "BarkNotificationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = BarkNotificationPreferences(defaults: defaults, keyPrefix: "test")
        let settings = BarkNotificationSettings(
            deviceKey: "  example-key  ",
            notifyFiveHourReset: true,
            notifyWeeklyReset: false,
            notifyOtherReset: true,
            notifyResetBankIncrease: true
        )
        let observation = snapshot(
            fiveHour: limit(.fiveHour, remaining: 40, reset: 5_000),
            weekly: nil,
            fetchedAt: 1_000
        )

        preferences.saveSettings(settings)
        preferences.saveLastObservation(observation)

        XCTAssertEqual(preferences.loadSettings().deviceKey, "example-key")
        XCTAssertTrue(preferences.loadSettings().isEnabled(.fiveHourReset))
        XCTAssertFalse(preferences.loadSettings().isEnabled(.weeklyReset))
        XCTAssertTrue(preferences.loadSettings().isEnabled(.otherReset))
        XCTAssertTrue(preferences.loadSettings().isEnabled(.resetBankIncrease))
        XCTAssertEqual(preferences.loadLastObservation(), observation)

        preferences.saveSettings(BarkNotificationSettings())
        XCTAssertEqual(preferences.loadSettings().deviceKey, "")
    }

    func testMigratesResetBankSettingFromOtherResetPreference() throws {
        let suiteName = "BarkNotificationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "test.notifyOtherReset")
        let preferences = BarkNotificationPreferences(defaults: defaults, keyPrefix: "test")

        XCTAssertTrue(preferences.loadSettings().notifyResetBankIncrease)

        var settings = preferences.loadSettings()
        settings.notifyResetBankIncrease = false
        preferences.saveSettings(settings)
        XCTAssertFalse(preferences.loadSettings().notifyResetBankIncrease)
    }

    func testBuildsPublicBarkEndpointFromKeyOrURL() throws {
        XCTAssertEqual(
            try BarkPushClient.endpoint(for: " example-key ").absoluteString,
            "https://api.day.app/example-key"
        )
        XCTAssertEqual(
            try BarkPushClient.endpoint(for: "https://api.day.app/example-key/").absoluteString,
            "https://api.day.app/example-key"
        )
        XCTAssertThrowsError(try BarkPushClient.endpoint(for: "https://example.com/example-key"))
        XCTAssertThrowsError(try BarkPushClient.endpoint(for: "https://api.day.app/example-key/message"))
    }

    func testSendsExpectedJSONRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BarkURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BarkPushClient(session: session)
        BarkURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.day.app/example-key")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
            let body = try XCTUnwrap(Self.requestBody(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(json["title"], "Title")
            XCTAssertEqual(json["body"], "Body")
            XCTAssertEqual(json["group"], "QuotasWatcher")
            XCTAssertEqual(json["level"], "active")
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, Data(#"{"code":200,"message":"success"}"#.utf8))
        }
        defer { BarkURLProtocol.requestHandler = nil }

        try await client.send(deviceKey: "example-key", title: "Title", body: "Body")
    }

    private static func requestBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else {
                return nil
            }
            if count == 0 {
                break
            }
            result.append(buffer, count: count)
        }
        return result
    }

    private func snapshot(
        fiveHour: QuotaLimit?,
        weekly: QuotaLimit?,
        fetchedAt: TimeInterval,
        availableResetCount: Int? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            fiveHour: fiveHour,
            weekly: weekly,
            fetchedAt: Date(timeIntervalSince1970: fetchedAt),
            availableResetCount: availableResetCount
        )
    }

    private func limit(_ kind: QuotaKind, remaining: Double, reset: TimeInterval?) -> QuotaLimit {
        QuotaLimit(
            kind: kind,
            window: RateLimitWindow(
                usedPercent: 100 - remaining,
                windowDurationMins: kind == .fiveHour ? 300 : 10_080,
                resetsAt: reset
            )
        )
    }
}

private final class BarkURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("Missing Bark URL protocol handler")
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
