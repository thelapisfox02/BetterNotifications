--!nonstrict
--[[
	BetterNotifications — Roblox experience notifications with a queue, retries,
	cross-server dedupe, scheduling and an opt-in registry.

		local notifSys = require(BetterNotifications)

		local notif = notifSys:New({ msg = "daily_reward" })
		for _, entry in notifSys:GetOptedIn() do
			notif:Send(entry)
		end

	Server-side only. Requiring this from a LocalScript is an error — the send
	API is server-only, and the client half installs itself automatically.

	Setup lives in README.md; platform facts and limits are cited to
	docs/RESEARCH.md throughout the source.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local StarterPlayer = game:GetService("StarterPlayer")

if not RunService:IsServer() then
	error(
		"[BetterNotifications] must be required from the server. "
			.. "The opt-in prompt half installs itself into StarterPlayerScripts automatically.",
		2
	)
end

local Config = require(script.Config)
local Log = require(script.Log)
local Signal = require(script.Signal)
local Util = require(script.Util)
local Transport = require(script.Transport)
local Coordinator = require(script.Coordinator)
local Dispatcher = require(script.Dispatcher)
local Registry = require(script.Registry)
local Scheduler = require(script.Scheduler)
local Analytics = require(script.Analytics)
local Notification = require(script.Notification)

local BetterNotifications = {}

-- Fired for every send this server dispatches, whatever created it.
-- Per-Notification signals only cover sends that object queued; a scheduled
-- send drained by a different server fires that server's signals, not this
-- object's.
BetterNotifications.Sent = Signal.new()
BetterNotifications.Failed = Signal.new()

BetterNotifications.States = Registry.States
BetterNotifications.Config = Config

--[[ Client bootstrap ------------------------------------------------------]]

local remoteFolder = nil

local function ensureRemotes()
	if remoteFolder then
		return remoteFolder
	end

	local folder = ReplicatedStorage:FindFirstChild("BetterNotifications")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "BetterNotifications"
		folder.Parent = ReplicatedStorage
	end

	local function ensureRemote(name: string)
		local remote = folder:FindFirstChild(name)
		if not remote then
			remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
		return remote
	end

	ensureRemote("OptInReport")
	ensureRemote("PromptOptIn")

	folder:SetAttribute("AutoPromptOptIn", Config.AutoPromptOptIn)
	folder:SetAttribute("PromptDelaySeconds", Config.PromptDelaySeconds)

	remoteFolder = folder
	return folder
end

local function installClientScript()
	local source = script:FindFirstChild("Client")
	source = source and source:FindFirstChild("OptInPrompt")

	if not source then
		Log.warn("bootstrap.client_script_missing", {
			effect = "opt-in prompts will not be shown; registry will stay empty",
		})
		return
	end

	-- Picked up by everyone who joins from here on.
	local starterScripts = StarterPlayer:FindFirstChildOfClass("StarterPlayerScripts")
	if starterScripts and not starterScripts:FindFirstChild(source.Name) then
		local clone = source:Clone()
		clone.Parent = starterScripts
	end

	-- ...and directly to anyone already here, in case this module was required
	-- late in the server's life.
	--
	-- Not PlayerScripts: that container is client-only and is simply not there
	-- from the server's point of view, so parenting into it silently does
	-- nothing. PlayerGui is server-visible, replicates, and runs LocalScripts.
	local function injectInto(player: Player)
		local container = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10)
		if container and not container:FindFirstChild(source.Name) then
			local clone = source:Clone()
			clone.Parent = container
		end
	end

	for _, player in Players:GetPlayers() do
		task.spawn(injectInto, player)
	end
end

local function connectOptInReports()
	local folder = ensureRemotes()
	local report = folder:FindFirstChild("OptInReport")
	if not report then
		return
	end

	report.OnServerEvent:Connect(function(player, outcome, source)
		-- Only "prompted" carries information: the modal was actually shown.
		-- "cannot_prompt" is ambiguous (RESEARCH.md §3) and recorded as nothing.
		if outcome == "prompted" then
			Registry.markPrompted(player.UserId)
			Log.debug("optin.prompted", { userId = player.UserId, source = tostring(source) })
		elseif outcome == "closed" then
			Log.debug("optin.closed", { userId = player.UserId })
		end
	end)
end

--[[ Wiring ----------------------------------------------------------------]]

Dispatcher.addObserver(function(event, item, result)
	Analytics.observe(event, item, result)

	-- Only real send outcomes update the registry. A duplicate drop says
	-- nothing about the user, and recording it would wrongly mark them
	-- ineligible.
	if event == "sent" or event == "failed" then
		if Config.EnableRegistry then
			Registry.recordResult(item.userId, result)
		end
		if event == "sent" then
			BetterNotifications.Sent:Fire(item.userId, result)
		else
			BetterNotifications.Failed:Fire(item.userId, result)
		end
	end
end)

--[[ Public API ------------------------------------------------------------]]

--[=[
	Creates a reusable notification.

	spec = {
		msg        = alias | exact configured text | asset UUID   (required)
		params     = { [name] = number | string | boolean | Player }
		launchData = string | table   -- max 200 bytes once encoded
		category   = string           -- Dashboard grouping, defaults to the alias
		priority   = number           -- higher drains first, default 0
	}

	Throws if `msg` cannot be resolved — that is a config bug, and notification
	strings must exist in the Creator Dashboard before they can be sent.
]=]
function BetterNotifications:New(spec)
	return Notification.new(spec)
end

--[=[
	Snapshot of users we believe may receive a notification.

	This is a confidence model, not ground truth: there is no API that lists
	opted-in users (RESEARCH.md §8). Yields — call once and reuse.
]=]
function BetterNotifications:GetOptedIn(includePrompted: boolean?)
	return Registry.getOptedIn(includePrompted)
end

function BetterNotifications:GetEntry(target)
	local userId = Util.toUserId(target)
	return userId and Registry.get(userId) or nil
end

--[=[
	Live counters, bucketed by status and error code.
]=]
function BetterNotifications:GetStats()
	local stats = Analytics.getStats()
	stats.queueSize = Dispatcher.getQueueSize()
	stats.registry = Registry.getHealth()
	return stats
end

--[=[
	Asks a specific player's client to show the opt-in modal. The client still
	has to pass CanPromptOptInAsync, so this is a request, not a guarantee.
]=]
function BetterNotifications:PromptOptIn(target): boolean
	local player = target
	if typeof(target) ~= "Instance" then
		local userId = Util.toUserId(target)
		player = userId and Players:GetPlayerByUserId(userId) or nil
	end

	if not player or not player:IsA("Player") then
		Log.warn("promptoptin.no_player", { target = tostring(target) })
		return false
	end

	local folder = ensureRemotes()
	local remote = folder:FindFirstChild("PromptOptIn")
	if not remote then
		return false
	end

	remote:FireClient(player)
	return true
end

function BetterNotifications:SetLogLevel(level: string)
	Log.setLevel(level)
end

--[=[
	Clears the local negative cache for a user so the next send actually reaches
	the API.

	A terminal error parks that userId for Config.NegativeCacheSeconds, which is
	right in production — but after you fix the config bug that caused it, every
	retry would be skipped locally without ever being attempted. Call this once
	the underlying problem is fixed.
]=]
function BetterNotifications:ClearNotEligible(target): boolean
	local userId = Util.toUserId(target)
	if not userId then
		Log.warn("clearnoteligible.bad_target", { target = tostring(target) })
		return false
	end

	Coordinator.clearNotEligible(userId)
	Log.debug("clearnoteligible", { userId = userId })
	return true
end

--[=[
	True when a real send could be attempted: either DryRun is on, or the
	Creator Store Open Cloud package resolved.
]=]
function BetterNotifications:IsReady(): boolean
	return Transport.isAvailable()
end

function BetterNotifications:GetQueueSize(): number
	return Dispatcher.getQueueSize()
end

--[=[
	Forces staged registry writes to DataStore. Yields. Called automatically on
	a timer and at server close.
]=]
function BetterNotifications:FlushRegistry()
	Registry.flush()
end

-- Call after mutating Config.Messages at runtime.
function BetterNotifications:RefreshMessages()
	Util.refreshMessages()
end

--[[ Start -----------------------------------------------------------------]]

do
	ensureRemotes()
	installClientScript()
	connectOptInReports()

	Dispatcher.start()
	Registry.start()
	Scheduler.start()

	if not Transport.isAvailable() then
		Log.warn("startup.transport_unavailable", {
			effect = "sends will fail until the Open Cloud package is installed",
			fix = "install 'Open Cloud' from the Creator Store into ServerScriptService, or set Config.DryRun = true",
		})
	end

	Log.info("startup", {
		dryRun = Config.DryRun,
		diagnostics = Config.Diagnostics,
		messages = (function()
			local count = 0
			for _ in Config.Messages do
				count += 1
			end
			return count
		end)(),
		sendsPerMinute = Config.SendsPerMinute,
		registry = Config.EnableRegistry,
		scheduler = Config.EnableScheduler,
	})
end

return BetterNotifications
