import Foundation
import Testing
@testable import OpenIslandCore

struct ClaudeKeychainTokenProviderTests {
    @Test
    func extractsAccessTokenFromClaudeCredentialsJSON() {
        let data = Data("""
        {"claudeAiOauth":{"accessToken":"tok-123","refreshToken":"r","expiresAt":1760000000}}
        """.utf8)
        #expect(ClaudeKeychainTokenProvider.extractAccessToken(from: data) == "tok-123")
    }

    @Test
    func returnsNilForMissingOrMalformed() {
        #expect(ClaudeKeychainTokenProvider.extractAccessToken(from: Data("{}".utf8)) == nil)
        #expect(ClaudeKeychainTokenProvider.extractAccessToken(from: Data("{\"claudeAiOauth\":{}}".utf8)) == nil)
        #expect(ClaudeKeychainTokenProvider.extractAccessToken(from: Data("not json".utf8)) == nil)
    }
}
