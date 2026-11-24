# BetterNotifications

A Roblox experience-notification module with a fire-and-forget send queue,
retry/backoff, cross-server dedupe, durable scheduling, an opt-in registry and
analytics.

```lua
local notifSys = require(game.ServerScriptService.BetterNotifications)

local notif = notifSys:New({ msg = "daily_reward" })
for _, entry in notifSys:GetOptedIn() do
    notif:Send(entry)
end
```

`Send` never yields. It queues, and a rate-limited worker drains the queue with
retries.

Platform behaviour is documented in [docs/RESEARCH.md](docs/RESEARCH.md); the
source cites it by section. Design decisions are in [docs/PLAN.md](docs/PLAN.md).

---

## Before anything else: can you even send?

Experience notifications have hard gates that have nothing to do with this
module. Check all of these first, or you will misdiagnose a platform refusal as
a module bug.

| Requirement | Detail |
| --- | --- |
| **100+ visits since launch** | A brand-new place **cannot send at all**. This is the most common cause of a first test failing. |
| Not under moderation | The experience must be in good standing. |
| Manage permission | You must have permission to manage the experience. |
| Recipient is 13+ | Under-13 accounts cannot receive them. |
| Recipient opted in | Via the bell on the Experience Details Page, or the in-experience prompt this module installs. |

