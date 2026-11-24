# Research — Roblox Experience Notifications

Compiled 2026-08-13. Everything below is sourced from official Roblox documentation or
Developer Forum threads; links are listed at the bottom. Where a claim is inferred rather
than documented, it is marked **[inference]**.

---

## 1. What Experience Notifications are

Out-of-experience push notifications delivered to a user's Roblox notification stream.
Their purpose is **re-engagement** — pulling back users who are *not currently in your
experience*. They are:

- Available only to users **age 13+**.
- Available only to users who have **opted in** to notifications for your experience
  (via the bell/"Notify" icon on the Experience Details Page, or via an in-experience
  opt-in prompt).
- Subject to moderation and text filtering regardless of the experience's age rating.

---

## 2. The send API (server-side Luau)

This is **not a built-in engine service**. It is the **Open Cloud package** installed from
the Creator Store into `ServerScriptService`. Internally it wraps the Open Cloud v2 REST
endpoint (the engine class `OpenCloudApiV1` / `CreateUserNotificationAsync` exists but is
marked **deprecated** — do not call it directly).

### Signature

```
createUserNotification(userId: number, userNotification: UserNotification): UserNotificationResult
```

### Canonical example (verbatim from docs)

```lua
local ServerScriptService = game:GetService("ServerScriptService")

local OCUserNotification = require(ServerScriptService.OpenCloud.V2.UserNotification)
local recipientPlayerID = 505306092

-- In the payload, "messageId" is the value of the notification asset ID
local userNotification = {
	payload = {
		messageId = "5dd7024b-68e3-ac4d-8232-4217f86ca244",
		type = "MOMENT"
	}
}

local result = OCUserNotification.createUserNotification(recipientPlayerID, userNotification)

if result.statusCode ~= 200 then
	print(result.statusCode)
	print(result.error.code)
	print(result.error.message)
end
```

### With parameters (verbatim from docs)

```lua
local userIdFriendParam = {int64Value = 3702832553}
local pointsParam = {stringValue = "5"}

-- notification string: "{userId-friend} beat your high score by {points} points! Time to level up?"
local userNotification = {
	payload = {
		messageId = "ef0e0790-e2e8-4441-9a32-93f3a5783bf1",
		type = "MOMENT",
		parameters = {
			["userId-friend"] = userIdFriendParam,
			["points"] = pointsParam
		}
	}
}
```

### With launch data + analytics data (verbatim from docs)

```lua
local userNotification = {
	payload = {
		messageId = "5dd7024b-68e3-ac4d-8232-4217f86ca244",
		type = "MOMENT",
		joinExperience = {
			launchData = "Test_Launch_Data"
		},
		analyticsData = {
			category = "Test_Analytics_Category"
		}
	}
}
```

### `UserNotification` payload table

| Key | Type | Required | Purpose |
| --- | --- | --- | --- |
| `messageId` | string | yes | Asset ID (UUID) of the notification string created in the Creator Dashboard |
| `type` | string | yes | Only `"MOMENT"` is currently supported |
| `parameters` | table | no | Fills `{placeholder}` slots in the notification string |
| `joinExperience` | table | no | `{ launchData = string }`, **max 200 bytes**, read via `Player:GetJoinData()` |
| `analyticsData` | table | no | `{ category = string }`, groups rows in the Creator Dashboard analytics |

Parameter values are typed wrappers: `{int64Value = <number>}` or `{stringValue = <string>}`.

### `UserNotificationResult`

| Key | Type | Contents |
| --- | --- | --- |
| `statusCode` | number | HTTP status; `200` = accepted |
| `error` | table | `{ code = <GRPC code string>, message = <string> }` |
| `response` | table | `{ id = <UUID>, path = "users/{userId}/notifications/{id}" }` |

**Important:** the function *returns* a non-200 result rather than throwing for API-level
errors, but the call yields and can still throw at the Luau level (network/instance
issues). Always wrap in `pcall` **and** check `statusCode`. **[inference — docs show only
the statusCode check, but the call performs network I/O]**

---

## 3. Opt-in prompt API (client-side)

`ExperienceNotificationService` — `NotCreatable`, `NotReplicated`.

