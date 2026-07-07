import Foundation
import Testing
@testable import OpenIslandCore

private struct StubToken: ClaudeTokenProviding {
    let token: String?
    func accessToken() -> String? { token }
}

private final class StubHTTP: UsageHTTPClient, @unchecked Sendable {
    let data: Data?
    private(set) var callCount = 0
    private(set) var lastBearer: String?
    init(data: Data?) { self.data = data }
    func getJSON(url: URL, bearerToken: String) async -> Data? {
        callCount += 1
        lastBearer = bearerToken
        return data
    }
}

struct ClaudeUsageProberTests {
    private let sample = Data("""
    {"five_hour":{"utilization":42.0,"resets_at":1760000000},
     "seven_day":{"utilization":18.0}}
    """.utf8)

    @Test
    func probeReturnsSnapshotOnSuccess() async {
        let http = StubHTTP(data: sample)
        let prober = ClaudeUsageProber(tokenProvider: StubToken(token: "abc"), httpClient: http)
        let snapshot = await prober.probe()
        #expect(snapshot?.fiveHour?.roundedUsedPercentage == 42)
        #expect(snapshot?.sevenDay?.roundedUsedPercentage == 18)
        #expect(snapshot?.cachedAt == nil)
        #expect(http.lastBearer == "abc")
    }

    @Test
    func probeReturnsNilWhenNoToken() async {
        let http = StubHTTP(data: sample)
        let prober = ClaudeUsageProber(tokenProvider: StubToken(token: nil), httpClient: http)
        let snapshot = await prober.probe()
        #expect(snapshot == nil)
        #expect(http.callCount == 0)  // never hits the network without a token
    }

    @Test
    func probeReturnsNilWhenHTTPFails() async {
        let http = StubHTTP(data: nil)  // simulates non-2xx / transport error
        let prober = ClaudeUsageProber(tokenProvider: StubToken(token: "abc"), httpClient: http)
        #expect(await prober.probe() == nil)
    }
}
