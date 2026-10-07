--!strict
--[[
	Format
	Path: ReplicatedStorage.Shared.Utilities.Format

	Display formatting for UI text. Pure functions, no Roblox dependencies.

	API:
		Commas(number) -> string            -- 12345 -> "12,345"
		Countdown(seconds) -> string        -- 75 -> "1:15", 9 -> "0:09"
		Percent(fraction) -> string         -- 0.425 -> "43%"
		Multiplier(value) -> string         -- 1.5 -> "x1.50"
		Roman(n) -> string                  -- 4 -> "IV" (danger levels)
]]

local Format = {}

function Format.Commas(value: number): string
	local rounded = math.floor(value + 0.5)
	local negative = rounded < 0
	local digits = tostring(math.abs(rounded))
	local formatted = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if formatted:sub(1, 1) == "," then
		formatted = formatted:sub(2)
	end
	return if negative then "-" .. formatted else formatted
end

function Format.Countdown(seconds: number): string
	local total = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", total // 60, total % 60)
end

function Format.Percent(fraction: number): string
	return string.format("%d%%", math.floor(math.clamp(fraction, 0, 1) * 100 + 0.5))
end

function Format.Multiplier(value: number): string
	return string.format("x%.2f", value)
end

local ROMAN = {
	{ 1000, "M" }, { 900, "CM" }, { 500, "D" }, { 400, "CD" }, { 100, "C" }, { 90, "XC" },
	{ 50, "L" }, { 40, "XL" }, { 10, "X" }, { 9, "IX" }, { 5, "V" }, { 4, "IV" }, { 1, "I" },
}

function Format.Roman(n: number): string
	local remaining = math.max(0, math.floor(n))
	if remaining == 0 then
		return "0"
	end
	local parts = {}
	for _, pair in ROMAN do
		local value, numeral = pair[1] :: number, pair[2] :: string
		while remaining >= value do
			table.insert(parts, numeral)
			remaining -= value
		end
	end
	return table.concat(parts)
end

return Format