| Member | Signature | Notes |
| --- | --- | --- |
| `CanPromptOptInAsync()` | `(): boolean` | **Yields.** LocalScript / client-context only. Must be pcall'd. |
| `PromptOptIn()` | `(): ()` | Shows the in-experience modal. Text is standardized and cannot be customized. Only call after `CanPromptOptInAsync()` returns true. |
| `OptInPromptClosed` | Event | Fires when the local player closes a prompt shown via `PromptOptIn()`. |

### Canonical example (verbatim from docs)

```lua
local ExperienceNotificationService = game:GetService("ExperienceNotificationService")

-- Function to check whether the player can be prompted to enable notifications
local function canPromptOptIn()
	local success, canPrompt = pcall(function()
		return ExperienceNotificationService:CanPromptOptInAsync()
	end)
	return success and canPrompt
end

local canPrompt = canPromptOptIn()
if canPrompt then
	local success, errorMessage = pcall(function()
		ExperienceNotificationService:PromptOptIn()
	end)
end

-- Listen to opt-in prompt closed event
ExperienceNotificationService.OptInPromptClosed:Connect(function()
	print("Opt-in prompt closed")
end)
```

### The ambiguity problem

`CanPromptOptInAsync()` returns `false` for **three different reasons**, which it does not
distinguish:

1. The user is under 13.
2. The user has **already opted in**.
3. The user was shown the prompt **within the last 30 days**.

Consequence: after you prompt someone, re-checking `CanPromptOptInAsync()` tells you
nothing useful — it returns `false` either way, because of rule 3.

---

## 4. Notification strings (Creator Dashboard)

- **No API exists to create notification strings.** They must be authored in the Creator
  Dashboard: *your experience → Engagement → Notifications → Create a Notification String*.
- **Limited to 99 characters.** Unlimited custom parameters.
- The experience title is used automatically as the notification **header**; `{experienceName}`
  can be used inside the **body**.
- `{userId-<name>}` placeholders render a user mention (see delivery rules in §6).
- Copy the asset ID via the row's **⋯ → Copy Asset ID**; that UUID is your `messageId`.
- Strings are **moderated**; a moderated string will not deliver.

Documented example strings:

- `"You're {numQuests} quests away from completing the weekly challenge!"`
- `"{userId-friend} just beat your record on the Tokyo Tour track! Time for revenge?"`

---

## 5. Eligibility requirements

Your experience must satisfy **all three**:

1. **Minimum 100 visits since launch.**
2. Not currently under moderation.
3. You (the developer) must have permission to manage the experience.

---

## 6. Rate limits, throttling, and delivery

### Documented limits

- **1 notification per user per experience per day.** (Relaxed in an announcement from the
  previous 1-per-3-days limit; the change was effective immediately and the confusing
  "every 3 days" error text was fixed.)
- An **aggregate cross-experience daily throttle** exists — a user who has received many
  notifications from other experiences may not receive yours.
- **Engagement-based suppression:** delivery reach correlates with user engagement. Roblox
  has stated it monitors total notification volume per user and may introduce bundling.
- Users receive "transparent feedback when a user's throttle limit is reached."

### Delivery is NOT guaranteed by a 200

The docs explicitly warn that a successful API response does not guarantee delivery.
Documented non-delivery reasons:

- Experience eligibility criteria not met (§5).
- Recipient has not opted in.
- Recipient's per-experience daily throttle (1/day) already used.
- Recipient's aggregate cross-experience daily limit exceeded.
- The notification string was moderated.
- Invalid request parameters.
- For user-mention notifications: the receiver and the mentioned user **are not friends**,
  or the mentioned user disabled the activity-sharing/activity-update setting in their
  account privacy controls.

**Design consequence:** you cannot reliably infer opt-in status from a `200`. See §8.

### No documented per-server / per-minute API call limit

Neither the docs nor the forum threads state a calls-per-minute ceiling for
`createUserNotification`. Assume one exists and self-limit. **[inference]**

---

## 7. Error codes (Open Cloud v2)

| Code | HTTP | Meaning | Retry? |
| --- | --- | --- | --- |
| `INVALID_ARGUMENT` | 400 | Invalid argument, e.g. bad `universeId` or `messageId` | **No** — config bug |
| `PERMISSION_DENIED` | 403 | Insufficient permissions or scopes | **No** — config/eligibility bug |
| `NOT_FOUND` | 404 | Specified resource not found | **No** — config bug |
| `ABORTED` | 409 | Operation aborted (conflict) | Conditional |
| `RESOURCE_EXHAUSTED` | 429 | Out of quota / too many requests | **Yes** — backoff |
| `CANCELLED` | 499 | Terminated, typically client-side timeout | **Yes** |
| `INTERNAL` | 500 | Internal server error / server bug | **Yes** |
| `NOT_IMPLEMENTED` | 501 | Method not implemented | **No** |
| `UNAVAILABLE` | 503 | Service down | **Yes** |

