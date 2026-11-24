--!nonstrict
--[[
	Dispatcher — the fire-and-forget worker behind `notif:Send()`.

	`Send` must never yield the caller's loop, so it only ever appends to this
	queue. A single worker coroutine drains it, spending one token bucket token
	per attempt and spawning the actual send so a slow API response can't stall
	the drain.

	No per-minute ceiling is documented for createUserNotification
	(RESEARCH.md §6), so the bucket defaults are deliberately conservative.

	This module deliberately knows nothing about Notification objects,
	Analytics or the Registry — it reports what happened to registered
	observers, which is what keeps the dependency graph acyclic.
]]

local Config = require(script.Parent.Config)
local Log = require(script.Parent.Log)
local Transport = require(script.Parent.Transport)
local Coordinator = require(script.Parent.Coordinator)

local Dispatcher = {}

--[[ Observers -------------------------------------------------------------]]

local observers = {}

--[=[
	observer(event: string, item: QueueItem, result: SendResult?)

	Events: "enqueued", "attempt", "sent", "retry", "failed",
	        "dropped_duplicate", "dropped_not_eligible", "dropped_queue_full"
]=]
function Dispatcher.addObserver(fn)
	table.insert(observers, fn)
end

local function notify(event: string, item, result)
	for _, observer in observers do
		local ok, err = pcall(observer, event, item, result)
		if not ok then
			Log.error("dispatcher.observer_error", { event = event, reason = tostring(err) })
		end
	end
end

--[[ Queue -----------------------------------------------------------------]]

-- One FIFO ring per priority level, drained highest priority first. Ring
-- indices rather than table.remove(q, 1) so a full queue stays O(1) per op.
local buckets = {}
local priorities = {}
local queueCount = 0

-- Items whose readyAt is still in the future (retry backoff). Small by nature.
local delayed = {}

local function pushBucket(priority: number, item)
	local bucket = buckets[priority]
	if not bucket then
		bucket = { items = {}, head = 1, tail = 0 }
		buckets[priority] = bucket
		table.insert(priorities, priority)
		table.sort(priorities, function(a, b)
			return a > b
		end)
	end

	bucket.tail += 1
	bucket.items[bucket.tail] = item
	queueCount += 1
end

local function popNext()
	for _, priority in priorities do
		local bucket = buckets[priority]
		if bucket.head <= bucket.tail then
			local item = bucket.items[bucket.head]
			bucket.items[bucket.head] = nil
			bucket.head += 1
			queueCount -= 1

			if bucket.head > bucket.tail then
				bucket.head = 1
				bucket.tail = 0
			end
			return item
		end
	end
	return nil
end

local function promoteDelayed(now: number)
	if #delayed == 0 then
		return
	end

	-- Iterate backwards so removals don't skip entries.
	for index = #delayed, 1, -1 do
		local item = delayed[index]
		if item.readyAt <= now then
			table.remove(delayed, index)
			pushBucket(item.priority, item)
		end
	end
end

function Dispatcher.getQueueSize(): number
	return queueCount + #delayed
end

--[[ Token bucket ----------------------------------------------------------]]

local tokens = Config.BurstSize
local lastRefill = os.clock()

-- Returns nil when a token was consumed, otherwise the seconds to wait.
local function takeToken(): number?
	local rate = Config.SendsPerMinute / 60
	if rate <= 0 then
		return 1
	end

	local now = os.clock()
	tokens = math.min(Config.BurstSize, tokens + (now - lastRefill) * rate)
	lastRefill = now

	if tokens >= 1 then
		tokens -= 1
		return nil
	end

	return (1 - tokens) / rate
end

--[[ Retry policy ----------------------------------------------------------]]

local backoffRandom = Random.new()

local function backoffSeconds(attempts: number): number
	local base = Config.RetryBaseSeconds * (2 ^ (attempts - 1))
	local capped = math.min(base, Config.RetryMaxSeconds)
	local jitter = capped * Config.RetryJitter
	return math.max(0, capped + backoffRandom:NextNumber(-jitter, jitter))
end

local function shouldRetry(item, result): boolean
	if not result.retryable then
		return false
	end
	-- 409 ABORTED is conditional, not plainly retryable (RESEARCH.md §7).
	if Transport.isConditional(result.statusCode) then
		return item.attempts < 2
	end
	return item.attempts < Config.MaxAttempts
end

--[[ Completion ------------------------------------------------------------]]

local function complete(item, result, event: string)
	notify(event, item, result)

	if item.onComplete then
		local ok, err = pcall(item.onComplete, item.userId, result)
		if not ok then
			Log.error("dispatcher.oncomplete_error", { userId = item.userId, reason = tostring(err) })
		end
	end
end

