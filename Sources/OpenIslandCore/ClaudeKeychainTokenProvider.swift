import Foundation
import Security

/// Reads Claude Code's OAuth access token from the login Keychain, read-only.
/// The item is a generic password owned by the `claude` binary; the first read
/// from another app raises a one-time macOS authorization prompt. Any failure
/// (denied, absent, malformed) returns `nil` so the prober fails open.
public struct ClaudeKeychainTokenProvider: ClaudeTokenProviding {
    private let service: String

    public init(service: String = "Claude Code-credentials") {
        self.service = service
    }

    public func accessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return Self.extractAccessToken(from: data)
    }

    /// Pure JSON extraction, split out for testing.
    public static func extractAccessToken(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
    }
}
