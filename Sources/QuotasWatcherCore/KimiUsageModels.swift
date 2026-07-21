import Foundation

struct KimiUsageResponse: Decodable {
    let usage: KimiUsageSummary?
    let limits: [KimiUsageLimit]?
}

struct KimiUsageSummary: Decodable {
    let limit: KimiDecodableNumber?
    let remaining: KimiDecodableNumber?
    let used: KimiDecodableNumber?
    let resetTime: String?

    init(limit: KimiDecodableNumber?, remaining: KimiDecodableNumber?, used: KimiDecodableNumber?, resetTime: String?) {
        self.limit = limit
        self.remaining = remaining
        self.used = used
        self.resetTime = resetTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limit = try container.decodeIfPresent(KimiDecodableNumber.self, forKey: .limit)
        remaining = try container.decodeIfPresent(KimiDecodableNumber.self, forKey: .remaining)
        used = try container.decodeIfPresent(KimiDecodableNumber.self, forKey: .used)
        resetTime = try container.decodeIfPresent(String.self, forKey: .resetTime)
            ?? container.decodeIfPresent(String.self, forKey: .resetAt)
            ?? container.decodeIfPresent(String.self, forKey: .resetTimeSnake)
            ?? container.decodeIfPresent(String.self, forKey: .resetAtSnake)
    }

    private enum CodingKeys: String, CodingKey {
        case limit
        case remaining
        case used
        case resetTime
        case resetAt
        case resetTimeSnake = "reset_time"
        case resetAtSnake = "reset_at"
    }
}

struct KimiUsageLimit: Decodable {
    let window: KimiUsageWindow?
    let detail: KimiUsageDetail?
    // Item-level fallbacks: the official parser reads window fields from the
    // item itself when `window` is absent, and count fields when `detail` is
    // absent (the detail record falls back to the item record).
    let duration: KimiDecodableNumber?
    let timeUnit: String?
    let limit: KimiDecodableNumber?
    let remaining: KimiDecodableNumber?
    let used: KimiDecodableNumber?
    let resetTime: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        window = try container.decodeIfPresent(KimiUsageWindow.self, forKey: .window)
        detail = try container.decodeIfPresent(KimiUsageDetail.self, forKey: .detail)
        duration = try container.decodeIfPresent(KimiDecodableNumber.self, forKey: .duration)
        timeUnit = try container.decodeIfPresent(String.self, forKey: .timeUnit)
        limit = try container.decodeIfPresent(KimiDecodableNumber.self, forKey: .limit)
        remaining = try container.decodeIfPresent(KimiDecodableNumber.self, forKey: .remaining)
        used = try container.decodeIfPresent(KimiDecodableNumber.self, forKey: .used)
        resetTime = try container.decodeIfPresent(String.self, forKey: .resetTime)
            ?? container.decodeIfPresent(String.self, forKey: .resetAt)
            ?? container.decodeIfPresent(String.self, forKey: .resetTimeSnake)
            ?? container.decodeIfPresent(String.self, forKey: .resetAtSnake)
    }

    private enum CodingKeys: String, CodingKey {
        case window
        case detail
        case duration
        case timeUnit
        case limit
        case remaining
        case used
        case resetTime
        case resetAt
        case resetTimeSnake = "reset_time"
        case resetAtSnake = "reset_at"
    }

    /// Window fields from `window`, falling back to the item itself.
    var effectiveWindow: KimiUsageWindow? {
        if let window { return window }
        guard duration != nil || timeUnit != nil else { return nil }
        return KimiUsageWindow(duration: duration, timeUnit: timeUnit)
    }

    /// Count fields from `detail`, falling back to the item itself.
    var effectiveDetail: KimiUsageDetail? {
        if let detail { return detail }
        guard limit != nil || remaining != nil || used != nil || resetTime != nil else { return nil }
        return KimiUsageDetail(limit: limit, remaining: remaining, used: used, resetTime: resetTime)
    }
}

struct KimiUsageWindow: Decodable {
    let duration: KimiDecodableNumber?
    let timeUnit: String?

    init(duration: KimiDecodableNumber?, timeUnit: String?) {
        self.duration = duration
        self.timeUnit = timeUnit
    }
}

struct KimiUsageDetail: Decodable {
    let limit: KimiDecodableNumber?
    let remaining: KimiDecodableNumber?
    let used: KimiDecodableNumber?
    let resetTime: String?

    init(limit: KimiDecodableNumber?, remaining: KimiDecodableNumber?, used: KimiDecodableNumber?, resetTime: String?) {
        self.limit = limit
        self.remaining = remaining
        self.used = used
        self.resetTime = resetTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limit = try container.decodeIfPresent(KimiDecodableNumber.self, forKey: .limit)
        remaining = try container.decodeIfPresent(KimiDecodableNumber.self, forKey: .remaining)
        used = try container.decodeIfPresent(KimiDecodableNumber.self, forKey: .used)
        resetTime = try container.decodeIfPresent(String.self, forKey: .resetTime)
            ?? container.decodeIfPresent(String.self, forKey: .resetAt)
            ?? container.decodeIfPresent(String.self, forKey: .resetTimeSnake)
            ?? container.decodeIfPresent(String.self, forKey: .resetAtSnake)
    }

    private enum CodingKeys: String, CodingKey {
        case limit
        case remaining
        case used
        case resetTime
        case resetAt
        case resetTimeSnake = "reset_time"
        case resetAtSnake = "reset_at"
    }
}

enum KimiDecodableNumber: Decodable, Equatable {
    case int(Int)
    case double(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }
        if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
            return
        }
        let stringValue = try container.decode(String.self)
        self = .string(stringValue)
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value):
            return Double(value)
        case .double(let value):
            return value
        case .string(let value):
            return Double(value)
        }
    }
}
