import Foundation

public enum QuotaNotificationKind: String, Codable, CaseIterable, Equatable {
    case fiveHourReset
    case weeklyReset
    case otherReset
    case resetBankIncrease
}

public struct QuotaResetChange: Equatable {
    public let kind: QuotaKind
    public let previousRemainingPercent: Double
    public let currentRemainingPercent: Double

    public init(kind: QuotaKind, previousRemainingPercent: Double, currentRemainingPercent: Double) {
        self.kind = kind
        self.previousRemainingPercent = previousRemainingPercent
        self.currentRemainingPercent = currentRemainingPercent
    }
}

public struct QuotaResetEvent: Equatable {
    public let kind: QuotaNotificationKind
    public let changes: [QuotaResetChange]
    public let resetBankChange: ResetBankChange?

    public init(
        kind: QuotaNotificationKind,
        changes: [QuotaResetChange] = [],
        resetBankChange: ResetBankChange? = nil
    ) {
        self.kind = kind
        self.changes = changes
        self.resetBankChange = resetBankChange
    }
}

public struct ResetBankChange: Equatable {
    public let previousCount: Int
    public let currentCount: Int

    public init(previousCount: Int, currentCount: Int) {
        self.previousCount = previousCount
        self.currentCount = currentCount
    }
}

public enum QuotaResetDetector {
    public static func events(
        previous: QuotaSnapshot,
        current: QuotaSnapshot,
        maximumScheduledResetObservationInterval: TimeInterval = 30 * 60,
        maximumOtherResetObservationInterval: TimeInterval = 6 * 60 * 60,
        resetBoundaryTolerance: TimeInterval = 5 * 60,
        otherResetThreshold: Double = 10
    ) -> [QuotaResetEvent] {
        let observationInterval = current.fetchedAt.timeIntervalSince(previous.fetchedAt)
        guard observationInterval >= 0 else {
            return []
        }

        var events: [QuotaResetEvent] = []
        if let previousCount = previous.availableResetCount,
           let currentCount = current.availableResetCount,
           currentCount > previousCount {
            events.append(QuotaResetEvent(
                kind: .resetBankIncrease,
                resetBankChange: ResetBankChange(
                    previousCount: previousCount,
                    currentCount: currentCount
                )
            ))
        }

        var otherChanges: [QuotaResetChange] = []

        inspect(
            kind: .fiveHour,
            previous: previous.fiveHour,
            current: current.fiveHour,
            fetchedAt: current.fetchedAt,
            observationInterval: observationInterval,
            maximumScheduledResetObservationInterval: maximumScheduledResetObservationInterval,
            maximumOtherResetObservationInterval: maximumOtherResetObservationInterval,
            resetBoundaryTolerance: resetBoundaryTolerance,
            otherResetThreshold: otherResetThreshold,
            scheduledKind: .fiveHourReset,
            events: &events,
            otherChanges: &otherChanges
        )
        inspect(
            kind: .weekly,
            previous: previous.weekly,
            current: current.weekly,
            fetchedAt: current.fetchedAt,
            observationInterval: observationInterval,
            maximumScheduledResetObservationInterval: maximumScheduledResetObservationInterval,
            maximumOtherResetObservationInterval: maximumOtherResetObservationInterval,
            resetBoundaryTolerance: resetBoundaryTolerance,
            otherResetThreshold: otherResetThreshold,
            scheduledKind: .weeklyReset,
            events: &events,
            otherChanges: &otherChanges
        )

        if !otherChanges.isEmpty {
            events.append(QuotaResetEvent(kind: .otherReset, changes: otherChanges))
        }
        return events
    }

    private static func inspect(
        kind: QuotaKind,
        previous: QuotaLimit?,
        current: QuotaLimit?,
        fetchedAt: Date,
        observationInterval: TimeInterval,
        maximumScheduledResetObservationInterval: TimeInterval,
        maximumOtherResetObservationInterval: TimeInterval,
        resetBoundaryTolerance: TimeInterval,
        otherResetThreshold: Double,
        scheduledKind: QuotaNotificationKind,
        events: inout [QuotaResetEvent],
        otherChanges: inout [QuotaResetChange]
    ) {
        guard let previous, let current else {
            return
        }

        let change = QuotaResetChange(
            kind: kind,
            previousRemainingPercent: previous.remainingPercent,
            currentRemainingPercent: current.remainingPercent
        )

        if observationInterval <= maximumScheduledResetObservationInterval,
           isScheduledReset(
            previous: previous,
            current: current,
            fetchedAt: fetchedAt,
            tolerance: resetBoundaryTolerance
        ) {
            events.append(QuotaResetEvent(kind: scheduledKind, changes: [change]))
            return
        }

        guard observationInterval <= maximumOtherResetObservationInterval,
              current.remainingPercent - previous.remainingPercent >= otherResetThreshold,
              let previousResetDate = previous.resetDate,
              let currentResetDate = current.resetDate,
              currentResetDate > previousResetDate.addingTimeInterval(resetBoundaryTolerance),
              fetchedAt < previousResetDate.addingTimeInterval(-resetBoundaryTolerance)
        else {
            return
        }
        otherChanges.append(change)
    }

    private static func isScheduledReset(
        previous: QuotaLimit,
        current: QuotaLimit,
        fetchedAt: Date,
        tolerance: TimeInterval
    ) -> Bool {
        guard let previousResetDate = previous.resetDate,
              let currentResetDate = current.resetDate,
              currentResetDate > previousResetDate,
              fetchedAt >= previousResetDate.addingTimeInterval(-tolerance)
        else {
            return false
        }
        return true
    }
}

