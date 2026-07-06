# Context Glossary — Open Island

The ubiquitous language of this project. Definitions only — no implementation details.
When code or conversation uses one of these words to mean something else, that is a bug in the language; fix it here or fix the usage.

## Usage terms

These two are routinely conflated (and that conflation was a real user-reported bug). They are **different metrics from different scopes** and must never be shown as if interchangeable.

- **Context-window usage** — How full the *current session's* context window is, as a percentage (e.g. "90% context"). **Per session / per worktree.** Rises as a conversation grows, drops on compaction. Source: the Claude Code `statusLine` stdin field `context_window.used_percentage`. This is the number the CLI status line shows.

- **Quota usage** (a.k.a. **rate-limit usage**) — How much of the *account-wide* subscription allowance has been consumed within a rolling window. **Per account, not per session.** Expressed as one or more **usage windows**. Source: the `rate_limits` field. This is what the `/usage` CLI command and the notch usage panel show.

- **Usage window** — One rolling quota bucket with a used percentage and a reset time. Claude exposes a **5h window** and a **7d (weekly) window**. Codex exposes its own (primary/secondary) windows. A window is a facet of *quota usage*, never of *context-window usage*.

- **Peak window** — The single usage window with the highest used percentage among a provider's windows. Historically the notch panel collapsed a provider down to just its peak window; the two windows are distinct facts and should be legible independently.

- **Reset time** — The instant a usage window rolls over and its used percentage returns toward zero. A window whose reset time is in the past is **expired**: any percentage still held for it is a pre-reset leftover and must not be presented as current.

- **Stale reading** — A captured usage value that is older than the freshest data the app could hope to have. The app is only ever as fresh as the most recent status-line turn across all live sessions; it never actively polls. Staleness is surfaced honestly, never hidden.
