--!strict
--[[
	Validate
	Path: ReplicatedStorage.Shared.Utilities.Validate

	Payload validation for everything that crosses the network. Each remote in
	NetworkConfig declares an argument schema; RemoteService runs CheckArgs before a
	handler ever sees the data, so handlers can rely on types and ranges.

	Schema entry kinds:
		{ Kind = "string",  MaxLength = n, Pattern = luaPattern? }
		{ Kind = "integer", Min = n, Max = n }
		{ Kind = "number",  Min = n, Max = n }        -- always rejects NaN / inf
		{ Kind = "boolean" }
		{ Kind = "Vector3", MaxMagnitude = n }        -- rejects NaN / inf components
		{ Kind = "enum",    Values = { string } }
		Optional = true on any entry allows nil.

	Dependencies: none.

	API:
		IsFiniteNumber(value) -> boolean
		IsFiniteVector3(value) -> boolean
		CheckValue(value, rule) -> (boolean, string?)
		CheckArgs(args, argCount, schema) -> (boolean, string?)
]]

export type Rule = {
	Kind: string,
	Optional: boolean?,
	MaxLength: number?,
	Pattern: string?,
	Min: number?,
	Max: number?,
	MaxMagnitude: number?,
	Values: { string }?,
}

local Validate = {}

function Validate.IsFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Validate.IsFiniteVector3(value: any): boolean
	return typeof(value) == "Vector3"
		and Validate.IsFiniteNumber(value.X)
		and Validate.IsFiniteNumber(value.Y)
		and Validate.IsFiniteNumber(value.Z)
end

local function checkRange(value: number, rule: Rule): (boolean, string?)
	if rule.Min ~= nil and value < rule.Min then
		return false, "below minimum"
	end
	if rule.Max ~= nil and value > rule.Max then
		return false, "above maximum"
	end
	return true, nil
end

function Validate.CheckValue(value: any, rule: Rule): (boolean, string?)
	if value == nil then
		if rule.Optional then
			return true, nil
		end
		return false, "missing value"
	end

	local kind = rule.Kind
	if kind == "string" then
		if type(value) ~= "string" then
			return false, "expected string"
		end
		if #value == 0 then
			return false, "empty string"
		end
		if rule.MaxLength and #value > rule.MaxLength then
			return false, "string too long"
		end
		if rule.Pattern and not string.match(value, rule.Pattern) then
			return false, "string format"
		end
		return true, nil
	elseif kind == "integer" then
		if not Validate.IsFiniteNumber(value) or value % 1 ~= 0 then
			return false, "expected integer"
		end
		return checkRange(value, rule)
	elseif kind == "number" then
		if not Validate.IsFiniteNumber(value) then
			return false, "expected finite number"
		end
		return checkRange(value, rule)
	elseif kind == "boolean" then
		if type(value) ~= "boolean" then
			return false, "expected boolean"
		end
		return true, nil
	elseif kind == "Vector3" then
		if not Validate.IsFiniteVector3(value) then
			return false, "expected finite Vector3"
		end
		if rule.MaxMagnitude and (value :: Vector3).Magnitude > rule.MaxMagnitude then
			return false, "vector too large"
		end
		return true, nil
	elseif kind == "enum" then
		if type(value) ~= "string" or rule.Values == nil or table.find(rule.Values, value) == nil then
			return false, "unknown enum value"
		end
		return true, nil
	end

	return false, `unknown rule kind {kind}`
end

-- `argCount` is select("#", ...) of the received payload, which catches extra
-- trailing arguments that a plain table length would miss.
function Validate.CheckArgs(args: { any }, argCount: number, schema: { Rule }): (boolean, string?)
	if argCount > #schema then
		return false, "too many arguments"
	end
	for index, rule in schema do
		local ok, reason = Validate.CheckValue(args[index], rule)
		if not ok then
			return false, `arg {index}: {reason}`
		end
	end
	return true, nil
end

return Validate