public struct BarkNotificationSettings: Equatable {
    public var deviceKey: String
    public var notifyFiveHourReset: Bool
    public var notifyWeeklyReset: Bool
    public var notifyOtherReset: Bool
    public var notifyResetBankIncrease: Bool

    public init(
        deviceKey: String = "",
        notifyFiveHourReset: Bool = false,
        notifyWeeklyReset: Bool = false,
        notifyOtherReset: Bool = false,
        notifyResetBankIncrease: Bool = false
    ) {
        self.deviceKey = deviceKey
        self.notifyFiveHourReset = notifyFiveHourReset
        self.notifyWeeklyReset = notifyWeeklyReset
        self.notifyOtherReset = notifyOtherReset
        self.notifyResetBankIncrease = notifyResetBankIncrease
    }

    public func isEnabled(_ kind: QuotaNotificationKind) -> Bool {
        switch kind {
        case .fiveHourReset:
            return notifyFiveHourReset
        case .weeklyReset:
            return notifyWeeklyReset
        case .otherReset:
            return notifyOtherReset
        case .resetBankIncrease:
            return notifyResetBankIncrease
        }
    }
}

public final class BarkNotificationPreferences {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "barkNotifications") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func loadSettings() -> BarkNotificationSettings {
        let resetBankKey = key("notifyResetBankIncrease")
        let notifyResetBankIncrease = defaults.object(forKey: resetBankKey) as? Bool
            ?? defaults.bool(forKey: key("notifyOtherReset"))
        return BarkNotificationSettings(
            deviceKey: defaults.string(forKey: key("deviceKey")) ?? "",
            notifyFiveHourReset: defaults.bool(forKey: key("notifyFiveHourReset")),
            notifyWeeklyReset: defaults.bool(forKey: key("notifyWeeklyReset")),
            notifyOtherReset: defaults.bool(forKey: key("notifyOtherReset")),
            notifyResetBankIncrease: notifyResetBankIncrease
        )
    }

    public func saveSettings(_ settings: BarkNotificationSettings) {
        let trimmedKey = settings.deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty {
            defaults.removeObject(forKey: key("deviceKey"))
        } else {
            defaults.set(trimmedKey, forKey: key("deviceKey"))
        }
        defaults.set(settings.notifyFiveHourReset, forKey: key("notifyFiveHourReset"))
        defaults.set(settings.notifyWeeklyReset, forKey: key("notifyWeeklyReset"))
        defaults.set(settings.notifyOtherReset, forKey: key("notifyOtherReset"))
        defaults.set(settings.notifyResetBankIncrease, forKey: key("notifyResetBankIncrease"))
    }

    public func loadLastObservation() -> QuotaSnapshot? {
        guard let data = defaults.data(forKey: key("lastObservation")) else {
            return nil
        }
        return try? JSONDecoder().decode(QuotaSnapshot.self, from: data)
    }

    public func saveLastObservation(_ snapshot: QuotaSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        defaults.set(data, forKey: key("lastObservation"))
    }

    private func key(_ suffix: String) -> String {
        "\(keyPrefix).\(suffix)"
    }
}

public enum BarkPushError: LocalizedError, Equatable {
    case invalidDeviceKey
    case requestFailed
    case httpError(Int)
    case apiError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDeviceKey:
            return "The Bark device key is invalid."
        case .requestFailed:
            return "The Bark request failed."
        case .httpError(let statusCode):
            return "Bark returned HTTP status \(statusCode)."
        case .apiError(let message):
            return "Bark returned an error: \(message)"
        }
    }
}

public struct BarkPushClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static func deviceKey(from input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") {
            guard let components = URLComponents(string: trimmed),
                  components.scheme?.lowercased() == "https",
                  components.host?.lowercased() == "api.day.app",
                  components.query == nil,
                  components.fragment == nil
            else {
                throw BarkPushError.invalidDeviceKey
            }
            let pathComponents = components.path.split(separator: "/").map(String.init)
            guard pathComponents.count == 1 else {
                throw BarkPushError.invalidDeviceKey
            }
            return try validateDeviceKey(pathComponents[0])
        }
        return try validateDeviceKey(trimmed)
    }

    public static func endpoint(for deviceKey: String) throws -> URL {
        let key = try Self.deviceKey(from: deviceKey)
        return URL(string: "https://api.day.app")!.appendingPathComponent(key)
    }

    private static func validateDeviceKey(_ key: String) throws -> String {
        let forbiddenCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/?#"))
        guard !key.isEmpty, key.rangeOfCharacter(from: forbiddenCharacters) == nil else {
            throw BarkPushError.invalidDeviceKey
        }
        return key
    }

    public func send(deviceKey: String, title: String, body: String) async throws {
        let endpoint = try Self.endpoint(for: deviceKey)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(BarkPushPayload(
            title: title,
            body: body,
            group: "QuotasWatcher",
            level: "active"
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BarkPushError.requestFailed
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw BarkPushError.httpError(statusCode)
        }

        if let apiResponse = try? JSONDecoder().decode(BarkAPIResponse.self, from: data),
           let code = apiResponse.code,
           code != 200 {
            throw BarkPushError.apiError(apiResponse.message ?? "code \(code)")
        }
    }
}

private struct BarkPushPayload: Encodable {
    let title: String
    let body: String
    let group: String
    let level: String
}

private struct BarkAPIResponse: Decodable {
    let code: Int?
    let message: String?
}