Even with all of that satisfied, **a `200` response does not mean the
notification was delivered.** See [Why opt-in is a guess](#why-opt-in-is-a-guess).

---

## Install

### 1. The Open Cloud package (required)

Sending is not a built-in engine service. Install the **Open Cloud** package by
Roblox from the Creator Store into `ServerScriptService`, so that this path
resolves:

```
ServerScriptService.OpenCloud.V2.UserNotification
```

Without it, every send fails with `PACKAGE_MISSING`. You can develop without it
by setting `Config.DryRun = true`.

> Do not call the engine's `OpenCloudApiV1` / `CreateUserNotificationAsync`
> directly — it is deprecated.

### 2. This module

The place itself hosts the scripts — Studio is the source of truth, and `src/`
in this repo is the mirror. The instance tree under `ServerScriptService` must
match the [layout](#layout) below: a `BetterNotifications` ModuleScript whose
children are the sibling modules, plus a `Client` Folder holding the
`OptInPrompt` LocalScript.

To hand the module to someone else as a single file:

```powershell
.\build-rbxmx.ps1
```

Drag the resulting `BetterNotifications.rbxmx` into Studio, then move the
`BetterNotifications` ModuleScript into `ServerScriptService`.

### 3. Enable API access

`Game Settings -> Security -> Enable Studio Access to API Services`. Required
for DataStore and MemoryStore, which the registry, dedupe and scheduler all use.

---

## Authoring notification strings

**There is no API for this.** Notification strings must be created by hand in
the Creator Dashboard before code can reference them.

1. Creator Dashboard -> your experience -> **Engagement** -> **Notifications**
2. **Create a Notification String**
3. Write the body. Limit **99 characters**. The experience title is used as the
   header automatically; `{experienceName}` works inside the body.
   - Custom placeholders: `{points}`, `{numQuests}`, …
   - User mentions: `{userId-friend}` — see the delivery caveat below.
4. Save, then use the row's **⋯ -> Copy Asset ID**. That UUID is your
   `messageId`.

Then register it in `src/Config.luau`:

```lua
Config.Messages = {
    daily_reward = {
        id = "5dd7024b-68e3-ac4d-8232-4217f86ca244",
        text = "Come back for your daily reward",
    },
    friend_beat_score = {
        id = "ef0e0790-e2e8-4441-9a32-93f3a5783bf1",
        text = "{userId-friend} beat your high score by {points} points!",
    },
}
```

`msg` resolves in three ways, in order — alias key, exact configured `text`, or
a raw asset UUID:

```lua
notifSys:New({ msg = "daily_reward" })                              -- alias
notifSys:New({ msg = "Come back for your daily reward" })           -- text
notifSys:New({ msg = "5dd7024b-68e3-ac4d-8232-4217f86ca244" })      -- UUID
```

An unresolvable `msg` throws immediately, listing everything configured. That is
deliberate: it is a config bug, not a runtime condition.

---

## Usage

### Parameters

Plain values are wrapped into the typed form the API needs. A `Player` becomes
its UserId, which is what a `{userId-…}` placeholder wants.

```lua
local notif = notifSys:New({
    msg = "friend_beat_score",
    params = { ["userId-friend"] = somePlayer, points = 5 },
})
```

Because notifications must be personalised to the receiver, per-send overrides
usually matter more than the defaults:

```lua
notif:Send(userId, { params = { ["userId-friend"] = rival, points = score } })
```

### Launch data

Read on the other side with `Player:GetJoinData().LaunchData`. Tables are
JSON-encoded for you. **Max 200 bytes**, enforced locally so you find out at
author time rather than from a 400.

```lua
notifSys:New({ msg = "daily_reward", launchData = { screen = "rewards" } })
```

### Scheduling

Durable and cross-server: whichever server is alive at the due time delivers it,
not necessarily the one that scheduled it.

```lua
notif:SendIn(3600, userId)              -- in an hour
notif:SendAt(os.time() + 86400, userId) -- absolute unix time
notif:SendAtRandom(600, 7200, userId)   -- spread a wave out
```

### Signals

```lua
notif.Sent:Connect(function(userId, result) end)
notif.Failed:Connect(function(userId, result) end)

notifSys.Sent:Connect(function(userId, result) end)    -- every send on this server
notifSys.Failed:Connect(function(userId, result) end)
```

Per-object signals only fire for sends that object queued **on this server**. A
scheduled send drained by a different server fires that server's `notifSys`
signals instead. Use the module-level signals if you need to catch everything.

---

## API

### Module

| Call | Returns | Notes |
| --- | --- | --- |
| `:New(spec)` | Notification | `spec = { msg, params?, launchData?, category?, priority? }`. Throws on unresolvable `msg`. |
| `:GetOptedIn(includePrompted?)` | array of entries | **Yields.** Confidence model — see below. `includePrompted` defaults to true. |
| `:GetEntry(target)` | entry or nil | Registry record for one user. |
| `:GetStats()` | table | Live counters bucketed by status and error code, plus `queueSize` and a `registry` health block (`degraded`, `pending`, `failingShards`, `droppedStages`). |
| `:PromptOptIn(player)` | boolean | Asks that client to show the opt-in modal. |
| `:SetLogLevel(level)` | — | `"error"`, `"warn"`, `"info"`, `"debug"`. |
| `:ClearNotEligible(target)` | boolean | Un-parks a user from the negative cache. Call after fixing the config bug that caused a terminal error, or retries are skipped locally without ever being attempted. |
| `:IsReady()` | boolean | Open Cloud package resolved (or DryRun is on). |
| `:GetQueueSize()` | number | Queued + waiting-on-backoff. |
| `:FlushRegistry()` | — | **Yields.** Forces staged writes. Runs on a timer and at close anyway. |
| `:RefreshMessages()` | — | Call after mutating `Config.Messages` at runtime. |

### Notification

| Call | Returns | Notes |
| --- | --- | --- |
| `:Send(target, overrides?)` | boolean | Queues; returns instantly. False = unresolvable target or full queue. |
| `:SendAll(targets, overrides?)` | number | Count actually queued. |
| `:SendIn(seconds, target, overrides?)` | boolean | Cross-server durable. |
| `:SendAt(unixTime, target, overrides?)` | boolean | Past times fire on the next poll. |
| `:SendAtRandom(min, max, target, overrides?)` | boolean | Uniform inside the window. |
| `:Destroy()` | — | Disconnects its signals. |

`target` can be a userId, a `Player`, or any table carrying `userId` / `UserId`
/ `id` / `player` — so registry entries and your own player-state tables both
work without unwrapping.

`overrides` accepts `params`, `launchData`, `category` and `priority`.

---

## Why opt-in is a guess

**There is no API — Luau or Open Cloud — that lists opted-in users or answers
"is user X opted in?"** The Creator Dashboard shows an aggregate count and no
user list.

The client-side `CanPromptOptInAsync()` returns `false` for three reasons it
does not distinguish: the user is under 13, the user has already opted in, or
the user was prompted within the last 30 days. Re-checking it after prompting
tells you nothing.

And a `200` from a send does not confirm delivery. Documented non-delivery
reasons include: eligibility not met, recipient not opted in, recipient's daily
throttle already used, the cross-experience aggregate throttle, a moderated
string, and — for user mentions — the two users not being friends.

So `GetOptedIn()` returns **plausibly reachable**, not **opted in**. It is built
from two weak signals:

| State | Meaning |
| --- | --- |
| `UNKNOWN` | Never prompted, never sent to. |
| `PROMPTED` | This module showed the opt-in modal and it was closed. |
| `LIKELY_OPTED_IN` | A send to this user returned `200`. |
| `NOT_ELIGIBLE` | A send returned a terminal error. Excluded from `GetOptedIn()`. |

**Measure before you trust it.** `Config.Diagnostics = true` (the default) logs
the raw `statusCode` and `error.code` of the first `DiagnosticsSampleCount`
sends at warn level, bypassing the log level. Run a real wave, read the sample,
then decide how much weight the registry deserves in your universe.

---

## Testing without burning quota

```lua
Config.DryRun = true
```

No API calls are made. `Transport` returns simulated results using
`Config.DryRunOutcomes` (85% 200, 7% 429, 4% 500, 4% 400 by default), so the
queue, token bucket, retry/backoff, dedupe, registry and scheduler all exercise
end to end.

Caveats when testing in Studio:

- The Creator Store package's behaviour in Studio can differ from a live server.
- DataStore and MemoryStore need **Studio Access to API Services** enabled.
- MemoryStore needs a published place. Without it, dedupe and the scheduler
  degrade — dedupe fails **open** (a duplicate attempt costs one wasted API
  call, whereas failing closed would silently drop real sends), and scheduling
  is unavailable.
- The 100-visit eligibility gate applies to real sends regardless of Studio.

---

## Troubleshooting

| Status | Code | What it actually means | Retried? |
| --- | --- | --- | --- |
| 400 | `INVALID_ARGUMENT` | **Read `errorMessage` — this code has several causes.** *"Missing parameter X to replace the placeholders in content"* means your string has a `{X}` placeholder with no matching `params` entry. Otherwise: a bad `messageId`, or one authored in a different experience. | No |
| 403 | `PERMISSION_DENIED` | **Usually the 100-visit gate**, or active moderation, or you lack manage permission. | No |
| 404 | `NOT_FOUND` | `messageId` or universe not found — the string may have been deleted. | No |
| 409 | `ABORTED` | Conflicting operation. | Once |
| 429 | `RESOURCE_EXHAUSTED` | Out of quota. Lower `Config.SendsPerMinute`. | Yes |
| 499 | `CANCELLED` | Client-side timeout. | Yes |
| 500 | `INTERNAL` | Roblox internal error. | Yes |
| 501 | `NOT_IMPLEMENTED` | Method not implemented. | No |
| 503 | `UNAVAILABLE` | Service down. | Yes |
| 0 | `PACKAGE_MISSING` | Open Cloud package not in `ServerScriptService`. | No |
| 0 | `LUAU_ERROR` | The call threw — network or instance problem. | Yes |

Non-API drops, visible in `GetStats()`:

| Code | Meaning |
| --- | --- |
| `DUPLICATE` | Another server already claimed this user's slot today. Working as intended. |
| `NEGATIVE_CACHE` | This user returned a terminal error recently; skipped without an API call. |
| `QUEUE_FULL` | Queue hit `Config.MaxQueueSize`. |

**Sends succeed but nobody sees anything.** Expected if the recipients never
opted in. Check the Dashboard's Opted-in Users count — and note that Dashboard
analytics need **100 impressions** before statistics display at all.

---

## Limits worth knowing

| Limit | Value |
| --- | --- |
| Notification string length | 99 characters |
| `launchData` | 200 bytes |
| Per user, per experience | 1 notification per day |
| Cross-experience | An aggregate daily throttle also applies, invisible to you |
| Notification type | `MOMENT` only |
| MemoryStore request units | `1000 + 120 × CCU` per minute |
| Analytics custom fields | 8,000 unique combinations per experience |
| Scheduling horizon | 45 days (MemoryStore TTL cap) |

Notifications must be personalised and based on the receiver's own in-experience
activity. Disguised ads, false time pressure, bait-and-switch rewards and
manipulative purchase tricks are explicitly prohibited and moderated.

---

## Configuration

Everything lives in `src/Config.luau`, grouped and commented. The only section
you must fill in is `Messages`.

Frequently changed:

| Key | Default | Purpose |
| --- | --- | --- |
| `DryRun` | `false` | Simulate everything; no API calls. |
| `Diagnostics` | `true` | Log raw results for the first N sends. |
| `LogLevel` | `"info"` | `error` / `warn` / `info` / `debug`. |
| `SendsPerMinute` | `60` | Token-bucket rate. No per-minute ceiling is documented, so this is deliberately conservative. |
| `MaxAttempts` | `5` | Retry attempts for retryable errors. |
| `AutoPromptOptIn` | `true` | Prompt joining players automatically. |
| `PromptDelaySeconds` | `60` | Delay before the automatic prompt. |
| `EnableScheduler` | `true` | `SendIn` / `SendAt` / `SendAtRandom`. |
| `RegistryShards` | `16` | DataStore shards. **Changing this after launch orphans existing entries.** |

---

## Layout

```
src/
├── init.luau                    Public API; bootstraps the client half
├── Config.luau                  USER-EDITED: messageId registry + tuning
├── Types.luau                   Shared type definitions
├── Notification.luau            The object returned by :New()
├── Dispatcher.luau              Token-bucket queue, retry state machine
├── Transport.luau               Open Cloud wrapper, result normalisation, DryRun
├── Coordinator.luau             MemoryStore claim locks + negative cache
├── Scheduler.luau               SortedMap of due sends + DataStore mirror
├── Registry.luau                Opt-in confidence registry (sharded DataStore)
├── Analytics.luau               Category, AnalyticsService, runtime stats
├── Signal.luau                  Minimal pure-Luau signal
├── Util.luau                    Target/message resolution, payload coercion
└── Client/
    └── OptInPrompt.client.luau  Auto-installed into StarterPlayerScripts
```

---

## How this was built

Built with AI tooling under the author's direction. Treat it like any dependency:
read the source, run it in `DryRun` first, and use `test/RealSendTest.server.luau`
against a place that clears the eligibility gate before you rely on it.

## Credits

- Sending goes through the **Open Cloud** package by Roblox (Creator Store), which
  is not bundled here and keeps its own licence.

## License

[MIT](LICENSE).
