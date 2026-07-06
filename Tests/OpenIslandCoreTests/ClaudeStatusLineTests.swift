import Foundation
import Testing
@testable import OpenIslandCore

/// Coverage for the status-line → bridge pipeline: parsing the raw status-line
/// JSON and merging per-session context% into session state without clobbering
/// other metadata.
struct ClaudeStatusLineTests {
    private func seededState(sessionID: String, metadata: ClaudeSessionMetadata?) -> SessionState {
        var state = SessionState()
        state.apply(
            .sessionStarted(
                SessionStarted(
                    sessionID: sessionID,
                    title: "Claude · demo",
                    tool: .claudeCode,
                    origin: .live,
                    summary: "Working",
                    timestamp: Date(timeIntervalSince1970: 1_000)
                )
            )
        )
        if let metadata {
            state.apply(
                .claudeSessionMetadataUpdated(
                    ClaudeSessionMetadataUpdated(
                        sessionID: sessionID,
                        claudeMetadata: metadata,
                        timestamp: Date(timeIntervalSince1970: 1_100)
                    )
                )
            )
        }
        return state
    }

    @Test
    func parsesContextAndQuotaFromStatusLineJSON() throws {
        let json = """
        {
          "session_id": "abc-123",
          "workspace": {"current_dir": "/Users/x/proj"},
          "context_window": {
            "used_percentage": 90.4,
            "context_window_size": 200000,
            "total_input_tokens": 180800
          },
          "rate_limits": {
            "five_hour": {"used_percentage": 23, "resets_at": 1710000000},
            "seven_day": {"used_percentage": 12.5, "resets_at": 1710500000}
          }
        }
        """
        let payload = try #require(ClaudeStatusLineParser.parse(Data(json.utf8)))

        #expect(payload.sessionID == "abc-123")
        #expect(payload.workspaceDir == "/Users/x/proj")
        #expect(payload.contextUsedPercentage == 90.4)
        #expect(payload.contextWindowSize == 200000)
        #expect(payload.totalInputTokens == 180800)
        #expect(payload.hasContextData)

        let usage = try #require(payload.usageSnapshot)
        #expect(usage.fiveHour?.usedPercentage == 23)
        #expect(usage.sevenDay?.usedPercentage == 12.5)
        #expect(usage.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_710_000_000))
    }

    @Test
    func parseReturnsNilWithoutSessionID() {
        let json = #"{"context_window": {"used_percentage": 50}}"#
        #expect(ClaudeStatusLineParser.parse(Data(json.utf8)) == nil)
    }

    @Test
    func parseToleratesMissingQuotaForNonSubscribers() throws {
        let json = #"{"session_id": "s1", "context_window": {"used_percentage": 42}}"#
        let payload = try #require(ClaudeStatusLineParser.parse(Data(json.utf8)))
        #expect(payload.contextUsedPercentage == 42)
        #expect(payload.usageSnapshot == nil)
    }

    /// The context update must merge only context fields — never wipe the
    /// transcript/prompt/tool metadata that arrived via the richer hook event.
    @Test
    func contextUpdateMergesWithoutClobberingOtherMetadata() {
        let existing = ClaudeSessionMetadata(
            transcriptPath: "/tmp/t.jsonl",
            lastUserPrompt: "hello",
            currentTool: "Edit",
            model: "claude-opus-4-8",
            worktreeBranch: "feat/x"
        )
        var state = seededState(sessionID: "s1", metadata: existing)

        state.apply(
            .claudeContextUpdated(
                ClaudeContextUpdated(
                    sessionID: "s1",
                    contextUsedPercentage: 88,
                    contextWindowSize: 200000,
                    totalInputTokens: 176000,
                    timestamp: Date(timeIntervalSince1970: 2_000)
                )
            )
        )

        let md = state.session(id: "s1")?.claudeMetadata
        #expect(md?.contextUsedPercentage == 88)
        #expect(md?.totalInputTokens == 176000)
        // Untouched fields survive.
        #expect(md?.transcriptPath == "/tmp/t.jsonl")
        #expect(md?.currentTool == "Edit")
        #expect(md?.worktreeBranch == "feat/x")
    }

    /// Context telemetry is passive — it must not bump the session's updatedAt
    /// (which would reorder cards and reset idle timers).
    @Test
    func contextUpdateDoesNotBumpUpdatedAt() {
        var state = seededState(sessionID: "s1", metadata: ClaudeSessionMetadata(model: "m"))
        let before = state.session(id: "s1")?.updatedAt

        state.apply(
            .claudeContextUpdated(
                ClaudeContextUpdated(
                    sessionID: "s1",
                    contextUsedPercentage: 70,
                    contextWindowSize: nil,
                    totalInputTokens: nil,
                    timestamp: Date(timeIntervalSince1970: 9_999)
                )
            )
        )

        #expect(state.session(id: "s1")?.updatedAt == before)
        #expect(state.session(id: "s1")?.claudeMetadata?.contextUsedPercentage == 70)
    }

    @Test
    func contextUpdateForUnknownSessionIsIgnored() {
        var state = SessionState()
        state.apply(
            .claudeContextUpdated(
                ClaudeContextUpdated(
                    sessionID: "ghost",
                    contextUsedPercentage: 50,
                    contextWindowSize: nil,
                    totalInputTokens: nil,
                    timestamp: Date(timeIntervalSince1970: 1)
                )
            )
        )
        #expect(state.session(id: "ghost") == nil)
    }
}
