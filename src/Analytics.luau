--!nonstrict
--[[
	Analytics — runtime counters plus AnalyticsService telemetry.

	THE OFFLINE PROBLEM
	-------------------
	AnalyticsService:LogCustomEvent requires a live Player instance
	(RESEARCH.md §9). The primary use case for experience notifications is
	re-engaging users who are NOT in the experience, so most sends cannot be
	logged through it at all. Those fall through to the counters below and the
	structured log.

	Dashboard-side grouping is handled elsewhere: Notification stamps
	analyticsData.category onto every payload, which is what splits rows in the
	Creator Dashboard's itemised table.
]]

local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")

local Config = require(script.Parent.Config)
local Log = require(script.Parent.Log)

local Analytics = {}

local EVENT_NAME = "bns_notification"

local stats = {
	enqueued = 0,
	attempts = 0,
	sent = 0,
	failed = 0,
	retried = 0,
	droppedDuplicate = 0,
	droppedNotEligible = 0,
	droppedQueueFull = 0,
	onlineLogged = 0,
	offlineUnlogged = 0,
	byErrorCode = {},
	byStatusCode = {},
}

--[[ Custom fields ---------------------------------------------------------]]

-- LogCustomEvent only accepts the three predefined custom-field keys. Resolved
-- defensively so an engine change can't take the whole module down.
local CUSTOM_FIELDS = nil
do
	local ok, keys = pcall(function()
		return {
			Enum.AnalyticsCustomFieldKeys.CustomField01.Name,
			Enum.AnalyticsCustomFieldKeys.CustomField02.Name,
			Enum.AnalyticsCustomFieldKeys.CustomField03.Name,
		}
	end)
	if ok then
		CUSTOM_FIELDS = keys
	else
		Log.debug("analytics.custom_fields_unavailable")
	end
end

--[=[
	Cardinality budget: the cap is 8,000 unique custom-field-value combinations
	per experience (RESEARCH.md §9). This uses alias x outcome x statusCode,
	so it stays under with up to ~80 distinct message aliases.
]=]
local function customFields(alias: string, outcome: string, statusCode: number?)
	if not CUSTOM_FIELDS then
		return nil
	end
	return {
		[CUSTOM_FIELDS[1]] = alias,
		[CUSTOM_FIELDS[2]] = outcome,
		[CUSTOM_FIELDS[3]] = tostring(statusCode or 0),
	}
end

local function logCustomEvent(userId: number, alias: string, outcome: string, statusCode: number?)
	if not Config.EnableAnalytics then
		return
	end

	local player = Players:GetPlayerByUserId(userId)
	if not player then
		-- Offline recipient: no Player instance, so no LogCustomEvent.
		stats.offlineUnlogged += 1
		return
	end

	local ok, err = pcall(function()
		AnalyticsService:LogCustomEvent(player, EVENT_NAME, 1, customFields(alias, outcome, statusCode))
	end)

	if ok then
		stats.onlineLogged += 1
	else
		Log.debug("analytics.log_failed", { userId = userId, reason = tostring(err) })
	end
end

--[[ Counters --------------------------------------------------------------]]

local function bump(bucket, key)
	if key == nil then
		return
	end
	bucket[key] = (bucket[key] or 0) + 1
end

--[=[
	Dispatcher observer. See Dispatcher.addObserver for the event list.
]=]
function Analytics.observe(event: string, item, result)
	local alias = (item and item.alias) or "?"

	if event == "enqueued" then
		stats.enqueued += 1
	elseif event == "attempt" then
		stats.attempts += 1
	elseif event == "sent" then
		stats.sent += 1
		bump(stats.byStatusCode, result and result.statusCode)
		logCustomEvent(item.userId, alias, "sent", result and result.statusCode)
	elseif event == "retry" then
		stats.retried += 1
		bump(stats.byStatusCode, result and result.statusCode)
		bump(stats.byErrorCode, result and result.errorCode)
	elseif event == "failed" then
		stats.failed += 1
		bump(stats.byStatusCode, result and result.statusCode)
		bump(stats.byErrorCode, result and result.errorCode)
		logCustomEvent(item.userId, alias, "failed", result and result.statusCode)
	elseif event == "dropped_duplicate" then
		stats.droppedDuplicate += 1
	elseif event == "dropped_not_eligible" then
		stats.droppedNotEligible += 1
	elseif event == "dropped_queue_full" then
		stats.droppedQueueFull += 1
	end
end

--[=[
	Snapshot of live counters. Safe to mutate — it's a copy.
]=]
function Analytics.getStats()
	local snapshot = table.clone(stats)
	snapshot.byErrorCode = table.clone(stats.byErrorCode)
	snapshot.byStatusCode = table.clone(stats.byStatusCode)
	return snapshot
end

function Analytics.reset()
	for key, value in stats do
		if type(value) == "number" then
			stats[key] = 0
		end
	end
	table.clear(stats.byErrorCode)
	table.clear(stats.byStatusCode)
end

return Analytics
