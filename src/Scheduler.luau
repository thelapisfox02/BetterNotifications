--!nonstrict
--[[
	Scheduler — durable, cross-server future sends.

	A MemoryStore SortedMap keyed by unix due-time. Every live server polls on a
	jittered interval, takes the earliest page, and claims each due entry before
	dispatching, so exactly one server delivers it.

	Entry keys are deterministic (userId:alias:dueTime), which makes re-inserting
	the same schedule idempotent — that is what lets DataStore rehydration run
	without creating duplicates.

	MemoryStore is transient (RESEARCH.md §10), so schedules further out than
	Config.PersistThresholdSeconds are mirrored into a DataStore and replayed on
	server start.
]]

local MemoryStoreService = game:GetService("MemoryStoreService")
local DataStoreService = game:GetService("DataStoreService")

local Config = require(script.Parent.Config)
local Log = require(script.Parent.Log)
local Coordinator = require(script.Parent.Coordinator)
local Dispatcher = require(script.Parent.Dispatcher)

local Scheduler = {}

local SECONDS_PER_DAY = 86400
local MAX_EXPIRATION = 45 * SECONDS_PER_DAY -- MemoryStore hard cap

local pollRandom = Random.new()

--[[ Handles ---------------------------------------------------------------]]

local sortedMap = nil
local sortedMapFailed = false

local function getMap()
	if sortedMap then
		return sortedMap
	end
	if sortedMapFailed then
		return nil
	end

	local ok, map = pcall(function()
		return MemoryStoreService:GetSortedMap(Config.KeyPrefix .. "_schedule")
	end)

	if not ok or not map then
		sortedMapFailed = true
		Log.warn("scheduler.memorystore_unavailable", {
			reason = tostring(map),
			effect = "SendIn/SendAt/SendAtRandom will not work on this server",
		})
		return nil
	end

	sortedMap = map
	return map
end

local scheduleStore = nil
local scheduleStoreFailed = false

local function getStore()
	if scheduleStore then
		return scheduleStore
	end
	if scheduleStoreFailed or not Config.PersistSchedules then
		return nil
	end

	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(Config.DataStoreName .. "_schedules")
	end)

	if not ok or not store then
		scheduleStoreFailed = true
		Log.warn("scheduler.datastore_unavailable", {
			reason = tostring(store),
			effect = "long-horizon schedules will not survive a MemoryStore flush",
		})
		return nil
	end

	scheduleStore = store
	return store
end

--[[ Keys ------------------------------------------------------------------]]

local function entryKey(entry, at: number): string
	return ("%d:%s:%d"):format(entry.userId, entry.alias, at)
end

local function bucketKey(at: number): string
	return ("bucket:%d"):format(math.floor(at / SECONDS_PER_DAY))
end

--[[ Persistence mirror ----------------------------------------------------]]

local function mirrorToStore(entry, at: number)
	local store = getStore()
	if not store then
		return
	end

	local key = bucketKey(at)
	local id = entryKey(entry, at)

	local ok, err = pcall(function()
		store:UpdateAsync(key, function(existing)
			local bucket = existing or {}
			bucket[id] = {
				userId = entry.userId,
				alias = entry.alias,
				payload = entry.payload,
				priority = entry.priority,
				at = at,
			}
			return bucket
		end)
	end)

	if not ok then
		Log.warn("scheduler.mirror_failed", { key = key, reason = tostring(err) })
	end
end

local function unmirror(entry, at: number)
	local store = getStore()
	if not store then
		return
	end

	local id = entryKey(entry, at)
	pcall(function()
		store:UpdateAsync(bucketKey(at), function(existing)
			if not existing then
				return nil
			end
			existing[id] = nil
			return existing
		end)
	end)
end

--[[ Scheduling ------------------------------------------------------------]]

--[=[
	entry: { userId, alias, payload, priority }
]=]
function Scheduler.schedule(at: number, entry): boolean
	local map = getMap()
	if not map then
		return false
	end

	at = math.floor(at)
	local now = os.time()
	local secondsOut = at - now

	if secondsOut > MAX_EXPIRATION then
		Log.warn("scheduler.too_far_out", {
			userId = entry.userId,
			alias = entry.alias,
			days = secondsOut / SECONDS_PER_DAY,
			maxDays = 45,
		})
		return false
	end

	-- Keep the entry alive well past its due time so a brief gap in live
	-- servers doesn't silently drop it.
	local expiration = math.clamp(math.max(secondsOut, 0) + SECONDS_PER_DAY, 60, MAX_EXPIRATION)
	local key = entryKey(entry, at)

	-- Recorded on the entry itself so the drain knows whether there is anything
	-- to clean up, instead of issuing a DataStore write per short-horizon send.
	local shouldMirror = Config.PersistSchedules and secondsOut > Config.PersistThresholdSeconds

	local ok, err = pcall(function()
		map:SetAsync(key, {
			userId = entry.userId,
			alias = entry.alias,
			payload = entry.payload,
			priority = entry.priority,
			at = at,
			mirrored = shouldMirror or nil,
		}, expiration, at)
	end)

	if not ok then
		Log.warn("scheduler.schedule_failed", {
			userId = entry.userId,
			alias = entry.alias,
			reason = tostring(err),
		})
		return false
	end

	if shouldMirror then
		mirrorToStore(entry, at)
	end

	Log.debug("scheduler.scheduled", {
		userId = entry.userId,
		alias = entry.alias,
		inSeconds = secondsOut,
		key = key,
	})

	Scheduler.start()
	return true
