import Foundation
import Testing
@testable import OpenIslandCore

struct ClaudeUsageProbePolicyTests {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let threshold: TimeInterval = 120

    @Test
    func doesNotProbeWithoutActiveSession() {
        #expect(shouldProbeClaudeUsage(lastCachedAt: nil, now: now, hasActiveSession: false, stalenessThreshold: threshold) == false)
    }

    @Test
    func probesWhenActiveAndNoSnapshot() {
        #expect(shouldProbeClaudeUsage(lastCachedAt: nil, now: now, hasActiveSession: true, stalenessThreshold: threshold) == true)
    }

    @Test
    func doesNotProbeWhenSnapshotFresh() {
        let fresh = now.addingTimeInterval(-30)
        #expect(shouldProbeClaudeUsage(lastCachedAt: fresh, now: now, hasActiveSession: true, stalenessThreshold: threshold) == false)
    }

    @Test
    func probesWhenSnapshotStale() {
        let stale = now.addingTimeInterval(-200)
        #expect(shouldProbeClaudeUsage(lastCachedAt: stale, now: now, hasActiveSession: true, stalenessThreshold: threshold) == true)
    }
}
