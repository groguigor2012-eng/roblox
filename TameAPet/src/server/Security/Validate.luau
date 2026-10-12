--!strict
-- Argument validators for remote handlers. Each validator takes the raw (untrusted) value
-- and returns (ok, cleanValue). Remote handlers only ever see clean values.

export type Validator = (any) -> (boolean, any)

local Validate = {}

local ID_PATTERN = "^[%w_%-]+$"

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

-- Identifier strings (pet ids are GUIDs, config ids are alphanumeric).
function Validate.id(maxLength: number?): Validator
	local limit = maxLength or 64
	return function(value)
		if type(value) ~= "string" or #value == 0 or #value > limit then
			return false, nil
		end
		if not value:match(ID_PATTERN) then
			return false, nil
		end
		return true, value
	end
end

-- Like id() but also accepts "" / nil, normalised to "" (used for "unequip").
function Validate.optionalId(maxLength: number?): Validator
	local inner = Validate.id(maxLength)
	return function(value)
		if value == nil or value == "" then
			return true, ""
		end
		return inner(value)
	end
end

function Validate.boolean(): Validator
	return function(value)
		if type(value) ~= "boolean" then
			return false, nil
		end
		return true, value
	end
end

-- Finite number clamped into [min, max]. Rejects NaN, inf and non-numbers.
function Validate.clampedNumber(min: number, max: number): Validator
	return function(value)
		if not isFinite(value) then
			return false, nil
		end
		return true, math.clamp(value, min, max)
	end
end

function Validate.oneOf(allowed: { [string]: any }): Validator
	return function(value)
		if type(value) ~= "string" or allowed[value] == nil then
			return false, nil
		end
		return true, value
	end
end

Validate.isFinite = isFinite

return Validate
