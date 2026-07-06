import Foundation

/// The subset of Claude Code's `statusLine` stdin JSON that Open Island cares
/// about. `OpenIslandHooks --source claude-statusline` parses the raw
/// status-line payload into this flat, transport-friendly shape and forwards it
/// over the bridge. It carries two *different* metrics (see the CONTEXT.md
/// usage glossary): per-session **context-window usage** and account-wide
/// **quota usage** (5h / 7d windows). The bridge splits them on arrival.
public struct ClaudeStatusLinePayload: Equatable, Codable, Sendable {
    public var sessionID: String
    public var workspaceDir: String?
    // Per-session context window
    public var contextUsedPercentage: Double?
    public var contextWindowSize: Int?
    public var totalInputTokens: Int?
    // Account-wide quota windows
    public var fiveHour: ClaudeUsageWindow?
    public var sevenDay: ClaudeUsageWindow?

    public init(
        sessionID: String,
        workspaceDir: String? = nil,
        contextUsedPercentage: Double? = nil,
        contextWindowSize: Int? = nil,
        totalInputTokens: Int? = nil,
        fiveHour: ClaudeUsageWindow? = nil,
        sevenDay: ClaudeUsageWindow? = nil
    ) {
        self.sessionID = sessionID
        self.workspaceDir = workspaceDir
        self.contextUsedPercentage = contextUsedPercentage
        self.contextWindowSize = contextWindowSize
        self.totalInputTokens = totalInputTokens
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    /// The account-wide quota facet, ready for the usage panel.
    /// `cachedAt` is left nil here; the bridge stamps it on receipt so freshness
    /// reflects when the app actually learned the value.
    public var usageSnapshot: ClaudeUsageSnapshot? {
        let snapshot = ClaudeUsageSnapshot(fiveHour: fiveHour, sevenDay: sevenDay)
        return snapshot.isEmpty ? nil : snapshot
    }

    public var hasContextData: Bool {
        contextUsedPercentage != nil || contextWindowSize != nil || totalInputTokens != nil
    }
}

public enum ClaudeStatusLineParser {
    /// Tolerantly parses the raw status-line JSON Claude Code pipes to the
    /// `statusLine.command`. Returns nil when there is no `session_id` to key on
    /// (nothing we can attribute), mirroring the lenient JSONSerialization style
    /// of `ClaudeUsageLoader`.
    public static func parse(_ data: Data) -> ClaudeStatusLinePayload? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any],
              let sessionID = payload["session_id"] as? String,
              !sessionID.isEmpty else {
            return nil
        }

        let workspaceDir = (payload["workspace"] as? [String: Any])?["current_dir"] as? String
            ?? payload["cwd"] as? String

        var contextUsedPercentage: Double?
        var contextWindowSize: Int?
        var totalInputTokens: Int?
        if let context = payload["context_window"] as? [String: Any] {
            contextUsedPercentage = number(from: context["used_percentage"])
            contextWindowSize = number(from: context["context_window_size"]).map { Int($0) }
            totalInputTokens = number(from: context["total_input_tokens"]).map { Int($0) }
        }

        var fiveHour: ClaudeUsageWindow?
        var sevenDay: ClaudeUsageWindow?
        if let rateLimits = payload["rate_limits"] as? [String: Any] {
            fiveHour = window(from: rateLimits["five_hour"])
            sevenDay = window(from: rateLimits["seven_day"])
        }

        return ClaudeStatusLinePayload(
            sessionID: sessionID,
            workspaceDir: workspaceDir,
            contextUsedPercentage: contextUsedPercentage,
            contextWindowSize: contextWindowSize,
            totalInputTokens: totalInputTokens,
            fiveHour: fiveHour,
            sevenDay: sevenDay
        )
    }

    private static func window(from value: Any?) -> ClaudeUsageWindow? {
        guard let window = value as? [String: Any],
              let used = number(from: window["used_percentage"]) ?? number(from: window["utilization"]) else {
            return nil
        }
        return ClaudeUsageWindow(usedPercentage: used, resetsAt: date(from: window["resets_at"]))
    }

    private static func number(from value: Any?) -> Double? {
        switch value {
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
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
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractional.date(from: value) {
                return date
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: value)
        default:
            return nil
        }
    }
}
