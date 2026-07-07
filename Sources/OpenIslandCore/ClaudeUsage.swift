import Foundation

public struct ClaudeUsageWindow: Equatable, Codable, Sendable {
    public var usedPercentage: Double
    public var resetsAt: Date?

    public init(usedPercentage: Double, resetsAt: Date?) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    public var roundedUsedPercentage: Int {
        Int(usedPercentage.rounded())
    }
}

public struct ClaudeUsageSnapshot: Equatable, Codable, Sendable {
    public var fiveHour: ClaudeUsageWindow?
    public var sevenDay: ClaudeUsageWindow?
    public var cachedAt: Date?

    public init(
        fiveHour: ClaudeUsageWindow?,
        sevenDay: ClaudeUsageWindow?,
        cachedAt: Date? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.cachedAt = cachedAt
    }

    public var isEmpty: Bool {
        fiveHour == nil && sevenDay == nil
    }
}

public enum ClaudeUsageLoader {
    public static let defaultCacheURL = URL(fileURLWithPath: "/tmp/open-island-rl.json")
    public static let legacyCacheURL = URL(fileURLWithPath: "/tmp/vibe-island-rl.json")

    public static func load() throws -> ClaudeUsageSnapshot? {
        try load(from: [defaultCacheURL, legacyCacheURL])
    }

    public static func load(from url: URL) throws -> ClaudeUsageSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let payload = object as? [String: Any] else {
            return nil
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let cachedAt = attributes?[.modificationDate] as? Date
        return snapshot(from: payload, cachedAt: cachedAt)
    }

    public static func load(from urls: [URL]) throws -> ClaudeUsageSnapshot? {
        let candidates = urls
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { url in
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let modificationDate = attributes?[.modificationDate] as? Date ?? .distantPast
                return (url, modificationDate)
            }
            .sorted { lhs, rhs in
                lhs.1 > rhs.1
            }

        for (url, _) in candidates {
            if let snapshot = try load(from: url) {
                return snapshot
            }
        }

        return nil
    }

    /// Parses a decoded usage payload (from the status-line cache file OR the
    /// `/api/oauth/usage` probe) into a snapshot. Tolerant of two shapes: window
    /// metrics at the window-dict root, or nested under a `limit` sub-dict; and an
    /// optional top-level `data` / `rate_limits` envelope.
    public static func snapshot(from payload: [String: Any], cachedAt: Date?) -> ClaudeUsageSnapshot? {
        let root = (payload["data"] as? [String: Any])
            ?? (payload["rate_limits"] as? [String: Any])
            ?? payload
        let snapshot = ClaudeUsageSnapshot(
            fiveHour: usageWindow(for: "five_hour", in: root),
            sevenDay: usageWindow(for: "seven_day", in: root),
            cachedAt: cachedAt
        )
        return snapshot.isEmpty ? nil : snapshot
    }

    private static func usageWindow(for key: String, in payload: [String: Any]) -> ClaudeUsageWindow? {
        guard let window = payload[key] as? [String: Any] else { return nil }
        let metrics = (window["limit"] as? [String: Any]) ?? window
        guard let rawPercentage = number(from: metrics["used_percentage"])
            ?? number(from: metrics["utilization"]) else {
            return nil
        }
        return ClaudeUsageWindow(
            usedPercentage: rawPercentage,
            resetsAt: date(from: metrics["resets_at"])
        )
    }

    private static func number(from value: Any?) -> Double? {
        switch value {
        case let value as NSNumber:
            value.doubleValue
        case let value as String:
            Double(value)
        default:
            nil
        }
    }

    private static func date(from value: Any?) -> Date? {
        switch value {
        case let value as NSNumber:
            return Date(timeIntervalSince1970: value.doubleValue)
        case let value as String:
            if let seconds = Double(value) {
                return Date(timeIntervalSince1970: seconds)
            }
            let formatterWithFractionalSeconds = ISO8601DateFormatter()
            formatterWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatterWithFractionalSeconds.date(from: value) {
                return date
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) {
                return date
            }
            return nil
        default:
            return nil
        }
    }
}
