--!nonstrict
--[[
	Registry — the opt-in confidence model.

	READ THIS BEFORE TRUSTING IT
	----------------------------
	There is no API that lists opted-in users or answers "is user X opted in?"
	(RESEARCH.md §8), and a 200 from a send does not prove delivery
	(RESEARCH.md §6). So this is an inference built from two weak signals:

	  * the client reported that the opt-in modal was shown and closed;
	  * a send to that userId came back 200 (or came back terminal).

	Neither is ground truth. `GetOptedIn()` returns "plausibly reachable", not
	"opted in". Run with Config.Diagnostics on for a while and read the sampled
	statusCodes before tuning anything against it.

	STORAGE
	-------
	Sharded across Config.RegistryShards DataStore keys so the set stays
	enumerable. Writes are accumulated as per-user deltas and merged inside
	UpdateAsync, so two servers writing the same shard don't clobber each other.
]]

local DataStoreService = game:GetService("DataStoreService")

local Config = require(script.Parent.Config)
local Log = require(script.Parent.Log)

local Registry = {}

local STATE_UNKNOWN = "UNKNOWN"
local STATE_PROMPTED = "PROMPTED"
local STATE_LIKELY = "LIKELY_OPTED_IN"
local STATE_NOT_ELIGIBLE = "NOT_ELIGIBLE"

Registry.States = {
	Unknown = STATE_UNKNOWN,
	Prompted = STATE_PROMPTED,
	LikelyOptedIn = STATE_LIKELY,
	NotEligible = STATE_NOT_ELIGIBLE,
}

-- How much a state is worth keeping when two servers disagree. A confirmed
-- send outranks a prompt; a terminal failure outranks both.
local STATE_RANK = {
	[STATE_UNKNOWN] = 0,
	[STATE_PROMPTED] = 1,
	[STATE_LIKELY] = 2,
	[STATE_NOT_ELIGIBLE] = 3,
}

--[[ Store -----------------------------------------------------------------]]

local store = nil
local storeFailed = false

local function getStore()
	if store then
		return store
	end
	if storeFailed or not Config.EnableRegistry then
		return nil
	end

	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(Config.DataStoreName .. "_registry")
	end)

	if not ok or not result then
		storeFailed = true
		Log.warn("registry.datastore_unavailable", {
			reason = tostring(result),
			effect = "opt-in registry disabled on this server",
		})
		return nil
	end

	store = result
	return store
end

local function shardFor(userId: number): number
	return userId % Config.RegistryShards
end

local function shardKey(shard: number): string
	return ("shard:%d"):format(shard)
end

--[[ State -----------------------------------------------------------------]]

-- Loaded shard contents: cache[shard][userIdString] = record
local cache = {}
local cacheLoadedAt = {}

-- Unflushed local changes: pending[shard][userIdString] = record
local pending = {}
local pendingCount = {}

local CACHE_TTL = 60

-- Flush failure handling. Without backoff, a DataStore outage means all shards
-- retry every RegistryFlushSeconds forever, each emitting a warning — enough
-- output to drown everything else — while `pending` grows without limit.
local FLUSH_BACKOFF_BASE = 30
local FLUSH_BACKOFF_MAX = 600
local MAX_PENDING_PER_SHARD = 5000

local shardFailures = {}
local shardRetryAt = {}
local degraded = false
local droppedStages = 0

-- Records are stored with short field names; a shard holding tens of thousands
-- of users is close enough to the 4MB value cap to be worth the ugliness.
local function toEntry(userId: number, record)
	return {
		userId = userId,
		state = record.s or STATE_UNKNOWN,
		promptedAt = record.p,
		lastAttemptAt = record.a,
		lastOkAt = record.o,
		lastErrorCode = record.e,
	}
end

local function mergeRecord(existing, incoming)
	if not existing then
		return incoming
	end

	local merged = {
		s = existing.s,
		p = existing.p or incoming.p,
		a = math.max(existing.a or 0, incoming.a or 0),
		o = math.max(existing.o or 0, incoming.o or 0),
		e = incoming.e or existing.e,
	}

	if merged.a == 0 then
		merged.a = nil
	end
	if merged.o == 0 then
		merged.o = nil
	end

	-- Newer information about the same user wins only if it is at least as
	-- strong a signal, EXCEPT that a fresh success clears a stale failure.
	local existingRank = STATE_RANK[existing.s] or 0
	local incomingRank = STATE_RANK[incoming.s] or 0

	if incoming.s == STATE_LIKELY and (incoming.o or 0) >= (existing.o or 0) then
		merged.s = STATE_LIKELY
		merged.e = incoming.e
	elseif incomingRank >= existingRank then
		merged.s = incoming.s
	end

	return merged
