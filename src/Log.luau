--!nonstrict
--[[
	Log — leveled structured logging.

	Usage:
		Log.info("send.ok", { userId = 123, status = 200 })
		-> [BetterNotifications][info] send.ok status=200 userId=123

	Fields are sorted by key so log lines for the same event are diffable.
]]

local Config = require(script.Parent.Config)

local Log = {}

local LEVELS = {
	error = 1,
	warn = 2,
	info = 3,
	debug = 4,
}

local PREFIX = "[BetterNotifications]"

local currentLevel = LEVELS[Config.LogLevel] or LEVELS.info

function Log.setLevel(level: string)
	local resolved = LEVELS[level]
	if not resolved then
		error(
			("[BetterNotifications] unknown log level %q (expected error/warn/info/debug)"):format(
				tostring(level)
			),
			2
		)
	end
	currentLevel = resolved
end

function Log.getLevel(): string
	for name, value in LEVELS do
		if value == currentLevel then
			return name
		end
	end
	return "info"
end

local function stringifyValue(value: any): string
	local kind = typeof(value)
	if kind == "string" then
		-- Quote only when the value would otherwise break key=value parsing.
		if value:find("[%s=]") then
			return ("%q"):format(value)
		end
		return value
	elseif kind == "number" then
		if value % 1 == 0 then
			return ("%d"):format(value)
		end
		return ("%.3f"):format(value)
	elseif kind == "Instance" then
		return value.Name
	end
	return tostring(value)
end

local function compose(level: string, event: string, fields: { [string]: any }?): string
	local line = ("%s[%s] %s"):format(PREFIX, level, event)
	if not fields then
		return line
	end

	local keys = {}
	for key in fields do
		table.insert(keys, key)
	end
	table.sort(keys)

	local parts = table.create(#keys)
	for _, key in keys do
		table.insert(parts, ("%s=%s"):format(key, stringifyValue(fields[key])))
	end

	if #parts == 0 then
		return line
	end
	return line .. " " .. table.concat(parts, " ")
end

local function emit(level: string, event: string, fields: { [string]: any }?)
	if LEVELS[level] > currentLevel then
		return
	end
	local line = compose(level, event, fields)
	if level == "error" or level == "warn" then
		warn(line)
	else
		print(line)
	end
end

function Log.error(event: string, fields: { [string]: any }?)
	emit("error", event, fields)
end

function Log.warn(event: string, fields: { [string]: any }?)
	emit("warn", event, fields)
end

function Log.info(event: string, fields: { [string]: any }?)
	emit("info", event, fields)
end

function Log.debug(event: string, fields: { [string]: any }?)
	emit("debug", event, fields)
end

-- Bypasses the level filter. Used by Config.Diagnostics so the raw sample is
-- visible even at LogLevel = "error".
function Log.diagnostic(event: string, fields: { [string]: any }?)
	warn(compose("diag", event, fields))
end

return Log
