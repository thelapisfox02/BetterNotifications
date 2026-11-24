--!nonstrict
--[[
	RealSendTest — drop-in harness for testing a REAL send in a published,
	eligible experience.

	This is NOT part of the module. It is a standalone Script you paste into
	ServerScriptService of a game that already clears the eligibility gate
	(100+ visits since launch, no active moderation, you can manage it).

	It deliberately does NOT edit Config.luau. Everything is set by mutating the
	live Config table at runtime, so the module stays byte-identical to the repo
	and you can delete this one script to undo the whole test.

	SETUP — all four steps are required:

	  1. ServerScriptService.BetterNotifications ....... the module
	  2. ServerScriptService.OpenCloud ................. Creator Store, "Open Cloud" by Roblox
	  3. A notification string authored in THIS experience's Creator Dashboard
	     (Engagement -> Notifications), asset ID pasted into MESSAGE_ID below
	  4. This script, in ServerScriptService

	READ BEFORE YOU RUN IT:

	  * The messageId is scoped to the experience it was authored in. A UUID
	    copied from a different game returns 400/404 here. This is the single
	    most common way this test fails.
	  * You get ONE delivery per user per day. A second run today returns 200
	    and silently delivers nothing. Plan on one real attempt per day, or use
	    a second account.
	  * A 200 does NOT mean delivered. Check your Roblox notification stream
	    (bell icon on the website/app), not the console, for ground truth.
	  * You must be 13+ and opted in to THIS experience.
]]

--=========================================================================
-- CONFIGURE ME
--=========================================================================

-- Creator Dashboard -> your experience -> Engagement -> Notifications
-- -> the row's "..." -> Copy Asset ID
local MESSAGE_ID = "PASTE-YOUR-ASSET-UUID-HERE"

-- The text you authored, purely so console output is readable.
local MESSAGE_TEXT = "Test notification from BetterNotifications"

-- EVERY {placeholder} in your notification string needs a matching entry here.
-- Miss one and the send fails with 400 INVALID_ARGUMENT:
--   "Missing parameter \"x\" to replace the placeholders in content."
--
-- The key is the placeholder name WITHOUT the braces, so a string like
--   "You have {count} rewards waiting, {message}"
-- needs:
--   { count = 3, message = "come back soon" }
--
-- Numbers must be whole. A Player becomes its UserId, which is what a
-- {userId-<name>} mention placeholder expects. Do NOT pass {experienceName} —
-- the platform fills that one in itself.
local MESSAGE_PARAMS = {
	-- message = "come back and claim your reward",
}

-- Seconds to wait after prompting before sending, giving you time to accept
-- the opt-in modal.
local SEND_DELAY_SECONDS = 25

-- Restrict the test to one account. 0 = whoever joins first.
-- Set this to your userId so a stray visitor can't burn their daily slot.
local ONLY_USER_ID = 0

-- Set false to skip the opt-in prompt entirely (use if you already opted in
-- via the bell on the experience page).
local PROMPT_FIRST = true

--=========================================================================

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local notifSys = require(ServerScriptService:WaitForChild("BetterNotifications"))

local TAG = "[RealSendTest]"

if MESSAGE_ID == "PASTE-YOUR-ASSET-UUID-HERE" or MESSAGE_ID == "" then
	error(
		TAG
			.. " MESSAGE_ID is not set. Author a notification string in THIS experience's "
			.. "Creator Dashboard (Engagement -> Notifications), then use the row's "
			.. "'...' -> Copy Asset ID and paste it into MESSAGE_ID.",
		0
	)
end

-- Runtime config only — Config.luau is left untouched.
notifSys.Config.DryRun = false
notifSys.Config.Diagnostics = true
notifSys.Config.DiagnosticsSampleCount = 25
notifSys:SetLogLevel("debug")

notifSys.Config.Messages.real_test = { id = MESSAGE_ID, text = MESSAGE_TEXT }
notifSys:RefreshMessages()

-- Don't let the module's own auto-prompt race this script's.
notifSys.Config.AutoPromptOptIn = not PROMPT_FIRST

print(TAG, "ready =", notifSys:IsReady(), "| placeId =", game.PlaceId)

