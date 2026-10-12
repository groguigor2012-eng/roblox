--!strict
-- Text formatting helpers shared by UI and billboards.

local Format = {}

-- 1234567 -> "1,234,567"
function Format.commas(value: number): string
	local negative = value < 0
	local whole = math.floor(math.abs(value) + 0.5)
	local text = tostring(whole)
	local formatted = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if formatted:sub(1, 1) == "," then
		formatted = formatted:sub(2)
	end
	return if negative then "-" .. formatted else formatted
end

-- Trims trailing zeros: 12.50 -> "12.5", 3.00 -> "3".
function Format.decimal(value: number, decimals: number): string
	local text = string.format(`%.{decimals}f`, value)
	if text:find("%.") then
		text = text:gsub("0+$", ""):gsub("%.$", "")
	end
	return text
end

-- 1500 -> "1.5k", 2300000 -> "2.3M"
function Format.compact(value: number): string
	local absValue = math.abs(value)
	if absValue >= 1e9 then
		return Format.decimal(value / 1e9, 1) .. "B"
	elseif absValue >= 1e6 then
		return Format.decimal(value / 1e6, 1) .. "M"
	elseif absValue >= 1e4 then
		return Format.decimal(value / 1e3, 1) .. "k"
	end
	return Format.commas(value)
end

function Format.distance(studs: number, compactOver: number, unit: string): string
	if studs >= compactOver then
		return `{Format.decimal(studs / 1000, 1)}k {unit}`
	end
	return `{math.floor(studs + 0.5)} {unit}`
end

function Format.speed(studsPerSecond: number): string
	return `{math.floor(studsPerSecond + 0.5)} studs/s`
end

return Format
