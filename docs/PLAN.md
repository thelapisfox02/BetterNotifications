# BetterNotifications — Implementation Plan

Status: **design record, written before the build. The module is built; see the README for how it works today.**
This file is kept as the record of the decisions. Two things in it differ from the repo as published: the source
is edited in Roblox Studio and `src/` is a mirror (there is no Rojo project file), and the `README.md` is the
current reference for the API and limits.
Companion document: [RESEARCH.md](./RESEARCH.md) — all platform facts and limits cited here
are sourced there.

---

## 0. Decisions taken

Confirmed with the user:

| Decision | Choice |
| --- | --- |
| Opt-in audience discovery | **Full registry + send-and-learn** — ship a client opt-in prompt helper, persist a registry, and additionally classify send results to cache known-bad userIds |
| Targeting scope | **Online + offline + scheduler** — Players, raw userIds, and future/random-time scheduled sends drained by any live server |
| `Send` semantics | **Fire-and-forget queue** — returns instantly, internal rate-limited worker with retries; results observable via signals |
| Analytics depth | **Dashboard category + AnalyticsService** — auto `analyticsData.category`, `LogCustomEvent` telemetry, plus a runtime stats table |

Decided without asking (flagged to the user, open to reversal):

- Source is authored as `.luau` with a Rojo project file, **plus** an optional packer that
  emits a real `.rbxmx` so the module can be literally drag-and-dropped into Studio.
- MemoryStore lock failures **fail open** (see §4).

---

## 1. Known-unknown: opt-in status is not knowable

Per RESEARCH.md §6 and §8: there is no API to list or query opted-in users, and a `200`
response does **not** confirm delivery — so it cannot be trusted as proof of opt-in.

Therefore the registry is a **confidence model**, not ground truth, and the module ships a
`Config.Diagnostics` mode that dumps the raw `statusCode` / `error.code` for the first N
sends. That lets the real behaviour of a specific universe be measured empirically, and the
classifier tightened from evidence rather than assumption. No other part of the module
depends on resolving this.

---

## 2. File layout

```
src/
├── init.luau                  Public API; bootstraps the client half on first require
├── Config.luau                USER-EDITED: messageId registry + tuning knobs
├── Types.luau                 Shared type definitions
├── Notification.luau          Object returned by :New() — Send / SendIn / SendAtRandom / signals
├── Dispatcher.luau            Token-bucket worker queue, retry/backoff state machine
├── Transport.luau             Wraps the OpenCloud package; normalizes results; DryRun mock
├── Coordinator.luau           MemoryStore locks: per-user/day claim + negative cache
├── Scheduler.luau             MemoryStore SortedMap of due sends + DataStore mirror
├── Registry.luau              Opt-in confidence registry (DataStore + MemoryStore cache)
├── Analytics.luau             category + AnalyticsService + runtime stats
├── Log.luau                   Leveled structured logging
└── Client/
    └── OptInPrompt.luau       Auto-installed LocalScript
default.project.json           → rojo build -o BetterNotifications.rbxm
build-rbxmx.ps1                Optional packer → true drag-and-drop .rbxmx
README.md                      Setup, Creator Dashboard steps, eligibility checklist
```

---

## 3. Public API

The user's original snippet must work verbatim:

```lua
local notifSys = require(BetterNotifications)

local notif = notifSys:New({ msg = "Come back for your daily reward" })
for _, player in notifSys:GetOptedIn() do
    if player.HasDailyWaiting then
        notif:Send(player)
    end
end
```

### `msg` resolution

Resolved through `Config.Messages` in three ways, in order:

1. Alias key — `"daily_reward"`
2. The human-readable text itself — `"Come back for your daily reward"`
3. A raw asset UUID — `"5dd7024b-68e3-ac4d-8232-4217f86ca244"`

Unresolvable → **immediate `error()`** listing every configured string. This is a config
bug, not a runtime condition, and should fail loudly at author time.

Rationale: notification strings must be pre-authored in the Creator Dashboard (RESEARCH.md
§4), so a literal string in code can never be sent as-is. The alias table is the bridge.

### Surface

| Call | Behaviour |
| --- | --- |
| `notifSys:New{msg, params, launchData, category, priority}` | `params` auto-typed to `int64Value` / `stringValue`; `launchData` table auto-JSON-encoded with a hard **200-byte** check; `category` defaults to the message alias |
| `notif:Send(playerOrUserId)` | Enqueues and returns instantly — never yields the caller's loop |
| `notif:SendAll({ids})` | Batch enqueue |
| `notif:SendIn(seconds, target)` | Cross-server durable schedule |
| `notif:SendAt(unixTime, target)` | Absolute-time schedule |
| `notif:SendAtRandom(minSecs, maxSecs, target)` | Random delay inside a window |
| `notif.Sent` / `notif.Failed` | Signals, `(userId, result)` |
| `notifSys:GetOptedIn()` | Registry snapshot |
| `notifSys:GetStats()` | Live counters bucketed by error code |
| `notifSys:PromptOptIn(player)` | Force the opt-in prompt from the server |
| `notifSys:SetLogLevel(level)` | `"error" \| "warn" \| "info" \| "debug"` |

---

## 4. Reliability layer

### Retry classification

Straight from the Open Cloud v2 error table (RESEARCH.md §7):

- **Retryable** — `429 RESOURCE_EXHAUSTED`, `499 CANCELLED`, `500 INTERNAL`,
  `503 UNAVAILABLE`. Exponential backoff: 1s base, ×2, ±25% jitter, 5 attempts max.
