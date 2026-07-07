# VS Code 额度探测 — 设计（VS Code usage probe）

Date: 2026-07-07
Branch: `feat/vscode-usage-probe`
Status: Approved (design), pending implementation plan

## 背景与问题

账户级用量面板显示 Claude 的 **5 小时 / 7 天额度窗口**（`ClaudeUsageSnapshot` 里的
`fiveHour` / `sevenDay`，各是一个 `usedPercentage` + `resetsAt`）。这份数据在
Open Island 里**只有一个来源**：Claude Code `statusLine.command` 传进来的 stdin JSON 里的
`rate_limits` 字段，经由 status-line shim → `OpenIslandHooks --source claude-statusline`
→ `BridgeServer.handleClaudeStatusLine` → `onClaudeUsageSnapshot` 送到面板。

`statusLine` 是**终端专属**功能。Claude Code 的 VS Code 扩展把 `claude` 当作**无 TTY 的
子进程**跑在扩展宿主里，用自己的原生 UI，从不调用 `statusLine.command`（代码注释
`ClaudeHooks.swift:1208` 与 Claude Code 官方文档均证实）。因此在**纯 VS Code 场景**下，
额度快照只在偶发的终端对话触发 status line 时才刷新；纯 VS Code 工作时面板冻结在上一次
终端来源的值——这就是「用 VS Code 时流量监控不更新」的现象。

### 已排除的本地来源（深挖结论）

5h/7d 额度窗口（`utilization` / `resets_at`）在本地**任何被动可读文件里都不存在**：

| 候选来源 | 结果 |
|---|---|
| transcript JSONL (`~/.claude/projects/*.jsonl`) | ❌ 只有每条消息 token 计数，无结构化 `rate_limits` |
| `~/.claude/stats-cache.json` | ❌ 只有每日各模型 token 累计，无额度窗口 |
| `~/.claude.json` | ❌ 有 `skillUsage`/`pluginUsage` 等，均非额度窗口 |
| `session-env/` `sessions/` `ide/` `cache/` `telemetry/` `debug/` | ❌ 无额度数据 |
| `claude` CLI 子命令 | ❌ 无 `usage` 子命令；`/usage` 仅交互式 |

额度来自 Anthropic API 响应头（`anthropic-ratelimit-unified-*`），Claude Code 只把它
送进 status line，**从不落盘**。

## 目标 / 非目标

**目标**：VS Code（及其它无 status line 的无-TTY 场景）下，5h/7d 用量面板能刷新。

**非目标**：
- 不改动现有 status line 路径（终端仍走 status line，更实时）。
- 不做 per-model 额度细分展示（endpoint 返回 `seven_day_opus` 等，YAGNI，忽略）。
- 不做 OAuth token 刷新（见下）。
- 不改 context-window（context%）路径——用户明确说这是「token 用量，不是 context」。

## 唯一可行来源：`/api/oauth/usage`

从 Claude Code 原生二进制中提取确认（内部函数 `fetchUtilization` / `api_usage_fetch`）：

- **端点**：`GET https://api.anthropic.com/api/oauth/usage`
- **认证**：`Authorization: Bearer <accessToken>` + oauth beta 头，`timeout 5s`，`Content-Type: application/json`
- **额度成本**：**无**——这是专用 usage GET，**不是** `/v1/messages`，轮询它不消耗 token。
- **响应**：窗口对象 `{ utilization, resets_at }`，键含 `five_hour`、`seven_day`，以及 per-model
  细分（`seven_day_opus` / `seven_day_sonnet` 等，本设计忽略）。
- **兼容性**：现有 `ClaudeUsageWindow` 解析器**已兼容**——它把 `utilization` 当作
  `used_percentage` 的别名读，并读 `resets_at`（`ClaudeUsage.swift:90,96`）。

## 触发策略

**仅当 status line 发不上时兜底**：满足下列**全部**条件才发起一次探测：

1. 存在至少一个活跃 Claude session；且
2. `claudeUsageSnapshot` 为空，或其 `cachedAt` 距今超过 **staleness 阈值**（默认 120 秒）。

终端场景 status line 每轮都在刷 `cachedAt`，因此几乎不会触发探测；只有 VS Code 等无
status line 的场景才会走探测路径。API 调用最少、最贴合 local-first。

判定逻辑抽成纯函数便于单测：

```
func shouldProbe(lastCachedAt: Date?, now: Date, hasActiveSession: Bool,
                 stalenessThreshold: TimeInterval) -> Bool
```