end

--[[ Draining --------------------------------------------------------------]]

local function dispatchEntry(record)
	Dispatcher.enqueue({
		userId = record.userId,
		alias = record.alias,
		payload = record.payload,
		priority = record.priority or 0,
		onComplete = nil,
	})
end

local function drainOnce()
	local map = getMap()
	if not map then
		return
	end

	-- Ascending order means every due entry precedes every future one, so a
	-- single bounded page plus a client-side cutoff is enough — and it avoids
	-- depending on the exact shape of GetRangeAsync's bound arguments.
	local ok, items = pcall(function()
		return map:GetRangeAsync(Enum.SortDirection.Ascending, Config.SchedulerPageSize)
	end)

	if not ok then
		Log.warn("scheduler.range_failed", { reason = tostring(items) })
		return
	end

	if not items or #items == 0 then
		return
	end

	local now = os.time()

	for _, item in items do
		local record = item.value
		local dueAt = tonumber(item.sortKey) or (type(record) == "table" and record.at) or 0

		if dueAt > now then
			-- Ascending: nothing after this is due either.
			break
		end

		if type(record) ~= "table" or not record.userId or not record.payload then
			Log.warn("scheduler.malformed_entry", { key = tostring(item.key) })
			pcall(function()
				map:RemoveAsync(item.key)
			end)
			continue
		end

		-- Short-lived ownership claim so only one server dispatches this entry.
		-- Fails closed; the per-user daily lock backs it up.
		if Coordinator.claimToken("sched:" .. tostring(item.key), 300) then
			pcall(function()
				map:RemoveAsync(item.key)
			end)

			-- Only entries that were actually mirrored have anything to remove.
			if record.mirrored then
				unmirror(record, dueAt)
			end

			Log.debug("scheduler.due", { userId = record.userId, alias = record.alias, lateBy = now - dueAt })
			dispatchEntry(record)
		end
	end
end

--[[ Rehydration -----------------------------------------------------------]]

-- Replays mirrored schedules whose MemoryStore entries may have been lost.
-- Idempotent: deterministic keys mean a re-insert overwrites rather than
-- duplicates.
local function rehydrate()
	local store = getStore()
	if not store then
		return
	end

	local now = os.time()
	local today = math.floor(now / SECONDS_PER_DAY)
	local restored = 0

	-- Yesterday covers entries that came due during a gap in live servers.
	for offset = -1, 1 do
		local key = ("bucket:%d"):format(today + offset)

		local ok, bucket = pcall(function()
			return store:GetAsync(key)
		end)

		if ok and type(bucket) == "table" then
			local stale = {}

			for id, record in bucket do
				if type(record) == "table" and record.at and record.userId then
					-- Anything more than a day overdue is abandoned rather than
					-- delivered wildly late.
					if record.at < now - SECONDS_PER_DAY then
						table.insert(stale, id)
					else
						local map = getMap()
						if map then
							-- It came out of the mirror, so it still has a row
							-- there for the drain to clean up.
							record.mirrored = true
							local wrote = pcall(function()
								map:SetAsync(id, record, math.clamp(record.at - now + SECONDS_PER_DAY, 60, MAX_EXPIRATION), record.at)
							end)
							if wrote then
								restored += 1
							end
						end
					end
				else
					table.insert(stale, id)
				end
			end

			if #stale > 0 then
				pcall(function()
					store:UpdateAsync(key, function(existing)
						if not existing then
							return nil
						end
						for _, id in stale do
							existing[id] = nil
						end
						return existing
					end)
				end)
			end
		end
	end

	if restored > 0 then
		Log.info("scheduler.rehydrated", { restored = restored })
	end
end

--[[ Lifecycle -------------------------------------------------------------]]

local started = false

function Scheduler.start()
	if started or not Config.EnableScheduler then
		return
	end
	started = true

	task.spawn(function()
		if Config.PersistSchedules then
			local ok, err = pcall(rehydrate)
			if not ok then
				Log.warn("scheduler.rehydrate_failed", { reason = tostring(err) })
			end
		end

		while true do
			-- Jittered so N servers don't all poll on the same tick.
			local interval = Config.SchedulerPollSeconds
			task.wait(pollRandom:NextNumber(interval * 0.75, interval * 1.25))

			local ok, err = pcall(drainOnce)
			if not ok then
				Log.warn("scheduler.drain_error", { reason = tostring(err) })
			end
		end
	end)

	Log.debug("scheduler.started", { pollSeconds = Config.SchedulerPollSeconds })
end

return Scheduler
