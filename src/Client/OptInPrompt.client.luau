--!nonstrict
--[[
	OptInPrompt — auto-installed by BetterNotifications.

	Do not edit this copy: the server clones it into StarterPlayerScripts on
	every server start, so changes here are overwritten. Edit the module source
	at src/Client/OptInPrompt.client.luau instead.

	WHAT THIS CAN AND CANNOT KNOW
	-----------------------------
	CanPromptOptInAsync() returns false for three reasons it does not
	distinguish (RESEARCH.md §3): the user is under 13, the user has already
	opted in, or the user was prompted within the last 30 days. Re-checking it
	after a prompt closes therefore tells you nothing — it returns false either
	way. This script only ever reports "the modal was shown and closed", which
	is the strongest claim available.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local folder = ReplicatedStorage:WaitForChild("BetterNotifications", 30)
if not folder then
	return
end

local report = folder:WaitForChild("OptInReport", 30)
local promptRequest = folder:WaitForChild("PromptOptIn", 30)
if not report then
	return
end

-- ExperienceNotificationService is client-context only.
local ok, ExperienceNotificationService = pcall(function()
	return game:GetService("ExperienceNotificationService")
end)

if not ok or not ExperienceNotificationService then
	warn("[BetterNotifications] ExperienceNotificationService unavailable on this client")
	return
end

local promptShown = false

local function canPromptOptIn(): boolean
	local success, canPrompt = pcall(function()
		return ExperienceNotificationService:CanPromptOptInAsync()
	end)

	if not success then
		warn("[BetterNotifications] CanPromptOptInAsync failed: " .. tostring(canPrompt))
		return false
	end

	return canPrompt == true
end

local function tryPrompt(source: string)
	if promptShown then
		return
	end

	if not canPromptOptIn() then
		-- Ambiguous false; the server records nothing from this.
		report:FireServer("cannot_prompt", source)
		return
	end

	local success, err = pcall(function()
		ExperienceNotificationService:PromptOptIn()
	end)

	if not success then
		warn("[BetterNotifications] PromptOptIn failed: " .. tostring(err))
		return
	end

	promptShown = true
	report:FireServer("prompted", source)
end

ExperienceNotificationService.OptInPromptClosed:Connect(function()
	report:FireServer("closed")
end)

-- Server-initiated prompt, via notifSys:PromptOptIn(player).
if promptRequest then
	promptRequest.OnClientEvent:Connect(function()
		tryPrompt("server")
	end)
end

-- Automatic prompt, if enabled. Attributes are set by the server so the client
-- doesn't need its own copy of Config.
if folder:GetAttribute("AutoPromptOptIn") then
	task.delay(folder:GetAttribute("PromptDelaySeconds") or 60, function()
		tryPrompt("auto")
	end)
end
