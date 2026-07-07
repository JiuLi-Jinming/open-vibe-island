import Foundation

/// Supplies the Claude Code OAuth access token (read-only; never refreshes).
public protocol ClaudeTokenProviding: Sendable {
    func accessToken() -> String?
}

/// Performs the quota GET. Returns response bytes on 2xx, `nil` on any failure.
public protocol UsageHTTPClient: Sendable {
    func getJSON(url: URL, bearerToken: String) async -> Data?
}

/// Fetches account 5h/7d quota from Claude Code's dedicated, quota-free
/// `/api/oauth/usage` endpoint — the fallback source for TTY-less (VS Code)
/// sessions where the terminal status line never runs. Fails open: any missing
/// token, auth failure, transport error, or empty payload yields `nil`.
public actor ClaudeUsageProber {
    public static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let tokenProvider: ClaudeTokenProviding
    private let httpClient: UsageHTTPClient

    public init(tokenProvider: ClaudeTokenProviding, httpClient: UsageHTTPClient) {
        self.tokenProvider = tokenProvider
        self.httpClient = httpClient
    }

    /// Returns a snapshot with `cachedAt == nil` (the caller stamps time), or
    /// `nil` on any failure. Never throws.
    public func probe() async -> ClaudeUsageSnapshot? {
        guard let token = tokenProvider.accessToken(), !token.isEmpty else { return nil }
        guard let data = await httpClient.getJSON(url: Self.usageEndpoint, bearerToken: token) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any] else { return nil }
        return ClaudeUsageLoader.snapshot(from: payload, cachedAt: nil)
    }
}