(Open Cloud v1 additionally defines `403 INSUFFICIENT_SCOPE`.)

---

## 8. THE central constraint: you cannot enumerate or query opted-in users

There is **no API** — Luau or Open Cloud — that:

- returns the list of users opted in to your experience, **or**
- answers "is user X opted in?" from the server.

`CanPromptOptInAsync()` is client-only and ambiguous (§3). The Creator Dashboard shows an
aggregate "Opted-in Users" count but no user list.

### What developers actually do (from forum threads)

- **Manual DataStore tracking** — build a custom opt-in UI, record who opted in yourself.
  Devs describe this as reimplementing what the platform should provide.
- **Brute-force send** — loop the entire DataStore of known players and send to everyone,
  eating failures for non-opted-in users.
- **Sharded scanning** — distribute the scan across live servers, each taking a userId
  prefix range. Only viable with enough concurrent servers.
- **Send-on-leave snapshotting** — write player state to an OrderedDataStore when they
  leave, so batch sends don't need per-player lookups.

Reported pain points: no event fires when a player enables notifications; checking
`CanPromptOptIn` costs an extra round trip; DataStore Open Cloud reads are capped at
**300 requests/minute/universe**, so scanning 100,000 entries takes roughly 5.5 hours.
One dev reported dashboard analytics showing 1 opted-in user against 10 self-tracked
DataStore entries — i.e. self-tracking over-counts.

### Consequence for this project

Any "opted-in users" list is a **confidence model**, not ground truth. Because a `200`
does not confirm delivery (§6), send-and-learn classification is unproven for this
specific signal. Mitigation: ship a diagnostics mode that logs raw `statusCode` /
`error.code` for the first N sends so the real behaviour of a given universe can be
measured, then tighten the classifier from evidence.

---

## 9. Analytics

### Creator Dashboard (built in)

Metrics available: **Opted-in Users**, **Impressions**, **Clicks**, **CTR**,
**Turn-off rate**, **Dismiss rate**. Requires a minimum of **100 impressions** before
statistics display. An itemized per-notification table is ordered by first impression date.
`analyticsData.category` is what groups rows here.

### `AnalyticsService` (in-experience, for our own telemetry)

| Method | Signature | Constraints |
| --- | --- | --- |
| `LogCustomEvent` | `(player: Player, eventName: string, value?: double, customFields?: Dictionary)` | **8,000 unique custom-field-value combinations per experience** |
| `LogEconomyEvent` | `(player, flowType, currencyType, amount, endingBalance, transactionType, itemSku, customFields?)` | 5 currency types, 20 transaction types, 100 SKUs |
| `LogFunnelStepEvent` | `(player, funnelName, funnelSessionId, step?, stepName, customFields?)` | 10 funnels, steps 1–100, repeats ignored |
| `GetPlayerSegmentsAsync` | `(player): Dictionary` | Server-only, yields, cached per player |

**Critical limitation:** `LogCustomEvent` requires a live `Player` instance. Notifications
sent to **offline** userIds — the primary use case — cannot be logged through it. Offline
sends must fall back to an internal counter table plus structured logs.

---

## 10. Cross-server coordination — MemoryStoreService

The correct tool for preventing every live server from sending to the same user at once.

### Structures

| Structure | Use |
| --- | --- |
| `MemoryStoreHashMap` | Key lookups, distributed locks/claims, negative caching |
| `MemoryStoreSortedMap` | Ordered by sort key — ideal for "sends due at timestamp T" |
| `MemoryStoreQueue` | Sequential processing; **invisibility timeout gives free cross-server retry** — an item not explicitly removed becomes visible to another server again |

### Limits

| Limit | Value |
| --- | --- |
| Request units | `1000 + 120 × [concurrent users]` per minute |
| Memory quota | `64 KB + 1.2 KB × [concurrent users]` per experience |
| Per-structure cap | 1,000,000 items / 100 MB |
| Max item size | 32 KB |
| Default TTL | 45 days (docs recommend the shortest workable TTL) |

