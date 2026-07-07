# VS Code Usage Probe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh the 5h/7d account-quota usage panel during VS Code (TTY-less) sessions, where Claude Code never runs the terminal status line.

**Architecture:** An opt-in fallback. A `ClaudeUsageProber` actor in `OpenIslandCore` reads the OAuth access token from the macOS Keychain (read-only, never refreshes) and does a quota-free `GET https://api.anthropic.com/api/oauth/usage`. `AppModel` drives it from a 60 s poll loop that fires the probe only when a session is live **and** the existing usage snapshot is stale (>120 s). The status-line path is untouched; the probe writes into the same `hooks.claudeUsageSnapshot` sink.

**Tech Stack:** Swift 6.2, SwiftPM, swift-testing (`import Testing`), Foundation `URLSession`, `Security` (Keychain). macOS 14+.

## Global Constraints

- Swift 6.2, macOS 14+. All new models `Sendable` + `Codable` where they cross concurrency domains.
- `OpenIslandCore` has **no** SwiftPM dependencies — use only `Foundation` / `Security` (system frameworks). Do not add package deps.
- Tests use **swift-testing** (`import Testing`, `struct` suite, `@Test`, `#expect`), NOT XCTest. New Core tests → `Tests/OpenIslandCoreTests/`.
- Hooks/probes **fail open**: any failure (no token, 401, network, bad JSON) → return `nil`, keep the last snapshot, never crash and never block.
- **Never** perform an OAuth token refresh. Read the token, use it, and on any auth failure just skip this cycle.
- Endpoint is quota-free (`/api/oauth/usage`, a dedicated GET — NOT `/v1/messages`). Do not call `/v1/messages` for usage.
- New files are globbed by SwiftPM — no `Package.swift` edits needed for `Sources/OpenIslandCore/*` or `Tests/OpenIslandCoreTests/*`.
- Conventional commit messages. Commit after each task. Never `--amend`.

---

### Task 0: Confirm the live response schema (spike)

This pins the JSON shape the parser must accept. The endpoint is quota-free, but it needs the user's OAuth token, so **the user runs this** (via the `!` prompt prefix) and pastes the redacted shape — do not materialize the credential in the agent transcript.

**Files:** none (investigation only).

- [ ] **Step 1: Ask the user to capture the response shape**

Ask the user to run (in their shell, token stays local):

```bash
TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w | python3 -c 'import sys,json;print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])')
curl -s https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "Content-Type: application/json" \
  | python3 -m json.tool | sed -E 's/[0-9]+\.[0-9]+/NN.N/g'
```

Ask them to paste the **structure** (keys/nesting) — the `sed` blurs exact numbers.

- [ ] **Step 2: Record the confirmed shape**

Note the confirmed nesting in the Task 1 fixture below. The parser in Task 1 is written to tolerate the two plausible shapes regardless; use the capture to pick which fixture is the "real" one and to catch any envelope key (e.g. a top-level `data`) not anticipated here. If the capture reveals a shape neither fixture covers, extend Task 1's parser + fixtures to match before proceeding.

> If the user declines to run it, proceed with the tolerant parser as written — it already accepts window metrics at the root or under `limit`, with an optional `data` envelope.

---

### Task 1: Tolerant dict→snapshot parser in `ClaudeUsageLoader`

**Files:**
- Modify: `Sources/OpenIslandCore/ClaudeUsage.swift`
- Test: `Tests/OpenIslandCoreTests/ClaudeUsageTests.swift` (add cases to the existing suite)

