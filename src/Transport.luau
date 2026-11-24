--!nonstrict
--[[
	Transport — the only module that touches the Open Cloud package.

	Responsibilities:
	  * locate ServerScriptService.OpenCloud.V2.UserNotification lazily, with a
	    loud, actionable error if it was never installed;
	  * call createUserNotification inside a pcall AND check statusCode — the
	    call performs network I/O, so it can throw at the Luau level entirely
	    independently of the status it would otherwise return (RESEARCH.md §2);
	  * normalise every outcome into a single SendResult shape;
	  * classify retryable vs terminal from the Open Cloud v2 error table
	    (RESEARCH.md §7);
	  * serve simulated results when Config.DryRun is on.

	Nothing here retries or rate-limits. That is the Dispatcher's job.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(script.Parent.Config)
local Log = require(script.Parent.Log)
local Types = require(script.Parent.Types)

local Transport = {}

--[[ Error classification --------------------------------------------------]]

-- RESEARCH.md §7. `hint` is printed on terminal failures because every one of
-- them is a configuration bug the developer can actually fix.
local STATUS_INFO = {
	[400] = {
		code = "INVALID_ARGUMENT",
		retryable = false,
		hint = "check the messageId is the asset UUID copied from the Creator Dashboard (... -> Copy Asset ID), and that parameter names match the notification string",
	},
	[403] = {
		code = "PERMISSION_DENIED",
		retryable = false,
		hint = "experience eligibility not met (needs 100+ visits since launch, no active moderation) or you lack permission to manage this experience",
	},
	[404] = {
		code = "NOT_FOUND",
		retryable = false,
		hint = "messageId or universe not found — the notification string may have been deleted",
	},
	[409] = {
		code = "ABORTED",
		retryable = true,
		conditional = true,
		hint = "conflicting operation; retried once",
	},
	[429] = {
		code = "RESOURCE_EXHAUSTED",
		retryable = true,
		hint = "out of quota — lower Config.SendsPerMinute if this is frequent",
	},
	[499] = { code = "CANCELLED", retryable = true, hint = "client-side timeout" },
	[500] = { code = "INTERNAL", retryable = true, hint = "Roblox internal error" },
	[501] = { code = "NOT_IMPLEMENTED", retryable = false, hint = "method not implemented" },
	[503] = { code = "UNAVAILABLE", retryable = true, hint = "service unavailable" },
}

-- Statuses where only a single retry is worthwhile (RESEARCH.md §7: 409 is
-- "conditional" rather than plainly retryable).
function Transport.isConditional(statusCode: number): boolean
	local info = STATUS_INFO[statusCode]
	return info ~= nil and info.conditional == true
end

function Transport.getHint(statusCode: number): string?
	local info = STATUS_INFO[statusCode]
	return info and info.hint or nil
end

local function classify(statusCode: number): (boolean, boolean)
	if statusCode == 200 then
		return false, false
	end

	local info = STATUS_INFO[statusCode]
	if info then
		return info.retryable, not info.retryable
	end

	-- Undocumented status. Anything 5xx (or a zero from a Luau-level throw) is
	-- plausibly transient; everything else is treated as a caller error.
	local retryable = statusCode >= 500 or statusCode == 0
	return retryable, not retryable
end

local function makeResult(fields): Types.SendResult
	local statusCode = fields.statusCode or 0
	local retryable, terminal = classify(statusCode)

	return {
		ok = statusCode == 200,
		statusCode = statusCode,
		errorCode = fields.errorCode,
		errorMessage = fields.errorMessage,
		notificationId = fields.notificationId,
		retryable = retryable,
		terminal = terminal,
		threw = fields.threw == true,
		dryRun = fields.dryRun == true,
	}
end

--[[ Package resolution ----------------------------------------------------]]

local INSTALL_HINT = table.concat({
	"the Open Cloud UserNotification package is not installed.",
	"Get it from the Creator Store ('Open Cloud' by Roblox) and place it in",
	"ServerScriptService so the path ServerScriptService.OpenCloud.V2.UserNotification resolves.",
	"Set Config.DryRun = true to develop without it.",
}, " ")

-- Re-probe rather than latching a failure forever: the package can be dropped
-- into ServerScriptService after the server has already started, and a server
-- that gave up permanently would return PACKAGE_MISSING for its whole life.
local RESOLVE_RETRY_SECONDS = 60

local resolvedPackage = nil
local resolveAttemptedAt: number? = nil
local resolveError: string? = nil
local resolveErrorLogged = false

local function resolvePackage()
	if resolvedPackage then
		return resolvedPackage
	end
	if resolveAttemptedAt and (os.clock() - resolveAttemptedAt) < RESOLVE_RETRY_SECONDS then
		return nil
	end
	resolveAttemptedAt = os.clock()

	local ok, result = pcall(function()
		local root = ServerScriptService:FindFirstChild("OpenCloud")
		if not root then
			error("ServerScriptService.OpenCloud is missing", 0)
		end
		local v2 = root:FindFirstChild("V2")
		if not v2 then
			error("ServerScriptService.OpenCloud.V2 is missing", 0)
		end
		local module = v2:FindFirstChild("UserNotification")
		if not module or not module:IsA("ModuleScript") then
			error("ServerScriptService.OpenCloud.V2.UserNotification is missing", 0)
		end
		return require(module)
	end)

	if not ok then
		resolveError = tostring(result)
		-- Logged once, not on every re-probe.
		if not resolveErrorLogged then
			resolveErrorLogged = true
			Log.error("transport.package_missing", { reason = resolveError, fix = INSTALL_HINT })
		end
		return nil
	end

	if type(result) ~= "table" or type(result.createUserNotification) ~= "function" then
		resolveError = "package resolved but has no createUserNotification function"
		if not resolveErrorLogged then
			resolveErrorLogged = true
			Log.error("transport.package_invalid", { reason = resolveError })
		end
		return nil
	end

	resolvedPackage = result
	if resolveErrorLogged then
		Log.info("transport.package_recovered", { effect = "sends will now reach the Open Cloud API" })
	end
	Log.debug("transport.package_ready")
	return resolvedPackage
end

-- True when a real send could be attempted right now.
function Transport.isAvailable(): boolean
	if Config.DryRun then
		return true
	end
	return resolvePackage() ~= nil
end

--[[ DryRun ----------------------------------------------------------------]]

local dryRunRandom = Random.new()
local dryRunCounter = 0

local function pickDryRunStatus(): number
	local total = 0
	for _, outcome in Config.DryRunOutcomes do
		total += outcome.weight
	end
	if total <= 0 then
		return 200
	end

	local roll = dryRunRandom:NextNumber() * total
	local accumulated = 0
	for _, outcome in Config.DryRunOutcomes do
		accumulated += outcome.weight
		if roll <= accumulated then
			return outcome.statusCode
		end
	end
	return 200
end

local function dryRunSend(userId: number): Types.SendResult
	local latency = Config.DryRunLatency
	if latency and latency.max and latency.max > 0 then
		task.wait(dryRunRandom:NextNumber(latency.min or 0, latency.max))
	end

	local statusCode = pickDryRunStatus()
	dryRunCounter += 1

	local info = STATUS_INFO[statusCode]
	return makeResult({
		statusCode = statusCode,
		errorCode = info and info.code or nil,
		errorMessage = statusCode ~= 200 and "simulated dry-run failure" or nil,
		notificationId = statusCode == 200 and ("dryrun-%d-%d"):format(userId, dryRunCounter) or nil,
		dryRun = true,
	})
end

--[[ Diagnostics -----------------------------------------------------------]]

-- A 200 does not prove delivery (RESEARCH.md §6), so the registry's opt-in
-- inference is unproven until measured. This dumps raw results for the first N
-- sends so the real behaviour of a given universe can be observed.
local diagnosticsLogged = 0

local function logDiagnostic(userId: number, result: Types.SendResult)
	if not Config.Diagnostics or diagnosticsLogged >= Config.DiagnosticsSampleCount then
		return
	end
	diagnosticsLogged += 1

	Log.diagnostic("send.sample", {
		n = diagnosticsLogged,
		of = Config.DiagnosticsSampleCount,
		userId = userId,
		statusCode = result.statusCode,
		errorCode = result.errorCode or "-",
		errorMessage = result.errorMessage or "-",
		threw = result.threw,
		dryRun = result.dryRun,
	})
end

--[[ Send ------------------------------------------------------------------]]

--[=[
	Performs exactly one attempt. Never throws: Luau-level errors are captured
	and returned as a SendResult with statusCode 0 and threw = true.
]=]
function Transport.send(userId: number, userNotification: Types.UserNotification): Types.SendResult
	local result

	if Config.DryRun then
		result = dryRunSend(userId)
	else
		local package = resolvePackage()
		if not package then
			-- Terminal by classification (0 would otherwise be retryable), because
			-- retrying a missing package is pointless.
			result = makeResult({
				statusCode = 0,
				errorCode = "PACKAGE_MISSING",
				errorMessage = resolveError or INSTALL_HINT,
				threw = true,
			})
			result.retryable = false
			result.terminal = true
		else
			local ok, response = pcall(package.createUserNotification, userId, userNotification)

			if not ok then
				result = makeResult({
					statusCode = 0,
					errorCode = "LUAU_ERROR",
					errorMessage = tostring(response),
					threw = true,
				})
			else
				local statusCode = 0
				local errorCode, errorMessage, notificationId

				if type(response) == "table" then
					statusCode = tonumber(response.statusCode) or 0
					if type(response.error) == "table" then
						errorCode = response.error.code
						errorMessage = response.error.message
					end
					if type(response.response) == "table" then
						notificationId = response.response.id
					end
				else
					errorCode = "MALFORMED_RESPONSE"
					errorMessage = "package returned " .. typeof(response)
				end

				result = makeResult({
					statusCode = statusCode,
					errorCode = errorCode or (STATUS_INFO[statusCode] and STATUS_INFO[statusCode].code),
					errorMessage = errorMessage,
					notificationId = notificationId,
				})
			end
		end
	end

	logDiagnostic(userId, result)
	return result
end

return Transport
