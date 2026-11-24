--!strict
--[[
	Config — USER-EDITED.

	The only section you MUST fill in is `Messages`. Everything below it has a
	working default.

	Read docs/RESEARCH.md §4 first: notification strings cannot be created from
	code. You author them in the Creator Dashboard
	(your experience -> Engagement -> Notifications -> Create a Notification
	String), then copy the asset ID via the row's "..." -> Copy Asset ID. That
	UUID is the `id` below.
]]

local Config = {}

--[=[
	1. MESSAGES
	-----------
	Maps a short alias you use in code to the Dashboard-authored string.

	`text` is optional but recommended: it lets `:New{ msg = "..." }` accept the
	human-readable sentence as well as the alias, and it is what gets printed in
	the error message when a lookup fails.

	Example:

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

	Notification strings are limited to 99 characters and are moderated.
]=]
export type MessageDef = {
	id: string,
	text: string?,
	category: string?,
}

Config.Messages = {} :: { [string]: MessageDef }

--[=[
	2. SAFETY / DEVELOPMENT
]=]

-- When true, no real API calls are made. Transport returns simulated results
-- using `DryRunOutcomes` below, so the queue, retry, dedupe and scheduler
-- logic can all be exercised in Studio without burning quota or installing the
-- Creator Store package.
Config.DryRun = false

-- Logs the raw statusCode / error.code of the first N sends at `warn` level.
-- A `200` does not prove delivery (RESEARCH.md §6), so this is how you measure
-- what your specific universe actually does before trusting the registry.
Config.Diagnostics = true
Config.DiagnosticsSampleCount = 50

-- "error" | "warn" | "info" | "debug"
Config.LogLevel = "info" :: string

-- Simulated outcome mix for DryRun. Weights are relative, not percentages.
Config.DryRunOutcomes = {
	{ statusCode = 200, weight = 85 },
	{ statusCode = 429, weight = 7 },
	{ statusCode = 500, weight = 4 },
	{ statusCode = 400, weight = 4 },
}

-- Artificial latency range for DryRun sends, in seconds.
Config.DryRunLatency = { min = 0.05, max = 0.25 }

--[=[
	3. RATE LIMITING

	No per-minute API ceiling is documented for createUserNotification
	(RESEARCH.md §6), so the Dispatcher self-limits with a token bucket. The
	default is deliberately conservative.
]=]

Config.SendsPerMinute = 60
Config.BurstSize = 10

-- Ceiling on sends awaiting a response at once. The token bucket is the real
-- limiter; this only stops requests piling up if the API goes slow.
Config.MaxConcurrentSends = 8

-- Hard cap on the in-memory queue. Enqueues past this are dropped and counted
-- in `GetStats().droppedQueueFull`.
Config.MaxQueueSize = 10000

--[=[
	4. RETRIES

	Classification is fixed by the Open Cloud error table (RESEARCH.md §7) and
	lives in Transport; only the timing is tunable here.
]=]

Config.MaxAttempts = 5
Config.RetryBaseSeconds = 1
Config.RetryMaxSeconds = 60
Config.RetryJitter = 0.25

--[=[
	5. CROSS-SERVER COORDINATION (MemoryStore)
]=]

-- Per-user/day claim lock, mirroring Roblox's own 1-per-user-per-day throttle.
-- Lock failures fail OPEN: a duplicate attempt costs one wasted API call,
-- whereas failing closed would silently drop real notifications.
Config.EnableDedupe = true

-- How long a userId that returned a terminal error is skipped without an API
-- call. Set to 0 to disable the negative cache.
Config.NegativeCacheSeconds = 3600

--[=[
	6. OPT-IN REGISTRY
]=]

Config.EnableRegistry = true

-- The registry is sharded across this many DataStore keys so it stays
-- enumerable. Changing this after launch orphans existing entries.
Config.RegistryShards = 16
Config.RegistryFlushSeconds = 30

-- Show the opt-in prompt to joining players automatically.
Config.AutoPromptOptIn = true
Config.PromptDelaySeconds = 60

--[=[
	7. SCHEDULER
]=]

Config.EnableScheduler = true
Config.SchedulerPollSeconds = 15
Config.SchedulerPageSize = 50

-- MemoryStore is transient (RESEARCH.md §10). Schedules further out than
-- `PersistThresholdSeconds` are mirrored to a DataStore and rehydrated on
-- server start.
Config.PersistSchedules = true
Config.PersistThresholdSeconds = 3600

--[=[
	8. ANALYTICS
]=]

Config.EnableAnalytics = true

--[=[
	9. NAMESPACING

	Change `KeyPrefix` only if you run two independent copies of this module in
	one universe.
]=]

Config.KeyPrefix = "bns"
Config.DataStoreName = "BetterNotifications"

-- Hard platform limit on joinExperience.launchData (RESEARCH.md §2).
Config.MaxLaunchDataBytes = 200

return Config