**Interfaces:**
- Produces: `public static func snapshot(from payload: [String: Any], cachedAt: Date?) -> ClaudeUsageSnapshot?` on `ClaudeUsageLoader`. Returns `nil` when both windows are absent. Accepts window metrics for keys `"five_hour"`/`"seven_day"` located either at the window-dict root or nested under a `"limit"` sub-dict; unwraps an optional top-level `"data"` or `"rate_limits"` envelope. Percentage read from `"used_percentage"` or `"utilization"`; reset from `"resets_at"`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/OpenIslandCoreTests/ClaudeUsageTests.swift` inside `struct ClaudeUsageTests`:

```swift
@Test
func snapshotParsesFlatWindowShape() {
    let payload: [String: Any] = [
        "five_hour": ["utilization": 42.0, "resets_at": 1_760_000_000],
        "seven_day": ["utilization": 18.0, "resets_at": 1_760_500_000],
    ]
    let snapshot = ClaudeUsageLoader.snapshot(from: payload, cachedAt: nil)
    #expect(snapshot?.fiveHour?.roundedUsedPercentage == 42)
    #expect(snapshot?.sevenDay?.roundedUsedPercentage == 18)
    #expect(snapshot?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_760_000_000))
}

@Test
func snapshotParsesNestedLimitAndDataEnvelope() {
    let payload: [String: Any] = [
        "data": [
            "five_hour": ["limit": ["used_percentage": 55.0, "resets_at": "2026-07-07T12:00:00Z"]],
            "seven_day": ["limit": ["used_percentage": 12.0]],
        ]
    ]
    let snapshot = ClaudeUsageLoader.snapshot(from: payload, cachedAt: Date(timeIntervalSince1970: 100))
    #expect(snapshot?.fiveHour?.roundedUsedPercentage == 55)
    #expect(snapshot?.sevenDay?.roundedUsedPercentage == 12)
    #expect(snapshot?.sevenDay?.resetsAt == nil)
    #expect(snapshot?.cachedAt == Date(timeIntervalSince1970: 100))
}

