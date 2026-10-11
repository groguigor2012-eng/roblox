--!strict
-- Structured logging: "[Platformer/<Scope>] <Event> key=value ...".
-- Debug lines print only with GameConfig.Debug.VerboseLogging, so expected
-- gameplay events (duplicate pickups, cooldown rejections) stay quiet.

local GameConfig = require(script.Parent.Parent.Config.GameConfig)

local Logger = {}
Logger.__index = Logger

type Fields = { _prefix: string }
export type Logger = typeof(setmetatable({} :: Fields, Logger))

function Logger.new(scope: string): Logger
	return setmetatable({ _prefix = `[Platformer/{scope}]` }, Logger)
end

local function formatFields(fields: { [string]: any }?): string
	if not fields then
		return ""
	end
	local keys = {}
	for key in fields do
		table.insert(keys, key)
	end
	table.sort(keys)
	local parts = table.create(#keys)
	for _, key in keys do
		local value = fields[key]
		if typeof(value) == "Instance" then
			value = (value :: Instance):GetFullName()
		end
		table.insert(parts, `{key}={tostring(value)}`)
	end
	return " " .. table.concat(parts, " ")
end

function Logger.Format(self: Logger, event: string, fields: { [string]: any }?): string
	return `{self._prefix} {event}{formatFields(fields)}`
end

function Logger.Debug(self: Logger, event: string, fields: { [string]: any }?)
	if GameConfig.Debug.VerboseLogging then
		print(self:Format(event, fields))
	end
end

function Logger.Info(self: Logger, event: string, fields: { [string]: any }?)
	print(self:Format(event, fields))
end

function Logger.Warn(self: Logger, event: string, fields: { [string]: any }?)
	warn(self:Format(event, fields))
end

-- Logs an error without throwing (the caller decides how to fail).
function Logger.Error(self: Logger, event: string, fields: { [string]: any }?)
	warn("ERROR " .. self:Format(event, fields))
end

return Logger
