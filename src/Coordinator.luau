--!nonstrict
--[[
	Coordinator — cross-server MemoryStore state.

	Two jobs:

	  1. Per-user/day claim lock, so every live server doesn't fire the same
	     notification at the same user. Key expires at end of UTC day, which
	     mirrors Roblox's own 1-per-user-per-day throttle (RESEARCH.md §6).

	  2. Negative cache of userIds that returned a terminal error, so repeat
	     attempts are skipped without spending an API call.

	FAIL-OPEN POLICY
	----------------
	Every MemoryStore failure here resolves to "allowed". Roblox independently
	enforces 1/user/day, so a lock that wrongly lets a duplicate through costs
	one wasted API call. Failing closed would silently drop real notifications,
	which is strictly worse. Failures are logged at `warn`.
]]

local MemoryStoreService = game:GetService("MemoryStoreService")

local Config = require(script.Parent.Config)
local Log = require(script.Parent.Log)

local Coordinator = {}

local SECONDS_PER_DAY = 86400

--[[ Map handles -----------------------------------------------------------]]

local maps = {}
local mapFailed = {}

local function getMap(name: string)
	if maps[name] then
		return maps[name]
	end
	if mapFailed[name] then
		return nil
	end

	local ok, map = pcall(function()
		return MemoryStoreService:GetHashMap(name)
	end)

	if not ok or not map then
		mapFailed[name] = true
		Log.warn("coordinator.memorystore_unavailable", {
			map = name,
			reason = tostring(map),
			effect = "dedupe and negative cache disabled for this server",
		})
		return nil
	end

	maps[name] = map
	return map
end

local function claimsMap()
	return getMap(Config.KeyPrefix .. "_claims")
end

local function negativeMap()
	return getMap(Config.KeyPrefix .. "_negative")
end

function Coordinator.isAvailable(): boolean
	return claimsMap() ~= nil
end

--[[ Daily claim lock ------------------------------------------------------]]

-- Returns the UTC day number and the seconds remaining in that day.
local function utcDay(now: number): (number, number)
	local day = math.floor(now / SECONDS_PER_DAY)
	local remaining = SECONDS_PER_DAY - (now % SECONDS_PER_DAY)
	-- MemoryStore rejects a zero expiration; never hand it less than a second.
	return day, math.max(1, math.floor(remaining))
end

local function claimKey(userId: number, day: number): string
	return ("%s:claim:%d:%d"):format(Config.KeyPrefix, userId, day)
end

--[=[
	Attempts to claim today's single send slot for `userId`.

	Returns true if this server won the claim (or if dedupe is off/unavailable,
	per the fail-open policy), false if another server already holds it.

	Costs 2 MemoryStore request units against a `1000 + 120 x CCU` per-minute
	budget (RESEARCH.md §10) — negligible.
]=]
function Coordinator.claimDailySend(userId: number): boolean
	if not Config.EnableDedupe then
		return true
	end

	local map = claimsMap()
	if not map then
		return true
	end

	local now = os.time()
	local day, ttl = utcDay(now)
	local key = claimKey(userId, day)

	local ok, claimed = pcall(function()
		-- Returning nil from the transform aborts the update, so a non-nil
		-- return means we were first.
		local value = map:UpdateAsync(key, function(existing)
			if existing ~= nil then
				return nil
			end
			return now
		end, ttl)
		return value ~= nil
	end)

	if not ok then
		Log.warn("coordinator.claim_error_fail_open", { userId = userId, reason = tostring(claimed) })
		return true
	end

	if not claimed then
		Log.debug("coordinator.claim_lost", { userId = userId })
	end
	return claimed
end

--[=[
	Gives today's slot back after a send that definitively did not deliver, so a
	later attempt (or a config fix) isn't blocked for the rest of the UTC day.
]=]
function Coordinator.releaseDailySend(userId: number)
	if not Config.EnableDedupe then
		return
	end

	local map = claimsMap()
	if not map then
		return
	end

	local day = utcDay(os.time())
	local ok, err = pcall(function()
		map:RemoveAsync(claimKey(userId, day))
	end)

	if not ok then
		Log.warn("coordinator.release_failed", { userId = userId, reason = tostring(err) })
	end
end

--[[ Generic one-shot claim -----------------------------------------------]]

--[=[
	Generic "first server to call this wins" claim, used by the Scheduler to
	take ownership of a due entry.

	Unlike the daily lock this fails CLOSED — returning true on error would let
	every server dispatch the same scheduled entry. The daily lock is still
	behind it as a second line of defence.
]=]
function Coordinator.claimToken(token: string, ttlSeconds: number): boolean
	local map = claimsMap()
	if not map then
		return false
	end

	local key = ("%s:token:%s"):format(Config.KeyPrefix, token)

	local ok, claimed = pcall(function()
		local value = map:UpdateAsync(key, function(existing)
			if existing ~= nil then
				return nil
			end
			return 1
		end, math.max(1, math.floor(ttlSeconds)))
		return value ~= nil
	end)

	if not ok then
		Log.warn("coordinator.token_error", { token = token, reason = tostring(claimed) })
		return false
	end

	return claimed
end

--[[ Negative cache --------------------------------------------------------]]

-- Per-server mirror, so a hot userId costs no request units at all.
local localNegative: { [number]: number } = {}

local function negativeKey(userId: number): string
	return ("%s:neg:%d"):format(Config.KeyPrefix, userId)
end

function Coordinator.isNotEligible(userId: number): boolean
	if Config.NegativeCacheSeconds <= 0 then
		return false
	end

	local now = os.time()
	local expiresAt = localNegative[userId]
	if expiresAt then
		if expiresAt > now then
			return true
		end
		localNegative[userId] = nil
	end

	local map = negativeMap()
	if not map then
		return false
	end

	local ok, value = pcall(function()
		return map:GetAsync(negativeKey(userId))
	end)

	if not ok then
		Log.warn("coordinator.negative_read_failed", { userId = userId, reason = tostring(value) })
		return false
	end

	if value == nil then
		return false
	end

	-- Mirror locally for the remainder of the window.
	localNegative[userId] = now + Config.NegativeCacheSeconds
	return true
end

function Coordinator.markNotEligible(userId: number, errorCode: string?)
	if Config.NegativeCacheSeconds <= 0 then
		return
	end

	localNegative[userId] = os.time() + Config.NegativeCacheSeconds

	local map = negativeMap()
	if not map then
		return
	end

	local ok, err = pcall(function()
		map:SetAsync(negativeKey(userId), errorCode or "TERMINAL", Config.NegativeCacheSeconds)
	end)

	if not ok then
		Log.warn("coordinator.negative_write_failed", { userId = userId, reason = tostring(err) })
	end
end

function Coordinator.clearNotEligible(userId: number)
	localNegative[userId] = nil

	local map = negativeMap()
	if not map then
		return
	end

	pcall(function()
		map:RemoveAsync(negativeKey(userId))
	end)
end

return Coordinator