Cost notes: most calls cost 1 unit; `GetRangeAsync()` costs per item returned;
`UpdateAsync()` costs a minimum of 2 units.

### Best practices (from docs)

Remove processed items promptly; use the shortest possible expiration; shard large
structures into several smaller ones; use exponential backoff on retries; compress values.

### Durability warning

MemoryStore is **transient**. Forum guidance: it is not a database — anything that must
survive a data expiry or platform restart needs a DataStore mirror plus a recovery path.

### Applicable patterns

- **Per-user daily claim lock:** `HashMap:UpdateAsync("bns:<userId>:<utcDay>", …)` as a
  compare-and-set, TTL to end of UTC day. Costs 2 request units. First server to claim
  wins; all others drop. This mirrors Roblox's own 1/day throttle exactly.
- **Scheduled / randomly-timed sends:** `SortedMap` with sort key = unix timestamp; each
  server polls on a jittered interval, `GetRangeAsync` for due entries, claims each with
  the lock above, dispatches, then removes.
- **Fail-open reasoning:** because Roblox independently enforces 1/user/day, a lock
  failure that lets a duplicate attempt through costs one wasted API call. Failing
  *closed* would silently drop real notifications. Fail open, and log. **[inference]**

---

## 11. Open Cloud REST alternative (external / out-of-game sending)

```
POST https://apis.roblox.com/cloud/v2/users/{userId}/notifications
Headers: x-api-key: ${ApiKey}
         Content-Type: application/json
```

```json
{
  "source":  { "universe": "universes/${UniverseID}" },
  "payload": {
    "message_id": "${AssetID}",
    "type": "MOMENT",
    "parameters": { "parameterName": { "string_value": "value" } }
  },
  "join_experience": { "launch_data": "string" },
  "analytics_data":  { "category": "string" }
}
```

Response:

```json
{ "path": "users/{userId}/notifications/{NotificationID}", "id": "{NotificationID}" }
```

Required: `source.universe`, `payload.message_id`, `payload.type`.
Auth: API key or OAuth 2.0. Note the REST field names are **snake_case** while the Luau
package uses **camelCase**.

---

## 12. Usage guidelines (moderation-relevant)

Notifications must be personalized to the receiver and based on in-experience activity
specifically relevant to them — **not generic advertising**. Explicitly prohibited:

- Disguised advertisements
- False time pressure
- Bait-and-switch rewards
- Manipulative purchase tricks

Content is subject to Community Standards and text filtering regardless of the
experience's age rating.

---

## Sources

- [Experience notifications — Creator Docs](https://create.roblox.com/docs/production/promotion/experience-notifications)
- [creator-docs source: experience-notifications.md](https://github.com/Roblox/creator-docs/blob/main/content/en-us/production/promotion/experience-notifications.md)
- [creator-docs includes: delivery-system.md, eligibility.md, implementation-create-notification-string.md](https://github.com/Roblox/creator-docs/tree/main/content/en-us/includes/experience-notifications)
- [Open Cloud guide: experience-notifications.md](https://github.com/Roblox/creator-docs/blob/main/content/en-us/cloud/guides/experience-notifications.md)
- [Open Cloud error codes](https://github.com/Roblox/creator-docs/blob/main/content/en-us/cloud/reference/errors.md)
- [ExperienceNotificationService reference](https://create.roblox.com/docs/reference/engine/classes/ExperienceNotificationService)
- [OpenCloudApiV1 reference (deprecated)](https://create.roblox.com/docs/reference/engine/classes/OpenCloudApiV1)
- [AnalyticsService reference](https://create.roblox.com/docs/reference/engine/classes/AnalyticsService)
- [Memory stores — Creator Docs](https://create.roblox.com/docs/cloud-services/memory-stores)
- [DevForum: Updates to Notification Rate Limits](https://devforum.roblox.com/t/updates-to-notification-rate-limits/3007106)
- [DevForum: Introducing Experience Notifications](https://devforum.roblox.com/t/introducing-experience-notifications/2826474)
- [DevForum: Introducing In-Experience Notification Permission Prompts](https://devforum.roblox.com/t/introducing-in-experience-notification-permission-prompts/2909125)
- [DevForum: Experience Notification are so inefficient](https://devforum.roblox.com/t/experience-notification-are-so-inefficient/3613054)
- [DevForum: Experience Notifications and Rate Limits](https://devforum.roblox.com/t/experience-notifications-and-rate-limits/4615621)
