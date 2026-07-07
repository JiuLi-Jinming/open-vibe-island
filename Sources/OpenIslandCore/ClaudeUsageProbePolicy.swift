import Foundation

/// Whether to fire the `/api/oauth/usage` fallback probe this tick. Probe only
/// when a session is live AND the last quota snapshot is missing or older than
/// `stalenessThreshold` — so terminal sessions (status line keeps `cachedAt`
/// fresh) essentially never trigger it, and TTY-less (VS Code) sessions do.
public func shouldProbeClaudeUsage(
    lastCachedAt: Date?,
    now: Date,
    hasActiveSession: Bool,
    stalenessThreshold: TimeInterval
) -> Bool {
    guard hasActiveSession else { return false }
    guard let lastCachedAt else { return true }
    return now.timeIntervalSince(lastCachedAt) > stalenessThreshold
}
