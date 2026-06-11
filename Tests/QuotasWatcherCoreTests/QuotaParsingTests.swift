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

    private func decode(_ json: String) throws -> GetAccountRateLimitsResponse {
        try JSONDecoder().decode(GetAccountRateLimitsResponse.self, from: Data(json.utf8))
    }
}