@Test
func snapshotReturnsNilWhenNoWindows() {
    #expect(ClaudeUsageLoader.snapshot(from: ["unrelated": 1], cachedAt: nil) == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ClaudeUsageTests`
Expected: FAIL — `snapshot(from:cachedAt:)` does not exist (compile error).

- [ ] **Step 3: Implement the parser and route `load(from:)` through it**

In `Sources/OpenIslandCore/ClaudeUsage.swift`, add to `enum ClaudeUsageLoader` (public), and change `usageWindow` to search a nested `limit`:

```swift
    /// Parses a decoded usage payload (from the status-line cache file OR the
    /// `/api/oauth/usage` probe) into a snapshot. Tolerant of two shapes: window
    /// metrics at the window-dict root, or nested under a `limit` sub-dict; and an
    /// optional top-level `data` / `rate_limits` envelope.
    public static func snapshot(from payload: [String: Any], cachedAt: Date?) -> ClaudeUsageSnapshot? {
        let root = (payload["data"] as? [String: Any])
            ?? (payload["rate_limits"] as? [String: Any])
            ?? payload
        let snapshot = ClaudeUsageSnapshot(
            fiveHour: usageWindow(for: "five_hour", in: root),
            sevenDay: usageWindow(for: "seven_day", in: root),
            cachedAt: cachedAt
        )
        return snapshot.isEmpty ? nil : snapshot
    }
```

Replace the existing `usageWindow(for:in:)` body so it looks at the window root and a nested `limit`:

```swift
    private static func usageWindow(for key: String, in payload: [String: Any]) -> ClaudeUsageWindow? {
        guard let window = payload[key] as? [String: Any] else { return nil }
        let metrics = (window["limit"] as? [String: Any]) ?? window
        guard let rawPercentage = number(from: metrics["used_percentage"])
            ?? number(from: metrics["utilization"]) else {
            return nil
        }
        return ClaudeUsageWindow(
            usedPercentage: rawPercentage,
            resetsAt: date(from: metrics["resets_at"])
        )
    }
```

Then route the existing file loader through the new parser to keep one code path. In `load(from url: URL)`, replace the block that builds `snapshot` (currently `ClaudeUsage.swift:56-64`) with:

```swift
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let cachedAt = attributes?[.modificationDate] as? Date
        return snapshot(from: payload, cachedAt: cachedAt)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ClaudeUsageTests`
Expected: PASS — new cases plus the pre-existing `claudeUsageLoaderParsesCachedRateLimits` (regression: file path still works through the shared parser).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenIslandCore/ClaudeUsage.swift Tests/OpenIslandCoreTests/ClaudeUsageTests.swift
git commit -m "feat: add tolerant dict->ClaudeUsageSnapshot parser"
```

---

### Task 2: `ClaudeUsageProber` actor + injectable protocols

**Files:**
- Create: `Sources/OpenIslandCore/ClaudeUsageProber.swift`
- Test: `Tests/OpenIslandCoreTests/ClaudeUsageProberTests.swift`

**Interfaces:**
- Consumes: `ClaudeUsageLoader.snapshot(from:cachedAt:)` (Task 1).
- Produces:
  - `public protocol ClaudeTokenProviding: Sendable { func accessToken() -> String? }`
  - `public protocol UsageHTTPClient: Sendable { func getJSON(url: URL, bearerToken: String) async -> Data? }` (returns `nil` on any non-2xx or transport error — the client swallows failures so the prober stays simple)
  - `public actor ClaudeUsageProber` with `public init(tokenProvider: ClaudeTokenProviding, httpClient: UsageHTTPClient)` and `public func probe() async -> ClaudeUsageSnapshot?`. Returns a snapshot with `cachedAt == nil` (the driver stamps time); `nil` when there's no token, the HTTP call fails, or the JSON has no windows. Does NOT call the HTTP client when the token is `nil`.
  - `public static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!`

- [ ] **Step 1: Write the failing tests**

Create `Tests/OpenIslandCoreTests/ClaudeUsageProberTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ClaudeUsageProberTests`
Expected: FAIL — `ClaudeUsageProber` / protocols do not exist.

- [ ] **Step 3: Implement the prober**

Create `Sources/OpenIslandCore/ClaudeUsageProber.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ClaudeUsageProberTests`
Expected: PASS (all three).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenIslandCore/ClaudeUsageProber.swift Tests/OpenIslandCoreTests/ClaudeUsageProberTests.swift
git commit -m "feat: add ClaudeUsageProber actor for quota fallback"
```

---

### Task 3: Keychain token provider

**Files:**
- Create: `Sources/OpenIslandCore/ClaudeKeychainTokenProvider.swift`
- Test: `Tests/OpenIslandCoreTests/ClaudeKeychainTokenProviderTests.swift`

**Interfaces:**
- Consumes: `ClaudeTokenProviding` (Task 2).
- Produces: `public struct ClaudeKeychainTokenProvider: ClaudeTokenProviding` with `public init(service: String = "Claude Code-credentials")` and `func accessToken() -> String?`. Also a pure, testable helper: `static func extractAccessToken(from data: Data) -> String?` reading `claudeAiOauth.accessToken`.

- [ ] **Step 1: Write the failing tests (pure JSON extraction)**

Create `Tests/OpenIslandCoreTests/ClaudeKeychainTokenProviderTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ClaudeKeychainTokenProviderTests`
Expected: FAIL — type does not exist.

- [ ] **Step 3: Implement the provider**

Create `Sources/OpenIslandCore/ClaudeKeychainTokenProvider.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ClaudeKeychainTokenProviderTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenIslandCore/ClaudeKeychainTokenProvider.swift Tests/OpenIslandCoreTests/ClaudeKeychainTokenProviderTests.swift
git commit -m "feat: read Claude OAuth token from Keychain (read-only)"
```

---

### Task 4: URLSession HTTP client

**Files:**
- Create: `Sources/OpenIslandCore/URLSessionUsageHTTPClient.swift`

**Interfaces:**
- Consumes: `UsageHTTPClient` (Task 2).
- Produces: `public struct URLSessionUsageHTTPClient: UsageHTTPClient` with `public init(session: URLSession = .shared, timeout: TimeInterval = 5)`.

This is a thin system-framework adapter (no unit test — it only wires `URLSession`; behavior is covered by the prober's stubbed tests and the manual verification in Task 6).

- [ ] **Step 1: Implement the client**

Create `Sources/OpenIslandCore/URLSessionUsageHTTPClient.swift`:

```swift
import Foundation

/// Default `UsageHTTPClient`: a GET with Bearer auth + the OAuth beta header.
/// Returns `nil` on any non-2xx status or transport error (fail open).
public struct URLSessionUsageHTTPClient: UsageHTTPClient {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 5) {
        self.session = session
        self.timeout = timeout
    }

    public func getJSON(url: URL, bearerToken: String) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        return data
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenIslandCore/URLSessionUsageHTTPClient.swift
git commit -m "feat: add URLSession-based usage HTTP client"
```

---

### Task 5: `shouldProbe` decision + AppModel driver

**Files:**
- Create: `Sources/OpenIslandCore/ClaudeUsageProbePolicy.swift`
- Test: `Tests/OpenIslandCoreTests/ClaudeUsageProbePolicyTests.swift`
- Modify: `Sources/OpenIslandApp/AppModel.swift`

**Interfaces:**
- Consumes: `ClaudeUsageProber.probe()` (Task 2), `ClaudeKeychainTokenProvider` (Task 3), `URLSessionUsageHTTPClient` (Task 4), `hooks.claudeUsageSnapshot` sink (`HookInstallationCoordinator.claudeUsageSnapshot`), `state.liveSessionCount` (`SessionState`).
- Produces: `public func shouldProbeClaudeUsage(lastCachedAt: Date?, now: Date, hasActiveSession: Bool, stalenessThreshold: TimeInterval) -> Bool`.

- [ ] **Step 1: Write the failing tests for the policy**

Create `Tests/OpenIslandCoreTests/ClaudeUsageProbePolicyTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ClaudeUsageProbePolicyTests`
Expected: FAIL — function undefined.

- [ ] **Step 3: Implement the policy**

Create `Sources/OpenIslandCore/ClaudeUsageProbePolicy.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ClaudeUsageProbePolicyTests`
Expected: PASS.

- [ ] **Step 5: Wire the driver into AppModel**

In `Sources/OpenIslandApp/AppModel.swift`, add a stored property near the other task handles (e.g. beside `bridgeReconnectTask`):

```swift
    private var claudeUsageProbeTask: Task<Void, Never>?
    private let claudeUsageProber = ClaudeUsageProber(
        tokenProvider: ClaudeKeychainTokenProvider(),
        httpClient: URLSessionUsageHTTPClient()
    )
```

Add the driver method (place it near `scheduleBridgeReconnect`):

```swift
    /// Fallback quota refresh for TTY-less (VS Code) sessions: the terminal
    /// status line never runs there, so the 5h/7d panel would otherwise freeze.
    /// Polls every 60 s but only probes when a session is live and the snapshot
    /// is stale (>120 s) — terminal sessions keep it fresh via the status line.
    private func startClaudeUsageProbeIfNeeded() {
        guard claudeUsageProbeTask == nil else { return }
        claudeUsageProbeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let self {
                    let hasActiveSession = self.state.liveSessionCount > 0
                    if shouldProbeClaudeUsage(
                        lastCachedAt: self.hooks.claudeUsageSnapshot?.cachedAt,
                        now: Date(),
                        hasActiveSession: hasActiveSession,
                        stalenessThreshold: 120
                    ) {
                        if var snapshot = await self.claudeUsageProber.probe() {
                            snapshot.cachedAt = Date()
                            self.hooks.claudeUsageSnapshot = snapshot
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
```

Start it in the lifecycle where the Claude usage monitor is started (`AppModel.swift:1091-1096`, right after `hooks.startClaudeUsageMonitoringIfNeeded()`):

```swift
        startClaudeUsageProbeIfNeeded()
```

Cancel it wherever `bridgeReconnectTask` / other tasks are cancelled on teardown (mirror the existing `?.cancel()` cleanup):

```swift
        claudeUsageProbeTask?.cancel()
        claudeUsageProbeTask = nil
```

> Verify the exact accessor for a live-session count. This plan uses `state.liveSessionCount` (`SessionState.swift:32-33`). If `state` is named differently in `AppModel`, adjust to the real property; the intent is "≥1 live session".

- [ ] **Step 6: Build and run the full test suite**

Run: `swift build && swift test`
Expected: builds; all tests pass (new + existing).

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenIslandCore/ClaudeUsageProbePolicy.swift Tests/OpenIslandCoreTests/ClaudeUsageProbePolicyTests.swift Sources/OpenIslandApp/AppModel.swift
git commit -m "feat: drive quota probe from AppModel when snapshot is stale"
```

---

### Task 6: Staleness indicator on the usage panel — DROPPED (already implemented)

**Status: not implemented — redundant.** During execution we found the usage
panel already renders staleness: `IslandPanelView.usageWindowSubPill`
(`Sources/OpenIslandApp/Views/IslandPanelView.swift:1086-1127`) computes
`staleAge` from `provider.cachedAt`, flags `isStale` past a 5-min threshold,
shows a dim `·<age>` hint, and greys expired windows — and no-ops for providers
without `cachedAt` (Codex). Task 5 stamps `snapshot.cachedAt = Date()` on probe
success, so probe-sourced data flows through this existing UI unchanged. The
`ClaudeUsageFreshness.swift` helpers below were therefore NOT created. Original
plan text retained for the record:



**Files:**
- Create: `Sources/OpenIslandCore/ClaudeUsageFreshness.swift`
- Test: `Tests/OpenIslandCoreTests/ClaudeUsageFreshnessTests.swift`
- Modify: the usage-panel view (`Sources/OpenIslandApp/Views/IslandPanelView.swift` — the block that renders `model.claudeUsageSnapshot`, ~`:873`)

**Interfaces:**
- Produces: `public func claudeUsageFreshnessLabel(cachedAt: Date?, now: Date, staleAfter: TimeInterval) -> String?` — `nil` when fresh/unknown, else e.g. `"updated 3m ago"`; and `public func claudeUsageIsStale(cachedAt: Date?, now: Date, staleAfter: TimeInterval) -> Bool`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/OpenIslandCoreTests/ClaudeUsageFreshnessTests.swift`:

```swift
import Foundation
import Testing
@testable import OpenIslandCore

struct ClaudeUsageFreshnessTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test
    func freshSnapshotHasNoLabel() {
        #expect(claudeUsageFreshnessLabel(cachedAt: now.addingTimeInterval(-30), now: now, staleAfter: 120) == nil)
        #expect(claudeUsageIsStale(cachedAt: now.addingTimeInterval(-30), now: now, staleAfter: 120) == false)
    }

    @Test
    func staleSnapshotIsLabeledInMinutes() {
        let label = claudeUsageFreshnessLabel(cachedAt: now.addingTimeInterval(-200), now: now, staleAfter: 120)
        #expect(label == "updated 3m ago")
        #expect(claudeUsageIsStale(cachedAt: now.addingTimeInterval(-200), now: now, staleAfter: 120) == true)
    }

    @Test
    func unknownCachedAtIsStaleWithoutLabel() {
        #expect(claudeUsageFreshnessLabel(cachedAt: nil, now: now, staleAfter: 120) == nil)
        #expect(claudeUsageIsStale(cachedAt: nil, now: now, staleAfter: 120) == true)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ClaudeUsageFreshnessTests`
Expected: FAIL — functions undefined.

- [ ] **Step 3: Implement the helpers**

Create `Sources/OpenIslandCore/ClaudeUsageFreshness.swift`:

```swift
import Foundation

/// A human "updated Nm ago" label when the quota snapshot is older than
/// `staleAfter`, else `nil` (fresh, or no timestamp to report).
public func claudeUsageFreshnessLabel(cachedAt: Date?, now: Date, staleAfter: TimeInterval) -> String? {
    guard let cachedAt else { return nil }
    let age = now.timeIntervalSince(cachedAt)
    guard age > staleAfter else { return nil }
    let minutes = Int(age / 60)
    return minutes < 1 ? "updated just now" : "updated \(minutes)m ago"
}

/// Whether the quota panel should render in a dimmed "not live" state.
/// A missing timestamp counts as stale.
public func claudeUsageIsStale(cachedAt: Date?, now: Date, staleAfter: TimeInterval) -> Bool {
    guard let cachedAt else { return true }
    return now.timeIntervalSince(cachedAt) > staleAfter
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ClaudeUsageFreshnessTests`
Expected: PASS.

- [ ] **Step 5: Show the label / dim in the usage panel**

In `Sources/OpenIslandApp/Views/IslandPanelView.swift`, find the view that renders `model.claudeUsageSnapshot` (~`:873`). Add, using the helpers (compute `now` from the view's existing time source, or `Date()`):

- When `claudeUsageFreshnessLabel(cachedAt: snapshot.cachedAt, now: Date(), staleAfter: 120)` is non-nil, render it as a small caption under the windows.
- When `claudeUsageIsStale(...)` is true, apply `.opacity(0.55)` to the windows.

Follow the file's existing SwiftUI idioms (spacing, font, secondary color) — match the neighboring badge/caption styling rather than inventing new modifiers. Keep it a couple of lines.

- [ ] **Step 6: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenIslandCore/ClaudeUsageFreshness.swift Tests/OpenIslandCoreTests/ClaudeUsageFreshnessTests.swift Sources/OpenIslandApp/Views/IslandPanelView.swift
git commit -m "feat: show quota freshness / dim panel when stale"
```

---

### Task 7: Manual end-to-end verification + docs

**Files:**
- Modify: `README.md` (support matrix / behavior note)

- [ ] **Step 1: Manual verification (VS Code path)**

Per CLAUDE.md, use the dev app:

```bash
zsh scripts/launch-dev-app.sh
```

- Start a Claude Code session **inside the VS Code extension** (not the integrated terminal).
- Confirm the session shows as "VS Code" in Open Island.
- Watch the usage panel: within ~2–3 minutes it should populate/refresh the 5h/7d windows without any terminal session running. (First run triggers the one-time Keychain authorization prompt — click "Always Allow".)
- Regression: a Terminal session should still update the panel via the status line, and the probe should stay idle (snapshot never goes stale enough to fire). Confirm no duplicate/flapping values.

Record the observed result in the PR description (evidence before claiming success — per verification-before-completion).

- [ ] **Step 2: Update README**

Add a short note under the relevant section that account quota now refreshes for VS Code (TTY-less) sessions via a quota-free `/api/oauth/usage` probe, and that Open Island reads the Claude Code OAuth token from the Keychain (one-time authorization prompt). Keep the support matrix accurate.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: note VS Code quota refresh via oauth usage probe"
```

---

## Self-Review

**Spec coverage:**
- Problem/root cause → Task 0 (schema) + Tasks 1–2 (fetch/parse). ✓
- Trigger "only when status line can't deliver" → Task 5 policy + driver. ✓
- Auth read-only, no refresh, 401 → skip → Task 3 (read-only Keychain) + Task 2/4 (nil on failure) + Global Constraints. ✓
- Endpoint quota-free `/api/oauth/usage` → Task 2 constant + Task 4 request. ✓
- Existing parser compatible / reuse → Task 1 routes file loader through shared parser. ✓
- Architecture: `ClaudeUsageProber` actor + injected `TokenProvider`/`HTTPClient` → Tasks 2–4. ✓
- Feed existing `hooks.claudeUsageSnapshot` sink, stamp `cachedAt` → Task 5 driver. ✓
- Staleness fallback UI → Task 6. ✓
- Ignore per-model breakdown → parser only reads `five_hour`/`seven_day` (Task 1). ✓
- Testing plan (pure funcs, mocks, regression) → Tasks 1,2,3,5,6 tests + Task 5 step 6. ✓
- Guardrail note / README → Task 7. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code. Task 0 is a genuine investigation step, not a placeholder; Task 6 step 5 defers to the file's own SwiftUI idioms deliberately (visual styling), with concrete helper calls specified.

**Type consistency:** `ClaudeTokenProviding.accessToken() -> String?`, `UsageHTTPClient.getJSON(url:bearerToken:) -> Data?`, `ClaudeUsageProber.probe() -> ClaudeUsageSnapshot?`, `ClaudeUsageLoader.snapshot(from:cachedAt:)`, `shouldProbeClaudeUsage(...)`, `claudeUsageFreshnessLabel(...)`/`claudeUsageIsStale(...)` — names/signatures consistent across tasks and tests.
