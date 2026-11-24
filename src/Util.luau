--!nonstrict
--[[
	Util — resolution and coercion helpers shared by the public API.

	Kept separate from Notification because init.luau and Scheduler need target
	resolution too.
]]

local HttpService = game:GetService("HttpService")

local Config = require(script.Parent.Config)

local Util = {}

local UUID_PATTERN = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

function Util.isUuid(value): boolean
	return type(value) == "string" and value:match(UUID_PATTERN) ~= nil
end

--[[ Targets ---------------------------------------------------------------]]

--[=[
	Coerces anything sensible into a userId, or nil if it can't.

	Accepts: a raw userId, a Player, or a table carrying userId / UserId / id /
	player (so a RegistryEntry, or the caller's own player-state table, works
	without unwrapping).
]=]
function Util.toUserId(target): number?
	local kind = typeof(target)

	if kind == "number" then
		if target > 0 and target % 1 == 0 then
			return target
		end
		return nil
	elseif kind == "Instance" then
		if target:IsA("Player") then
			return target.UserId
		end
		return nil
	elseif kind == "string" then
		local parsed = tonumber(target)
		if parsed and parsed > 0 and parsed % 1 == 0 then
			return parsed
		end
		return nil
	elseif kind == "table" then
		local id = target.userId or target.UserId or target.id or target.Id
		if type(id) == "number" and id > 0 and id % 1 == 0 then
			return id
		end
		if type(id) == "string" then
			return tonumber(id)
		end

		local player = target.player or target.Player
		if typeof(player) == "Instance" and player:IsA("Player") then
			return player.UserId
		end
		return nil
	end

	return nil
end

--[[ Messages --------------------------------------------------------------]]

local textIndex = nil

local function messageId(def): string?
	if type(def) == "string" then
		return def
	end
	if type(def) == "table" and type(def.id) == "string" then
		return def.id
	end
	return nil
end

local function buildTextIndex()
	textIndex = {}
	for alias, def in Config.Messages do
		if type(def) == "table" and type(def.text) == "string" then
			textIndex[def.text] = alias
		end
	end
end

-- Call after mutating Config.Messages at runtime.
function Util.refreshMessages()
	textIndex = nil
end

local function describeConfigured(): string
	local lines = {}
	for alias, def in Config.Messages do
		local id = messageId(def) or "<missing id>"
		local text = type(def) == "table" and def.text or nil
		table.insert(lines, ("    %s -> %s%s"):format(alias, id, text and (" (%q)"):format(text) or ""))
	end

	if #lines == 0 then
		return "    (Config.Messages is empty — add your Creator Dashboard notification strings to it)"
	end

	table.sort(lines)
	return table.concat(lines, "\n")
end

--[=[
	Resolves `msg` to a Dashboard asset UUID, returning (messageId, alias).

	Three forms are accepted, in order: the alias key, the human-readable text,
	or a raw asset UUID.

	An unresolvable msg is a config bug, not a runtime condition — notification
	strings must be pre-authored in the Creator Dashboard (RESEARCH.md §4), so a
	literal sentence in code can never be sent as-is. This throws rather than
	failing quietly at send time.
]=]
function Util.resolveMessage(msg: string, errorLevel: number?): (string, string)
	local level = errorLevel or 3

	if type(msg) ~= "string" or msg == "" then
		error("[BetterNotifications] `msg` must be a non-empty string, got " .. typeof(msg), level)
	end

	if not textIndex then
		buildTextIndex()
	end

	local direct = Config.Messages[msg]
	if direct ~= nil then
		local id = messageId(direct)
		if not id then
			error(
				("[BetterNotifications] Config.Messages[%q] has no `id` — set it to the asset UUID from the Creator Dashboard"):format(
					msg
				),
				level
			)
		end
		return id, msg
	end

	local alias = textIndex[msg]
	if alias then
		local id = messageId(Config.Messages[alias])
		if id then
			return id, alias
		end
	end

	if Util.isUuid(msg) then
		return msg, msg
	end

	error(
		("[BetterNotifications] cannot resolve msg %q.\n  Expected an alias key, the exact configured text, or an asset UUID.\n  Configured messages:\n%s"):format(
			msg,
			describeConfigured()
		),
		level
	)
end

--[[ Payload pieces --------------------------------------------------------]]

--[=[
	Wraps plain values in the typed parameter form the payload requires
	(RESEARCH.md §2): numbers become int64Value, strings stringValue.

	A Player is accepted and becomes its UserId, which is what a
	`{userId-<name>}` placeholder in the notification string needs.
]=]
function Util.buildParameters(params, errorLevel: number?)
	if params == nil then
		return nil
	end

	local level = errorLevel or 3
	if type(params) ~= "table" then
		error("[BetterNotifications] `params` must be a table, got " .. typeof(params), level)
	end

	local out = {}
	local count = 0

	for name, value in params do
		if type(name) ~= "string" then
			error("[BetterNotifications] parameter names must be strings, got " .. typeof(name), level)
		end

		local kind = typeof(value)
		if kind == "number" then
			if value % 1 ~= 0 then
				-- int64Value is the only numeric wrapper; a float would be
				-- silently truncated, so make the caller choose.
				error(
					("[BetterNotifications] parameter %q is a non-integer number (%s). Round it, or pass it as a string."):format(
						name,
						tostring(value)
					),
					level
				)
			end
			out[name] = { int64Value = value }
		elseif kind == "string" then
			out[name] = { stringValue = value }
		elseif kind == "boolean" then
			out[name] = { stringValue = tostring(value) }
		elseif kind == "Instance" and value:IsA("Player") then
			out[name] = { int64Value = value.UserId }
		elseif kind == "table" and (value.int64Value ~= nil or value.stringValue ~= nil) then
			-- Already wrapped by the caller.
			out[name] = value
		else
			error(
				("[BetterNotifications] parameter %q has unsupported type %s (expected number, string, boolean or Player)"):format(
					name,
					kind
				),
				level
			)
		end

		count += 1
	end

	if count == 0 then
		return nil
	end
	return out
end

--[=[
	Normalises launchData to a string and enforces the 200-byte platform cap
	(RESEARCH.md §2) at author time rather than letting the API reject it.
]=]
function Util.encodeLaunchData(launchData, errorLevel: number?): string?
	if launchData == nil then
		return nil
	end

	local level = errorLevel or 3
	local encoded

	if type(launchData) == "string" then
		encoded = launchData
	elseif type(launchData) == "table" then
		local ok, result = pcall(function()
			return HttpService:JSONEncode(launchData)
		end)
		if not ok then
			error("[BetterNotifications] launchData could not be JSON-encoded: " .. tostring(result), level)
		end
		encoded = result
	else
		error("[BetterNotifications] `launchData` must be a string or table, got " .. typeof(launchData), level)
	end

	if #encoded > Config.MaxLaunchDataBytes then
		error(
			("[BetterNotifications] launchData is %d bytes, over the %d-byte platform limit: %s"):format(
				#encoded,
				Config.MaxLaunchDataBytes,
				encoded
			),
			level
		)
	end

	return encoded
end

return Util
