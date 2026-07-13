import XCTest
@testable import QuotasWatcherCore

final class QuotaParsingTests: XCTestCase {
    func testDecodesSingleRateLimitPayload() throws {
        let response = try decode("""
        {
          "rateLimits": {
            "limitId": "legacy",
            "limitName": "Codex",
            "primary": { "usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1000 },
            "secondary": { "usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 2000 }
          },
          "rateLimitsByLimitId": null
        }
        """)

        let snapshot = QuotaParser.snapshot(from: response, fetchedAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 75)
        XCTAssertEqual(snapshot.fiveHour?.resetDate, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 60)
        XCTAssertEqual(snapshot.weekly?.windowDurationMins, 10080)
    }

    func testPrefersCodexBucketFromMultiBucketPayload() throws {
        let response = try decode("""
        {
          "rateLimits": {
            "limitId": "legacy",
            "limitName": "Legacy",
            "primary": { "usedPercent": 90, "windowDurationMins": 300, "resetsAt": 1000 },
            "secondary": { "usedPercent": 90, "windowDurationMins": 10080, "resetsAt": 2000 }
          },
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "limitName": "Codex",
              "primary": { "usedPercent": 12.5, "windowDurationMins": 300, "resetsAt": 3000 },
              "secondary": { "usedPercent": 65.5, "windowDurationMins": 10080, "resetsAt": 4000 }
            }
          }
        }
        """)

        let snapshot = QuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 87.5)
        XCTAssertEqual(snapshot.fiveHour?.resetDate, Date(timeIntervalSince1970: 3000))
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 34.5)
    }

    func testHandlesNullWindowsAndResetTimes() throws {
        let response = try decode("""
        {
          "rateLimits": {
            "limitId": "codex",
            "limitName": "Codex",
            "primary": { "usedPercent": 110, "windowDurationMins": 300, "resetsAt": null },
            "secondary": null
          },
          "rateLimitsByLimitId": null
        }
        """)

        let snapshot = QuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 0)
        XCTAssertNil(snapshot.fiveHour?.resetDate)
        XCTAssertNil(snapshot.weekly)
    }

    func testClassifiesWeeklyOnlyPrimaryWindowByDuration() throws {
        let response = try decode("""
        {
          "rateLimits": {
            "limitId": "codex",
            "limitName": null,
            "primary": { "usedPercent": 1, "windowDurationMins": 10080, "resetsAt": 1784507267 },
            "secondary": null
          },
          "rateLimitsByLimitId": null
        }
        """)

        let snapshot = QuotaParser.snapshot(from: response)
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 99)
        XCTAssertEqual(snapshot.weekly?.windowDurationMins, 10_080)
    }

    func testClassifiesWindowsByDurationInsteadOfPosition() throws {
        let response = try decode("""
        {
          "rateLimits": {
            "limitId": "codex",
            "limitName": "Codex",
            "primary": { "usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 2000 },
            "secondary": { "usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1000 }
          },
          "rateLimitsByLimitId": null
        }
        """)

        let snapshot = QuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 75)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 60)
    }

    func testFallsBackToLegacyPositionsWhenDurationsAreMissing() throws {
        let response = try decode("""
        {
          "rateLimits": {
            "limitId": "codex",
            "limitName": "Codex",
            "primary": { "usedPercent": 25, "windowDurationMins": null, "resetsAt": 1000 },
            "secondary": { "usedPercent": 40, "windowDurationMins": null, "resetsAt": 2000 }
          },
          "rateLimitsByLimitId": null
        }
        """)

        let snapshot = QuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 75)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 60)
    }

    func testFailedRefreshPreservesPreviousSnapshot() {
        let original = QuotaSnapshot(
            fiveHour: QuotaLimit(kind: .fiveHour, window: RateLimitWindow(usedPercent: 20, windowDurationMins: 300, resetsAt: nil)),
            weekly: nil,
            fetchedAt: Date(timeIntervalSince1970: 10)
        )
        var state = QuotaRefreshState(snapshot: original)

        state.beginRefresh()
        state.finishRefresh(with: .failure(CodexAppServerError.rpcError("network unavailable")))

        XCTAssertFalse(state.isRefreshing)
        XCTAssertEqual(state.snapshot, original)
        XCTAssertEqual(state.errorMessage, "network unavailable")
    }

    func testCodexLaunchEnvironmentAddsLauncherAndStandardBinaryPaths() {
        let command = CodexBinaryResolver.Command(
            executableURL: URL(fileURLWithPath: "/custom/bin/codex"),
            arguments: []
        )

        let environment = CodexBinaryResolver.launchEnvironment(
            for: command,
            environment: ["PATH": "/minimal/bin", "HOME": "/tmp/home"]
        )

        XCTAssertEqual(
            environment["PATH"],
            "/custom/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:/minimal/bin"
        )
        XCTAssertEqual(environment["HOME"], "/tmp/home")
    }

    private func decode(_ json: String) throws -> GetAccountRateLimitsResponse {
        try JSONDecoder().decode(GetAccountRateLimitsResponse.self, from: Data(json.utf8))
    }
}