end

local function stage(userId: number, record)
	if not Config.EnableRegistry then
		return
	end

	local shard = shardFor(userId)
	local id = tostring(userId)

	local bucket = pending[shard]
	if not bucket then
		bucket = {}
		pending[shard] = bucket
		pendingCount[shard] = 0
	end

	if bucket[id] == nil then
		-- Bound the backlog during a prolonged DataStore outage. Users already
		-- staged keep accumulating updates; brand-new ones are dropped rather
		-- than growing this table until the server runs out of memory.
		if (pendingCount[shard] or 0) >= MAX_PENDING_PER_SHARD then
			droppedStages += 1
			return
		end
		pendingCount[shard] = (pendingCount[shard] or 0) + 1
	end

	bucket[id] = mergeRecord(bucket[id], record)

	-- Reflect immediately in the local view so a read-after-write in the same
	-- server sees it without waiting for the flush.
	if cache[shard] then
		cache[shard][id] = mergeRecord(cache[shard][id], record)
	end
end

--[[ Public writes ---------------------------------------------------------]]

function Registry.markPrompted(userId: number)
	stage(userId, { s = STATE_PROMPTED, p = os.time() })
	Log.debug("registry.prompted", { userId = userId })
end

--[=[
	Folds a send outcome into the registry.

	A 200 is recorded as LIKELY_OPTED_IN — "likely" is doing real work in that
	name, see the header.
]=]
function Registry.recordResult(userId: number, result)
	local now = os.time()

	if result.ok then
		stage(userId, { s = STATE_LIKELY, a = now, o = now })
	elseif result.terminal then
		stage(userId, { s = STATE_NOT_ELIGIBLE, a = now, e = result.errorCode })
	else
		-- Transient failure says nothing about the user; record the attempt only.
		stage(userId, { s = STATE_UNKNOWN, a = now })
	end
end

--[[ Flushing --------------------------------------------------------------]]

local function flushShard(shard: number): boolean
	local changes = pending[shard]
	if not changes or next(changes) == nil then
		return true
	end

	-- Still cooling off from a previous failure.
	local retryAt = shardRetryAt[shard]
	if retryAt and os.clock() < retryAt then
		return false
	end

	local dataStore = getStore()
	if not dataStore then
		return false
	end

	-- Detach before the write so concurrent stages during the yield land in the
	-- next batch instead of being lost.
	pending[shard] = nil
	pendingCount[shard] = 0

	local ok, err = pcall(function()
		dataStore:UpdateAsync(shardKey(shard), function(existing)
			local merged = existing or {}
			for id, record in changes do
				merged[id] = mergeRecord(merged[id], record)
			end
			return merged
		end)
	end)

	if not ok then
		-- Put them back so the next flush retries.
		local bucket = pending[shard] or {}
		pending[shard] = bucket
		for id, record in changes do
			if bucket[id] == nil then
				pendingCount[shard] = (pendingCount[shard] or 0) + 1
			end
			bucket[id] = mergeRecord(bucket[id], record)
		end

		local failures = (shardFailures[shard] or 0) + 1
		shardFailures[shard] = failures

		local backoff = math.min(FLUSH_BACKOFF_MAX, FLUSH_BACKOFF_BASE * (2 ^ (failures - 1)))
		shardRetryAt[shard] = os.clock() + backoff

		-- Throttled: one warning per shard on first failure, then every tenth.
		if failures == 1 or failures % 10 == 0 then
			Log.warn("registry.flush_failed", {
				shard = shard,
				failures = failures,
				retryInSeconds = backoff,
				reason = tostring(err),
			})
		else
			Log.debug("registry.flush_failed", { shard = shard, failures = failures })
		end

		-- GetDataStore() succeeds even when writes are refused, so the
		-- store-level "unavailable" warning never fires. This is the signal
		-- that the registry has actually stopped persisting.
		if not degraded and failures >= 3 then
			degraded = true
			Log.warn("registry.datastore_degraded", {
				effect = "opt-in state is no longer persisting; GetOptedIn will go stale",
				fix = "enable Studio Access to API Services, or check your DataStore quota",
			})
		end

		return false
	end

	if shardFailures[shard] then
		shardFailures[shard] = nil
		shardRetryAt[shard] = nil
	end

	if degraded then
		degraded = false
		Log.info("registry.datastore_recovered")
	end

	-- The shard on disk has moved on; force a reload next time it's read.
	cacheLoadedAt[shard] = nil
	return true