轮询节奏：定时器（如每 30–60 秒）唤醒一次做上面的判定；满足才真正发请求。具体间隔在
实现计划里定，默认 60 秒。

## 认证 —（关键决策）只读、不刷新

- 从 Keychain 读 generic password `svce = "Claude Code-credentials"`（`login.keychain-db`），
  取 JSON 里的 `claudeAiOauth.accessToken`。
- **不做 OAuth refresh**。理由：触发条件要求「有活跃 session」，即 `claude` 进程正活着
  并自己在轮换 token，读到的即有效 token。Open Island 对凭证保持**只读**，避免和
  Claude Code 抢着轮换 refresh token 造成竞态 / 互相失效。
- GET 返回 401 或任何失败 → **本轮跳过，下轮再试，绝不自己刷新**。
- 首次读 Keychain 会弹一次 macOS 授权框（`Open Island 想访问 Claude Code-credentials`），
  用户点「始终允许」后不再提示。这是标准行为，无法绕过；会在文档里说明。

## 架构

新增 `ClaudeUsageProber`（`OpenIslandCore`，`actor`，`Sendable`）：

- 依赖注入两个协议，便于测试：
  - `ClaudeTokenProviding` — `func accessToken() throws -> String?`（默认实现读 Keychain）
  - `UsageHTTPClient` — `func get(_ url: URL, bearer: String) async throws -> Data`（默认 `URLSession`）
- `func probe() async -> ClaudeUsageSnapshot?`：读 token → GET → 用现有
  `ClaudeStatusLineParser` 风格解析（或复用 `ClaudeUsageLoader` 的 `usageWindow`）
  → 返回 `ClaudeUsageSnapshot`（`cachedAt = now` 由调用方 stamp，与 bridge 行为一致）。
  失败返回 `nil`。

`AppModel` 侧：

- 一个轻量定时器（复用现有调度设施）周期性调 `shouldProbe(...)`。
- 命中则 `await prober.probe()`，成功后写入现有 sink `hooks.claudeUsageSnapshot`
  （与 status line 同一出口）。stamp `cachedAt = now`。
- 探测结果绝不覆盖更新的 status-line 值（因为只在 stale 时才探，且成功即 `cachedAt=now`；
  随后到来的 status line 同样 `cachedAt=now` 会自然接管）。

数据流：
```
定时器 → shouldProbe? →（是）ClaudeUsageProber.probe()
       → Keychain accessToken + GET /api/oauth/usage
       → ClaudeUsageSnapshot → hooks.claudeUsageSnapshot → 用量面板
```

## 降级兜底 UI（建议，随本功能一并做）

探测失败 / 离线 / token 读不到时，面板用已有 `cachedAt` 显示「X 分钟前更新」并在明显
过期时弱化（变灰），避免冻结误导。属于防御性 UX；若实现计划想拆分可标为可选。

## 错误处理

- Keychain 读失败（拒绝授权 / 项不存在）：`accessToken()` 返回 `nil`，本轮不探测；记一条
  调试日志，不打扰用户。
- 网络 / 5s 超时 / 非 200：`probe()` 返回 `nil`，保留上一份快照 + 走降级 UI。
- 401（token 过期）：同上，不刷新、不重试风暴；下个定时器周期再看。
- 响应 JSON 结构异常：解析器容错（沿用现有 `JSONSerialization` 宽松风格），缺字段即该窗口为 `nil`。

## 测试

- `shouldProbe(...)` 纯函数单测：覆盖无 session、快照新鲜、快照过期、快照为空各分支。
- `ClaudeUsageProber` 解析单测：喂样例 `/api/oauth/usage` JSON（含 `utilization`/`resets_at`
  与缺字段情形）→ 断言 `ClaudeUsageSnapshot`。
- token / HTTP 走协议 mock：mock 401 → `probe()` 返回 `nil`；mock 成功 → 返回快照。
- 回归：确认 status-line 路径不受影响（现有测试保持绿）。

## Guardrail 说明

本功能引入一个云 API 调用——用**用户自己的凭证**调 **Anthropic 自家端点**，与 Claude Code
自身行为一致，并非 Open Island 自建远程服务。这触碰 CLAUDE.md 的 local-first 守则，属于
「explicit ask」（用户已明确选择该方案）。会在 `README.md` / `docs/` 标注这一新行为与
Keychain 授权提示。

## 支持矩阵影响

`README.md` 的 agents / terminals / IDEs 支持矩阵在 release 时需反映：VS Code（及 forks）
场景的账户额度现在可刷新。