-- Builds a SendResult-shaped table for outcomes that never reached Transport.
local function syntheticResult(errorCode: string, errorMessage: string)
	return {
		ok = false,
		statusCode = 0,
		errorCode = errorCode,
		errorMessage = errorMessage,
		notificationId = nil,
		retryable = false,
		terminal = true,
		threw = false,
		dryRun = Config.DryRun,
	}
end

local function handleResult(item, result)
	if result.ok then
		Log.debug("dispatcher.sent", {
			userId = item.userId,
			alias = item.alias,
			attempts = item.attempts,
		})
		complete(item, result, "sent")
		return
	end

	if shouldRetry(item, result) then
		local delay = backoffSeconds(item.attempts)
		item.readyAt = os.clock() + delay
		table.insert(delayed, item)

		Log.debug("dispatcher.retry", {
			userId = item.userId,
			statusCode = result.statusCode,
			errorCode = result.errorCode or "-",
			attempt = item.attempts,
			inSeconds = delay,
		})
		notify("retry", item, result)
		return
	end

	-- Out of road. Terminal errors are config bugs, so say so loudly and with
	-- the specific fix rather than making the developer look up the code.
	local hint = Transport.getHint(result.statusCode)
	Log.warn("dispatcher.failed", {
		userId = item.userId,
		alias = item.alias,
		statusCode = result.statusCode,
		errorCode = result.errorCode or "-",
		errorMessage = result.errorMessage or "-",
		attempts = item.attempts,
		fix = hint or "-",
	})

	-- The send definitively did not land, so give today's slot back rather than
	-- blocking this user until the UTC day rolls over.
	if item.claimed then
		Coordinator.releaseDailySend(item.userId)
	end

	if result.terminal then
		Coordinator.markNotEligible(item.userId, result.errorCode)
	end

	complete(item, result, "failed")
end

--[[ Processing ------------------------------------------------------------]]

local inFlight = 0

local function processItem(item)
	inFlight += 1

	local ok, err = pcall(function()
		if Coordinator.isNotEligible(item.userId) then
			Log.debug("dispatcher.skip_not_eligible", { userId = item.userId })
			complete(
				item,
				syntheticResult("NEGATIVE_CACHE", "skipped: userId recently returned a terminal error"),
				"dropped_not_eligible"
			)
			return
		end

		-- Claim once per item, not once per attempt: a retry is the same send.
		if item.attempts == 0 then
			if not Coordinator.claimDailySend(item.userId) then
				complete(
					item,
					syntheticResult("DUPLICATE", "another server already sent to this user today"),
					"dropped_duplicate"
				)
				return
			end
			item.claimed = true
		end

		item.attempts += 1
		notify("attempt", item, nil)

		local result = Transport.send(item.userId, { payload = item.payload })
		handleResult(item, result)
	end)

	inFlight -= 1

	if not ok then
		Log.error("dispatcher.process_error", { userId = item.userId, reason = tostring(err) })
		complete(item, syntheticResult("DISPATCHER_ERROR", tostring(err)), "failed")
	end
end

--[[ Worker ----------------------------------------------------------------]]

local started = false

local function worker()
	while true do
		promoteDelayed(os.clock())

		if queueCount == 0 or inFlight >= Config.MaxConcurrentSends then
			task.wait(0.2)
			continue
		end

		local waitFor = takeToken()
		if waitFor then
			task.wait(waitFor)
			continue
		end

		local item = popNext()
		if item then
			task.spawn(processItem, item)
		else
			-- Nothing to spend the token on; hand it back.
			tokens += 1
		end
	end
end

function Dispatcher.start()
	if started then
		return
	end
	started = true
	task.spawn(worker)
	Log.debug("dispatcher.started", {
		sendsPerMinute = Config.SendsPerMinute,
		burst = Config.BurstSize,
		dryRun = Config.DryRun,
	})
end

--[[ Enqueue ---------------------------------------------------------------]]

--[=[
	Appends a send to the queue. Returns false if the queue is full.

	item: { userId, alias, payload, priority?, onComplete? }
]=]
function Dispatcher.enqueue(item): boolean
	if Dispatcher.getQueueSize() >= Config.MaxQueueSize then
		Log.warn("dispatcher.queue_full", {
			userId = item.userId,
			size = Dispatcher.getQueueSize(),
			max = Config.MaxQueueSize,
		})
		complete(item, syntheticResult("QUEUE_FULL", "dispatcher queue is at Config.MaxQueueSize"), "dropped_queue_full")
		return false
	end

	item.attempts = item.attempts or 0
	item.priority = item.priority or 0
	item.readyAt = item.readyAt or os.clock()
	item.enqueuedAt = item.enqueuedAt or os.time()
	item.claimed = false

	pushBucket(item.priority, item)
	notify("enqueued", item, nil)

	Dispatcher.start()
	return true
end

return Dispatcher
