--!nonstrict
--[[
	Notification — the object returned by `notifSys:New{...}`.

	Holds a resolved messageId plus its default parameters, and hands sends to
	the Dispatcher (immediate) or the Scheduler (future). Every Send variant
	returns immediately; none of them yield the caller.

	Per-send overrides matter more than they look: usage guidelines require
	notifications to be personalised to the receiver (RESEARCH.md §12), so one
	Notification object sent to many users usually needs per-user parameters.

		local notif = notifSys:New{ msg = "friend_beat_score" }
		notif:Send(userId, { params = { friend = otherPlayer, points = 5 } })
]]

local Config = require(script.Parent.Config)
local Log = require(script.Parent.Log)
local Signal = require(script.Parent.Signal)
local Util = require(script.Parent.Util)
local Dispatcher = require(script.Parent.Dispatcher)
local Scheduler = require(script.Parent.Scheduler)

local Notification = {}
Notification.__index = Notification

local scheduleRandom = Random.new()

function Notification.new(spec)
	if type(spec) ~= "table" then
		error("[BetterNotifications] :New expects a table, e.g. :New{ msg = \"daily_reward\" }", 3)
	end

	local messageId, alias = Util.resolveMessage(spec.msg, 4)

	local self = setmetatable({
		messageId = messageId,
		alias = alias,
		category = spec.category or alias,
		priority = tonumber(spec.priority) or 0,
		parameters = Util.buildParameters(spec.params, 4),
		launchData = Util.encodeLaunchData(spec.launchData, 4),

		-- (userId, result) — fired for sends this server dispatched.
		Sent = Signal.new(),
		Failed = Signal.new(),
	}, Notification)

	Log.debug("notification.created", { alias = alias, messageId = messageId, category = self.category })
	return self
end

--[[ Payload ---------------------------------------------------------------]]

function Notification:_buildPayload(overrides)
	local payload = {
		messageId = self.messageId,
		-- "MOMENT" is the only type the platform currently supports.
		type = "MOMENT",
	}

	local parameters = self.parameters
	local launchData = self.launchData

	if overrides then
		if overrides.params ~= nil then
			parameters = Util.buildParameters(overrides.params, 4)
		end
		if overrides.launchData ~= nil then
			launchData = Util.encodeLaunchData(overrides.launchData, 4)
		end
	end

	if parameters then
		payload.parameters = parameters
	end
	if launchData then
		payload.joinExperience = { launchData = launchData }
	end

	-- This is what groups rows in the Creator Dashboard's itemised table.
	local category = (overrides and overrides.category) or self.category
	if category then
		payload.analyticsData = { category = tostring(category) }
	end

	return payload
end

function Notification:_enqueue(userId: number, overrides): boolean
	return Dispatcher.enqueue({
		userId = userId,
		alias = self.alias,
		payload = self:_buildPayload(overrides),
		priority = (overrides and tonumber(overrides.priority)) or self.priority,
		onComplete = function(id, result)
			if result.ok then
				self.Sent:Fire(id, result)
			else
				self.Failed:Fire(id, result)
			end
		end,
	})
end

local function resolveTarget(self, target, method: string): number?
	local userId = Util.toUserId(target)
	if not userId then
		-- Warn rather than throw: this usually sits inside a loop over player
		-- state, and one bad row shouldn't kill the whole batch.
		Log.warn("notification.bad_target", {
			alias = self.alias,
			method = method,
			targetType = typeof(target),
			target = tostring(target),
		})
	end
	return userId
end

--[[ Immediate -------------------------------------------------------------]]

--[=[
	Queues a send and returns instantly. Returns false if the target could not
	be resolved or the queue is full.
]=]
function Notification:Send(target, overrides): boolean
	local userId = resolveTarget(self, target, "Send")
	if not userId then
		return false
	end
	return self:_enqueue(userId, overrides)
end

--[=[
	Batch form. Returns the number of sends actually queued.
]=]
function Notification:SendAll(targets, overrides): number
	if type(targets) ~= "table" then
		error("[BetterNotifications] :SendAll expects an array of targets, got " .. typeof(targets), 2)
	end

	local queued = 0
	for _, target in targets do
		if self:Send(target, overrides) then
			queued += 1
		end
	end

	Log.debug("notification.send_all", { alias = self.alias, requested = #targets, queued = queued })
	return queued
end

--[[ Scheduled -------------------------------------------------------------]]

function Notification:_schedule(atUnixTime: number, target, overrides, method: string): boolean
	local userId = resolveTarget(self, target, method)
	if not userId then
		return false
	end

	if not Config.EnableScheduler then
		Log.warn("notification.scheduler_disabled", { alias = self.alias, method = method })
		return false
	end

	return Scheduler.schedule(atUnixTime, {
		userId = userId,
		alias = self.alias,
		payload = self:_buildPayload(overrides),
		priority = (overrides and tonumber(overrides.priority)) or self.priority,
	})
end

--[=[
	Sends after `seconds`. Durable across servers: whichever server is alive at
	the due time delivers it, not necessarily this one.
]=]
function Notification:SendIn(seconds: number, target, overrides): boolean
	local delay = tonumber(seconds)
	if not delay or delay < 0 then
		error("[BetterNotifications] :SendIn expects a non-negative number of seconds", 2)
	end
	return self:_schedule(os.time() + delay, target, overrides, "SendIn")
end

--[=[
	Sends at an absolute unix timestamp. A time already in the past is sent on
	the next scheduler poll.
]=]
function Notification:SendAt(unixTime: number, target, overrides): boolean
	local at = tonumber(unixTime)
	if not at then
		error("[BetterNotifications] :SendAt expects a unix timestamp", 2)
	end
	return self:_schedule(at, target, overrides, "SendAt")
end

--[=[
	Sends at a uniformly random point inside [minSeconds, maxSeconds] from now.
	Useful for spreading a re-engagement wave so it doesn't all land at once.
]=]
function Notification:SendAtRandom(minSeconds: number, maxSeconds: number, target, overrides): boolean
	local low = tonumber(minSeconds)
	local high = tonumber(maxSeconds)

	if not low or not high then
		error("[BetterNotifications] :SendAtRandom expects (minSeconds, maxSeconds, target)", 2)
	end
	if low < 0 or high < low then
		error("[BetterNotifications] :SendAtRandom needs 0 <= minSeconds <= maxSeconds", 2)
	end

	local delay = scheduleRandom:NextNumber(low, high)
	return self:_schedule(os.time() + math.floor(delay), target, overrides, "SendAtRandom")
end

--[[ Misc ------------------------------------------------------------------]]

function Notification:Destroy()
	self.Sent:DisconnectAll()
	self.Failed:DisconnectAll()
end

return Notification