- **Terminal, never retried** — `400 INVALID_ARGUMENT`, `403 PERMISSION_DENIED`,
  `404 NOT_FOUND`, `501 NOT_IMPLEMENTED`. Logged loudly with a specific fix hint
  (bad `messageId` / eligibility not met / wrong universe).
- `409 ABORTED` — conditional, single retry.

Every transport call is wrapped in `pcall` **and** has its `statusCode` checked: the
package yields and can throw at the Luau level independently of the returned status.

### Rate limiting

No per-minute API limit is documented (RESEARCH.md §6), so the Dispatcher self-limits with
a token bucket — conservative default, configurable. One worker coroutine drains the queue.

### Cross-server dedupe

`MemoryStoreHashMap:UpdateAsync("bns:<userId>:<utcDay>", …)` as a compare-and-set, TTL to
end of UTC day. Costs 2 request units against a `1000 + 120 × CCU` per-minute budget —
negligible. First server to claim wins; all others drop silently. This mirrors Roblox's own
1-per-user-per-day throttle exactly.

**Fail-open rationale:** because Roblox independently enforces 1/user/day, a lock failure
that lets a duplicate through costs one wasted API call. Failing *closed* would silently
drop real notifications. So: fail open, and log at `warn`.

### Negative cache

Users that return a terminal error get a MemoryStore HashMap entry (~1h TTL) so repeat
attempts are skipped without an API call.

---

## 5. Scheduler

MemoryStore `SortedMap`, sort key = unix timestamp. Each server polls on a **jittered**
interval, calls `GetRangeAsync` for entries due at or before now, claims each via the §4
lock, dispatches, then removes the entry.

MemoryStore is transient (RESEARCH.md §10), so `Config.PersistSchedules` (default **on**)
mirrors schedules more than 1 hour out into a DataStore and rehydrates them on server
start. Gated by config to avoid burning DataStore budget for experiences that only ever
schedule short-horizon sends.

`GetRangeAsync` costs per item returned — the poll uses a bounded page size.

---

## 6. Opt-in registry

### Client half — auto-install

On first server `require`, the module:

1. Creates its RemoteEvent/RemoteFunction under a `BetterNotifications` folder in
   `ReplicatedStorage`.
2. Clones `Client/OptInPrompt` into `StarterPlayer.StarterPlayerScripts` (picked up by all
   subsequent joins).
3. Also injects directly into `PlayerScripts` for anyone already in the server, so it works
   if the module is required late.

### Client flow

`pcall(CanPromptOptInAsync)` → if true, `PromptOptIn()` → wait for `OptInPromptClosed` →
report the outcome back over the RemoteEvent.

Note the ambiguity documented in RESEARCH.md §3: re-checking `CanPromptOptInAsync()` after
the prompt closes is **useless**, because it returns `false` either way (the 30-day
re-prompt rule). The client reports "prompt was shown and closed", nothing stronger.

### States

| State | Meaning |
| --- | --- |
| `UNKNOWN` | Default — never prompted, never sent to |
| `PROMPTED` | We showed the opt-in modal (with timestamp) |
| `LIKELY_OPTED_IN` | A send returned `200` |
| `NOT_ELIGIBLE` | A send returned a terminal error |

Backed by DataStore for durability, hot-cached in MemoryStore so all live servers share
one view. `NOT_ELIGIBLE` also drives the §4 negative cache.

---

## 7. Analytics

- Auto-fills `analyticsData.category` on every payload, defaulting to the message alias —
  this is what groups rows in the Creator Dashboard itemized table.
- `AnalyticsService:LogCustomEvent` for `attempt` / `sent` / `retry` / `throttled` /
  `failed`. **Online players only** — that API requires a live `Player` instance, so sends
  to offline userIds (the primary use case) cannot use it and fall through to the stats
  table plus structured logs. Field cardinality is kept well under the 8,000
  unique-combination cap.
- `notifSys:GetStats()` returns live counters bucketed by error code.

---

## 8. Build order

1. `Types` + `Config` + `Log`
2. `Transport` — including the `DryRun` mock, so the module can be exercised in Studio
   without burning quota or requiring the Creator Store package
3. `Coordinator` — MemoryStore locks + negative cache
4. `Dispatcher` — queue, token bucket, retry state machine
5. `Notification` + `init` — public API; **the user's snippet works from here on**
6. `Registry` + `Client/OptInPrompt` + auto-bootstrap
7. `Scheduler`
8. `Analytics`
9. `README.md` — setup, Creator Dashboard walkthrough, eligibility checklist
   (100 visits, no active moderation, manage permissions), troubleshooting table keyed by
   error code
10. `default.project.json` + `build-rbxmx.ps1`

---

## 9. Testing approach

There is no headless Roblox runtime available here, so verification is:

- `Config.DryRun = true` — `Transport` returns simulated results (configurable mix of 200s,
  429s, 500s, 400s) so the queue, retry, backoff, dedupe and scheduler logic can all be
  exercised in Studio without touching the live API.
- Studio caveat to document: the Creator Store OpenCloud package's behaviour in Studio may
  differ from a live server; MemoryStore and DataStore both require API access to be
  enabled for Studio.
- The eligibility gate (100 visits) means a brand-new place cannot send at all — call this
  out prominently in the README so a failing first test isn't misdiagnosed as a module bug.
