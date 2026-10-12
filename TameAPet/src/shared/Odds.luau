--!strict
-- Exact odds for weighted reward pools.
--
-- Definition used everywhere in the game: the odds of a species are the odds of getting it
-- from ONE egg of the tier it hatched from, i.e. weight / sum(weights) of that tier's pool.
-- The "1 in N" denominator is sum / weight. When N is not a whole number it is shown with
-- up to two decimals instead of being rounded to a misleading integer.

local WeightedRandom = require(script.Parent.WeightedRandom)
local Format = require(script.Parent.Format)

local Odds = {}

function Odds.chance(pool: WeightedRandom.Pool, key: string): number?
	local weight = pool[key]
	local total = WeightedRandom.total(pool)
	if type(weight) ~= "number" or weight <= 0 or total <= 0 then
		return nil
	end
	return weight / total
end

function Odds.denominator(pool: WeightedRandom.Pool, key: string): number?
	local weight = pool[key]
	local total = WeightedRandom.total(pool)
	if type(weight) ~= "number" or weight <= 0 or total <= 0 then
		return nil
	end
	return total / weight
end

function Odds.formatDenominator(denominator: number): string
	if denominator <= 1.000001 then
		return "Guaranteed"
	end
	local rounded = math.floor(denominator + 0.5)
	if math.abs(denominator - rounded) < 1e-6 then
		return `1 in {Format.commas(rounded)}`
	end
	if denominator >= 1000 then
		-- Large non-integer denominators: keep it honest with a "~".
		return `~1 in {Format.commas(rounded)}`
	end
	return `1 in {Format.decimal(denominator, 2)}`
end

-- e.g. "1 in 50" or nil when the key is not in the pool.
function Odds.text(pool: WeightedRandom.Pool, key: string): string?
	local denominator = Odds.denominator(pool, key)
	if not denominator then
		return nil
	end
	return Odds.formatDenominator(denominator)
end

return Odds
