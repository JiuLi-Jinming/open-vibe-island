# Per-session context% and account quota flow over the bridge, not a /tmp side-channel

**Status:** accepted

## Context & decision

Claude Code exposes two distinct usage numbers only through its `statusLine` stdin JSON: **context-window usage** (`context_window.used_percentage`, per session) and **quota / rate-limit usage** (`rate_limits.{five_hour,seven_day}`, per account). Neither appears in regular hook payloads (verified against the official hooks docs), so the status-line shim is the *only* injection point for both.

Historically the shim wrote only `rate_limits` to a global file (`/tmp/open-island-rl.json`) that the app polled, and merely `echo`ed the context percentage to the terminal — the app never captured it. This produced the reported "23% vs 90%" confusion: the notch panel showed account quota while the CLI status line showed context fill, two different metrics.

We decided to route **both** numbers through the existing bridge (`statusLine → OpenIslandHooks --source claude-statusline → socket → BridgeServer → SessionState.apply`):

- **Context%** becomes per-session state on `AgentSession.claudeMetadata` via a new dedicated `claudeContextUpdated` event that *merges* only context fields (a wholesale `claudeSessionMetadataUpdated` would clobber transcriptPath/prompts/tools with nils).
- **Quota** stops using the `/tmp` file entirely (full cutover); the account-wide snapshot is fed from the same bridge payload with a receive timestamp.

## Considered alternatives

- **Side-channel file for context% too** (mirror `rate_limits`): rejected — context is per-session, and the repo already has a first-class per-session pipeline (the reducer is the single source of truth per CLAUDE.md); a second polling side-channel plus per-session file cleanup is strictly worse.
- **Keep the `/tmp` quota file as a bridge fallback**: rejected — leaves the old path alive, defeating the point; hooks already fail open, so a momentarily-down bridge just means one skipped refresh, and stale readings are now labelled honestly.
- **Active `/usage` API polling** to match the CLI live: rejected — needs account credentials and a network dependency, violating local-first. The app is honestly bounded by "freshest status-line turn across all sessions" and surfaces staleness instead of hiding it.

## Consequences

- The app can never be fresher than the most recent status-line turn across all live sessions; it must show staleness rather than pretend. Expired windows (`now > resetsAt`) are greyed and stop showing the pre-reset value; readings older than 5 min get a subtle age hint.
- Upgrades rely on the app re-installing the managed/wrapper status-line script (existing repair path) to start forwarding to the bridge.
- Codex quota keeps its own separate mechanism (rollout JSONL parsing); this ADR covers Claude-family agents only.