end

function Registry.flush()
	for shard = 0, Config.RegistryShards - 1 do
		flushShard(shard)
	end
end

--[[ Reads -----------------------------------------------------------------]]

local function loadShard(shard: number, force: boolean?)
	local loadedAt = cacheLoadedAt[shard]
	if not force and loadedAt and os.clock() - loadedAt < CACHE_TTL then
		return cache[shard]
	end

	local dataStore = getStore()
	if not dataStore then
		return cache[shard]
	end

	local ok, value = pcall(function()
		return dataStore:GetAsync(shardKey(shard))
	end)

	if not ok then
		Log.warn("registry.read_failed", { shard = shard, reason = tostring(value) })
		return cache[shard]
	end

	local loaded = type(value) == "table" and value or {}

	-- Re-apply anything not yet flushed so the view doesn't go backwards.
	local unflushed = pending[shard]
	if unflushed then
		for id, record in unflushed do
			loaded[id] = mergeRecord(loaded[id], record)
		end
	end

	cache[shard] = loaded
	cacheLoadedAt[shard] = os.clock()
	return loaded
end

function Registry.get(userId: number)
	if not Config.EnableRegistry then
		return nil
	end

	local shard = loadShard(shardFor(userId))
	local record = shard and shard[tostring(userId)]
	if not record then
		return nil
	end
	return toEntry(userId, record)
end

--[=[
	Snapshot of everyone we believe might receive a notification.

	`includePrompted` (default true) also returns users we showed the opt-in
	modal to but have never successfully sent to. Excluded either way: users
	whose last send returned a terminal error.

	Reads every shard, so it yields. Call it once and reuse the result rather
	than per-player.
]=]
function Registry.getOptedIn(includePrompted: boolean?)
	local entries = {}
	if not Config.EnableRegistry then
		Log.warn("registry.disabled", { effect = "GetOptedIn returned an empty list" })
		return entries
	end

	local wantPrompted = includePrompted ~= false

	for shard = 0, Config.RegistryShards - 1 do
		local contents = loadShard(shard)
		if contents then
			for id, record in contents do
				local state = record.s
				local keep = state == STATE_LIKELY or (wantPrompted and state == STATE_PROMPTED)
				if keep then
					local userId = tonumber(id)
					if userId then
						table.insert(entries, toEntry(userId, record))
					end
				end
			end
		end
	end

	table.sort(entries, function(a, b)
		return a.userId < b.userId
	end)

	Log.debug("registry.snapshot", { count = #entries, includePrompted = wantPrompted })
	return entries
end

function Registry.count(): number
	local total = 0
	for shard = 0, Config.RegistryShards - 1 do
		local contents = loadShard(shard)
		if contents then
			for _ in contents do
				total += 1
			end
		end
	end
	return total
end

--[=[
	Persistence health. `degraded` true means writes are being refused and the
	registry has stopped being durable — `GetOptedIn` will go stale.
]=]
function Registry.getHealth()
	local pendingTotal = 0
	local failingShards = 0

	for shard = 0, Config.RegistryShards - 1 do
		pendingTotal += pendingCount[shard] or 0
		if shardFailures[shard] then
			failingShards += 1
		end
	end

	return {
		degraded = degraded,
		pending = pendingTotal,
		failingShards = failingShards,
		droppedStages = droppedStages,
	}
end

--[[ Lifecycle -------------------------------------------------------------]]

local started = false

function Registry.start()
	if started or not Config.EnableRegistry then
		return
	end
	started = true

	task.spawn(function()
		while true do
			task.wait(Config.RegistryFlushSeconds)
			local ok, err = pcall(Registry.flush)
			if not ok then
				Log.warn("registry.flush_error", { reason = tostring(err) })
			end
		end
	end)

	-- Last chance to persist staged changes before the server closes.
	game:BindToClose(function()
		local ok, err = pcall(Registry.flush)
		if not ok then
			Log.warn("registry.close_flush_error", { reason = tostring(err) })
		end
	end)

	Log.debug("registry.started", { shards = Config.RegistryShards })
end

return Registry