if not notifSys:IsReady() then
	warn(
		TAG
			.. " transport is NOT ready — the Open Cloud package is missing. "
			.. "Install 'Open Cloud' by Roblox from the Creator Store into ServerScriptService. "
			.. "Sends will fail with PACKAGE_MISSING until you do."
	)
end

--=========================================================================

local notif = notifSys:New({
	msg = "real_test",
	params = MESSAGE_PARAMS,
	launchData = { source = "RealSendTest" },
	category = "real_send_test",
})

do
	local names = {}
	for key in MESSAGE_PARAMS do
		table.insert(names, key)
	end
	table.sort(names)
	print(TAG, "params being sent:", #names > 0 and table.concat(names, ", ") or "(none)")
end

-- The module-level signals catch every send on this server, which is what you
-- want here — the per-object ones would miss anything the scheduler drained.
notifSys.Sent:Connect(function(userId, result)
	print(
		TAG,
		("SENT userId=%d status=%d notificationId=%s"):format(
			userId,
			result.statusCode,
			tostring(result.notificationId)
		)
	)
	print(TAG, "A 200 is NOT proof of delivery. Check your Roblox notification stream to confirm.")
end)

notifSys.Failed:Connect(function(userId, result)
	warn(
		TAG,
		("FAILED userId=%d status=%d code=%s message=%s"):format(
			userId,
			result.statusCode,
			tostring(result.errorCode),
			tostring(result.errorMessage)
		)
	)

	-- Read the actual message before guessing: a 400 has several distinct
	-- causes and blaming the wrong one wastes a day of testing.
	local message = string.lower(tostring(result.errorMessage))

	if result.statusCode == 403 then
		warn(TAG, "403 usually means this experience has not cleared the 100-visit gate, or you lack manage permission.")
	elseif string.find(message, "parameter", 1, true) or string.find(message, "placeholder", 1, true) then
		warn(
			TAG,
			"Your notification string has a {placeholder} with no matching entry in MESSAGE_PARAMS. "
				.. "Add it at the top of this script — the key is the placeholder name without the braces."
		)
	elseif result.statusCode == 400 or result.statusCode == 404 then
		warn(TAG, "400/404 here usually means MESSAGE_ID was not authored in THIS experience. Re-copy it from this game's dashboard.")
	end
end)

--=========================================================================

local fired = false

local function runTest(player: Player)
	if fired then
		return
	end
	if ONLY_USER_ID ~= 0 and player.UserId ~= ONLY_USER_ID then
		print(TAG, "ignoring", player.Name, "- ONLY_USER_ID is set to", ONLY_USER_ID)
		return
	end
	fired = true

	print(TAG, "target:", player.Name, player.UserId)

	if PROMPT_FIRST then
		local requested = notifSys:PromptOptIn(player)
		print(TAG, "opt-in prompt requested =", requested, "- accept it in-experience if it appears")
		print(TAG, "note: the prompt does not appear if you are under 13, already opted in, or were prompted in the last 30 days")
	end

	print(TAG, ("sending in %d seconds..."):format(SEND_DELAY_SECONDS))
	task.wait(SEND_DELAY_SECONDS)

	-- Any earlier terminal failure parked this userId in the negative cache for
	-- Config.NegativeCacheSeconds (1h by default). Without clearing it, this run
	-- would be dropped locally as NEGATIVE_CACHE and never reach the API — which
	-- looks identical to the module doing nothing. Repeated testing needs this.
	notifSys:ClearNotEligible(player.UserId)

	-- Send to the userId rather than the Player object so this is exactly the
	-- same code path an offline re-engagement send would take.
	local queued = notif:Send(player.UserId)
	print(TAG, "queued =", queued)

	task.wait(10)
	local stats = notifSys:GetStats()
	print(
		TAG,
		("stats: enqueued=%d sent=%d failed=%d retried=%d queue=%d"):format(
			stats.enqueued,
			stats.sent,
			stats.failed,
			stats.retried,
			stats.queueSize
		)
	)
	for code, count in stats.byStatusCode do
		print(TAG, ("  status %s x%d"):format(tostring(code), count))
	end
end

for _, player in Players:GetPlayers() do
	task.spawn(runTest, player)
end
Players.PlayerAdded:Connect(function(player)
	task.spawn(runTest, player)
end)

print(TAG, "armed - waiting for a player")
