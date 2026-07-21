import XCTest
@testable import QuotasWatcherCore

final class KimiQuotaParserTests: XCTestCase {
    func testObservedLiveShape() throws {
        let json = """
        {
          "usage": {
            "limit": "10000",
            "remaining": "8000",
            "resetTime": "2026-07-18T00:00:00.000Z"
          },
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "TIME_UNIT_MINUTE" },
              "detail": {
                "limit": "500",
                "remaining": "250",
                "used": "250",
                "resetTime": "2026-07-17T12:00:00.000Z"
              }
            }
          ]
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response, fetchedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 50)
        XCTAssertEqual(snapshot.fiveHour?.windowDurationMins, 300)
        XCTAssertNotNil(snapshot.fiveHour?.resetDate)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 80)
        XCTAssertNil(snapshot.availableResetCount)
    }

    func testNumericValues() throws {
        let json = """
        {
          "usage": { "limit": 100, "remaining": 75 },
          "limits": [
            {
              "window": { "duration": 300, "timeUnit": "minute" },
              "detail": { "limit": 100, "used": 30 }
            }
          ]
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 70)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 75)
    }

    func testDerivesUsedFromRemaining() throws {
        let json = """
        {
          "usage": { "limit": "100", "remaining": "60" },
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "minutes" },
              "detail": { "limit": "100", "remaining": "80" }
            }
          ]
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 80)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 60)
    }

    func testUnitAndCasingVariants() throws {
        let variants = ["minute", "MINUTE", "Minute", "min", "mins", "TIME_UNIT_MINUTE"]
        for unit in variants {
            let json = """
            {
              "limits": [
                {
                  "window": { "duration": "300", "timeUnit": "\(unit)" },
                  "detail": { "limit": "100", "used": "10" }
                }
              ]
            }
            """
            let response = try decode(json)
            let snapshot = try KimiQuotaParser.snapshot(from: response)
            XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 90, "Failed for unit \(unit)")
        }
    }

    func testWeeklyByDuration() throws {
        let json = """
        {
          "limits": [
            {
              "window": { "duration": "10080", "timeUnit": "minute" },
              "detail": { "limit": "1000", "used": "100" }
            }
          ]
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 90)
        XCTAssertNil(snapshot.fiveHour)
    }

    func testWeeklyByHours() throws {
        let json = """
        {
          "limits": [
            {
              "window": { "duration": "168", "timeUnit": "hour" },
              "detail": { "limit": "1000", "used": "100" }
            }
          ]
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 90)
    }

    func testIgnoresUnknownFields() throws {
        let json = """
        {
          "usage": {
            "limit": "100",
            "remaining": "80",
            "totalQuota": "10000",
            "parallel": "unknown",
            "user": "ignored"
          },
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "TIME_UNIT_MINUTE", "subType": "x" },
              "detail": {
                "limit": "100",
                "remaining": "80",
                "authentication": "ignored"
              }
            }
          ]
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 80)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 80)
    }

    func testMissingResetTimeDoesNotInvalidateData() throws {
        let json = """
        {
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "minute" },
              "detail": { "limit": "100", "used": "10" }
            }
          ]
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 90)
        XCTAssertNil(snapshot.fiveHour?.resetDate)
    }

    func testFractionalISO8601Timestamp() throws {
        let json = """
        {
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "minute" },
              "detail": { "limit": "100", "used": "10", "resetTime": "2026-07-17T12:34:56.789012Z" }
            }
          ]
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response)
        XCTAssertNotNil(snapshot.fiveHour?.resetDate)
    }

    func testResetAtAlias() throws {
        let json = """
        {
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "minute" },
              "detail": { "limit": "100", "used": "10", "resetAt": "2026-07-17T12:00:00Z" }
            }
          ]
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response)
        XCTAssertNotNil(snapshot.fiveHour?.resetDate)
    }

    func testInvalidLimitProducesError() throws {
        let json = """
        {
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "minute" },
              "detail": { "limit": "0", "used": "10" }
            }
          ]
        }
        """
        let response = try decode(json)
        XCTAssertThrowsError(try KimiQuotaParser.snapshot(from: response))
    }

    func testNegativeLimitProducesError() throws {
        let json = """
        {
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "minute" },
              "detail": { "limit": "-10", "used": "10" }
            }
          ]
        }
        """
        let response = try decode(json)
        XCTAssertThrowsError(try KimiQuotaParser.snapshot(from: response))
    }

    func testInvalidNumericStringProducesError() throws {
        let json = """
        {
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "minute" },
              "detail": { "limit": "abc", "used": "10" }
            }
          ]
        }
        """
        let response = try decode(json)
        XCTAssertThrowsError(try KimiQuotaParser.snapshot(from: response))
    }

    func testOverLimitCountIsClamped() throws {
        let json = """
        {
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "minute" },
              "detail": { "limit": "100", "used": "200" }
            }
          ]
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 0)
    }

    func testNoRecognizedWindowProducesError() throws {
        let json = """
        {
          "limits": [
            {
              "window": { "duration": "60", "timeUnit": "minute" },
              "detail": { "limit": "100", "used": "10" }
            }
          ]
        }
        """
        let response = try decode(json)
        XCTAssertThrowsError(try KimiQuotaParser.snapshot(from: response))
    }

    func testEmptyUsageAndLimitsProducesError() throws {
        let response = try decode("{}")
        XCTAssertThrowsError(try KimiQuotaParser.snapshot(from: response))
    }

    func testFallsBackToDurationWhenTimeUnitIsUnknownButMatchesKnownWindow() throws {
        let json = """
        {
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "UNKNOWN_UNIT" },
              "detail": { "limit": "100", "used": "10" }
            }
          ]
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 90)
    }

    func testHandlesSecondsDuration() throws {
        let json = """
        {
          "limits": [
            {
              "window": { "duration": "18000", "timeUnit": "SECOND" },
              "detail": { "limit": "100", "used": "10" }
            }
          ]
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 90)
    }

    func testSnakeCaseResetAliases() throws {
        let json = """
        {
          "usage": { "limit": "100", "remaining": "80", "reset_time": "2026-07-18T00:00:00Z" },
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "minute" },
              "detail": { "limit": "100", "used": "10", "reset_at": "2026-07-17T12:00:00Z" }
            }
          ]
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response)
        XCTAssertNotNil(snapshot.weekly?.resetDate)
        XCTAssertNotNil(snapshot.fiveHour?.resetDate)
    }

    func testNonFiniteLimitIsRejected() throws {
        let json = """
        {
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "minute" },
              "detail": { "limit": "nan", "used": "10" }
            }
          ]
        }
        """
        let response = try decode(json)
        XCTAssertThrowsError(try KimiQuotaParser.snapshot(from: response))
    }

    func testNegativeCountIsClamped() throws {
        let json = """
        {
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "minute" },
              "detail": { "limit": "100", "used": "-10" }
            }
          ]
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 100)
    }

    func testDerivedUsedFromRemaining() throws {
        let json = """
        {
          "usage": { "limit": "100", "remaining": "30" }
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 30)
    }

    func testTopLevelSummaryWithExplicitUsed() throws {
        let json = """
        {
          "usage": { "limit": "200", "used": "50" }
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 75)
        XCTAssertNil(snapshot.fiveHour)
    }

    func testNonFiniteUsedIsRejected() throws {
        let json = """
        {
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "minute" },
              "detail": { "limit": "100", "used": "inf" }
            }
          ]
        }
        """
        let response = try decode(json)
        XCTAssertThrowsError(try KimiQuotaParser.snapshot(from: response))
    }

    func testNonFiniteRemainingIsRejected() throws {
        let json = """
        {
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "minute" },
              "detail": { "limit": "100", "remaining": "nan" }
            }
          ]
        }
        """
        let response = try decode(json)
        XCTAssertThrowsError(try KimiQuotaParser.snapshot(from: response))
    }

    func testInvalidResetTimeLeavesDataValid() throws {
        let json = """
        {
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "minute" },
              "detail": { "limit": "100", "used": "10", "resetTime": "not-a-date" }
            }
          ]
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 90)
        XCTAssertNil(snapshot.fiveHour?.resetDate)
    }

    func testItemLevelCountsUsedWhenDetailMissing() throws {
        // Official tolerance: the item record itself carries the counts when
        // no `detail` object is present.
        let json = """
        {
          "limits": [
            {
              "window": { "duration": "300", "timeUnit": "TIME_UNIT_MINUTE" },
              "limit": "100",
              "used": "25"
            }
          ]
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 75)
    }

    func testItemLevelWindowUsedWhenWindowMissing() throws {
        // Official tolerance: duration/timeUnit may live on the item itself.
        let json = """
        {
          "limits": [
            {
              "duration": "300",
              "timeUnit": "minute",
              "detail": { "limit": "100", "used": "25" }
            }
          ]
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 75)
    }

    func testNullDetailFallsBackToItemCounts() throws {
        let json = """
        {
          "limits": [
            {
              "window": { "duration": "10080", "timeUnit": "minute" },
              "detail": null,
              "limit": "100",
              "remaining": "40"
            }
          ]
        }
        """
        let response = try decode(json)
        let snapshot = try KimiQuotaParser.snapshot(from: response)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 40)
        XCTAssertNil(snapshot.fiveHour)
    }

    private func decode(_ json: String) throws -> KimiUsageResponse {
        try JSONDecoder().decode(KimiUsageResponse.self, from: Data(json.utf8))
    }
}
